import AppKit
import SwiftUI

enum GalleryDeviceFilter: Hashable {
    case all
    case device(ScreenshotDevice)
    case unknown
}

struct GallerySourceSidebar: View {
    @ObservedObject var model: ReceiverModel
    let source: ScreenshotSource?
    let theme: GalleryTheme
    let select: (ScreenshotSource?) -> Void

    @FocusState private var focusedSource: String?
    @State private var hoveredSource: String?
    private static let orderedSources: [ScreenshotSource?] = [.iOS, .android, .harmony, .mac, nil]

    var body: some View {
        VStack(spacing: 9) {
            receiverCard
                .padding(.horizontal, 12)
                .padding(.top, 15)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    sectionTitle("手机平台")
                    row(.iOS, "iOS", "iphone")
                    row(.android, "Android", "smartphone")
                    row(.harmony, "鸿蒙", "circle.hexagonpath")
                    Divider().padding(.vertical, 9)
                    sectionTitle("其他")
                    row(.mac, "本机截图", "viewfinder")
                    row(nil, "未归类", "archivebox")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("图库来源")
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.subnavigation)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.border).frame(width: 1) }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func choose(_ platform: ScreenshotSource?) {
        select(platform)
        focusedSource = platform?.rawValue ?? "unclassified"
    }

    private func row(_ platform: ScreenshotSource?, _ title: String, _ symbol: String) -> some View {
        let key = platform?.rawValue ?? "unclassified"
        let count = model.recent[platform]?.count ?? 0
        let selected = source == platform
        let fill = selected ? theme.selection : (hoveredSource == key ? theme.selection.opacity(0.45) : .clear)
        return Button { choose(platform) } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .frame(width: 17)
                    .accessibilityHidden(true)
                Text(title).fontWeight(selected ? .semibold : .regular)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(selected ? theme.accent : .secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .foregroundStyle(selected ? theme.accent : Color.primary)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedSource, equals: key)
        .onHover { inside in
            if inside { hoveredSource = key } else if hoveredSource == key { hoveredSource = nil }
        }
        .onMoveCommand { direction in
            let order = Self.orderedSources
            guard let index = order.firstIndex(of: platform) else { return }
            switch direction {
            case .up where index > 0: choose(order[index - 1])
            case .down where index + 1 < order.count: choose(order[index + 1])
            default: break
            }
        }
        .accessibilityLabel(title)
        .accessibilityValue("\(count) 项")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("platform-\(key)")
    }

    private var receiverCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(model.status.isRunning ? "接收中" : model.status.label)
                    .font(.caption.weight(.semibold))
            }
            if let artwork = GalleryMacArtwork.current {
                Image(nsImage: artwork)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "desktopcomputer")
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .opacity(0.76)
                    .accessibilityHidden(true)
            }
            Text("本机接收端")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.78))
            Text(verbatim: MacFamily.current.galleryName)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 156)
        .background(
            LinearGradient(colors: [Color(red: 0.06, green: 0.21, blue: 0.18),
                                    Color(red: 0.22, green: 0.44, blue: 0.38)],
                           startPoint: .bottomLeading, endPoint: .topTrailing),
            in: RoundedRectangle(cornerRadius: 17)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gallery-receiver-status")
    }

    private var statusColor: Color {
        switch model.status {
        case .running: Color(red: 0.63, green: 0.92, blue: 0.72)
        case .stopped, .failed: Color(red: 1.0, green: 0.65, blue: 0.61)
        case .starting, .stopping: .yellow
        }
    }
}

private extension MacFamily {
    var galleryName: String {
        switch self {
        case .mini: "Mac mini"
        case .studio: "Mac Studio"
        case .imac: "iMac"
        case .pro: "Mac Pro"
        case .book: "MacBook"
        case .air: "MacBook Air"
        case .bookPro: "MacBook Pro"
        case .neo: "MacBook Neo"
        case .mac: "Mac"
        }
    }
}

struct GalleryDeviceTabs: View {
    @ObservedObject var model: ReceiverModel
    let source: ScreenshotSource
    let devices: [ScreenshotDevice]
    let hasUnknown: Bool
    let selection: GalleryDeviceFilter
    let width: CGFloat
    let theme: GalleryTheme
    let select: (GalleryDeviceFilter) -> Void
    let manage: () -> Void

    @State private var showingPicker = false
    @FocusState private var focusedTab: GalleryDeviceFilter?

    private var options: [GalleryDeviceFilter] {
        devices.map(GalleryDeviceFilter.device) + (hasUnknown ? [.unknown] : [])
    }

    private func title(_ item: GalleryDeviceFilter) -> String {
        switch item {
        case .all: ReceiverModel.allPicturesLabel
        case .unknown: "未识别设备"
        case .device(let device): model.name(for: device)
        }
    }

    private func subtitle(_ item: GalleryDeviceFilter) -> String? {
        guard case let .device(device) = item else { return nil }
        return model.subtitle(for: device)
    }

    private func identifier(_ item: GalleryDeviceFilter) -> String {
        switch item {
        case .all: "device-all"
        case .unknown: "device-unknown"
        case .device(let device): "device-\(device.id)"
        }
    }

    private func visibleItems(_ candidates: [GalleryDeviceFilter]) -> [GalleryDeviceFilter] {
        let limit = width >= 750 ? 5 : width >= 535 ? 3 : width >= 425 ? 2 : 1
        var visible = Array(candidates.prefix(limit))
        if selection != .all, !visible.contains(selection), candidates.contains(selection), !visible.isEmpty {
            visible[visible.count - 1] = selection
        }
        return [.all] + visible
    }

    var body: some View {
        let candidates = options
        let visible = visibleItems(candidates)
        let hidden = candidates.count + 1 - visible.count
        return HStack(spacing: 7) {
            HStack(spacing: 2) {
                ForEach(visible, id: \.self) { item in
                    tab(item)
                        .focused($focusedTab, equals: item)
                        .onMoveCommand { direction in
                            guard let at = visible.firstIndex(of: item) else { return }
                            let next: Int
                            switch direction {
                            case .left: next = (at + visible.count - 1) % visible.count
                            case .right: next = (at + 1) % visible.count
                            default: return
                            }
                            select(visible[next])
                            focusedTab = visible[next]
                        }
                }
            }
            .padding(3)
            .background(theme.subnavigation, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.border) }

            if hidden > 0 {
                Button {
                    showingPicker.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("更多 \(hidden)")
                        Image(systemName: "chevron.down").font(.caption2)
                    }
                    .fixedSize()
                }
                .accessibilityLabel("更多手机，另有 \(hidden) 台")
                .accessibilityIdentifier("gallery-more-devices")
                .popover(isPresented: $showingPicker, arrowEdge: .bottom) {
                    GalleryDevicePicker(model: model, source: source, devices: devices, hasUnknown: hasUnknown,
                                        selection: selection, theme: theme) { chosen in
                        showingPicker = false
                        select(chosen)
                    }
                }
            }
            Button("管理手机", action: manage)
                .buttonStyle(.borderless)
                .foregroundStyle(theme.accent)
                .fixedSize()
                .disabled(devices.isEmpty)
                .accessibilityIdentifier("gallery-manage-devices")
        }
        .font(.callout)
        .controlSize(.small)
        .frame(maxWidth: max(1, width), alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(source.label) 手机来源")
    }

    private func tab(_ item: GalleryDeviceFilter) -> some View {
        let name = title(item)
        let selected = selection == item
        return Button { select(item) } label: {
            HStack(spacing: 4) {
                if item == .all { Image(systemName: "photo.on.rectangle").accessibilityHidden(true) }
                Text(verbatim: name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: name.count > 12 ? 108 : nil)
                if case .device(let device) = item {
                    ConversationTabBadge(room: model.conversation(for: device))
                }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? theme.accent : Color.primary)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(selected ? theme.panel : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .layoutPriority(item == .all ? 1 : 0)
        .buttonStyle(.plain)
        .help([name, subtitle(item)].compactMap { $0 }.joined(separator: " · "))
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier(identifier(item))
    }
}

private struct GalleryDevicePicker: View {
    @ObservedObject var model: ReceiverModel
    let source: ScreenshotSource
    let devices: [ScreenshotDevice]
    let hasUnknown: Bool
    let selection: GalleryDeviceFilter
    let theme: GalleryTheme
    let select: (GalleryDeviceFilter) -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var matching: [ScreenshotDevice] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return devices }
        return devices.filter { device in
            let profile = model.profile(for: device)
            return [model.name(for: device), profile?.model, profile?.name, model.systemDescription(for: device)]
                .compactMap { $0 }.contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        let results = matching
        let unknownMatches = hasUnknown && (search.isEmpty || "未识别设备".localizedStandardContains(search))
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("\(source.label) 手机").font(.headline)
                Spacer()
                Text(search.isEmpty ? "\(devices.count) 台" : "\(results.count + (unknownMatches ? 1 : 0)) 项")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextField("搜索手机名称或型号", text: $search)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit {
                    if let first = results.first { select(.device(first)) }
                    else if unknownMatches { select(.unknown) }
                }
                .accessibilityIdentifier("gallery-device-search")
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(results) { device in
                        option(.device(device), name: model.name(for: device), subtitle: model.subtitle(for: device))
                            .accessibilityIdentifier("pick-\(device.id)")
                    }
                    if unknownMatches {
                        option(.unknown, name: "未识别设备", subtitle: nil)
                    }
                    if results.isEmpty && !unknownMatches {
                        Text("没有找到匹配的手机")
                            .font(.callout).foregroundStyle(.secondary)
                            .padding(.vertical, 20)
                    }
                }
            }
            .frame(height: 235)
        }
        .padding(13)
        .frame(width: 295)
        .onAppear { searchFocused = true }
    }

    private func option(_ item: GalleryDeviceFilter, name: String, subtitle: String?) -> some View {
        Button { select(item) } label: {
            HStack(spacing: 9) {
                Image(systemName: "smartphone").foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: name).font(.callout.weight(.medium)).lineLimit(2)
                    if let subtitle { Text(verbatim: subtitle).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 6)
                if selection == item {
                    Image(systemName: "checkmark").foregroundStyle(theme.accent)
                }
                if case .device(let device) = item { ConversationTabBadge(room: model.conversation(for: device)) }
            }
            .padding(6)
            .background(selection == item ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == item ? [.isSelected] : [])
    }
}
