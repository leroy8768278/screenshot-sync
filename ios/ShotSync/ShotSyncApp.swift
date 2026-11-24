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

private struct SyncHome: View {
    @ObservedObject var sync: PhotoSync
    @Environment(\.openURL) private var openURL
    @State private var connection: ConnectionScreen?
    @State private var manualDestination: ManualDestination?

    private let accent = Color.indigo
    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "即图"
    private var homeTitle: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return appName }
        return "\(appName) v\(version)"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    statusCard
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }

                if let receiver = sync.receiver {
                    Section {
                        Button {
                            manualDestination = ManualDestination(receiver: receiver)
                        } label: {
                            Text("手动发送")
                                .font(.headline)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.borderedProminent)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("manual-photos")
                    } footer: {
                        Text("可从系统相册选择照片或视频，确认后发送。")
                    }

                    Section {
                        Button {
                            connection = .manual
                        } label: {
                            LabeledContent("Mac 接收端", value: receiver.displayAddress)
                                .foregroundStyle(.primary)
                        }

                        scanButton

                        if receiver.automatic {
                            Button {
                                sync.setAutomatic(false)
                            } label: {
                                Label("暂停自动同步", systemImage: "pause.circle")
                            }
                        } else {
                            Button {
                                sync.setAutomatic(true)
                            } label: {
                                Label("继续自动同步", systemImage: "play.circle")
                            }
                        }
                        if #available(iOS 27.0, *) {
                            NavigationLink {
                                ScreenshotAutomationGuide()
                            } label: {
                                Label("设置后台截屏同步", systemImage: "bolt.circle")
                            }
                        }
                    } footer: {
                        if !receiver.automatic {
                            Text("继续后会补传配对成功后尚未同步的新截图。")
                        } else if #available(iOS 27.0, *) {
                            Text("要在其他 App 中截屏后立即发送，请设置一次后台截屏同步。")
                        } else {
                            Text("返回即图会立即检查待传截图，后台补传由 iOS 调度。")
                        }
                    }

                    Section("最近传输") {
                        LabeledContent("已同步", value: "\(sync.sentCount) 项")
                        LabeledContent("上次同步", value: lastSentLabel)
                    }

                    if sync.permission != .authorized {
                        Section {
                            photoAccess
                        } footer: {
                            Text(photoAccessExplanation)
                        }
                    }
                } else {
                    Section {
                        scanButton
                        Button {
                            connection = .manual
                        } label: {
                            Label("手动配对", systemImage: "keyboard")
                        }
                    } footer: {
                        Text("两台设备连接同一网络后，在 Mac 上打开「\(appName)」，点击「扫码配对」显示二维码。")
                    }
                }

                if let errorMessage = sync.errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(homeTitle)
            .tint(accent)
            .sheet(item: $connection) { screen in
                ConnectionForm(sync: sync, screen: screen)
                    .tint(accent)
            }
            .sheet(item: $manualDestination) { destination in
                ManualSelectionSheet(sync: sync, destination: destination.receiver)
                    .tint(accent)
            }
        }
    }

    private var scanButton: some View {
        Button {
            connection = .scan
        } label: {
            Label(sync.receiver == nil ? "扫一扫配对" : "扫码更换 Mac", systemImage: "qrcode.viewfinder")
        }
        .accessibilityIdentifier("scan-mac")
    }

    private var statusCard: some View {
        let current = status
        return VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(current.title)
                        .font(.title2.weight(.semibold))
                    Circle()
                        .fill(current.color)
                        .frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                }
                Text(statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(23)
        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .combine)
    }

    private var status: (title: String, color: Color) {
        guard let receiver = sync.receiver else { return ("连接你的 Mac", .red) }
        if receiver.pairedAt == nil {
            return (sync.working ? "正在验证连接" : "等待 Mac 验证", .red)
        }
        if !receiver.automatic { return ("自动同步已暂停", .red) }
        if !sync.canReadPhotos { return ("等待相册授权", .red) }
        if sync.errorMessage == PhotoSync.connectionError { return ("已配对 · Mac 暂不可达", .red) }
        if sync.errorMessage != nil { return ("自动同步需要处理", .red) }
        if sync.working { return ("正在自动同步", .green) }
        if sync.permission == .limited { return ("自动同步 · 照片权限有限", .green) }
        return ("自动同步已开启", .green)
    }

    private var statusDetail: String {
        guard let receiver = sync.receiver else { return "通过局域网把截图、照片和视频发送到 Mac。" }
        guard let pairedAt = receiver.pairedAt else { return "连接成功后，才会开始记录新截图。" }
        let date = pairedAt.formatted(date: .abbreviated, time: .shortened)
        return "仅自动同步 \(date) 配对成功后截取的新截图。"
    }

    private var lastSentLabel: String {
        sync.lastSent?.formatted(date: .abbreviated, time: .shortened) ?? "尚无记录"
    }

    private var photoAccessExplanation: String {
        if sync.permission == .limited { return "当前只会同步获准访问的截图。允许完全访问后，新截图可以自动加入同步。" }
        return "允许访问相册后会自动识别新截图。也可先通过系统相册手动发送。"
    }

    private var photoAccess: some View {
        Button {
            if sync.permission == .notDetermined {
                Task { await sync.requestPhotoAccess() }
            } else if let settings = URL(string: UIApplication.openSettingsURLString) {
                openURL(settings)
            }
        } label: {
            Label(sync.permission == .notDetermined ? "允许访问照片" : "管理照片权限", systemImage: "photo.on.rectangle")
        }
    }

    private struct ManualDestination: Identifiable {
        let id = UUID()
        let receiver: Receiver
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
            PairingScanner(manual: { screen = .manual }) { text in
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
                        Label("扫一扫配对", systemImage: "qrcode.viewfinder")
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
    @State private var completed = 0
    @State private var summary: String?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("发送到 Mac", value: destination.displayAddress)
                    if remaining.isEmpty, summary == nil {
                        Text("从系统相册选择要发送的照片或视频。")
                            .foregroundStyle(.secondary)
                    } else if !remaining.isEmpty {
                        Text("已选 \(remaining.count) 项")
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                            ForEach(Array(remaining.enumerated()), id: \.offset) { _, item in
                                SelectedMediaThumbnail(item: item)
                            }
                        }
                    }
                }

                if let summary {
                    Section {
                        Label(summary, systemImage: "checkmark.circle")
                    }
                }

                Section {
                    if transfer != nil {
                        ProgressView(value: Double(completed), total: Double(max(1, remaining.count))) {
                            Text("正在发送 \(completed)/\(remaining.count)")
                        }
                        Button("停止本次发送", role: .destructive) { transfer?.cancel() }
                    } else {
                        if !remaining.isEmpty {
                            Button(errorMessage == nil ? "发送 \(remaining.count) 项" : "重试 \(remaining.count) 项") {
                                send()
                            }
                            .accessibilityIdentifier("send-picked-photos")
                        }
                        Button("选择照片或视频") { showingPicker = true }
                            .accessibilityIdentifier("open-photo-picker")
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
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
                completed = 0
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

    private func send() {
        guard transfer == nil, !remaining.isEmpty else { return }
        let items = remaining
        errorMessage = nil
        completed = 0
        transfer = Task {
            let result = await sync.sendSelection(items, to: destination) { completed = $0 }
            remaining = result.remaining
            if result.sent > 0 {
                summary = "已发送 \(result.sent) 项"
            } else if result.alreadySent > 0 {
                summary = "已跳过 \(result.alreadySent) 个已发送的项目"
            }
            errorMessage = result.message
            transfer = nil
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
