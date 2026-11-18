import Photos
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
        }
    }
}

private struct SyncHome: View {
    @ObservedObject var sync: PhotoSync
    @Environment(\.openURL) private var openURL
    @State private var showConnection = false

    private let accent = Color.indigo

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
                            showConnection = true
                        } label: {
                            LabeledContent("Mac 接收端", value: receiver.displayAddress)
                                .foregroundStyle(.primary)
                        }
                        .disabled(sync.working)

                        Toggle("自动同步", isOn: Binding(
                            get: { receiver.automatic },
                            set: { sync.setAutomatic($0) }
                        ))
                        .disabled(sync.working)

                        Button {
                            Task { await sync.scan(manual: true) }
                        } label: {
                            Label("立即同步", systemImage: "arrow.clockwise")
                        }
                        .disabled(sync.working || !sync.canReadPhotos)
                    } footer: {
                        Text("打开 App 时自动检查新截图。后台同步由 iOS 安排，时间可能延后。")
                    }

                    Section {
                        LabeledContent("已同步", value: "\(sync.sentCount) 张")
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
                        Button {
                            showConnection = true
                        } label: {
                            Label("连接 Mac", systemImage: "desktopcomputer")
                        }
                    } footer: {
                        Text("打开 Mac 上的截图同步 App，将两台设备连接到同一网络，再输入接收端的地址和配对码。")
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
            .navigationTitle("截图同步")
            .tint(accent)
            .sheet(isPresented: $showConnection) {
                ConnectionForm(sync: sync)
                    .tint(accent)
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(status)
                    .font(.title2.weight(.semibold))
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

    private var status: String {
        if sync.working { return "正在同步" }
        guard let receiver = sync.receiver else { return "连接你的 Mac" }
        if !sync.canReadPhotos { return "等待照片权限" }
        if sync.errorMessage != nil { return "同步需要处理" }
        return receiver.automatic ? "自动同步已开启" : "自动同步已暂停"
    }

    private var statusDetail: String {
        guard let receiver = sync.receiver else { return "通过局域网把 iPhone 截图发送到 Mac。" }
        return receiver.startDate == nil ? "同步范围包含已有截图" : "同步范围为配对后的截图"
    }

    private var lastSentLabel: String {
        sync.lastSent?.formatted(date: .abbreviated, time: .shortened) ?? "尚无记录"
    }

    private var photoAccessExplanation: String {
        if sync.permission == .limited { return "当前只会同步获准访问的截图。允许完全访问后，新截图可以自动加入同步。" }
        return "需要照片权限来识别系统截图。App 只处理截图。"
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
}

private struct ConnectionForm: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var sync: PhotoSync
    @State private var address: String
    @State private var code: String
    @State private var includeHistory: Bool
    @State private var connecting = false
    @State private var errorMessage: String?

    init(sync: PhotoSync) {
        self.sync = sync
        _address = State(initialValue: sync.receiver?.displayAddress ?? "")
        _code = State(initialValue: sync.receiver?.code ?? "")
        _includeHistory = State(initialValue: sync.receiver != nil && sync.receiver?.startDate == nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("192.168.1.25:43871", text: $address)
                        .accessibilityLabel("Mac 地址和端口")
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("24 位配对码", text: $code)
                        .accessibilityLabel("配对码")
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                } footer: {
                    Text("输入 Mac App 显示的地址和配对码，端口默认为 43871。")
                }

                Section {
                    Toggle("同步已有截图", isOn: $includeHistory)
                } footer: {
                    Text("关闭时，先前的截图不会加入本次同步范围。")
                }

                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        if connecting {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("正在验证连接")
                            }
                        } else {
                            Text("验证并保存")
                        }
                    }
                    .disabled(connecting || address.isEmpty || code.isEmpty)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("连接 Mac")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(connecting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(connecting)
                }
            }
        }
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        errorMessage = nil
        do {
            let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = input.replacingOccurrences(of: "http://", with: "", options: .anchored).components(separatedBy: ":")
            guard fields.count <= 2 else { throw SyncIssue.invalidAddress }
            let sameReceiver = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == sync.receiver?.code
            let startDate = includeHistory ? nil : (sameReceiver ? sync.receiver?.startDate ?? .now : .now)
            let receiver = try Receiver(
                address: fields[0], port: fields.count == 2 ? fields[1] : "43871", code: code,
                startDate: startDate, automatic: sync.receiver?.automatic ?? true
            )
            try await sync.connect(receiver)
            dismiss()
        } catch is URLError {
            errorMessage = PhotoSync.connectionError
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
