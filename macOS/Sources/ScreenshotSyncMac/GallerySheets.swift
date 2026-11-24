import AppKit
import AVKit
import SwiftUI

struct ScreenshotPreviewSheet: View {
    private let source: ScreenshotSource?
    private let displayOrigin: (ReceivedScreenshot) -> String

    @ObservedObject private var model: ReceiverModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var images: [ReceivedScreenshot]
    @State private var index: Int
    @State private var pixels: GalleryImage.Pixels?
    @State private var copyTask: Task<Void, Never>?
    @State private var feedback: CopyFeedback?

    init(model: ReceiverModel, images: [ReceivedScreenshot], index: Int, source: ScreenshotSource?,
         displayOrigin: @escaping (ReceivedScreenshot) -> String) {
        self.model = model
        self.source = source
        self.displayOrigin = displayOrigin
        _images = State(initialValue: images)
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
                    .accessibilityLabel("第 \(index + 1) 项，共 \(images.count) 项")
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

                Group {
                    if image.isVideo {
                        GalleryVideoPlayer(url: image.url)
                    } else {
                        GalleryImageView(url: image.url, date: image.date, maximumDimension: 2_400) { decodedPixels in
                            if images[index].id == image.id { pixels = decodedPixels }
                        }
                    }
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
                Button(image.isVideo ? "打开视频" : "打开原图") {
                    if !NSWorkspace.shared.open(image.url) {
                        feedback = .failed("无法打开这个文件。")
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
                if !image.isVideo {
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
                Button {
                    model.refreshRecent()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("刷新预览")
                .accessibilityLabel("刷新预览")
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 575)
        .background(theme.panel)
        .accessibilityIdentifier("gallery-preview")
        .onReceive(model.$recent) { list in
            reconcile(with: list[source, default: []])
        }
        .onDisappear { copyTask?.cancel() }
    }

    private func reconcile(with updated: [ReceivedScreenshot]) {
        let current = images[index]
        let byID = Dictionary(uniqueKeysWithValues: updated.map { ($0.id, $0) })
        let surviving = images.compactMap { byID[$0.id] }
        guard let newIndex = surviving.firstIndex(where: { $0.id == current.id }) else {
            copyTask?.cancel()
            dismiss()
            return
        }
        images = surviving
        index = newIndex
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

private struct GalleryVideoPlayer: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(playerItem: AVPlayerItem(asset: Inbox.videoAsset(at: url)))
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
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
    @State private var removalTarget: ScreenshotDevice?
    @State private var confirmRemoval = false
    @FocusState private var nameFocused: Bool

    private var theme: GalleryTheme { GalleryTheme(colorScheme) }

    var body: some View {
        let devices = model.knownDevices(for: source)
        let counts = model.recent[source, default: []].reduce(into: [ScreenshotDevice: Int]()) { counts, item in
            if let device = item.device { counts[device, default: 0] += 1 }
        }
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("管理手机")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("\(source.label) · \(devices.count) 台设备")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if editing == nil {
                    Button("关闭") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("关闭") { dismiss() }
                }
            }
            if devices.isEmpty {
                Text("使用手机配对或发送文件后，可在这里查看设备。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            } else {
                ViewThatFits(in: .vertical) {
                    deviceRows(devices, counts: counts).fixedSize(horizontal: false, vertical: true)
                    ScrollView { deviceRows(devices, counts: counts) }
                        .frame(height: 360)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(theme.page)
        .accessibilityIdentifier("gallery-device-manager")
        .alert("删除手机？", isPresented: $confirmRemoval, presenting: removalTarget) { device in
            Button("删除", role: .destructive) {
                model.removeDevice(device)
                removalTarget = nil
            }
            .accessibilityIdentifier("device-remove-confirm")
            Button("取消", role: .cancel) { removalTarget = nil }
        } message: { device in
            Text("「\(model.name(for: device))」将从手机标签中移除。已接收的图片和视频可在「未识别设备」中查看。该手机再次发送新文件后会重新显示。")
        }
    }

    private func deviceRows(_ devices: [ScreenshotDevice], counts: [ScreenshotDevice: Int]) -> some View {
        VStack(spacing: 8) {
            ForEach(devices) { device in
                let title = model.name(for: device)
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: device.source == .iOS ? "iphone" : "smartphone")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(theme.accent)
                        .frame(width: 40, height: 44)
                        .background(theme.mat(for: device.source), in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 6) {
                        if editing == device {
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
                                Text(nameError).font(.caption).foregroundStyle(.red)
                            }
                        } else {
                            HStack(alignment: .firstTextBaseline) {
                                Text(title)
                                    .font(.headline)
                                    .lineLimit(2)
                                Spacer(minLength: 10)
                                Button {
                                    proposedName = title
                                    nameError = nil
                                    editing = device
                                } label: { Image(systemName: "pencil") }
                                .help("重命名")
                                .accessibilityLabel("重命名 \(title)")
                                .accessibilityIdentifier("rename-\(device.id)")
                                Button(role: .destructive) {
                                    removalTarget = device
                                    confirmRemoval = true
                                } label: { Image(systemName: "trash") }
                                .help("删除手机")
                                .accessibilityLabel("删除 \(title)")
                                .accessibilityIdentifier("remove-\(device.id)")
                            }
                            .controlSize(.small)
                        }
                        let profile = model.profile(for: device)
                        let specs = [profile?.model, model.systemDescription(for: device)]
                            .compactMap { $0 }.filter { $0 != title }
                        if !specs.isEmpty || profile?.model == nil {
                            Text(verbatim: specs.isEmpty ? "等待手机上报型号和系统版本" : specs.joined(separator: " · "))
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        let name = profile?.name.flatMap { $0 == title ? nil : "设备名称　\($0)" }
                        Text(verbatim: [name, "图库 \(counts[device, default: 0]) 项"]
                            .compactMap { $0 }.joined(separator: "　·　"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
                .background(theme.panel, in: RoundedRectangle(cornerRadius: 11))
                .overlay { RoundedRectangle(cornerRadius: 11).strokeBorder(theme.border) }
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
    @State private var pairingMethod: PairingMethod = .scan
    @State private var showCode = false
    @State private var confirmReset = false
    @State private var copied: String?

    private enum PairingMethod { case scan, manual }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("连接手机").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Picker("配对方式", selection: $pairingMethod) {
                Text("扫码配对").tag(PairingMethod.scan)
                Text("手动配对").tag(PairingMethod.manual)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if pairingMethod == .scan {
                qrPairing
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        manualPairing
                    }
                    .padding(2)
                }
                .frame(minHeight: 150, idealHeight: 165, maxHeight: 220)
            }
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
            Text("之前配对的手机需要重新扫码或输入新配对码。")
        }
    }

    @ViewBuilder private var qrPairing: some View {
        if !model.status.isRunning {
            Text("开启 Mac 接收后即可显示配对二维码。")
                .frame(maxWidth: .infinity, minHeight: 150)
        } else if let code = PairingQRCode(addresses: model.addresses, port: Receiver.port, token: model.token) {
            HStack(spacing: 20) {
                PairingCodeImage(code: code).equatable()
                VStack(alignment: .leading, spacing: 9) {
                    Text("用手机扫一扫").font(.headline)
                    Text("手机和 Mac 连入同一局域网后，打开手机上的「即图」，点「扫一扫配对」对准此二维码。")
                    Text("手机已配对时，点「扫码更换 Mac」即可切换。")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text("请将 Mac 接入 Wi-Fi 或以太网以生成配对二维码。")
                .frame(maxWidth: .infinity, minHeight: 150)
        }
    }

    @ViewBuilder private var manualPairing: some View {
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
    }

    private func copyButton(_ value: String) -> some View {
        Button(copied == value ? "已复制" : "复制") {
            NSPasteboard.general.clearContents()
            if NSPasteboard.general.setString(value, forType: .string) { copied = value }
        }
        .disabled(value.isEmpty)
    }
}

private struct PairingCodeImage: View, Equatable {
    let code: PairingQRCode

    var body: some View {
        if let image = code.image() {
            let side = CGFloat(image.width * (228 / image.width))
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: side, height: side)
                .frame(width: 228, height: 228)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityElement()
                .accessibilityLabel("此 Mac 的配对二维码")
                .accessibilityIdentifier("pairing-qr-image")
        } else {
            Text("二维码生成失败，请使用手动配对。")
                .frame(width: 228, height: 228)
        }
    }
}
