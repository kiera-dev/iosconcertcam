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
    /// Stereo with audio zoom and wind removal deliberately ON: the beam
    /// narrows toward whatever the camera is pointed at, attenuating nearby
    /// crowd noise (and off-key neighbors).
    case audioZoom = "AudioZoom"

    var id: String { rawValue }
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

/// Which physical built-in mic Raw mode records from. The back mic (on the
/// camera bump) faces the stage while the phone body shadows the crowd.
enum RawMic: String, CaseIterable, Identifiable {
    case bottom = "Bottom"
    case front = "Front"
    case back = "Back"

    var id: String { rawValue }

    var orientation: AVAudioSession.Orientation {
        switch self {
        case .bottom: return .bottom
        case .front: return .front
        case .back: return .back
        }
    }
}

/// Steadier modes crop more of the frame and add a little preview latency.
enum StabilizationMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case standard = "Standard"
    case cinematic = "Cinematic"
    case extended = "Extended"

    var id: String { rawValue }

    var avMode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: return .off
        case .standard: return .standard
        case .cinematic: return .cinematic
        case .extended: return .cinematicExtended
        }
    }
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
    /// Wind-noise removal (Stereo mode only — requires multichannel audio).
    @Published var isWindRemovalOn = false
    @Published var rawMic: RawMic = .bottom
    @Published var rawMicOptions: [RawMic] = []
    @Published var stabilization: StabilizationMode = .standard
    @Published var stabilizationOptions: [StabilizationMode] = []

    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()

    private let sessionQueue = DispatchQueue(label: "concertcam.session")
    private let levelQueue = DispatchQueue(label: "concertcam.audiolevel")
    private let movieOutput = AVCaptureMovieFileOutput()
    private let audioLevelOutput = AVCaptureAudioDataOutput()
    private var lastLevelPublish: CFTimeInterval = 0
    private var videoDevice: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var recordingTimer: Timer?
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
        isWindRemovalOn = UserDefaults.standard.bool(forKey: "windRemoval")
        if let saved = UserDefaults.standard.string(forKey: "stabilization"),
           let mode = StabilizationMode(rawValue: saved) {
            stabilization = mode
        }
        if let saved = UserDefaults.standard.string(forKey: "rawMic"),
           let mic = RawMic(rawValue: saved) {
            rawMic = mic
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

        // Movie output audio channels never update their power levels on
        // iOS, so meter from the raw sample buffers instead.
        if session.canAddOutput(audioLevelOutput) {
            session.addOutput(audioLevelOutput)
            audioLevelOutput.setSampleBufferDelegate(self, queue: levelQueue)
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
        refreshStabilizationOptions()
        setUpRotationCoordinator(for: camera)
        session.startRunning()
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
        case .stereo, .audioZoom:
            // Undo a previous Raw configuration so the capture session can
            // reclaim control of the audio session.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            session.automaticallyConfiguresApplicationAudioSession = true
            if audioInput.isMultichannelAudioModeSupported(.stereo) {
                audioInput.multichannelAudioMode = .stereo
            }
            if audioInput.isWindNoiseRemovalSupported {
                audioInput.isWindNoiseRemovalEnabled = mode == .audioZoom || isWindRemovalOn
            }
            if #available(iOS 26.4, *), audioInput.isAudioZoomSupported {
                audioInput.isAudioZoomEnabled = mode == .audioZoom
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
            refreshRawMicOptions()
            applyRawMicSelection()
        }
    }

    // MARK: - Raw mic selection

    func setRawMic(_ mic: RawMic) {
        guard !isRecording else { return }
        rawMic = mic
        UserDefaults.standard.set(mic.rawValue, forKey: "rawMic")
        sessionQueue.async { self.applyRawMicSelection() }
    }

    private func builtInMicPort() -> AVAudioSessionPortDescription? {
        AVAudioSession.sharedInstance().availableInputs?
            .first { $0.portType == .builtInMic }
    }

    private func refreshRawMicOptions() {
        let sources = builtInMicPort()?.dataSources ?? []
        let options = RawMic.allCases.filter { mic in
            sources.contains { $0.orientation == mic.orientation }
        }
        DispatchQueue.main.async {
            self.rawMicOptions = options
            if let first = options.first, !options.contains(self.rawMic) {
                self.rawMic = first
            }
        }
    }

    /// Routes Raw mode to the chosen physical mic; requests a cardioid
    /// (directional) pickup pattern when the hardware offers one.
    private func applyRawMicSelection() {
        guard audioMode == .raw, let port = builtInMicPort() else { return }
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setPreferredInput(port)
        guard let source = port.dataSources?
            .first(where: { $0.orientation == rawMic.orientation }) else { return }
        if let patterns = source.supportedPolarPatterns, patterns.contains(.cardioid) {
            try? source.setPreferredPolarPattern(.cardioid)
        }
        try? port.setPreferredDataSource(source)
    }

    // MARK: - Stabilization

    func setStabilization(_ mode: StabilizationMode) {
        guard !isRecording else { return }
        stabilization = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "stabilization")
    }

    /// Recomputes which stabilization modes the active format supports.
    private func refreshStabilizationOptions() {
        guard let format = videoDevice?.activeFormat else { return }
        let options = StabilizationMode.allCases.filter {
            $0 == .off || format.isVideoStabilizationModeSupported($0.avMode)
        }
        DispatchQueue.main.async {
            self.stabilizationOptions = options
            if !options.contains(self.stabilization) {
                self.stabilization = options.contains(.standard) ? .standard : .off
            }
        }
    }

    func setWindRemoval(_ on: Bool) {
        isWindRemovalOn = on
        UserDefaults.standard.set(on, forKey: "windRemoval")
        sessionQueue.async {
            guard let audioInput = self.audioInput,
                  audioInput.isWindNoiseRemovalSupported,
                  audioInput.multichannelAudioMode != .none else { return }
            self.session.beginConfiguration()
            audioInput.isWindNoiseRemovalEnabled = on
            self.session.commitConfiguration()
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
            self.refreshStabilizationOptions()
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
                    connection.preferredVideoStabilizationMode = self.stabilization.avMode
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

extension CameraManager: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let data = dataPointer, totalLength > 0 else { return }

        var sumOfSquares = 0.0
        var sampleCount = 0
        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 && asbd.mBitsPerChannel == 32 {
            sampleCount = totalLength / MemoryLayout<Float32>.size
            data.withMemoryRebound(to: Float32.self, capacity: sampleCount) { samples in
                for i in 0..<sampleCount {
                    let v = Double(samples[i])
                    sumOfSquares += v * v
                }
            }
        } else if asbd.mBitsPerChannel == 16 {
            sampleCount = totalLength / MemoryLayout<Int16>.size
            data.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                for i in 0..<sampleCount {
                    let v = Double(samples[i]) / 32768.0
                    sumOfSquares += v * v
                }
            }
        }
        guard sampleCount > 0 else { return }

        let rms = (sumOfSquares / Double(sampleCount)).squareRoot()
        let db = 20 * log10(max(rms, 1e-8))
        let normalized = Float(max(0, min(1, (db + 50) / 50)))

        let now = CACurrentMediaTime()
        guard now - lastLevelPublish > 0.08 else { return }
        lastLevelPublish = now
        DispatchQueue.main.async { self.audioLevel = normalized }
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
