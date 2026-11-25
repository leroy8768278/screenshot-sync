import AppKit
import Combine
import Foundation

@MainActor
final class MacConversationRoom: ObservableObject {
    struct Attachment: Identifiable {
        let id = UUID()
        let url: URL
    }

    let device: ScreenshotDevice
    @Published private(set) var messages: [ConversationMessage] = []
    @Published private(set) var unread = 0
    @Published private(set) var sending = false
    @Published private(set) var received = Set<UUID>()
    @Published var expanded = false
    @Published var draft = "" {
        didSet { if oldValue != draft { draftID = UUID() } }
    }
    @Published var attachments: [Attachment] = []
    @Published var notice: String?

    let store: ConversationStore
    private let defaults: UserDefaults
    private let cursorKey: String
    private var readThrough: Int
    private var draftID = UUID()
    private var changeObserver: AnyCancellable?
    private var loading = false
    private var reloadRequested = false

    init(device: ScreenshotDevice, defaults: UserDefaults, store: ConversationStore = .shared) {
        self.device = device
        self.defaults = defaults
        self.store = store
        cursorKey = "conversation.readThrough.\(device.id)"
        readThrough = defaults.integer(forKey: cursorKey)
        changeObserver = NotificationCenter.default.publisher(for: .conversationDidChange)
            .receive(on: DispatchQueue.main)
            .compactMap { $0.object as? String }
            .filter { $0 == device.id }
            .sink { [weak self] _ in self?.reload() }
        reload()
    }

    func reload() {
        guard !loading else {
            reloadRequested = true
            return
        }
        loading = true
        let device = device, store = store
        Task {
            do {
                let latest = try await Task.detached(priority: .utility) {
                    try store.messages(for: device)
                }.value
                messages = latest
                unread = latest.lazy.filter { $0.sender == "phone" && $0.sequence > self.readThrough }.count
            } catch {
                notice = "读取对话失败。\(error.localizedDescription)"
            }
            loading = false
            if reloadRequested {
                reloadRequested = false
                reload()
            }
        }
    }

    func markRead() {
        guard let last = messages.last, last.sequence > readThrough else { return }
        readThrough = last.sequence
        defaults.set(readThrough, forKey: cursorKey)
        unread = 0
    }

    var canSend: Bool {
        !sending && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "选择要发送的文件"
        panel.prompt = "添加"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !attachments.contains(where: { $0.url == url }) {
            attachments.append(Attachment(url: url))
        }
        notice = nil
    }

    func send() {
        guard canSend else { return }
        sending = true
        notice = nil
        let device = device, store = store, text = draft, id = draftID, files = attachments
        Task {
            defer { sending = false }
            do {
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    _ = try await Task.detached(priority: .userInitiated) {
                        try store.send(text: text, to: device, id: id)
                    }.value
                    draft = ""
                }
                for file in files {
                    _ = try await Task.detached(priority: .userInitiated) {
                        let scoped = file.url.startAccessingSecurityScopedResource()
                        defer { if scoped { file.url.stopAccessingSecurityScopedResource() } }
                        return try store.send(file: file.url, to: device, id: file.id)
                    }.value
                    attachments.removeAll { $0.id == file.id }
                }
                notice = "已发送至对话"
            } catch {
                notice = "发送失败。\(error.localizedDescription)"
            }
        }
    }

    func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        notice = board.setString(text, forType: .string) ? "已复制" : "复制失败，请重试。"
    }

    func save(_ message: ConversationMessage) {
        let panel = NSSavePanel()
        panel.title = "保存对话文件"
        panel.nameFieldStringValue = message.filename ?? "附件"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let device = device, store = store
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let source = try store.fileURL(for: message, device: device)
                    let files = FileManager.default
                    // Stage next to the destination volume so a copy error preserves an existing file.
                    let temp = try files.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                             appropriateFor: destination, create: true)
                    defer { try? files.removeItem(at: temp) }
                    let copy = temp.appendingPathComponent("attachment")
                    try files.copyItem(at: source, to: copy)
                    if files.fileExists(atPath: destination.path) {
                        _ = try files.replaceItemAt(destination, withItemAt: copy)
                    } else {
                        try files.moveItem(at: copy, to: destination)
                    }
                }.value
                received.insert(message.id)
                notice = "已保存「\(destination.lastPathComponent)」"
            } catch {
                notice = "保存失败。\(error.localizedDescription)"
            }
        }
    }
}
