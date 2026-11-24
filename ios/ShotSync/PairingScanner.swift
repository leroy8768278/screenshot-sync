import AVFoundation
import SwiftUI

struct PairingScanner: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var unavailable = false
    let manual: () -> Void
    let scanned: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if unavailable {
                    ContentUnavailableView("无法打开相机", systemImage: "camera",
                                           description: Text("点「手动配对」输入 Mac 地址和配对码。"))
                } else if permission == .authorized {
                    ZStack(alignment: .bottom) {
                        CameraPreview(scanned: scanned, failed: { unavailable = true })
                        Text("将 Mac 上的配对二维码对准镜头")
                            .padding()
                            .background(.regularMaterial, in: Capsule())
                            .padding()
                    }
                } else if permission == .notDetermined {
                    ProgressView("等待相机授权")
                } else {
                    ContentUnavailableView {
                        Label("需要相机权限", systemImage: "camera")
                    } description: {
                        Text("允许访问相机后即可扫码，也可以点「手动配对」输入 Mac 地址和配对码。")
                    } actions: {
                        if permission == .denied, let settings = URL(string: UIApplication.openSettingsURLString) {
                            Button("打开设置") { openURL(settings) }
                        }
                    }
                }
            }
            .navigationTitle("扫一扫")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("手动配对", action: manual)
                }
            }
            .task {
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                }
                permission = AVCaptureDevice.authorizationStatus(for: .video)
            }
            .onChange(of: phase) { _, value in
                if value == .active { permission = AVCaptureDevice.authorizationStatus(for: .video) }
            }
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let scanned: (String) -> Void
    let failed: () -> Void

    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var coordinator: AVCaptureDevice.RotationCoordinator?
        var rotation: NSKeyValueObservation?
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let queue = DispatchQueue(label: "local.shotsync.pairing-camera")
        let session = AVCaptureSession()
        private var active = true
        private let scanned: (String) -> Void
        private let failed: () -> Void

        init(scanned: @escaping (String) -> Void, failed: @escaping () -> Void) {
            self.scanned = scanned
            self.failed = failed
        }

        func start(with device: AVCaptureDevice?) {
            queue.async { [self] in
                guard let device, let input = try? AVCaptureDeviceInput(device: device),
                      session.canAddInput(input) else { reportFailure(); return }
                session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard session.canAddOutput(output) else { reportFailure(); return }
                session.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else { reportFailure(); return }
                output.metadataObjectTypes = [.qr]
                output.setMetadataObjectsDelegate(self, queue: .main)
                session.startRunning()
                if !session.isRunning { reportFailure() }
            }
        }

        private func reportFailure() {
            DispatchQueue.main.async { [self] in
                if active { failed() }
            }
        }

        func stop() {
            active = false
            queue.async { [session] in
                if session.isRunning { session.stopRunning() }
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard active, let qr = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                .first(where: { $0.type == .qr }), let text = qr.stringValue else { return }
            stop()
            scanned(text)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned, failed: failed) }

    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = context.coordinator.session
        let device = AVCaptureDevice.default(for: .video)
        if let device {
            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: view.previewLayer)
            view.coordinator = coordinator
            view.rotation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak view] rotation, _ in
                let angle = rotation.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async {
                    if let connection = view?.previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                }
            }
        }
        context.coordinator.start(with: device)
        return view
    }

    func updateUIView(_ uiView: Preview, context: Context) {}

    static func dismantleUIView(_ view: Preview, coordinator: Coordinator) {
        coordinator.stop()
        view.rotation = nil
    }
}
