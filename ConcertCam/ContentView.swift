import SwiftUI
import AVFoundation
import CoreMotion

/// Publishes how many degrees the phone is rolled away from level
/// (nil when tilted too far for the indicator to be useful).
final class HorizonLevel: ObservableObject {
    @Published var deviation: Double?
    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30.0
        motion.startDeviceMotionUpdates(to: .main) { [weak self] deviceMotion, _ in
            guard let gravity = deviceMotion?.gravity else { return }
            // Roll of the screen plane relative to gravity, folded to the
            // nearest 90° so it works in both portrait and landscape grips.
            let roll = atan2(gravity.x, gravity.y) * 180 / .pi + 180
            let deviation = roll - (roll / 90).rounded() * 90
            self?.deviation = abs(deviation) <= 12 ? deviation : nil
        }
    }

    func stop() { motion.stopDeviceMotionUpdates() }
}

struct CameraPreview: UIViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    final class PreviewUIView: UIView {
        let previewLayer: AVCaptureVideoPreviewLayer
        init(previewLayer: AVCaptureVideoPreviewLayer) {
            self.previewLayer = previewLayer
            super.init(frame: .zero)
            self.layer.addSublayer(previewLayer)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer.frame = bounds
        }
    }

    func makeUIView(context: Context) -> PreviewUIView {
        PreviewUIView(previewLayer: layer)
    }
    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var focusPoint: CGPoint?
    @State private var focusBoxVisible = false
    @State private var pinchBaseZoom: CGFloat?
    @State private var iconRotation: Angle = .zero
    @State private var deviceIsLandscape = false
    @StateObject private var horizon = HorizonLevel()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                CameraPreview(layer: camera.previewLayer)
                    .ignoresSafeArea()
                    .gesture(pinchToZoom)
                    .onTapGesture(count: 1, coordinateSpace: .local) { location in
                        camera.focusAndExpose(atLayerPoint: location)
                        showFocusBox(at: location)
                    }
            } else {
                Text("Camera and microphone access are required.\nEnable them in Settings.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding()
            }

            if camera.isAuthorized, let deviation = horizon.deviation {
                // Follow the device like the icons do, so the line tracks the
                // real-world horizon in landscape grips too.
                horizonLine(deviation: deviation)
                    .rotationEffect(iconRotation)
            }

            if let point = focusPoint, focusBoxVisible {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.yellow, lineWidth: 1.5)
                    .frame(width: 72, height: 72)
                    .position(point)
                    .transition(.scale(scale: 1.4).combined(with: .opacity))
                    .allowsHitTesting(false)
            }

            VStack {
                topBar
                Spacer()
                bottomControls
            }
        }
        .statusBarHidden()
        .onAppear {
            camera.start()
            horizon.start()
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        }
        // The UI is portrait-locked (like the stock camera); circular controls
        // rotate in place to follow the device instead.
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let angle: Angle?
            switch UIDevice.current.orientation {
            case .portrait: angle = .zero
            case .landscapeLeft: angle = .degrees(90)
            case .landscapeRight: angle = .degrees(-90)
            case .portraitUpsideDown: angle = .degrees(180)
            default: angle = nil // face up/down — keep current rotation
            }
            if let angle {
                withAnimation(.easeInOut(duration: 0.3)) {
                    iconRotation = angle
                    deviceIsLandscape = abs(angle.degrees) == 90
                }
            }
        }
    }

    // MARK: - Gestures

    private var pinchToZoom: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let base = pinchBaseZoom ?? camera.zoomFactor
                if pinchBaseZoom == nil { pinchBaseZoom = base }
                camera.setZoom(base * value)
            }
            .onEnded { _ in pinchBaseZoom = nil }
    }

    /// Stock-style level: fixed side ticks with a tilting center segment that
    /// snaps solid yellow when the phone is level.
    private func horizonLine(deviation: Double) -> some View {
        let isLevel = abs(deviation) < 1.5
        return ZStack {
            HStack {
                Rectangle().frame(width: 28, height: 1.5)
                Spacer()
                Rectangle().frame(width: 28, height: 1.5)
            }
            .frame(width: 200)
            .foregroundStyle(.white.opacity(isLevel ? 0 : 0.5))

            Rectangle()
                .frame(width: isLevel ? 200 : 110, height: 1.5)
                .foregroundStyle(isLevel ? .yellow : .white.opacity(0.85))
                .rotationEffect(.degrees(isLevel ? 0 : -deviation))
        }
        .animation(.easeOut(duration: 0.15), value: isLevel)
        .allowsHitTesting(false)
    }

    private func showFocusBox(at point: CGPoint) {
        focusPoint = point
        withAnimation(.easeOut(duration: 0.2)) { focusBoxVisible = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            withAnimation(.easeOut(duration: 0.3)) { focusBoxVisible = false }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                qualityMenu
                Spacer()
                stabilizationMenu
                windRemovalButton
                nightModeButton
            }
            .padding(.horizontal, 16)

            if camera.isRecording {
                Label(camera.isPaused ? "PAUSED · \(timeString(camera.recordingSeconds))"
                                      : timeString(camera.recordingSeconds),
                      systemImage: camera.isPaused ? "pause.circle" : "record.circle")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(camera.isPaused ? .yellow : .red)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
            } else {
                Picker("Audio", selection: Binding(
                    get: { camera.audioMode },
                    set: { camera.setAudioMode($0) }
                )) {
                    ForEach(AudioMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                Text(audioFootnote)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
            }

            if camera.isAuthorized {
                micMeter
            }

            if camera.isAuthorized && !deviceIsLandscape {
                Label("Rotate for YouTube", systemImage: "iphone.landscape")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(camera.isRecording ? .white : .white.opacity(0.9))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(camera.isRecording ? .red.opacity(0.85) : .black.opacity(0.5),
                                in: Capsule())
            }

            if let message = camera.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
            }
        }
        .padding(.top, 8)
    }

    /// Live mic level. If this stops moving — or drops when you grip the
    /// phone — a mic port is covered.
    private var micMeter: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.8))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule()
                        .fill(camera.audioLevel > 0.92 ? .red
                              : camera.audioLevel > 0.75 ? .yellow : .green)
                        .frame(width: geo.size.width * CGFloat(camera.audioLevel))
                        .animation(.linear(duration: 0.1), value: camera.audioLevel)
                }
            }
            .frame(width: 110, height: 4)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.5), in: Capsule())
    }

    private var qualityMenu: some View {
        Menu {
            ForEach(camera.qualityOptions) { option in
                Button {
                    camera.setQuality(option)
                } label: {
                    if option == camera.quality {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            Text(camera.quality?.label ?? "—")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
        }
        .disabled(camera.isRecording || camera.qualityOptions.isEmpty)
    }

    private var nightModeButton: some View {
        Button {
            camera.setNightMode(!camera.isNightModeOn)
        } label: {
            Image(systemName: camera.isNightModeOn ? "moon.stars.fill" : "moon.stars")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(camera.isNightModeOn ? .yellow : .white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.5), in: Circle())
        }
        .disabled(!camera.isNightModeSupported || camera.isRecording)
        .opacity(camera.isNightModeSupported ? 1 : 0.35)
        .rotationEffect(iconRotation)
    }

    private var stabilizationMenu: some View {
        Menu {
            ForEach(camera.stabilizationOptions) { option in
                Button {
                    camera.setStabilization(option)
                } label: {
                    if option == camera.stabilization {
                        Label(option.rawValue, systemImage: "checkmark")
                    } else {
                        Text(option.rawValue)
                    }
                }
            }
        } label: {
            Image(systemName: "gyroscope")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(camera.stabilization == .off ? .white : .green)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.5), in: Circle())
        }
        .disabled(camera.isRecording || camera.stabilizationOptions.isEmpty)
        .rotationEffect(iconRotation)
    }

    /// Wind-noise removal requires the multichannel audio path, so it's
    /// grayed out in Raw mode; AudioZoom mode locks it on.
    private var windRemovalButton: some View {
        let effectivelyOn = camera.audioMode == .audioZoom
            || (camera.audioMode == .stereo && camera.isWindRemovalOn)
        return Button {
            camera.setWindRemoval(!camera.isWindRemovalOn)
        } label: {
            Image(systemName: "wind")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(effectivelyOn ? .cyan : .white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.5), in: Circle())
        }
        .disabled(camera.audioMode != .stereo || camera.isRecording)
        .opacity(camera.audioMode == .raw ? 0.35 : 1)
        .rotationEffect(iconRotation)
    }

    private var audioFootnote: String {
        switch camera.audioMode {
        case .stereo:
            return "Stereo · audio zoom off · wind removal \(camera.isWindRemovalOn ? "ON" : "off")"
        case .raw:
            return "Mono · system audio processing bypassed"
        case .audioZoom:
            return "Stereo · beam follows your zoom · wind ON"
        }
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 16) {
            if camera.zoomPresets.count > 1 {
                HStack(spacing: 10) {
                    ForEach(camera.zoomPresets) { preset in
                        let isActive = preset == activePreset
                        Button {
                            camera.selectZoomPreset(preset)
                        } label: {
                            Text(preset.label)
                                .font(.system(size: isActive ? 14 : 12, weight: .bold, design: .rounded))
                                .foregroundStyle(isActive ? .yellow : .white)
                                .frame(width: isActive ? 40 : 34, height: isActive ? 40 : 34)
                                .background(.black.opacity(0.5), in: Circle())
                                .rotationEffect(iconRotation)
                        }
                    }
                }
                .animation(.easeOut(duration: 0.15), value: camera.zoomFactor)
            }

            ZStack {
                Button(action: camera.toggleRecording) {
                    ZStack {
                        Circle()
                            .strokeBorder(.white, lineWidth: 4)
                            .frame(width: 76, height: 76)
                        RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 32)
                            .fill(.red)
                            .frame(width: camera.isRecording ? 32 : 64,
                                   height: camera.isRecording ? 32 : 64)
                            .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
                    }
                }
                .disabled(!camera.isAuthorized)

                if camera.isRecording {
                    HStack {
                        Spacer()
                        Button(action: camera.togglePause) {
                            Image(systemName: camera.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(camera.isPaused ? .yellow : .white)
                                .frame(width: 54, height: 54)
                                .background(.black.opacity(0.5), in: Circle())
                        }
                        .rotationEffect(iconRotation)
                    }
                    .frame(width: 250)
                }
            }
        }
        .padding(.bottom, 24)
    }

    /// The preset whose range contains the current zoom factor.
    private var activePreset: ZoomPreset? {
        camera.zoomPresets.last { $0.factor <= camera.zoomFactor + 0.01 }
            ?? camera.zoomPresets.first
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
