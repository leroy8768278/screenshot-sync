import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ChatClearPlan: Identifiable {
    let id = UUID()
    let count: Int
    let through: Int
    let files: ChatDownloadSnapshot
}

@MainActor
final class PhoneConversation: ObservableObject {
    let receiver: Receiver
    var isViewing = false
    var action: Task<Void, Never>?
    var download: Task<Void, Never>?
    @Published private(set) var entries: [ConversationEntry] = []
    @Published private(set) var macName = "Mac"
    @Published private(set) var lastRead: Int
    @Published var draft = "" {
        didSet { if draft != oldValue { textID = UUID() } }
    }
    @Published private(set) var attachments: [DraftAttachment] = []
    @Published private(set) var working = false
    @Published private(set) var receiving: UUID?
    @Published private(set) var files: [UUID: URL] = [:]
    @Published var notice: String?
    @Published var connectionError: String?
    private var textID = UUID()
    private var refreshing = false
    private let readKey: String
    private let clearKey: String
    private var clearedThrough: Int
    private let draftFolder = FileManager.default.temporaryDirectory
        .appending(path: "ConversationDraft-\(UUID().uuidString)", directoryHint: .isDirectory)

    init(receiver: Receiver) {
        self.receiver = receiver
        readKey = "chat.lastRead." + receiver.historyKey
        lastRead = UserDefaults.standard.integer(forKey: readKey)
        clearKey = "chat.clearedThrough." + receiver.historyKey
        clearedThrough = UserDefaults.standard.integer(forKey: clearKey)
    }

    deinit { try? FileManager.default.removeItem(at: draftFolder) }

    var unread: Int { entries.filter { $0.sequence > lastRead && $0.sender == .mac }.count }
    var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    func markRead() {
        guard let sequence = entries.last?.sequence, sequence > lastRead else { return }
        lastRead = sequence
        UserDefaults.standard.set(sequence, forKey: readKey)
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            var more: Bool
            repeat {
                let cursor = max(clearedThrough, entries.last?.sequence ?? 0)
                let page = try await ConversationClient.messages(receiver, after: cursor)
                try Task.checkCancellation()
                var previous = cursor
                var visible: [ConversationEntry] = []
                for entry in page.messages {
                    guard entry.sequence > previous else { throw SyncIssue.invalidResponse }
                    previous = entry.sequence
                    guard entry.sequence > clearedThrough else { continue }
                    visible.append(entry)
                    if entry.kind == .file, let url = try? ConversationClient.localFile(entry, receiver: receiver),
                       FileManager.default.fileExists(atPath: url.path) { files[entry.id] = url }
                }
                if !page.macName.isEmpty, page.macName != macName { macName = page.macName }
                if !visible.isEmpty { entries.append(contentsOf: visible) }
                more = page.hasMore
                guard !more || previous > cursor else { throw SyncIssue.invalidResponse }
                if isViewing { markRead() }
            } while more
            if connectionError != nil { connectionError = nil }
        } catch {
            if !Task.isCancelled {
                connectionError = error is URLError ? "暂时连不上 Mac，将自动重连。" : error.localizedDescription
            }
        }
    }

    func poll() async {
        while !Task.isCancelled {
            await refresh()
            do { try await Task.sleep(for: .seconds(connectionError == nil ? (isViewing ? 2 : 5) : 8)) }
            catch { return }
        }
    }

    private static func stage(_ urls: [URL], folder: URL) async throws -> [DraftAttachment] {
        var copies: [DraftAttachment] = []
        do {
            for url in urls {
                try Task.checkCancellation()
                copies.append(try await Task.detached(priority: .userInitiated) {
                    try DraftAttachment.fromPicker(url, in: folder)
                }.value)
            }
            try Task.checkCancellation()
            return copies
        } catch {
            for copy in copies { try? FileManager.default.removeItem(at: copy.url.deletingLastPathComponent()) }
            throw error
        }
    }

    func attach(_ urls: [URL]) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let copies = try await Self.stage(urls, folder: draftFolder)
            attachments.append(contentsOf: copies)
            notice = nil
        } catch {
            if !Task.isCancelled { notice = error.localizedDescription }
        }
    }

    func remove(_ attachment: DraftAttachment) {
        attachments.removeAll { $0.id == attachment.id }
        try? FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
    }

    func send() async {
        guard !working, hasDraft else { return }
        working = true
        notice = "正在发送…"
        defer { working = false }
        do {
            if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await ConversationClient.send(draft, id: textID, to: receiver)
                draft = ""
            }
            for file in attachments {
                try Task.checkCancellation()
                try await ConversationClient.send(file, to: receiver)
                remove(file)
            }
            notice = "已发送"
        } catch {
            if !Task.isCancelled {
                notice = "发送失败，请重试。\(error is URLError ? "请检查与 Mac 的连接。" : error.localizedDescription)"
            }
        }
        if !Task.isCancelled { await refresh() }
    }

    func cleanupPlan() async throws -> ChatClearPlan {
        let downloads = try await ConversationDownloads.shared.snapshot(receiver)
        return ChatClearPlan(count: entries.count, through: entries.last?.sequence ?? clearedThrough, files: downloads)
    }

    func clear(_ plan: ChatClearPlan, includingDownloads: Bool) async {
        guard !working, receiving == nil else { return }
        working = true
        defer { working = false }
        clearedThrough = max(clearedThrough, plan.through)
        UserDefaults.standard.set(clearedThrough, forKey: clearKey)
        entries.removeAll { $0.sequence <= clearedThrough }
        if includingDownloads {
            do {
                let failed = try await ConversationDownloads.shared.remove(plan.files, receiver: receiver)
                files = files.filter { FileManager.default.fileExists(atPath: $0.value.path) }
                notice = failed == 0 ? "已清除对话记录和所选下载文件。" : "对话记录已清除。有 \(failed) 个文件已更改或无法删除，可在「文件」中查看。"
            } catch {
                notice = "对话记录已清除，下载文件未能全部删除。\(error.localizedDescription)"
            }
        } else {
            notice = "已清除本机对话记录。"
        }
    }

    func saveToFiles(_ file: URL, folder: URL) async {
        guard !working else { return }
        working = true
        defer { working = false }
        do {
            let name = try await ConversationDownloads.shared.export(file, to: folder, receiver: receiver)
            notice = "已保存「\(name)」"
        } catch { notice = "保存失败。\(error.localizedDescription)" }
    }

    func receive(_ entry: ConversationEntry) async {
        guard receiving == nil else { return }
        receiving = entry.id
        defer { receiving = nil }
        do {
            let url = try await ConversationClient.receive(entry, receiver: receiver)
            files[entry.id] = url
            notice = "已接收「\(url.lastPathComponent)」"
        } catch {
            if !Task.isCancelled { notice = "接收失败。\(error.localizedDescription)" }
        }
    }
}

struct ConversationLink: View {
    @ObservedObject var chat: PhoneConversation

    var body: some View {
        NavigationLink {
            DeviceConversation(chat: chat)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(.indigo)
                    .frame(width: 36, height: 36)
                    .background(.indigo.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("与 \(chat.macName) 对话").font(.headline).lineLimit(2)
                    Text(chat.entries.last?.snippet ?? "文字和文件")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if chat.unread > 0 {
                    Text("\(chat.unread) 条未读").font(.caption2.bold())
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(.indigo.opacity(0.18), in: Capsule())
                }
            }
            .padding(.vertical, 4)
        }
        .accessibilityIdentifier("phone-chat-open")
    }
}

private struct DeviceConversation: View {
    @ObservedObject var chat: PhoneConversation
    @State private var picking = false
    @State private var preview: URL?
    @State private var exportSource: URL?
    @State private var plan: ChatClearPlan?
    @State private var savedDownloads: ChatDownloadSnapshot?
    @FocusState private var composing: Bool
    @State private var visibleMessage: UUID?

    var body: some View {
        VStack(spacing: 0) {
            messageList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if let error = chat.connectionError {
                    Label(error, systemImage: "wifi.exclamationmark").font(.caption).foregroundStyle(.secondary)
                }
                if let notice = chat.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                composer
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .tint(.indigo)
        .navigationTitle(chat.macName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("已下载文件", systemImage: "folder") {
                        Task {
                            do { savedDownloads = try await ConversationDownloads.shared.snapshot(chat.receiver) }
                            catch { chat.notice = "无法读取已下载文件。\(error.localizedDescription)" }
                        }
                    }
                    Button("清除对话记录", systemImage: "trash", role: .destructive) {
                        composing = false
                        Task {
                            do { plan = try await chat.cleanupPlan() }
                            catch { chat.notice = "无法准备清除。\(error.localizedDescription)" }
                        }
                    }
                    .accessibilityIdentifier("phone-chat-clear")
                } label: {
                    Label("对话选项", systemImage: "ellipsis.circle")
                }
                .disabled(chat.working || chat.receiving != nil)
                .accessibilityIdentifier("phone-chat-options")
            }
        }
        .onAppear { chat.isViewing = true; chat.markRead() }
        .onDisappear { chat.isViewing = false }
        .fileImporter(isPresented: $picking, allowedContentTypes: exportSource == nil ? [.item] : [.folder], allowsMultipleSelection: exportSource == nil) { result in
            let exporting = exportSource
            exportSource = nil
            switch result {
            case .success(let urls):
                if let exporting, let folder = urls.first {
                    chat.action = Task { await chat.saveToFiles(exporting, folder: folder) }
                } else if exporting == nil {
                    chat.action = Task { await chat.attach(urls) }
                }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { chat.notice = error.localizedDescription }
            }
        }
        .sheet(item: $plan) { snapshot in
            ChatClearSheet(plan: snapshot, mac: chat.macName) { removeFiles in
                plan = nil
                chat.action = Task { await chat.clear(snapshot, includingDownloads: removeFiles) }
            }
        }
        .sheet(item: $savedDownloads) { snapshot in
            ChatDownloadsView(snapshot: snapshot)
        }
        .quickLookPreview($preview)
    }

    @ViewBuilder
    private var messageList: some View {
        if chat.entries.isEmpty {
            Text("暂无消息").font(.subheadline).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 58)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(chat.entries) { entry in row(entry).id(entry.id) }
                }
                .scrollTargetLayout()
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollPosition(id: $visibleMessage, anchor: .bottom)
            .onAppear { visibleMessage = chat.entries.last?.id }
            .onChange(of: chat.entries.last?.id) { previous, latest in
                if visibleMessage == previous || chat.entries.last?.sender == .phone {
                    visibleMessage = latest
                }
            }
        }
    }

    private func row(_ entry: ConversationEntry) -> some View {
        let mine = entry.sender == .phone
        return VStack(alignment: mine ? .trailing : .leading, spacing: 5) {
            let date = Date(timeIntervalSince1970: entry.createdAt)
            Text("\(mine ? "我" : chat.macName) · \(date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
            if let text = entry.text, entry.kind == .text {
                Text(verbatim: text)
                    .font(.subheadline).textSelection(.enabled)
                    .padding(.horizontal, 11).padding(.vertical, 8)
                    .background(mine ? Color.indigo.opacity(0.17) : Color.secondary.opacity(0.11),
                                in: RoundedRectangle(cornerRadius: 12))
                Button("复制") {
                    UIPasteboard.general.string = text
                    chat.notice = "已复制"
                }.font(.caption).accessibilityLabel("复制此条文字")
            } else if entry.kind == .file {
                HStack(spacing: 6) {
                    Image(systemName: "doc")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.filename ?? "附件").font(.caption.bold()).lineLimit(2)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(entry.bytes), countStyle: .file))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let url = chat.files[entry.id] {
                        Button("打开") { preview = url }.font(.caption)
                        Button("存到文件") {
                            exportSource = url
                            picking = true
                        }.font(.caption)
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up").accessibilityLabel("分享副本")
                        }
                    } else if chat.receiving == entry.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(mine ? "查看" : "接收") {
                            chat.download = Task {
                                await chat.receive(entry)
                                if mine { preview = chat.files[entry.id] }
                            }
                        }.font(.caption.bold()).disabled(chat.receiving != nil)
                    }
                }
                .padding(9).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .buttonStyle(.borderless)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("输入或粘贴文字…", text: $chat.draft, axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
                .accessibilityIdentifier("phone-chat-input")
                .focused($composing)
                .background {
                    if composing {
                        OutsideEditorTap { composing = false }
                            .allowsHitTesting(false)
                    }
                }
                .disabled(chat.working)
            if !chat.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(chat.attachments) { file in
                            HStack(spacing: 5) {
                                Image(systemName: "paperclip")
                                Text(file.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 175)
                                Button { chat.remove(file) } label: { Image(systemName: "xmark.circle.fill") }
                                    .accessibilityLabel("移除附件 \(file.name)")
                            }
                            .font(.caption)
                            .padding(6)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .disabled(chat.working)
            }
            HStack(spacing: 8) {
                Button { exportSource = nil; picking = true } label: { Label("选文件", systemImage: "paperclip") }
                    .buttonStyle(.borderless).disabled(chat.working)
                Spacer(minLength: 0)
                if chat.working { ProgressView().controlSize(.small) }
                Button {
                    composing = false
                    chat.action = Task { await chat.send() }
                } label: {
                    Text("发送")
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 30)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!chat.hasDraft || chat.working)
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("phone-chat-send")
            }
            .font(.subheadline).controlSize(.small)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .buttonStyle(.borderless)
    }
}

private struct OutsideEditorTap: UIViewRepresentable {
    let dismissKeyboard: () -> Void

    func makeUIView(context: Context) -> EditorBoundsView { EditorBoundsView() }

    func updateUIView(_ view: EditorBoundsView, context: Context) {
        view.dismissKeyboard = dismissKeyboard
    }

    final class EditorBoundsView: UIView, UIGestureRecognizerDelegate {
        var dismissKeyboard: (() -> Void)?
        private lazy var tap: UITapGestureRecognizer = {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tappedOutside))
            tap.cancelsTouchesInView = false
            tap.delaysTouchesEnded = false
            tap.delegate = self
            return tap
        }()

        override func didMoveToWindow() {
            super.didMoveToWindow()
            tap.view?.removeGestureRecognizer(tap)
            window?.addGestureRecognizer(tap)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            !bounds.contains(touch.location(in: self))
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc private func tappedOutside() { dismissKeyboard?() }
    }
}

private struct ChatDownloadsView: View {
    let snapshot: ChatDownloadSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var preview: URL?

    var body: some View {
        NavigationStack {
            List(snapshot.downloads) { item in
                HStack {
                    Button(item.url.lastPathComponent) { preview = item.url }.buttonStyle(.borderless)
                    Spacer()
                    ShareLink(item: item.url) { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                }
            }
            .overlay { if snapshot.downloads.isEmpty { Text("暂无已下载文件").foregroundStyle(.secondary) } }
            .navigationTitle("已下载文件")
            .toolbar { Button("完成") { dismiss() } }
            .quickLookPreview($preview)
        }
    }
}

private struct ChatClearSheet: View {
    let plan: ChatClearPlan
    let mac: String
    let confirm: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var includeFiles = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("清除这部手机与 \(mac) 的 \(plan.count) 条本机对话记录？")
                    Toggle("同时删除已下载文件（\(plan.files.count) 个）", isOn: $includeFiles)
                        .disabled(plan.files.count == 0)
                        .accessibilityIdentifier("phone-chat-clear-downloads")
                } footer: {
                    Text("包括即图内的下载和通过「存到文件」保存的附件。通过系统分享另存的副本可在「文件」App 中管理。")
                }
                Section {
                    Button("确认清除", role: .destructive) { confirm(includeFiles) }
                        .disabled(plan.count == 0 && (!includeFiles || plan.files.count == 0))
                        .accessibilityIdentifier("phone-chat-clear-confirm")
                }
            }
            .navigationTitle("清除对话记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
