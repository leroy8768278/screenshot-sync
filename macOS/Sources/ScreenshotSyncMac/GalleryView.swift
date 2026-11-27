import AppKit
import SwiftUI

struct GalleryView: View {
    @ObservedObject var model: ReceiverModel
    @ObservedObject var capture: LocalCaptureController
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @AppStorage("recentScreenshotSource") private var source: ScreenshotSource = .iOS
    @State private var showingUnclassified = false
    @State private var filters: [ScreenshotSource: GalleryDeviceFilter] = [:]
    @State private var sheet: GallerySheet?
    @State private var cleanupPlan: Inbox.ImageCleanupPlan?
    @State private var showingCleanupConfirmation = false
    @State private var cleanupBusy = false

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
        let hasUnknown = activeSource != nil && activeSource != .mac && images.contains { model.recognizedDevice(for: $0) == nil }
        let filter = validFilter(devices: devices, hasUnknown: hasUnknown)
        let visible = images.filter { image in
            switch filter {
            case .all: true
            case .device(let device): model.recognizedDevice(for: image) == device
            case .unknown: model.recognizedDevice(for: image) == nil
            }
        }

        GeometryReader { window in
            let sidebarWidth = min(215, max(155, window.size.width * 0.205))
            let inset: CGFloat = window.size.width < 800 ? 16 : 24
            let contentWidth = max(1, window.size.width - sidebarWidth - inset * 2 - 1)
            HStack(spacing: 0) {
                GallerySourceSidebar(model: model, source: activeSource, theme: theme) { selected in
                    if let selected { source = selected }
                    showingUnclassified = selected == nil
                }
                .frame(width: sidebarWidth)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    galleryHeader(width: contentWidth, devices: devices, hasUnknown: hasUnknown,
                                  filter: filter, count: visible.count)
                        .padding(.horizontal, inset)
                        .padding(.top, 19)
                        .padding(.bottom, 15)
                    notices.padding(.horizontal, inset)
                    gallery(visible, filter: filter, width: contentWidth, inset: inset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .background(theme.page)
        .tint(theme.accent)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新", action: model.refreshRecent)
                    .keyboardShortcut("r", modifiers: .command)
                    .help("重新读取传图文件夹")
                    .accessibilityIdentifier("gallery-refresh")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("在访达中打开传图文件夹", action: model.openFolder)
                    Button("更改存储位置", action: model.selectFolder)
                    Button("本机截图设置") { openWindow(id: "local-capture-settings") }
                    Divider()
                    Button("清除全部图片", role: .destructive, action: prepareImageCleanup)
                        .disabled(cleanupBusy || showingCleanupConfirmation)
                        .accessibilityIdentifier("gallery-clear-images")
                } label: {
                    Label("图库选项", systemImage: "ellipsis")
                }
                .accessibilityLabel("图库选项")
                .accessibilityIdentifier("gallery-options")
                .help("图库选项")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { sheet = .connection } label: {
                    Label("扫码配对", systemImage: "qrcode")
                }
                .labelStyle(.titleAndIcon)
                .buttonStyle(.borderedProminent)
                .tint(GalleryTheme.brand)
                .help("显示手机配对二维码、手动配对信息和保存位置")
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
                ScreenshotPreviewSheet(model: model, images: images, index: index, source: source) { image in
                    [source?.label ?? "未归类", deviceLabel(for: image, source: source)]
                        .compactMap { $0 }.joined(separator: " · ")
                }
            }
        }
        .onAppear(perform: model.refreshRecent)
        .alert(cleanupPlan?.count == 0 ? "没有可清除的图片" : "清除传图文件夹中的全部图片？",
               isPresented: $showingCleanupConfirmation, presenting: cleanupPlan) { plan in
            if plan.count == 0 {
                Button("好", role: .cancel) {}
            } else {
                Button("取消", role: .cancel) {}
                Button("移到废纸篓", role: .destructive) { clearImages(plan) }
            }
        } message: { plan in
            if plan.count == 0 {
                Text(verbatim: "传图文件夹\n\(plan.folder.path)")
            } else {
                Text(verbatim: "将把以下文件夹顶层的 \(plan.count) 张图片移到废纸篓，范围包括所有来源。\n\n\(plan.folder.path)")
            }
        }
        .onChange(of: showingCleanupConfirmation) { showing in
            if !showing { cleanupPlan = nil }
        }
        .onChange(of: model.folder) { _ in showingCleanupConfirmation = false }
        .onChange(of: devices) { available in
            if let activeSource, case .device(let selected) = filters[activeSource], !available.contains(selected) {
                filters[activeSource] = .all
            }
        }
    }

    private func prepareImageCleanup() {
        guard !cleanupBusy else { return }
        cleanupBusy = true
        let folder = model.folder
        Task {
            defer { cleanupBusy = false }
            do {
                let plan = try await Task.detached(priority: .userInitiated) {
                    try Inbox.prepareImageCleanup(in: folder)
                }.value
                guard model.folder == folder else { return }
                cleanupPlan = plan
                showingCleanupConfirmation = true
            } catch {
                if model.folder == folder { model.errorMessage = "无法读取传图文件夹。\(error.localizedDescription)" }
            }
        }
    }

    private func clearImages(_ plan: Inbox.ImageCleanupPlan) {
        guard !cleanupBusy, model.folder == plan.folder else { return }
        cleanupBusy = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Inbox.trashImages(in: plan)
            }.value
            cleanupBusy = false
            model.refreshRecent()
            if result.failures > 0 || result.skipped > 0 {
                var details = ["已将 \(result.moved) 张图片移到废纸篓。"]
                if result.skipped > 0 { details.append("已跳过 \(result.skipped) 张发生变化的图片。") }
                if result.failures > 0 { details.append("有 \(result.failures) 张未能移到废纸篓。") }
                if let error = result.firstError { details.append(error) }
                model.errorMessage = details.joined()
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if case .failed(let reason) = model.status {
            Label(reason, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red)
                .padding(.bottom, 8)
        }
        if let error = model.errorMessage {
            HStack {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Spacer()
                Button("关闭") { model.errorMessage = nil }.buttonStyle(.borderless)
            }
            .font(.callout)
            .padding(.bottom, 8)
        }
    }

    private func galleryHeader(width: CGFloat, devices: [ScreenshotDevice], hasUnknown: Bool,
                               filter: GalleryDeviceFilter, count: Int) -> some View {
        let mobile = activeSource != nil && activeSource != .mac
        let compact = width < 620
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 9))
                             : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        return layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(activeSource == .mac ? "本机截图" : activeSource.map { "\($0.label) 图库" } ?? "未归类")
                    .font(.system(size: 26, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(summary(filter: filter, devices: devices, count: count, mobile: mobile))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let activeSource, mobile {
                let available = compact ? width : max(260, width - 157)
                GalleryDeviceTabs(model: model, source: activeSource, devices: devices,
                                  hasUnknown: hasUnknown, selection: filter, width: available,
                                  theme: theme, select: { filters[activeSource] = $0 },
                                  manage: { sheet = .devices(activeSource) })
                .frame(width: available, alignment: compact ? .leading : .trailing)
            } else if activeSource == .mac {
                HStack(spacing: 12) {
                    Button("截图设置") { openWindow(id: "local-capture-settings") }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("local-capture-settings")
                    Button(action: capture.start) { Label("开始截图", systemImage: "viewfinder") }
                        .buttonStyle(.borderedProminent)
                        .tint(GalleryTheme.brand)
                        .disabled(capture.selecting)
                        .accessibilityIdentifier("local-capture-start")
                }
                .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(filter: GalleryDeviceFilter, devices: [ScreenshotDevice], count: Int, mobile: Bool) -> String {
        guard mobile else { return "\(count) 项" }
        switch filter {
        case .all: return "\(devices.count) 台手机 · \(count) 项"
        case .device(let device): return "\(model.subtitle(for: device) ?? model.name(for: device)) · \(count) 项"
        case .unknown: return "未识别设备 · \(count) 项"
        }
    }

    private func gallery(_ images: [ReceivedScreenshot], filter: GalleryDeviceFilter,
                         width: CGFloat, inset: CGFloat) -> some View {
        let spacing: CGFloat = 13
        let columnCount = min(6, max(1, Int((width - 12 + spacing) / (207 + spacing))))
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing, alignment: .top), count: columnCount)
        let tileWidth = (width - spacing * CGFloat(columnCount - 1)) / CGFloat(columnCount)
        let tileHeight = min(232, max(146, tileWidth * 0.78))
        let calendar = Calendar.autoupdatingCurrent
        let byDay = Dictionary(grouping: images) { calendar.startOfDay(for: $0.date) }

        return GeometryReader { area in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if case .device(let device) = filter {
                        DeviceConversationView(room: model.conversation(for: device),
                                               deviceName: model.name(for: device), theme: theme)
                            .id(device)
                    }
                    if images.isEmpty {
                        emptyGallery
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: spacing) {
                            ForEach(byDay.keys.sorted(by: >), id: \.self) { day in
                                Section {
                                    ForEach(byDay[day, default: []]) { image in
                                        ScreenshotTile(image: image, deviceLabel: deviceLabel(for: image, source: activeSource),
                                                       source: activeSource, theme: theme, height: tileHeight) {
                                            if let index = images.firstIndex(where: { $0.id == image.id }) {
                                                sheet = .preview(images: images, index: index, source: activeSource)
                                            }
                                        }
                                    }
                                } header: {
                                    dayHeading(day, calendar: calendar)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, inset)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, minHeight: area.size.height, alignment: .topLeading)
            }
            .accessibilityIdentifier("gallery-scroll")
            .id(activeSource)
        }
    }

    private func dayHeading(_ date: Date, calendar: Calendar) -> some View {
        let relative = calendar.isDateInToday(date) ? "今天" : calendar.isDateInYesterday(date) ? "昨天" : nil
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let relative { Text(relative).font(.headline) }
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(relative == nil ? .headline : .caption)
                .foregroundStyle(relative == nil ? .primary : .secondary)
        }
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var emptyGallery: some View {
        if model.isLoadingInbox {
            ProgressView("正在读取图库")
        } else {
            VStack(spacing: 9) {
                Image(systemName: activeSource == .mac ? "viewfinder" : "photo.on.rectangle")
                    .font(.system(size: 27, weight: .light))
                    .accessibilityHidden(true)
                Text(activeSource == .mac ? "还没有本机截图" : activeSource == nil ? "暂无未归类文件" : "还没有收到图片或视频")
                    .font(.callout)
                if activeSource == .mac {
                    Text("点击「开始截图」后拖选区域，按空格可选择窗口。")
                        .font(.caption)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private func validFilter(devices: [ScreenshotDevice], hasUnknown: Bool) -> GalleryDeviceFilter {
        guard let activeSource, let chosen = filters[activeSource] else { return .all }
        switch chosen {
        case .device(let device): return devices.contains(device) ? chosen : .all
        case .unknown: return hasUnknown ? chosen : .all
        case .all: return .all
        }
    }

    private func deviceLabel(for image: ReceivedScreenshot, source: ScreenshotSource?) -> String? {
        guard let source, source != .mac else { return nil }
        return model.recognizedDevice(for: image).map(model.name(for:)) ?? "未识别设备"
    }
}

private struct ScreenshotTile: View {
    let image: ReceivedScreenshot
    let deviceLabel: String?
    let source: ScreenshotSource?
    let theme: GalleryTheme
    let height: CGFloat
    let preview: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: preview) {
            VStack(alignment: .leading, spacing: 6) {
                GalleryImageView(url: image.url, date: image.date, maximumDimension: 512)
                    .padding(9)
                    .frame(height: height)
                    .background(theme.mat(for: source), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(hovering ? theme.accent : .clear, lineWidth: 1.5)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if image.isVideo {
                            Image(systemName: "play.fill")
                                .font(.caption).foregroundStyle(.white)
                                .padding(6).background(.black.opacity(0.65), in: Circle()).padding(7)
                                .accessibilityHidden(true)
                        }
                    }
                HStack {
                    Text(image.date.formatted(date: .omitted, time: .standard))
                        .font(.callout.weight(.semibold).monospacedDigit())
                    Spacer(minLength: 4)
                    if let deviceLabel {
                        Text(deviceLabel).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .lineLimit(1)
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(image.url.lastPathComponent)
        .accessibilityLabel(image.isVideo ? "播放视频" : "预览截图")
        .accessibilityValue([deviceLabel, image.date.formatted(date: .abbreviated, time: .standard)]
            .compactMap { $0 }.joined(separator: "，"))
        .accessibilityIdentifier("gallery-image")
    }
}

struct ReceiverStatusLabel: View {
    let status: ReceiverModel.Status

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(status.isRunning ? "接收中" : status.label)
                .foregroundStyle(.secondary)
        }
        .font(.callout.weight(.medium))
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
    static let brand = Color(red: 0.07, green: 0.34, blue: 0.28)

    init(_ colorScheme: ColorScheme) { dark = colorScheme == .dark }

    var page: Color { color(0xf8faf6, 0x0e1614) }
    var panel: Color { color(0xffffff, 0x1d2924) }
    var subnavigation: Color { color(0xeef3ee, 0x16211d) }
    var border: Color { color(0xd9e3da, 0x35453b) }
    var selection: Color { color(0xdeebe2, 0x263d32) }
    var accent: Color { dark ? Color(red: 0.55, green: 0.86, blue: 0.72) : Self.brand }

    func mat(for source: ScreenshotSource?) -> Color {
        switch source {
        case .iOS: color(0xd6e1d8, 0x304139)
        case .android: color(0xe4e8d8, 0x3b433b)
        case .harmony: color(0xe6e2d7, 0x433f34)
        case .mac: color(0xd9e1dc, 0x303c35)
        case nil: color(0xe1e4df, 0x373d3b)
        }
    }

    private func color(_ light: UInt32, _ dark: UInt32) -> Color {
        let hex = self.dark ? dark : light
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }
}
