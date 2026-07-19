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

// @unchecked Sendable: all mutable state is confined to sessionQueue or the
// main queue; @Published properties are only written via DispatchQueue.main.
final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {
    @Published var isAuthorized = false
    @Published var isRecording = false
    @Published var recordingSeconds = 0
    @Published var zoomFactor: CGFloat = 1.0
    @Published var maxZoom: CGFloat = 1.0
    @Published var audioMode: AudioMode = .stereo
    @Published var statusMessage: String?

    let session = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()

    private let sessionQueue = DispatchQueue(label: "concertcam.session")
    private let movieOutput = AVCaptureMovieFileOutput()
    private var videoDevice: AVCaptureDevice?
    private var audioInput: AVCaptureDeviceInput?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var recordingTimer: Timer?

    override init() {
        super.init()
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
    }

    // MARK: - Setup

    func start() {
        Task {
            let cameraOK = await AVCaptureDevice.requestAccess(for: .video)
            let micOK = await AVCaptureDevice.requestAccess(for: .audio)
            await MainActor.run { self.isAuthorized = cameraOK && micOK }
            guard cameraOK && micOK else { return }
            sessionQueue.async { self.configureSession() }
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
        session.commitConfiguration()

        let maxUseful = min(camera.activeFormat.videoMaxZoomFactor, 16)
        DispatchQueue.main.async { self.maxZoom = maxUseful }

        setUpRotationCoordinator(for: camera)
        session.startRunning()
    }

    // MARK: - Audio configuration

    func setAudioMode(_ mode: AudioMode) {
        guard !isRecording else { return }
        audioMode = mode
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

    // MARK: - Zoom

    func setZoom(_ factor: CGFloat) {
        zoomFactor = factor
        sessionQueue.async {
            guard let device = self.videoDevice else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = max(device.minAvailableVideoZoomFactor,
                                             min(factor, device.maxAvailableVideoZoomFactor))
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
                self?.recordingSeconds += 1
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
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
