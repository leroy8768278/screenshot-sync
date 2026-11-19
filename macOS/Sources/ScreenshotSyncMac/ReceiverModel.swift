import AppKit
import Foundation
import Network
import Security

@MainActor
final class ReceiverModel: ObservableObject {
    enum Status {
        case stopped, starting, running, stopping, failed(String)

        var label: String {
            switch self {
            case .stopped: "已暂停"
            case .starting: "正在启动"
            case .running: "正在接收"
            case .stopping: "正在暂停"
            case .failed: "接收异常"
            }
        }

        var canToggle: Bool {
            switch self {
            case .starting, .stopping: false
            default: true
            }
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var folder: URL
    @Published private(set) var token: String
    @Published private(set) var addresses = [LocalAddress]()
    @Published private(set) var recent = [ScreenshotSource?: [ReceivedScreenshot]]()
    @Published var errorMessage: String?

    private let defaults: UserDefaults
    private let pathMonitor = NWPathMonitor()
    private var receiver: Receiver?
    private var generation = UUID()

    init() {
        defaults = .standard
        let path = defaults.string(forKey: "inboxPath")
        let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures/截图同步", isDirectory: true)
        folder = path.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
        token = defaults.string(forKey: "receiverPairingCode") ?? ""
        addresses = LocalAddress.available()
        if token.isEmpty { resetToken() }
        refreshRecent()

        pathMonitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in self?.addresses = LocalAddress.available() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "local.screenshotsync.interfaces"))
        if defaults.object(forKey: "receivingEnabled") as? Bool != false {
            start()
        }
    }

    func toggleReceiver() {
        if status.isRunning {
            status = .stopping
            defaults.set(false, forKey: "receivingEnabled")
            receiver?.stop()
        } else if status.canToggle {
            defaults.set(true, forKey: "receivingEnabled")
            start()
        }
    }

    private func start() {
        guard !token.isEmpty else {
            status = .failed("未能生成配对码。请重新生成配对码。")
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let id = UUID()
            generation = id
            let receiver = try Receiver(folder: folder, token: token) { [weak self] state in
                Task { @MainActor in self?.updateStatus(state, generation: id) }
            } onReceive: { [weak self] in
                Task { @MainActor in self?.refreshRecent() }
            }
            self.receiver = receiver
            status = .starting
            receiver.start()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    private func updateStatus(_ state: NWListener.State, generation: UUID) {
        guard self.generation == generation else { return }
        switch state {
        case .ready:
            if case .starting = status { status = .running }
        case .waiting(let error), .failed(let error):
            guard let receiver else { return }
            self.receiver = nil
            self.generation = UUID()
            receiver.stop()
            status = .failed("无法监听端口 \(Receiver.port)。\(error.localizedDescription)")
        case .cancelled:
            receiver = nil
            status = .stopped
        default:
            break
        }
    }

    func resetToken() {
        var bytes = [UInt8](repeating: 0, count: 12)
        let result = bytes.withUnsafeMutableBytes { data in
            SecRandomCopyBytes(kSecRandomDefault, data.count, data.baseAddress!)
        }
        guard result == errSecSuccess else {
            errorMessage = "无法生成配对码，请重试。"
            return
        }
        token = bytes.map { String(format: "%02x", $0) }.joined()
        defaults.set(token, forKey: "receiverPairingCode")
        receiver?.configure(folder: folder, token: token)
    }

    func selectFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择截图保存位置"
        panel.prompt = "选择"
        panel.directoryURL = folder
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        folder = selected
        defaults.set(folder.path, forKey: "inboxPath")
        receiver?.configure(folder: folder, token: token)
        refreshRecent()
    }

    func refreshRecent() {
        recent = Inbox.recent(in: folder)
    }

    func openFolder() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
