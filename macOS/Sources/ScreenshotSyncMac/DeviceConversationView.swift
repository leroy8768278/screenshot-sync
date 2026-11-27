import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ConversationTabBadge: View {
    @ObservedObject var room: MacConversationRoom

    var body: some View {
        if room.unread > 0 {
            Text(room.unread > 99 ? "99+" : "\(room.unread)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 5)
                .foregroundStyle(.white)
                .background(GalleryTheme.brand, in: Capsule())
                .accessibilityLabel("\(room.unread) 条未读消息")
        }
    }
}

struct DeviceConversationView: View {
    @ObservedObject var room: MacConversationRoom
    let deviceName: String
    let theme: GalleryTheme

    @Environment(\.controlActiveState) private var windowState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var clearRequest: ClearRequest?

    private struct ClearRequest: Identifiable {
        let through: Int
        let count: Int
        var id: Int { through }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if room.expanded {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Button("清除对话记录") {
                        if let last = room.messages.last {
                            clearRequest = ClearRequest(through: last.sequence, count: room.messages.count)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(room.messages.isEmpty || room.clearing)
                    .accessibilityIdentifier("conversation-clear")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 7)
                    history
                    composer
                    if let notice = room.notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .help(notice)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        }
        .background(theme.panel, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(theme.border) }
        .onAppear { markReadIfVisible() }
        .onChange(of: room.unread) { _ in markReadIfVisible() }
        .onChange(of: room.expanded) { _ in markReadIfVisible() }
        .onChange(of: windowState) { _ in markReadIfVisible() }
        .onChange(of: scenePhase) { _ in markReadIfVisible() }
        .alert(item: $clearRequest) { request in
            Alert(
                title: Text("清除与“\(deviceName)”的对话记录？"),
                message: Text("将从本机对话中清除这 \(request.count) 条记录。手机仍可查看这些消息和附件。"),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .destructive(Text("清除记录")) { room.clearHistory(through: request.through) }
            )
        }
    }

    private func markReadIfVisible() {
        if room.expanded && windowState == .key && scenePhase == .active {
            room.markRead()
        }
    }

    private var header: some View {
        Button { room.expanded.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(theme.accent)
                    .frame(width: 32, height: 32)
                    .background(theme.selection, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("与 \(deviceName) 对话")
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Text(previewLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if room.unread > 0 {
                    Text("\(room.unread) 条未读")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(GalleryTheme.brand, in: Capsule())
                }
                Image(systemName: room.expanded ? "chevron.up" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(room.expanded ? "收起" : "展开")与 \(deviceName) 的对话")
        .accessibilityValue(room.unread > 0 ? "\(room.unread) 条未读" : previewLine)
        .accessibilityIdentifier("conversation-toggle")
    }

    private var previewLine: String {
        guard let last = room.messages.last else { return "文字和文件" }
        if let text = last.text { return String(text.prefix(120)).replacingOccurrences(of: "\n", with: " ") }
        return "文件 · \(last.filename ?? "附件")"
    }

    @ViewBuilder
    private var history: some View {
        if room.messages.isEmpty {
            Text("暂无消息")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 45)
        } else {
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(room.messages) { message in
                            ConversationBubble(room: room, message: message, deviceName: deviceName, theme: theme)
                                .id(message.id)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 3)
                }
                .frame(minHeight: 65, idealHeight: 145, maxHeight: 200)
                .accessibilityLabel("消息记录")
                .onAppear { scrollToLast(scroll) }
                .onChange(of: room.messages.last?.id) { _ in scrollToLast(scroll) }
            }
        }
    }

    private func scrollToLast(_ scroll: ScrollViewProxy) {
        if let id = room.messages.last?.id { scroll.scrollTo(id, anchor: .bottom) }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ConversationDraftField(text: $room.draft, onSend: room.send)
            if !room.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(room.attachments) { item in
                            HStack(spacing: 4) {
                                Image(systemName: "doc")
                                Text(item.url.lastPathComponent).lineLimit(1)
                                Button { room.attachments.removeAll { $0.id == item.id } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                                .disabled(room.sending)
                                .accessibilityLabel("移除附件 \(item.url.lastPathComponent)")
                            }
                            .font(.caption)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 6)
                            .background(theme.panel, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                }
            }
            HStack {
                Button(action: room.chooseFiles) {
                    Label("选文件", systemImage: "paperclip")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(theme.accent)
                .disabled(room.sending)
                Spacer()
                if room.sending {
                    ProgressView().controlSize(.small)
                }
                Button("发送", action: room.send)
                    .buttonStyle(.borderedProminent)
                    .tint(GalleryTheme.brand)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!room.canSend)
                    .help("回车发送，Shift + 回车换行")
                    .accessibilityIdentifier("conversation-send")
            }
        }
        .padding(10)
        .background {
            let shape = RoundedRectangle(cornerRadius: 12)
            if #available(macOS 26.0, *), !reduceTransparency {
                shape.fill(.clear).glassEffect(.regular, in: shape)
            } else {
                shape.fill(reduceTransparency ? AnyShapeStyle(theme.page) : AnyShapeStyle(.regularMaterial))
                    .overlay { shape.strokeBorder(theme.border) }
            }
        }
    }
}

private struct ConversationBubble: View {
    @ObservedObject var room: MacConversationRoom
    let message: ConversationMessage
    let deviceName: String
    let theme: GalleryTheme
    @State private var previewing = false

    private var mine: Bool { message.sender == "mac" }
    private var filename: String { message.filename ?? "附件" }
    private var isTextFile: Bool {
        UTType(filenameExtension: (filename as NSString).pathExtension)?.conforms(to: .text) == true
    }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            let date = Date(timeIntervalSince1970: message.createdAt)
            Text("\(mine ? "此 Mac" : deviceName) · \(date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let text = message.text {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(mine ? theme.selection : theme.subnavigation, in: RoundedRectangle(cornerRadius: 9))
                Button("复制") { room.copy(text) }
                    .accessibilityLabel("复制此条文字")
            } else if message.kind == "file" {
                HStack(spacing: 6) {
                    Image(systemName: "doc").foregroundStyle(theme.accent)
                    Text(filename).truncationMode(.middle)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(message.bytes), countStyle: .file))
                        .foregroundStyle(.secondary)
                    Button(!mine && !room.received.contains(message.id) ? "接收" : "另存为") { room.save(message) }
                    if isTextFile {
                        Button("查看文本") { previewing = true }
                            .popover(isPresented: $previewing) {
                                ConversationTextPreview(store: room.store, device: room.device, message: message)
                            }
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(mine ? theme.selection : theme.subnavigation, in: RoundedRectangle(cornerRadius: 7))
                .help(filename)
            }
        }
        .buttonStyle(.borderless)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .padding(mine ? .leading : .trailing, 38)
    }
}

private struct ConversationTextPreview: View {
    let store: ConversationStore
    let device: ScreenshotDevice
    let message: ConversationMessage
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message.filename ?? "文本预览").font(.headline)
            if let text {
                ScrollView {
                    Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView()
            }
        }
        .padding()
        .frame(width: 360, height: 220, alignment: .topLeading)
        .task {
            do {
                text = try await Task.detached(priority: .userInitiated) { [store, device, message] in
                    let url = try store.fileURL(for: message, device: device)
                    let file = try FileHandle(forReadingFrom: url)
                    defer { try? file.close() }
                    let limit = 64 * 1024
                    let data = try file.read(upToCount: limit) ?? Data()
                    let content = String(decoding: data, as: UTF8.self)
                    return message.bytes > limit ? content + "\n（预览前 64 KB）" : content
                }.value
            } catch {
                text = "无法预览文件。\(error.localizedDescription)"
            }
        }
    }
}
