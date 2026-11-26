import AVFoundation
import SwiftUI

struct PairingScanner: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var unavailable = false
    var currentMacName: String? = nil
    let manual: () -> Void
    let scanned: (String) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if unavailable {
                    ContentUnavailableView("无法打开相机", systemImage: "camera",
                                           description: Text("点「手动配对」输入 Mac 地址和配对码。"))
                } else if permission == .authorized {
                    VStack(spacing: 0) {
                        CameraPreview(scanned: scanned, failed: { unavailable = true })
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .overlay {
                                ScannerReticle()
                                    .stroke(Color(red: 0.72, green: 0.95, blue: 0.81),
                                            style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                                    .shadow(color: .black.opacity(0.55), radius: 2)
                                    .accessibilityHidden(true)
                                    .allowsHitTesting(false)
                            }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("对准 Mac 上的配对码").font(.headline)
                            Text("让两台设备接入同一局域网，在 Mac 版即图右上角点「扫码配对」。")
                                .foregroundStyle(.secondary)
                            if let currentMacName {
                                Text("当前接收设备为「\(currentMacName)」，验证成功后切换。")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.subheadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                        .background {
                            if reduceTransparency {
                                Color(uiColor: .secondarySystemBackground)
                            } else {
                                Rectangle().fill(.regularMaterial)
                            }
                        }
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(currentMacName == nil ? "扫码连接 Mac" : "扫码更换 Mac")
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
        .preferredColorScheme(.dark)
    }
}

private struct ScannerReticle: Shape {
    static func region(in bounds: CGRect) -> CGRect {
        let side = min(bounds.width * 0.70, bounds.height * 0.76, 320)
        return CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    func path(in rect: CGRect) -> Path {
        let frame = Self.region(in: rect)
        let half = frame.width / 2
        let arm = min(frame.width / 6, 26)
        var path = Path()
        for x in [-1.0, 1.0] as [CGFloat] {
            for y in [-1.0, 1.0] as [CGFloat] {
                let corner = CGPoint(x: frame.midX + x * half, y: frame.midY + y * half)
                path.move(to: CGPoint(x: corner.x - x * arm, y: corner.y))
                path.addLine(to: corner)
                path.addLine(to: CGPoint(x: corner.x, y: corner.y - y * arm))
            }
        }
        return path
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
        weak var preview: Preview?
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
            // The metadata delegate is registered on the main queue. Convert through
            // the preview layer so rotation and aspect-fill cropping match the visible frame.
            MainActor.assumeIsolated {
                guard active, let preview else { return }
                let frame = ScannerReticle.region(in: preview.bounds)
                for case let qr as AVMetadataMachineReadableCodeObject in objects where qr.type == .qr {
                    guard let projected = preview.previewLayer.transformedMetadataObject(for: qr),
                          frame.contains(CGPoint(x: projected.bounds.midX, y: projected.bounds.midY)),
                          let text = qr.stringValue else { continue }
                    stop()
                    scanned(text)
                    return
                }
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(scanned: scanned, failed: failed) }

    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.preview = view
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
