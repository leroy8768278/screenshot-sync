import AppKit
import SwiftUI

@main
struct ScreenshotSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ReceiverModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("截图同步", id: "inbox") {
            InboxView(model: model)
                .frame(minWidth: 610, minHeight: 540)
        }
        .defaultSize(width: 660, height: 650)

        MenuBarExtra("截图同步", systemImage: model.status.isRunning ? "tray.and.arrow.down.fill" : "tray") {
            Text(model.status.label)
            Button("显示截图同步") {
                openWindow(id: "inbox")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(model.status.isRunning ? "暂停接收" : "开启接收", action: model.toggleReceiver)
                .disabled(!model.status.canToggle)
            Button("打开截图文件夹", action: model.openFolder)
            Divider()
            Button("退出截图同步") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct InboxView: View {
    @ObservedObject var model: ReceiverModel
    @State private var showCode = false
    @State private var confirmReset = false
    @State private var copied: String?
    @State private var copyTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            if case .failed(let reason) = model.status {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
            pairing
            inboxFolder
            screenshotList
        }
        .padding(26)
        .alert("重新生成配对码？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("重新生成") { model.resetToken() }
        } message: {
            Text("之前配对的手机需要填写新配对码。")
        }
        .alert("截图同步", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear(perform: model.refreshRecent)
    }

    private var header: some View {
        HStack(spacing: 13) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("截图同步").font(.title2.bold())
                Label(model.status.label, systemImage: "circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.status.isRunning ? Color.green : Color.secondary)
            }
            Spacer()
            Button(model.status.isRunning ? "暂停接收" : "开启接收", action: model.toggleReceiver)
                .disabled(!model.status.canToggle)
        }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接手机").font(.headline)
            Text("手机和 Mac 连到同一局域网，在手机端填入以下信息。")
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                if model.addresses.isEmpty {
                    HStack {
                        Text("Mac 地址").frame(width: 72, alignment: .leading)
                        Text("等待 Wi‑Fi 或以太网连接").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(11)
                } else {
                    ForEach(model.addresses) { address in
                        let endpoint = "\(address.host):\(Receiver.port)"
                        HStack {
                            Text("Mac 地址").frame(width: 72, alignment: .leading)
                            Text(endpoint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            if model.addresses.count > 1 {
                                Text(address.interface).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            copyButton(endpoint)
                        }
                        .padding(11)
                    }
                }

                Divider().padding(.horizontal, 11)
                HStack {
                    Text("配对码").frame(width: 72, alignment: .leading)
                    Text(showCode ? model.token : "•••• •••• •••• •••• •••• ••••")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button {
                        showCode.toggle()
                    } label: {
                        Image(systemName: showCode ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(showCode ? "隐藏配对码" : "显示配对码")
                    Spacer()
                    copyButton(model.token)
                    Menu {
                        Button("重新生成配对码…") { confirmReset = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("配对码选项")
                }
                .padding(11)
            }
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var inboxFolder: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("保存位置").font(.headline)
                Text(model.folder.path(percentEncoded: false))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.folder.path)
            }
            Spacer()
            Button("更改…", action: model.selectFolder)
            Button("在访达中打开", action: model.openFolder)
        }
    }

    private var screenshotList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近接收").font(.headline)
            Group {
                if model.recent.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 25))
                            .accessibilityHidden(true)
                        Text("还没有收到截图").font(.callout)
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.recent) { screenshot in
                        HStack(spacing: 10) {
                            Image(systemName: "photo")
                                .foregroundStyle(Color.accentColor)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(screenshot.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Text(screenshot.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: screenshot.bytes, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                            Button("打开") { NSWorkspace.shared.open(screenshot.url) }
                                .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.inset)
                }
            }
            .frame(minHeight: 110)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func copyButton(_ value: String) -> some View {
        Button(copied == value ? "已复制" : "复制") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = value
            copyTask?.cancel()
            copyTask = Task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                copied = nil
            }
        }
        .disabled(value.isEmpty)
    }
}
