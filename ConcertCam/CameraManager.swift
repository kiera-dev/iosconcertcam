import AVFoundation
import Photos
import UIKit

/// How the microphone signal is captured.
enum AudioMode: String, CaseIterable, Identifiable {
    /// Stereo capture with audio zoom and wind-noise removal disabled.
    /// Sounds like the stock camera, minus the zoom/wind processing.
    case stereo = "Stereo"
    /// Mono capture through an AVAudioSession in `.measurement` mode, which
    /// bypasses Apple's software processing chain (auto gain, EQ, limiting).
    /// The most faithful option at very loud shows.
    case raw = "Raw"

    var id: String { rawValue }

    var footnote: String {
        switch self {
        case .stereo: return "Stereo · audio zoom off · wind removal off"
        case .raw: return "Mono · system audio processing bypassed"
        }
    }
}

struct VideoQuality: Equatable, Identifiable {
    let width: Int32
    let height: Int32
    let fps: Int

    var id: String { "\(width)x\(height)@\(fps)" }
    var label: String { "\(height == 2160 ? "4K" : "1080p") · \(fps)" }

    static let candidates: [VideoQuality] = [
        VideoQuality(width: 1920, height: 1080, fps: 30),
        VideoQuality(width: 1920, height: 1080, fps: 60),
        VideoQuality(width: 3840, height: 2160, fps: 30),
        VideoQuality(width: 3840, height: 2160, fps: 60),
    ]
}

struct ZoomPreset: Equatable, Identifiable {
    let factor: CGFloat
    let label: String
    var id: CGFloat { factor }
}

// @unchecked Sendable: all mutable state is confined to sessionQueue or the
// main queue; @Published properties are only written via DispatchQueue.main.
final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {
    @Published var isAuthorized = false
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingSeconds = 0
    @Published var zoomFactor: CGFloat = 1.0
    @Published var maxZoom: CGFloat = 1.0
    @Published var zoomPresets: [ZoomPreset] = []
    @Published var audioMode: AudioMode = .stereo
    @Published var qualityOptions: [VideoQuality] = []
    @Published var quality: VideoQuality?
    @Published var isNightModeOn = false
    @Published var isNightModeSupported = false
    @Published var statusMessage: String?
    /// Microphone input level, 0...1 (mapped from -50...0 dBFS).
    @Published var audioLevel: Float = 0

    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()

    private let sessionQueue = DispatchQueue(label: "concertcam.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoDevice: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var recordingTimer: Timer?
    private var levelTimer: Timer?
    /// Accessed on sessionQueue only.
    private var activeQuality: VideoQuality?

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        if let saved = UserDefaults.standard.string(forKey: "audioMode"),
           let mode = AudioMode(rawValue: saved) {
            audioMode = mode
        }
    }

    // MARK: - Setup

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { cameraOK in
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                DispatchQueue.main.async { self.isAuthorized = cameraOK && micOK }
                guard cameraOK && micOK else { return }
                self.sessionQueue.async { self.configureSession() }
            }
        }
    }

    private func bestBackCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] =
            [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .back)
            .devices.first
    }

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .high

        guard let camera = bestBackCamera(),
              let cameraInput = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(cameraInput) else {
            session.commitConfiguration()
            report("No usable camera found.")
            return
        }
        session.addInput(cameraInput)
        videoDevice = camera

        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
            audioInput = micInput
        } else {
            report("No microphone available.")
        }

        if session.canAddOutput(movieOutput) {
            session.addOutput(movieOutput)
        }

        applyAudioMode(audioMode)

        let options = VideoQuality.candidates.filter { selectFormat(for: $0) != nil }
        let savedID = UserDefaults.standard.string(forKey: "videoQuality")
        let selected = options.first { $0.id == savedID }
            ?? options.first { $0.id == "1920x1080@30" }
            ?? options.first
        DispatchQueue.main.async {
            self.qualityOptions = options
            self.quality = selected
        }
        if let selected { applyQuality(selected) }

        session.commitConfiguration()

        refreshZoomCaps()
        setUpRotationCoordinator(for: camera)
        session.startRunning()
        startLevelMetering()
    }

    /// Polls the movie output's audio channels so the UI can show a live mic
    /// meter — the practical way to spot a covered mic port or clipping.
    private func startLevelMetering() {
        DispatchQueue.main.async {
            self.levelTimer?.invalidate()
            self.levelTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self else { return }
                let channels = self.movieOutput.connection(with: .audio)?.audioChannels ?? []
                let peakDb = channels.map(\.averagePowerLevel).max() ?? -160
                self.audioLevel = max(0, min(1, (peakDb + 50) / 50))
            }
        }
    }

    // MARK: - Audio configuration

    func setAudioMode(_ mode: AudioMode) {
        guard !isRecording else { return }
        audioMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "audioMode")
        // Restart the session around the switch: changing the AVAudioSession
        // category/mode under a running capture session can silently kill
        // audio capture, and automaticallyConfiguresApplicationAudioSession
        // only takes effect on session start.
        sessionQueue.async {
            let wasRunning = self.session.isRunning
            if wasRunning { self.session.stopRunning() }
            self.session.beginConfiguration()
            self.applyAudioMode(mode)
            self.session.commitConfiguration()
            if wasRunning { self.session.startRunning() }
        }
    }

    /// Must be called between beginConfiguration/commitConfiguration.
    private func applyAudioMode(_ mode: AudioMode) {
        guard let audioInput else { return }

        switch mode {
        case .stereo:
            // Undo a previous Raw configuration so the capture session can
            // reclaim control of the audio session.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            session.automaticallyConfiguresApplicationAudioSession = true
            if audioInput.isMultichannelAudioModeSupported(.stereo) {
                audioInput.multichannelAudioMode = .stereo
            }
            if audioInput.isWindNoiseRemovalSupported {
                audioInput.isWindNoiseRemovalEnabled = false
            }
            if #available(iOS 26.4, *), audioInput.isAudioZoomSupported {
                audioInput.isAudioZoomEnabled = false
            }
        case .raw:
            // Audio zoom, wind removal, and stereo rendering only apply when
            // multichannelAudioMode != .none, so mono capture sidesteps them all.
            audioInput.multichannelAudioMode = .none
            session.automaticallyConfiguresApplicationAudioSession = false
            let audioSession = AVAudioSession.sharedInstance()
            do {
                try audioSession.setCategory(.playAndRecord, mode: .measurement)
                try audioSession.setActive(true)
            } catch {
                report("Couldn't switch to raw audio: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Video quality

    func setQuality(_ newQuality: VideoQuality) {
        guard !isRecording else { return }
        quality = newQuality
        UserDefaults.standard.set(newQuality.id, forKey: "videoQuality")
        sessionQueue.async {
            self.applyQuality(newQuality)
            self.refreshZoomCaps()
        }
    }

    private func selectFormat(for quality: VideoQuality) -> AVCaptureDevice.Format? {
        guard let device = videoDevice else { return nil }
        let matches = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == quality.width && dims.height == quality.height else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(quality.fps) && Double(quality.fps) <= $0.maxFrameRate
            }
        }
        // Prefer a format that can do low-light auto frame rate (night mode).
        return matches.first { $0.isAutoVideoFrameRateSupported } ?? matches.first
    }

    private func applyQuality(_ quality: VideoQuality) {
        guard let device = videoDevice, let format = selectFormat(for: quality) else { return }
        session.beginConfiguration()
        do {
            try device.lockForConfiguration()
            device.activeFormat = format
            let duration = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            report("Couldn't apply \(quality.label): \(error.localizedDescription)")
        }
        session.commitConfiguration()
        activeQuality = quality

        // Auto frame rate resets when the format changes.
        let nightSupported = format.isAutoVideoFrameRateSupported
        DispatchQueue.main.async {
            self.isNightModeSupported = nightSupported
            self.isNightModeOn = false
        }
    }

    // MARK: - Night mode (low-light auto frame rate)

    func setNightMode(_ on: Bool) {
        guard !isRecording else { return }
        sessionQueue.async {
            guard let device = self.videoDevice,
                  device.activeFormat.isAutoVideoFrameRateSupported else { return }
            do {
                try device.lockForConfiguration()
                if on {
                    // Auto frame rate requires default frame durations.
                    device.activeVideoMinFrameDuration = .invalid
                    device.activeVideoMaxFrameDuration = .invalid
                    device.isAutoVideoFrameRateEnabled = true
                } else {
                    device.isAutoVideoFrameRateEnabled = false
                    if let quality = self.activeQuality {
                        let duration = CMTime(value: 1, timescale: CMTimeScale(quality.fps))
                        device.activeVideoMinFrameDuration = duration
                        device.activeVideoMaxFrameDuration = duration
                    }
                }
                device.unlockForConfiguration()
                DispatchQueue.main.async { self.isNightModeOn = on }
            } catch {}
        }
    }

    // MARK: - Rotation

    private func setUpRotationCoordinator(for device: AVCaptureDevice) {
        DispatchQueue.main.async {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: self.previewLayer)
            self.rotationCoordinator = coordinator
            self.previewLayer.connection?.videoRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            self.rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, change in
                guard let self, let angle = change.newValue else { return }
                self.previewLayer.connection?.videoRotationAngle = angle
            }
        }
    }

    // MARK: - Focus & exposure

    func focusAndExpose(atLayerPoint point: CGPoint) {
        let devicePoint = previewLayer.captureDevicePointConverted(fromLayerPoint: point)
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                }
                if device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                }
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Zoom

    private func refreshZoomCaps() {
        guard let device = videoDevice else { return }
        let multiplier = device.displayVideoZoomFactorMultiplier
        let maxUseful = min(device.activeFormat.videoMaxZoomFactor, 16)

        var factors: [CGFloat] = [1.0]
        factors += device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        // Add a displayed-2x digital preset if no lens lands there (stock camera does this).
        let twoX = 2.0 / multiplier
        if twoX <= maxUseful && !factors.contains(where: { abs($0 * multiplier - 2.0) < 0.01 }) {
            factors.append(twoX)
        }

        let presets = factors.filter { $0 <= maxUseful }.sorted().map { factor -> ZoomPreset in
            let display = factor * multiplier
            let label: String
            if abs(display.rounded() - display) < 0.01 {
                label = "\(Int(display.rounded()))x"
            } else {
                label = String(format: "%.1fx", display)
            }
            return ZoomPreset(factor: factor, label: label)
        }

        DispatchQueue.main.async {
            self.maxZoom = maxUseful
            self.zoomPresets = presets
            self.zoomFactor = min(max(self.zoomFactor, 1), maxUseful)
        }
    }

    /// Immediate zoom, for pinch gestures.
    func setZoom(_ factor: CGFloat) {
        let clamped = min(max(factor, 1), maxZoom)
        zoomFactor = clamped
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = max(device.minAvailableVideoZoomFactor,
                                             min(clamped, device.maxAvailableVideoZoomFactor))
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Smooth ramp, for preset buttons.
    func selectZoomPreset(_ preset: ZoomPreset) {
        zoomFactor = preset.factor
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: preset.factor, withRate: 8)
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture
        sessionQueue.async {
            guard !self.movieOutput.isRecording else { return }
            if let connection = self.movieOutput.connection(with: .video) {
                if let angle, connection.isVideoRotationAngleSupported(angle) {
                    connection.videoRotationAngle = angle
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("concert-\(Date().timeIntervalSince1970).mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func stopRecording() {
        sessionQueue.async {
            guard self.movieOutput.isRecording else { return }
            self.movieOutput.stopRecording()
        }
    }

    func togglePause() {
        sessionQueue.async {
            guard self.movieOutput.isRecording else { return }
            if self.movieOutput.isRecordingPaused {
                self.movieOutput.resumeRecording()
            } else {
                self.movieOutput.pauseRecording()
            }
        }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async {
            self.statusMessage = message
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if self.statusMessage == message { self.statusMessage = nil }
            }
        }
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingSeconds = 0
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, !self.isPaused else { return }
                self.recordingSeconds += 1
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didPauseRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.isPaused = true }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didResumeRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async { self.isPaused = false }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.isPaused = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
        }
        if let error, !FileManager.default.fileExists(atPath: outputFileURL.path) {
            report("Recording failed: \(error.localizedDescription)")
            return
        }
        saveToPhotos(outputFileURL)
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.report("Photos access denied — video left in app sandbox.")
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                try? FileManager.default.removeItem(at: url)
                self.report(success ? "Saved to Photos ✓"
                                    : "Save failed: \(error?.localizedDescription ?? "unknown")")
            }
        }
    }
}
