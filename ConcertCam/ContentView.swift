import SwiftUI
import AVFoundation

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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                CameraPreview(layer: camera.previewLayer)
                    .ignoresSafeArea()
            } else {
                Text("Camera and microphone access are required.\nEnable them in Settings.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding()
            }

            VStack {
                topBar
                Spacer()
                bottomControls
            }
        }
        .statusBarHidden()
        .onAppear { camera.start() }
    }

    private var topBar: some View {
        VStack(spacing: 6) {
            if camera.isRecording {
                Label(timeString(camera.recordingSeconds), systemImage: "record.circle")
                    .font(.system(.headline, design: .monospaced))
                    .foregroundStyle(.red)
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
                .frame(maxWidth: 240)

                Text(camera.audioMode.footnote)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.5), in: Capsule())
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

    private var bottomControls: some View {
        VStack(spacing: 16) {
            if camera.maxZoom > 1 {
                Slider(value: Binding(
                    get: { camera.zoomFactor },
                    set: { camera.setZoom($0) }
                ), in: 1...camera.maxZoom)
                .frame(maxWidth: 260)
                .tint(.white)
            }

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
        }
        .padding(.bottom, 24)
    }

    private func timeString(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
