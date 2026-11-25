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
    @Published private var profiles: [String: DeviceProfile]
    @Published var errorMessage: String?

    static let allPicturesLabel = "全部图片"
    private static let deviceNamesKey = "screenshotDeviceNames"
    private static let profilesKey = "screenshotDeviceProfiles"
    // An empty name remembers a deleted device without letting older media recreate its tab.
    private static let deletedDeviceName = ""
    private let defaults: UserDefaults
    private let pathMonitor = NWPathMonitor()
    private var conversationRooms: [ScreenshotDevice: MacConversationRoom] = [:]
    private var receiver: Receiver?
    private var generation = UUID()
    private var needsInboxRefresh = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        deviceNames = defaults.dictionary(forKey: Self.deviceNamesKey) as? [String: String] ?? [:]
        profiles = defaults.data(forKey: Self.profilesKey).flatMap {
            try? PropertyListDecoder().decode([String: DeviceProfile].self, from: $0)
        } ?? [:]
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
            let receiver = try Receiver(folder: folder, token: token, onDeviceInfo: { [weak self] device, profile, createdFile in
                Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    self.record(profile, for: device, createdFile: createdFile)
                }
            }) { [weak self] state in
                Task { @MainActor in self?.updateStatus(state, generation: id) }
            } onReceive: { [weak self] device in
                Task { @MainActor in self?.receivedMedia(from: device) }
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

    func saveLocalScreenshot(_ image: CGImage) async throws {
        let destination = folder
        try await Task.detached(priority: .userInitiated) {
            try Inbox.saveLocalScreenshot(image, in: destination)
        }.value
        refreshRecent()
    }

    func knownDevices(for source: ScreenshotSource) -> [ScreenshotDevice] {
        deviceNames.compactMap { id, name in
            name == Self.deletedDeviceName ? nil : ScreenshotDevice(id: id)
        }.filter { $0.source == source }.sorted {
            let order = name(for: $0).localizedStandardCompare(name(for: $1))
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func conversation(for device: ScreenshotDevice) -> MacConversationRoom {
        if let room = conversationRooms[device] { return room }
        let room = MacConversationRoom(device: device, defaults: defaults)
        conversationRooms[device] = room
        return room
    }

    func name(for device: ScreenshotDevice) -> String {
        registeredName(for: device) ?? defaultNamePrefix(for: device.source)
    }

    func profile(for device: ScreenshotDevice) -> DeviceProfile? {
        profiles[device.id]
    }

    func systemDescription(for device: ScreenshotDevice) -> String? {
        guard let version = profile(for: device)?.osVersion else { return nil }
        let system = device.source == .harmony ? "HarmonyOS" : device.source.label
        return version.localizedCaseInsensitiveContains(system) ? version : "\(system) \(version)"
    }

    func subtitle(for device: ScreenshotDevice) -> String? {
        guard let profile = profile(for: device) else { return nil }
        let title = nameKey(name(for: device))
        return [profile.model, profile.name, systemDescription(for: device)]
            .compactMap { $0 }.first { nameKey($0) != title }
    }

    func recognizedDevice(for media: ReceivedScreenshot) -> ScreenshotDevice? {
        guard let device = media.device, registeredName(for: device) != nil else { return nil }
        return device
    }

    func rename(_ device: ScreenshotDevice, to name: String) throws {
        guard registeredName(for: device) != nil else { throw DeviceNameError.unknownDevice }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...24).contains(name.count), name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw DeviceNameError.invalidName
        }
        let match = nameKey(name)
        guard match != nameKey(Self.allPicturesLabel), match != nameKey("未识别设备"),
              !knownDevices(for: device.source).contains(where: { $0 != device && nameKey(self.name(for: $0)) == match }) else {
            throw DeviceNameError.nameUnavailable
        }
        var renamed = deviceNames
        renamed[device.id] = name
        saveDeviceNames(renamed)
    }

    func removeDevice(_ device: ScreenshotDevice) {
        guard registeredName(for: device) != nil else { return }
        var names = deviceNames
        names[device.id] = Self.deletedDeviceName
        saveDeviceNames(names)
        if profiles.removeValue(forKey: device.id) != nil { saveProfiles() }
    }

    private func record(_ profile: DeviceProfile, for device: ScreenshotDevice, createdFile: Bool) {
        let name = deviceNames[device.id]
        guard name != Self.deletedDeviceName || createdFile else { return }
        if name == nil || name == Self.deletedDeviceName {
            let used = Set(knownDevices(for: device.source).map { nameKey(self.name(for: $0)) })
            var names = deviceNames
            names[device.id] = availableName(for: device.source, profile: profile, used: used)
            saveDeviceNames(names)
        }
        if profiles[device.id] != profile {
            profiles[device.id] = profile
            saveProfiles()
        }
    }

    private func saveProfiles() {
        if let data = try? PropertyListEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.profilesKey)
        }
    }

    private func registeredName(for device: ScreenshotDevice) -> String? {
        guard let name = deviceNames[device.id], name != Self.deletedDeviceName else { return nil }
        return name
    }

    private func receivedMedia(from device: ScreenshotDevice?) {
        if let device, deviceNames[device.id] == Self.deletedDeviceName {
            var names = deviceNames
            names.removeValue(forKey: device.id)
            saveDeviceNames(names)
        }
        refreshRecent()
    }

    private func registerDevices(in received: [ScreenshotSource?: [ReceivedScreenshot]]) {
        var names = deviceNames
        for source in ScreenshotSource.allCases where source != .mac {
            let existingIDs = knownDevices(for: source)
            var usedNames = Set(existingIDs.map { nameKey(name(for: $0)) })
            for screenshot in received[source, default: []].reversed() {
                guard let device = screenshot.device, names[device.id] == nil else { continue }
                let alias = availableName(for: source, profile: nil, used: usedNames)
                names[device.id] = alias
                usedNames.insert(nameKey(alias))
            }
        }
        if names != deviceNames { saveDeviceNames(names) }
    }

    private func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
    }

    private func availableName(for source: ScreenshotSource, profile: DeviceProfile?, used: Set<String>) -> String {
        let reserved = [Self.allPicturesLabel, "未识别设备"].map(nameKey)
        let candidates = source == .iOS ? [profile?.name, profile?.model] : []
        let reported = candidates.compactMap { $0 }
            .map { String($0.prefix(24)) }.first { !reserved.contains(nameKey($0)) }
        if let reported, !used.contains(nameKey(reported)) { return reported }
        let prefix = reported ?? defaultNamePrefix(for: source)
        var number = reported == nil ? 1 : 2
        while true {
            let suffix = " \(number)"
            let candidate = String(prefix.prefix(24 - suffix.count)) + suffix
            if !used.contains(nameKey(candidate)) { return candidate }
            number += 1
        }
    }

    private func defaultNamePrefix(for source: ScreenshotSource) -> String {
        switch source {
        case .iOS: "iPhone"
        case .android: "Android"
        case .harmony: "Harmony"
        case .mac: "本机"
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
