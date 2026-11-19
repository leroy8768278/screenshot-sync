import AppKit
import SwiftUI

struct GalleryView: View {
    @ObservedObject var model: ReceiverModel
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("recentScreenshotSource") private var source: ScreenshotSource = .iOS
    @State private var showingUnclassified = false
    @State private var filters: [ScreenshotSource: DeviceFilter] = [:]
    @State private var sheet: GallerySheet?

    private enum DeviceFilter: Equatable {
        case all
        case device(ScreenshotDevice)
        case unknown
    }

    private enum GallerySheet: Identifiable {
        case connection
        case devices(ScreenshotSource)
        case preview(images: [ReceivedScreenshot], index: Int, source: ScreenshotSource?)

        var id: String {
            switch self {
            case .connection: "connection"
            case .devices(let source): "devices-\(source.rawValue)"
            case .preview: "preview"
            }
        }
    }

    private var activeSource: ScreenshotSource? { showingUnclassified ? nil : source }
    private var theme: GalleryTheme { GalleryTheme(colorScheme) }
    private var activeImages: [ReceivedScreenshot] { model.recent[activeSource, default: []] }

    var body: some View {
        let images = activeImages
        let devices = activeSource.map(model.knownDevices(for:)) ?? []
        let hasUnknown = images.contains { $0.device == nil }
        let filter = validFilter(devices: devices, hasUnknown: hasUnknown)
        let visible = images.filter { image in
            switch filter {
            case .all: true
            case .device(let device): image.device == device
            case .unknown: image.device == nil
            }
        }

        VStack(spacing: 0) {
            platformBar
            if let activeSource {
                deviceBar(source: activeSource, devices: devices, hasUnknown: hasUnknown, filter: filter)
            }
            if case .failed(let reason) = model.status {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 23)
                    .padding(.vertical, 8)
            }
            if let error = model.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                    Spacer()
                    Button("关闭") { model.errorMessage = nil }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal, 23)
                .padding(.vertical, 8)
            }
            gallery(visible)
        }
        .background(theme.page)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ReceiverStatusLabel(status: model.status)
                Button("连接") { sheet = .connection }
                    .help("查看 Mac 地址、配对码和保存位置")
                    .accessibilityIdentifier("gallery-connect")
            }
        }
        .sheet(item: $sheet) { item in
            switch item {
            case .connection:
                ConnectionSheet(model: model)
            case .devices(let source):
                DeviceManagerSheet(model: model, source: source)
            case .preview(let images, let index, let source):
                ScreenshotPreviewSheet(images: images, index: index, source: source) { image in
                    [source?.label ?? "未归类", deviceLabel(for: image, source: source)]
                        .compactMap { $0 }.joined(separator: " · ")
                }
            }
        }
        .onAppear(perform: model.refreshRecent)
    }

    private var platformBar: some View {
        HStack(spacing: 5) {
            ForEach(ScreenshotSource.allCases, id: \.self) { platform in
                GalleryTab(platform.label, selected: activeSource == platform, theme: theme) {
                    source = platform
                    showingUnclassified = false
                }
                .accessibilityIdentifier("platform-\(platform.rawValue)")
            }
            Spacer(minLength: 12)
            GalleryTab("未归类", selected: showingUnclassified, theme: theme) {
                showingUnclassified = true
            }
            .accessibilityIdentifier("platform-unclassified")
        }
        .padding(.horizontal, 23)
        .padding(.vertical, 8)
        .background(theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("平台来源")
    }

    private func deviceBar(
        source: ScreenshotSource, devices: [ScreenshotDevice], hasUnknown: Bool, filter: DeviceFilter
    ) -> some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    GalleryTab("全部手机", selected: filter == .all, theme: theme, compact: true) {
                        filters[source] = .all
                    }
                    .accessibilityIdentifier("device-all")
                    ForEach(devices) { device in
                        let name = model.name(for: device)
                        GalleryTab(name, selected: filter == .device(device), theme: theme, compact: true) {
                            filters[source] = .device(device)
                        }
                        .help(name)
                        .accessibilityIdentifier("device-\(device.id)")
                    }
                    if hasUnknown {
                        GalleryTab("未识别设备", selected: filter == .unknown, theme: theme, compact: true) {
                            filters[source] = .unknown
                        }
                        .accessibilityIdentifier("device-unknown")
                    }
                }
                .padding(2)
            }
            .scrollIndicators(.hidden)

            Button("管理手机") { sheet = .devices(source) }
                .disabled(devices.isEmpty)
                .accessibilityIdentifier("gallery-manage-devices")
        }
        .padding(.horizontal, 21)
        .padding(.vertical, 6)
        .background(theme.subnavigation)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(source.label) 手机来源")
    }

    private func gallery(_ images: [ReceivedScreenshot]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(activeSource.map { "\($0.label) 截图" } ?? "未归类截图")
                    .font(.system(size: 22, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(images.count) 张")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 23)
            .padding(.top, 17)

            if images.isEmpty && model.isLoadingInbox {
                ProgressView("正在读取截图")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if images.isEmpty {
                VStack(spacing: 9) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 28, weight: .light))
                        .accessibilityHidden(true)
                    Text("还没有截图")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 239), spacing: 13, alignment: .top)],
                        spacing: 13
                    ) {
                        ForEach(images) { image in
                            let platform = activeSource
                            ScreenshotTile(
                                image: image,
                                deviceLabel: deviceLabel(for: image, source: platform),
                                source: platform,
                                theme: theme
                            ) {
                                if let index = images.firstIndex(where: { $0.id == image.id }) {
                                    sheet = .preview(images: images, index: index, source: platform)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 23)
                    .padding(.top, 2)
                    .padding(.bottom, 23)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func validFilter(devices: [ScreenshotDevice], hasUnknown: Bool) -> DeviceFilter {
        guard let activeSource, let chosen = filters[activeSource] else { return .all }
        switch chosen {
        case .device(let device): return devices.contains(device) ? chosen : .all
        case .unknown: return hasUnknown ? chosen : .all
        case .all: return .all
        }
    }

    private func deviceLabel(for image: ReceivedScreenshot, source: ScreenshotSource?) -> String? {
        guard source != nil else { return nil }
        return image.device.map(model.name(for:)) ?? "未识别设备"
    }
}

private struct GalleryTab: View {
    let title: String
    let selected: Bool
    let theme: GalleryTheme
    var compact = false
    let action: () -> Void

    @State private var hovering = false

    init(_ title: String, selected: Bool, theme: GalleryTheme, compact: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.selected = selected
        self.theme = theme
        self.compact = compact
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(compact ? .callout : .body)
                .fontWeight(selected ? .semibold : .regular)
                .lineLimit(1)
                .foregroundStyle(selected ? theme.accent : Color.primary)
                .padding(.horizontal, compact ? 10 : 14)
                .frame(minHeight: compact ? 28 : 35)
                .background(selectionColor, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var selectionColor: Color {
        if selected { return theme.selection }
        return hovering ? theme.selection.opacity(0.38) : .clear
    }
}

private struct ScreenshotTile: View {
    let image: ReceivedScreenshot
    let deviceLabel: String?
    let source: ScreenshotSource?
    let theme: GalleryTheme
    let preview: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: preview) {
            VStack(alignment: .leading, spacing: 0) {
                GalleryImageView(url: image.url, date: image.date, maximumDimension: 440)
                    .padding(9)
                    .frame(height: 166)
                    .background(theme.mat(for: source))
                VStack(alignment: .leading, spacing: 3) {
                    Text(image.date.formatted(date: .abbreviated, time: .standard))
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .lineLimit(1)
                    if let deviceLabel {
                        Text(deviceLabel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: deviceLabel == nil ? 38 : 49, alignment: .topLeading)
            }
            .background(theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(hovering ? theme.accent : theme.border)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(image.url.lastPathComponent)
        .accessibilityLabel("预览截图")
        .accessibilityValue([deviceLabel, image.date.formatted(date: .abbreviated, time: .standard)]
            .compactMap { $0 }.joined(separator: "，"))
        .accessibilityIdentifier("gallery-image")
    }
}

struct ReceiverStatusLabel: View {
    let status: ReceiverModel.Status

    var body: some View {
        Label {
            Text(status.isRunning ? "接收中" : status.label)
        } icon: {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .accessibilityHidden(true)
        }
        .labelStyle(.titleAndIcon)
        .font(.callout)
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch status {
        case .running: .green
        case .failed: .red
        default: .secondary
        }
    }
}

struct GalleryTheme {
    private let dark: Bool

    init(_ colorScheme: ColorScheme) { dark = colorScheme == .dark }

    var page: Color { color(0xf7f9fd, 0x131b2a) }
    var panel: Color { color(0xffffff, 0x1c2637) }
    var subnavigation: Color { color(0xf2f5fa, 0x192334) }
    var border: Color { color(0xdbe1ec, 0x303d51) }
    var selection: Color { color(0xdce8ff, 0x273d67) }
    var accent: Color { color(0x224faf, 0xb8ceff) }

    func mat(for source: ScreenshotSource?) -> Color {
        switch source {
        case .iOS: color(0xdde8fc, 0x263b60)
        case .android: color(0xdceeea, 0x24463f)
        case .harmony: color(0xece6f6, 0x3a3051)
        case nil: color(0xe6edf4, 0x29384b)
        }
    }

    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        let hex = self.dark ? dark : light
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }
}
