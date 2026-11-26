import PhotosUI
import SwiftUI
import UIKit

@main
struct ShotSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var phase
    @StateObject private var sync = PhotoSync.shared

    var body: some Scene {
        WindowGroup {
            SyncHome(sync: sync)
                .onChange(of: phase, initial: true) { _, newPhase in
                    sync.phaseChanged(newPhase)
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
                    sync.scanWhileActive()
                }
        }
    }
}

enum RelayStyle {
    static let green = Color(red: 0.07, green: 0.34, blue: 0.28)
    static let accent = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(red: 0.55, green: 0.86, blue: 0.72, alpha: 1)
            : UIColor(red: 0.07, green: 0.34, blue: 0.28, alpha: 1)
    })
    static let canvas = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark ? UIColor(red: 0.055, green: 0.085, blue: 0.078, alpha: 1)
            : UIColor(red: 0.974, green: 0.980, blue: 0.965, alpha: 1)
    })
    static let card = LinearGradient(colors: [Color(red: 0.22, green: 0.44, blue: 0.38),
                                               Color(red: 0.06, green: 0.21, blue: 0.18)],
                                     startPoint: .topTrailing, endPoint: .bottomLeading)
}

struct RelayDock: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var solid
    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 23)
        if #available(iOS 26.0, *), !solid {
            content.padding(7).glassEffect(.regular, in: shape)
        } else {
            content.padding(7)
                .background(solid ? AnyShapeStyle(Color(uiColor: .secondarySystemBackground)) : AnyShapeStyle(.regularMaterial), in: shape)
                .overlay { shape.strokeBorder(.secondary.opacity(0.18), lineWidth: 1) }
        }
    }
}

private struct DockButtonLabel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(.white)
            .background(RelayStyle.green, in: RoundedRectangle(cornerRadius: 16))
            .modifier(RelayDock())
            .contentShape(Rectangle())
    }
}

private struct SyncHome: View {
    private struct RecentClear {
        let receiver: Receiver
        let ids: Set<String>
    }

    @ObservedObject var sync: PhotoSync
    @Environment(\.scenePhase) private var phase
    @State private var showingSettings = false
    @State private var chat: PhoneConversation?
    @State private var connection: ConnectionScreen?
    @State private var manualDestination: ManualDestination?
    @State private var clearTarget: RecentClear?

    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "即图"
    private let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    private var paired: Receiver? { sync.receiver.flatMap { $0.pairedAt == nil ? nil : $0 } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if sync.permission != .authorized, paired?.automatic != false {
                        PhotoAccessNotice(sync: sync)
                    }
                    if let receiver = paired {
                        pairedCard(receiver)
                        if let chat {
                            ConversationLink(chat: chat).id(ObjectIdentifier(chat))
                        }
                        if let message = sync.errorMessage {
                            Label(message, systemImage: "exclamationmark.circle")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        receipts
                    } else {
                        if sync.receiver != nil {
                            Label("已保存连接，等待 Mac 验证", systemImage: "clock").font(.subheadline)
                            Button("验证已保存的连接") { connection = .manual }
                        }
                        welcome
                        if let error = sync.errorMessage {
                            Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 18)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(RelayStyle.canvas.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let receiver = paired {
                    Button { manualDestination = ManualDestination(receiver: receiver) } label: {
                        Label("手动发送", systemImage: "photo.on.rectangle")
                            .modifier(DockButtonLabel())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("manual-photos")
                    .padding(.horizontal, 14).padding(.bottom, 4)
                    .frame(maxWidth: 620)
                }
            }
            .navigationDestination(isPresented: $showingSettings) { settings }
            .toolbar(.hidden, for: .navigationBar)
        }
        .tint(RelayStyle.accent)
        .sheet(item: $connection) { screen in
            ConnectionForm(sync: sync, screen: screen).tint(RelayStyle.accent)
        }
        .sheet(item: $manualDestination) { destination in
            ManualSelectionSheet(sync: sync, destination: destination.receiver)
                .presentationDetents([.large]).presentationDragIndicator(.visible)
                .tint(RelayStyle.accent)
        }
        .alert("清除最近传输记录？", isPresented: Binding(
            get: { clearTarget != nil },
            set: { if !$0 { clearTarget = nil } }
        ), presenting: clearTarget) { target in
            Button("取消", role: .cancel) { }
            Button("清除记录", role: .destructive) {
                sync.clearRecent(ids: target.ids, for: target.receiver)
            }
        } message: { target in
            Text("将清除发往「\(target.receiver.displayName)」的 \(target.ids.count) 条最近记录。手机原件和 Mac 上的文件都会保留。")
        }
        .onChange(of: sync.receiver, initial: true) { _, receiver in
            if clearTarget?.receiver.historyKey != receiver?.historyKey { clearTarget = nil }
            let paired = receiver.flatMap { $0.pairedAt == nil ? nil : $0 }
            if paired == nil { showingSettings = false }
            guard chat?.receiver.historyKey != paired?.historyKey ||
                  chat?.receiver.displayAddress != paired?.displayAddress else { return }
            chat?.action?.cancel()
            chat?.download?.cancel()
            chat = paired.map(PhoneConversation.init)
        }
        .task(id: phase == .active ? chat.map(ObjectIdentifier.init) : nil) {
            if phase == .active { await chat?.poll() }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(appName).font(.largeTitle.bold())
                if let version { Text("v\(version)").font(.caption.weight(.medium)).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if paired != nil {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape").font(.body.weight(.medium)).frame(width: 44, height: 44)
                        .background(Color.secondary.opacity(0.09), in: Circle())
                }
                .accessibilityLabel("连接与同步设置")
            }
        }
        .padding(.top, 8)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Label("尚未配对", systemImage: "link").font(.caption.weight(.semibold))
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 62, weight: .light)).foregroundStyle(.white.opacity(0.9))
                    .overlay(alignment: .center) {
                        Image(systemName: "qrcode").font(.system(size: 20)).offset(y: -7)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .accessibilityHidden(true)
                Text("连接你的 Mac").font(.title.bold())
                Text("配对后，新截的图会自动传到 Mac。").font(.subheadline)
                Button { connection = .scan } label: {
                    Label("扫码连接 Mac", systemImage: "qrcode.viewfinder")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 46)
                }
                .buttonStyle(.plain).foregroundStyle(RelayStyle.green)
                .background(.white, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("scan-mac")
            }
            .padding(20).foregroundStyle(.white)
            .background(RelayStyle.card, in: RoundedRectangle(cornerRadius: 24))
            Button("手动输入地址和配对码") { connection = .manual }
                .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("manual-pairing")
            Text("在 Mac 上打开配对码").font(.headline)
            Label("让手机和 Mac 接入同一局域网。", systemImage: "wifi")
            Label("在 Mac 版即图右上角点「扫码配对」。", systemImage: "qrcode")
        }
        .font(.subheadline)
    }

    private func automaticStatus(for receiver: Receiver) -> String {
        if !receiver.automatic { return "自动同步已暂停" }
        if sync.permission == .limited { return "自动同步 · 仅限所选照片" }
        return sync.canReadPhotos ? "自动同步已开启" : "自动同步待授权"
    }

    private func pairedCard(_ receiver: Receiver) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("已配对设备 · \(receiver.macProfile?.familyName ?? "Mac")", systemImage: "link")
                        .font(.caption.weight(.medium))
                    Text(receiver.displayName).font(.title2.bold()).privacySensitive()
                    Text(sync.errorMessage == PhotoSync.connectionError ? "暂时无法连接" :
                            sync.lastSent.map { "上次送达 \(Self.time($0))" } ?? "等待首次传输")
                        .font(.footnote)
                }
                Spacer(minLength: 0)
                Image(receiver.macProfile?.artwork ?? "receiver_mac")
                    .resizable().scaledToFit().frame(maxWidth: 100, maxHeight: 78)
                    .accessibilityHidden(true)
            }
            Button { connection = .scan } label: {
                Label("扫码更换 Mac", systemImage: "qrcode.viewfinder").font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12).frame(minHeight: 40)
            }
            .buttonStyle(.plain)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("scan-mac")
            Divider().overlay(.white.opacity(0.28))
            HStack(spacing: 8) {
                Circle().fill(receiver.automatic ? Color.mint : Color(red: 1, green: 0.44, blue: 0.40))
                    .frame(width: 9, height: 9).accessibilityHidden(true)
                Text(automaticStatus(for: receiver))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(receiver.automatic ? "暂停" : "继续") { sync.setAutomatic(!receiver.automatic) }
                    .font(.subheadline.weight(.semibold)).buttonStyle(.bordered)
                    .tint(.white).accessibilityLabel(receiver.automatic ? "暂停自动同步" : "继续自动同步")
            }
        }
        .padding(20).foregroundStyle(.white)
        .background(RelayStyle.card, in: RoundedRectangle(cornerRadius: 24))
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened)
    }

    private var receipts: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近传输").font(.title3.bold())
                if sync.sentCount > 0 { Text("累计 \(sync.sentCount) 项").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let receiver = paired, !sync.recent.isEmpty {
                    Button {
                        clearTarget = RecentClear(receiver: receiver, ids: Set(sync.recent.map(\.id)))
                    } label: {
                        Text("清除记录").font(.subheadline).frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("clear-recent-transfers")
                }
            }
            .padding(.bottom, 10)
            if sync.recent.isEmpty {
                Text(sync.sentCount == 0 ? "截图或手动发送后，可在这里查看送达记录。" : "新的送达记录会显示在这里。")
                    .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 10)
            }
            ForEach(sync.recent) { receipt in
                HStack(spacing: 12) {
                    Group {
                        if let bytes = receipt.thumbnail, let thumbnail = UIImage(data: bytes) {
                            Image(uiImage: thumbnail).resizable().scaledToFill()
                        } else {
                            Image(systemName: receipt.kind == .video ? "film" : "photo")
                                .foregroundStyle(RelayStyle.accent)
                        }
                    }
                    .frame(width: 43, height: 49)
                    .background(RelayStyle.accent.opacity(0.07)).clipShape(.rect(cornerRadius: 7))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.captured.map { "截图 \($0.formatted(date: .omitted, time: .standard))" } ?? (receipt.kind == .video ? "视频" : "照片"))
                            .font(.subheadline.weight(.semibold))
                        Text("\(receipt.kind == .screenshot ? "自动同步" : "手动发送") · \(ByteCountFormatter.string(fromByteCount: Int64(receipt.bytes), countStyle: .file))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 3)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(Self.time(receipt.delivered)).font(.caption.monospacedDigit())
                        Label("已送达", systemImage: "checkmark").font(.caption2).foregroundStyle(RelayStyle.accent)
                    }
                }
                .accessibilityElement(children: .combine)
                .padding(.vertical, 9)
                Divider()
            }
        }
    }

    private var settings: some View {
        Form {
            if let receiver = sync.receiver {
                Section("接收设备") {
                    LabeledContent("名称", value: receiver.displayName)
                    LabeledContent("局域网地址", value: receiver.displayAddress).privacySensitive()
                    Button("手动配对") { connection = .manual }
                }
                Section {
                    Toggle("自动同步新截图", isOn: Binding(get: { sync.receiver?.automatic ?? false }, set: sync.setAutomatic))
                    if let date = receiver.pairedAt {
                        Text("仅同步 \(date.formatted(date: .abbreviated, time: .shortened)) 配对后截取的新图。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if #available(iOS 27.0, *) {
                        NavigationLink("后台截屏同步") { ScreenshotAutomationGuide() }
                    }
                } header: { Text("自动同步") } footer: {
                    Text("暂停后仍可手动发送照片和视频。")
                }
                if sync.permission != .authorized {
                    Section {
                        PhotoAccessNotice(sync: sync)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .navigationTitle("连接与同步").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }

    private struct ManualDestination: Identifiable {
        let id = UUID()
        let receiver: Receiver
    }
}

private struct PhotoAccessNotice: View {
    @ObservedObject var sync: PhotoSync
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @State private var requesting = false

    private var message: (title: String, detail: String) {
        switch sync.permission {
        case .notDetermined:
            ("自动同步需要照片权限", "在接下来的系统弹窗中选择「完全访问」，即图就能读取配对后新截的图，并发送到你的 Mac。")
        case .limited:
            ("当前只能访问部分照片", "即图只能读取你选过的照片。要自动发现新截图，请在系统设置的「照片」中改为「完全访问」。")
        case .denied:
            ("照片权限已关闭", "自动同步暂时无法读取新截图。请在系统设置中点「照片」，选择「完全访问」。")
        case .restricted:
            ("照片访问受系统限制", "请检查屏幕使用时间或设备管理限制。解除限制后，即图才能自动读取新截图。")
        default:
            ("检查照片访问权限", "请在系统设置的「照片」中查看即图的访问权限。")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(message.title)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(scheme == .dark ? Color.orange : Color(red: 0.60, green: 0.31, blue: 0.05))
            }
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
            Text(message.detail)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            if sync.permission != .restricted {
                Button {
                    if sync.permission == .notDetermined {
                        guard !requesting else { return }
                        requesting = true
                        Task {
                            await sync.requestPhotoAccess()
                            requesting = false
                        }
                    } else if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                } label: {
                    Text(sync.permission == .notDetermined ? "开启照片访问" : "打开系统设置")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(RelayStyle.green, in: RoundedRectangle(cornerRadius: 13))
                .disabled(requesting)
                .accessibilityIdentifier("photo-access-action")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.primary)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(scheme == .dark ? Color(red: 0.19, green: 0.16, blue: 0.11) : Color(red: 1, green: 0.96, blue: 0.87))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(.orange.opacity(0.42))
                .allowsHitTesting(false)
        }
    }
}

private struct ScreenshotAutomationGuide: View {
    var body: some View {
        List {
            Section {
                Text("在「快捷指令」中新建快捷指令，搜索并添加即图的「同步新截图到 Mac」操作。")
                Text("在编辑器的「自动化」里添加「截屏」，选择存储到「照片」，并在这台 iPhone 上启用自动化。")
                Link("新建快捷指令", destination: URL(string: "shortcuts://create-shortcut")!)
            } footer: {
                Text("先允许即图完全访问照片和本地网络。设置好后，在其他 App 中正常截屏并存入「照片」，即图就会尝试发送到当前配对的 Mac。暂停自动同步也会暂停这个操作。")
            }
        }
        .navigationTitle("后台截屏同步")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private enum ConnectionScreen: Hashable, Identifiable {
    case scan, manual
    var id: Self { self }
}

private struct ConnectionForm: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync: PhotoSync
    @State private var address: String
    @State private var code: String
    @State private var connecting = false
    @State private var screen: ConnectionScreen
    @State private var verification: Task<Void, Never>?
    @State private var confirmDisconnect = false
    @State private var errorMessage: String?

    init(sync: PhotoSync, screen: ConnectionScreen) {
        self.sync = sync
        _screen = State(initialValue: screen)
        _address = State(initialValue: sync.receiver?.displayAddress ?? "")
        _code = State(initialValue: sync.receiver?.code ?? "")
    }

    var body: some View {
        if screen == .scan {
            PairingScanner(currentMacName: sync.receiver?.displayName, manual: { screen = .manual }) { text in
                screen = .manual
                startConnection(qr: text)
            }
        } else {
            form
        }
    }

    private var form: some View {
        NavigationStack {
            Form {
                if verification != nil {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在验证连接")
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }
                Section {
                    Button {
                        errorMessage = nil
                        screen = .scan
                    } label: {
                        Label(sync.receiver == nil ? "扫码连接 Mac" : "扫码更换 Mac", systemImage: "qrcode.viewfinder")
                    }
                    .disabled(connecting)
                    .accessibilityIdentifier("scan-pairing-code")
                } footer: {
                    Text(sync.receiver == nil ? "扫描 Mac 上的即图配对二维码即可连接。" : "扫描另一台 Mac 的即图配对二维码，验证成功后将切换到新 Mac。")
                }

                Section {
                    TextField("192.168.1.25:43871", text: $address)
                        .accessibilityLabel("Mac 地址和端口")
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("24 位配对码", text: $code)
                        .accessibilityLabel("配对码")
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                } header: {
                    Text("手动配对")
                } footer: {
                    Text("输入 Mac App 显示的地址和配对码，端口默认为 43871。")
                }

                Section {
                    Button(sync.receiver == nil ? "连接 Mac" : "验证并保存") {
                        startConnection()
                    }
                    .disabled(connecting || address.isEmpty || code.isEmpty)
                    .accessibilityIdentifier("confirm-connection")
                }

                if sync.receiver != nil {
                    Section {
                        Button("断开连接", role: .destructive) { confirmDisconnect = true }
                            .disabled(connecting)
                    }
                }
            }
            .navigationTitle("连接 Mac")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(connecting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        verification?.cancel()
                        dismiss()
                    }
                    .disabled(connecting && verification == nil)
                }
            }
            .confirmationDialog("断开与当前 Mac 的连接？", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("断开连接", role: .destructive) {
                    Task { await disconnect() }
                }
            } message: {
                Text("下次配对会从新的连接时间开始自动同步。")
            }
        }
    }

    private func startConnection(qr: String? = nil) {
        guard !connecting else { return }
        connecting = true
        errorMessage = nil
        verification = Task {
            defer {
                connecting = false
                verification = nil
            }
            do {
                if let qr {
                    try await sync.connect(scannedCode: qr)
                } else {
                    let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
                    let fields = input.replacingOccurrences(of: "http://", with: "", options: .anchored).components(separatedBy: ":")
                    guard fields.count <= 2 else { throw SyncIssue.invalidAddress }
                    let receiver = try Receiver(
                        address: fields[0], port: fields.count == 2 ? fields[1] : "43871", code: code,
                        automatic: true
                    )
                    try await sync.connect(receiver)
                }
                dismiss()
            } catch {
                if !Task.isCancelled {
                    errorMessage = error is URLError ? PhotoSync.connectionError : error.localizedDescription
                }
            }
        }
    }

    private func disconnect() async {
        connecting = true
        defer { connecting = false }
        do {
            try await sync.disconnect()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ManualSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var sync: PhotoSync
    let destination: Receiver

    @State private var showingPicker = false
    @State private var openedPicker = false
    @State private var selection: [PhotosPickerItem] = []
    @State private var remaining: [PhotosPickerItem] = []
    @State private var transfer: Task<Void, Never>?
    @State private var attemptID: UUID?
    @State private var progress = PhotoSync.ManualUploadProgress(item: 1)
    @State private var summary: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Image(systemName: "desktopcomputer").foregroundStyle(RelayStyle.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("发送到").font(.caption).foregroundStyle(.secondary)
                            Text(destination.macProfile != nil ? destination.displayName : destination.displayAddress)
                                .font(.headline).privacySensitive()
                        }
                        Spacer()
                    }
                    if !remaining.isEmpty {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 82, maximum: 128))], alignment: .leading, spacing: 8) {
                            ForEach(Array(remaining.enumerated()), id: \.offset) { _, item in
                                SelectedMediaThumbnail(item: item)
                            }
                        }
                        Text(selectionSummary).font(.headline)
                    }
                    if let summary {
                        Label(summary, systemImage: "checkmark.circle").foregroundStyle(RelayStyle.accent)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle").font(.subheadline)
                    }
                    if transfer == nil {
                        Button(remaining.isEmpty ? "选择照片或视频" : "重新选择") { showingPicker = true }
                            .accessibilityIdentifier("open-photo-picker")
                    }
                }
                .padding(20).frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(RelayStyle.canvas.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if transfer != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        transferProgress
                        Button("停止本次发送", role: .destructive) { transfer?.cancel() }
                    }
                    .padding(8).frame(maxWidth: 620, alignment: .leading)
                    .modifier(RelayDock()).padding(.horizontal, 14)
                } else if !remaining.isEmpty {
                    Button { send() } label: {
                        Text(errorMessage == nil ? "发送 \(remaining.count) 项" : "重试 \(remaining.count) 项")
                            .modifier(DockButtonLabel())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("send-picked-photos")
                    .padding(.horizontal, 14)
                }
            }
            .navigationTitle("确认发送")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                        .disabled(transfer != nil)
                }
            }
            .interactiveDismissDisabled(transfer != nil)
            .photosPicker(
                isPresented: $showingPicker, selection: $selection, selectionBehavior: .ordered,
                matching: .any(of: [.images, .videos]), preferredItemEncoding: .current, photoLibrary: .shared()
            )
            .onChange(of: selection) { _, items in
                remaining = items
                summary = nil
                errorMessage = nil
            }
            .task {
                if !openedPicker {
                    openedPicker = true
                    showingPicker = true
                }
            }
            .onDisappear { transfer?.cancel() }
        }
    }

    @ViewBuilder
    private var transferProgress: some View {
        let position = "第 \(progress.item)/\(remaining.count) 项"
        if let total = progress.total, total > 0, progress.sent < total {
            let sent = ByteCountFormatter.string(fromByteCount: progress.sent, countStyle: .file)
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            let percent = progress.sent * 100 / total
            ProgressView(value: Double(progress.sent), total: Double(total)) {
                Text("正在上传\(position) · \(percent)%")
            } currentValueLabel: {
                Text("\(sent) / \(size)")
            }
            .accessibilityIdentifier("manual-upload-progress")
        } else {
            HStack {
                ProgressView().controlSize(.small)
                Text(progress.total == nil ? "正在准备\(position)" : "\(position)已上传，等待 Mac 确认")
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var selectionSummary: String {
        let videos = remaining.filter(\.isVideoSelection).count
        let photos = remaining.count - videos
        return [photos > 0 ? "\(photos) 张照片" : nil, videos > 0 ? "\(videos) 个视频" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func send() {
        guard transfer == nil, !remaining.isEmpty else { return }
        let items = remaining
        errorMessage = nil
        let attempt = UUID()
        attemptID = attempt
        progress = PhotoSync.ManualUploadProgress(item: 1)
        transfer = Task {
            let result = await sync.sendSelection(items, to: destination) { update in
                guard attemptID == attempt, update.item >= progress.item else { return }
                guard update.item != progress.item || update.sent >= progress.sent else { return }
                progress = update
            }
            attemptID = nil
            remaining = result.remaining
            if result.sent > 0 {
                summary = "已发送 \(result.sent) 项"
            } else if result.alreadySent > 0 {
                summary = "已跳过 \(result.alreadySent) 个已发送的项目"
            }
            errorMessage = result.message
            transfer = nil
            if result.sent > 0, result.remaining.isEmpty, result.message == nil { dismiss() }
        }
    }
}

private struct SelectedMediaThumbnail: View {
    let item: PhotosPickerItem
    @State private var thumbnail: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.1))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if item.isVideoSelection {
                    VStack(spacing: 4) {
                        Image(systemName: "play.rectangle")
                        Text("视频").font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                } else if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .accessibilityHidden(!item.isVideoSelection)
            .task(id: item) {
                thumbnail = nil
                guard !item.isVideoSelection else { return }
                let preview = try? await item.loadTransferable(type: PickerThumbnail.self)
                if !Task.isCancelled, let preview { thumbnail = UIImage(cgImage: preview.image) }
            }
    }
}
