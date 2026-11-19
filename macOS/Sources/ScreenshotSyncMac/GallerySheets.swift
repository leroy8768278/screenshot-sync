import AppKit
import SwiftUI

struct ScreenshotPreviewSheet: View {
    private let images: [ReceivedScreenshot]
    private let source: ScreenshotSource?
    private let displayOrigin: (ReceivedScreenshot) -> String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var index: Int
    @State private var pixels: GalleryImage.Pixels?
    @State private var copyTask: Task<Void, Never>?
    @State private var feedback: CopyFeedback?

    init(images: [ReceivedScreenshot], index: Int, source: ScreenshotSource?,
         displayOrigin: @escaping (ReceivedScreenshot) -> String) {
        self.images = images
        self.source = source
        self.displayOrigin = displayOrigin
        _index = State(initialValue: index)
    }

    private enum CopyFeedback {
        case copied
        case failed(String)
    }

    var body: some View {
        let image = images[index]
        let theme = GalleryTheme(colorScheme)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(image.url.lastPathComponent)
                        .font(.headline)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text([displayOrigin(image), image.date.formatted(date: .abbreviated, time: .standard)]
                        .joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 14)
                Text("\(index + 1) / \(images.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("第 \(index + 1) 张，共 \(images.count) 张")
                    .accessibilityIdentifier("preview-position")
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            HStack(spacing: 8) {
                Button {
                    navigate(by: -1)
                } label: {
                    Image(systemName: "chevron.left").frame(minWidth: 25, minHeight: 25)
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(index == images.startIndex)
                .help("上一张（←）")
                .accessibilityLabel("上一张")
                .accessibilityIdentifier("preview-previous")

                GalleryImageView(url: image.url, date: image.date, maximumDimension: 2_400) { decodedPixels in
                    if images[index].id == image.id { pixels = decodedPixels }
                }
                .id(image.id)

                Button {
                    navigate(by: 1)
                } label: {
                    Image(systemName: "chevron.right").frame(minWidth: 25, minHeight: 25)
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(index == images.endIndex - 1)
                .help("下一张（→）")
                .accessibilityLabel("下一张")
                .accessibilityIdentifier("preview-next")
            }
            .padding(14)
            .frame(height: 398)
            .background(theme.mat(for: source), in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 10) {
                if let pixels {
                    Text("\(pixels.width) × \(pixels.height)")
                }
                Text(ByteCountFormatter.string(fromByteCount: image.bytes, countStyle: .file))
                Button("打开原图") {
                    if !NSWorkspace.shared.open(image.url) {
                        feedback = .failed("无法打开这张截图。")
                    }
                }
                Spacer(minLength: 8)
                if let feedback {
                    switch feedback {
                    case .copied:
                        Label("图片已复制", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Text(message).foregroundStyle(.red)
                    }
                }
                Button {
                    copyImage(image)
                } label: {
                    Label("复制图片", systemImage: "document.on.document")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("c", modifiers: .command)
                .disabled(copyTask != nil)
                .accessibilityIdentifier("preview-copy")
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 575)
        .background(theme.panel)
        .accessibilityIdentifier("gallery-preview")
        .onDisappear { copyTask?.cancel() }
    }

    private func navigate(by offset: Int) {
        let nextIndex = index + offset
        guard images.indices.contains(nextIndex) else { return }
        copyTask?.cancel()
        copyTask = nil
        feedback = nil
        pixels = nil
        index = nextIndex
    }

    private func copyImage(_ image: ReceivedScreenshot) {
        guard copyTask == nil else { return }
        feedback = nil
        copyTask = Task {
            defer {
                if !Task.isCancelled { copyTask = nil }
            }
            do {
                try await GalleryImage.copy(image.url)
                guard !Task.isCancelled else { return }
                feedback = .copied
            } catch {
                guard !Task.isCancelled else { return }
                feedback = .failed(error.localizedDescription)
            }
        }
    }
}

struct DeviceManagerSheet: View {
    @ObservedObject var model: ReceiverModel
    let source: ScreenshotSource

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var editing: ScreenshotDevice?
    @State private var proposedName = ""
    @State private var nameError: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        let devices = model.knownDevices(for: source)
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("管理 \(source.label) 手机").font(.headline)
                Spacer()
                if editing == nil {
                    Button("关闭") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("关闭") { dismiss() }
                }
            }
            if devices.isEmpty {
                Text("收到该平台的新设备截图后，手机会显示在这里。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ViewThatFits(in: .vertical) {
                    deviceRows(devices)
                    ScrollView { deviceRows(devices) }
                        .frame(height: 320)
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(17)
        .frame(width: 475)
        .background(GalleryTheme(colorScheme).panel)
        .accessibilityIdentifier("gallery-device-manager")
    }

    private func deviceRows(_ devices: [ScreenshotDevice]) -> some View {
        VStack(spacing: 0) {
            ForEach(devices) { device in
                Divider()
                if editing == device {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            TextField("手机名称", text: Binding(
                                get: { proposedName },
                                set: {
                                    proposedName = $0
                                    nameError = nil
                                }
                            ))
                                .onSubmit { save(device) }
                                .focused($nameFocused)
                                .task { nameFocused = true }
                                .accessibilityIdentifier("device-name-input")
                            Button("保存") { save(device) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("device-name-save")
                            Button("取消") {
                                editing = nil
                                nameError = nil
                            }
                            .keyboardShortcut(.cancelAction)
                        }
                        if let nameError {
                            Text(nameError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 10)
                } else {
                    HStack {
                        Text(model.name(for: device))
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                        Spacer(minLength: 10)
                        Button("重命名") {
                            proposedName = model.name(for: device)
                            nameError = nil
                            editing = device
                        }
                        .accessibilityLabel("重命名 \(model.name(for: device))")
                        .accessibilityIdentifier("rename-\(device.id)")
                    }
                    .padding(.vertical, 11)
                }
            }
        }
    }

    private func save(_ device: ScreenshotDevice) {
        do {
            try model.rename(device, to: proposedName)
            editing = nil
            nameError = nil
        } catch {
            nameError = error.localizedDescription
        }
    }
}

struct ConnectionSheet: View {
    @ObservedObject var model: ReceiverModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCode = false
    @State private var confirmReset = false
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("连接手机").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text("手机和 Mac 连到同一局域网，在手机端填入地址和配对码。")
                .foregroundStyle(.secondary)
                .font(.callout)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if model.addresses.isEmpty {
                        LabeledContent("Mac 地址", value: "等待 Wi-Fi 或以太网连接")
                    } else {
                        ForEach(model.addresses) { address in
                            let endpoint = "\(address.host):\(Receiver.port)"
                            HStack {
                                Text("Mac 地址")
                                Spacer()
                                if model.addresses.count > 1 {
                                    Text(address.interface)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(endpoint).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                copyButton(endpoint)
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Text("配对码")
                        Spacer()
                        Text(showCode ? model.token : "•••• •••• •••• •••• •••• ••••")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button {
                            showCode.toggle()
                        } label: {
                            Image(systemName: showCode ? "eye.slash" : "eye")
                        }
                        .accessibilityLabel(showCode ? "隐藏配对码" : "显示配对码")
                        copyButton(model.token)
                    }
                    Button("重新生成配对码…") { confirmReset = true }
                        .buttonStyle(.link)
                        .font(.callout)
                    Divider()
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("保存位置")
                            Text(model.folder.path(percentEncoded: false))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .help(model.folder.path)
                        }
                        Spacer()
                        Button("更改…", action: model.selectFolder)
                        Button("在访达中打开", action: model.openFolder)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
            .frame(minHeight: 180, idealHeight: 215, maxHeight: 265)
            HStack {
                ReceiverStatusLabel(status: model.status)
                Spacer()
                Button(model.status.isRunning ? "暂停接收" : "开启接收", action: model.toggleReceiver)
                    .disabled(!model.status.canToggle)
            }
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(17)
        .frame(width: 515)
        .alert("重新生成配对码？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("重新生成") {
                model.resetToken()
                copied = nil
            }
        } message: {
            Text("之前配对的手机需要填写新配对码。")
        }
    }

    private func copyButton(_ value: String) -> some View {
        Button(copied == value ? "已复制" : "复制") {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(value, forType: .string) { copied = value }
        }
        .disabled(value.isEmpty)
    }
}
