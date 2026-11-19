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
    @Published private(set) var isLoadingInbox = false
    @Published private var deviceNames: [String: String]
    @Published var errorMessage: String?

    private static let deviceNamesKey = "screenshotDeviceNames"
    private let defaults: UserDefaults
    private let pathMonitor = NWPathMonitor()
    private var receiver: Receiver?
    private var generation = UUID()
    private var needsInboxRefresh = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        deviceNames = defaults.dictionary(forKey: Self.deviceNamesKey) as? [String: String] ?? [:]
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
        guard folder != selected else { return }
        folder = selected
        recent = [:]
        defaults.set(folder.path, forKey: "inboxPath")
        receiver?.configure(folder: folder, token: token)
        refreshRecent()
    }

    func refreshRecent() {
        guard !isLoadingInbox else {
            needsInboxRefresh = true
            return
        }
        isLoadingInbox = true
        let currentFolder = folder
        let scan = Task.detached(priority: .utility) { try Inbox.recent(in: currentFolder) }
        Task { [weak self] in
            let result = await scan.result
            guard let self else { return }
            if folder == currentFolder {
                switch result {
                case .success(let received):
                    registerDevices(in: received)
                    recent = received
                case .failure(let error):
                    errorMessage = "无法读取截图文件夹。\(error.localizedDescription)"
                }
            }
            isLoadingInbox = false
            if needsInboxRefresh {
                needsInboxRefresh = false
                refreshRecent()
            }
        }
    }

    func knownDevices(for source: ScreenshotSource) -> [ScreenshotDevice] {
        deviceNames.keys.compactMap(ScreenshotDevice.init(id:)).filter { $0.source == source }.sorted {
            let order = name(for: $0).localizedStandardCompare(name(for: $1))
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func name(for device: ScreenshotDevice) -> String {
        deviceNames[device.id] ?? defaultNamePrefix(for: device.source)
    }

    func rename(_ device: ScreenshotDevice, to name: String) throws {
        guard deviceNames[device.id] != nil else { throw DeviceNameError.unknownDevice }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...24).contains(name.count), name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw DeviceNameError.invalidName
        }
        let match = nameKey(name)
        guard match != nameKey("全部手机"), match != nameKey("未识别设备"),
              !knownDevices(for: device.source).contains(where: { $0 != device && nameKey(self.name(for: $0)) == match }) else {
            throw DeviceNameError.nameUnavailable
        }
        var renamed = deviceNames
        renamed[device.id] = name
        saveDeviceNames(renamed)
    }

    private func registerDevices(in received: [ScreenshotSource?: [ReceivedScreenshot]]) {
        var names = deviceNames
        for source in ScreenshotSource.allCases {
            let existingIDs = knownDevices(for: source)
            var usedNames = Set(existingIDs.map { nameKey(name(for: $0)) })
            var ordinal = 1
            for screenshot in received[source, default: []].reversed() {
                guard let device = screenshot.device, names[device.id] == nil else { continue }
                let prefix = defaultNamePrefix(for: source)
                var alias = "\(prefix) \(ordinal)"
                while usedNames.contains(nameKey(alias)) {
                    ordinal += 1
                    alias = "\(prefix) \(ordinal)"
                }
                names[device.id] = alias
                usedNames.insert(nameKey(alias))
                ordinal += 1
            }
        }
        if names != deviceNames { saveDeviceNames(names) }
    }

    private func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    private func defaultNamePrefix(for source: ScreenshotSource) -> String {
        switch source {
        case .iOS: "iPhone"
        case .android: "Android 手机"
        case .harmony: "鸿蒙手机"
        }
    }

    private func saveDeviceNames(_ names: [String: String]) {
        defaults.set(names, forKey: Self.deviceNamesKey)
        deviceNames = names
    }

    func openFolder() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private enum DeviceNameError: LocalizedError {
        case unknownDevice
        case invalidName
        case nameUnavailable

        var errorDescription: String? {
            switch self {
            case .unknownDevice: "找不到此手机。"
            case .invalidName: "请输入 1–24 个字符的名称。"
            case .nameUnavailable: "此名称已在手机标签中使用。"
            }
        }
    }
}
