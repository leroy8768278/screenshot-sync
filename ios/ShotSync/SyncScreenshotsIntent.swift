import AppIntents

struct SyncScreenshotsIntent: AppIntent {
    static let title: LocalizedStringResource = "同步新截图到 Mac"
    static let description = IntentDescription("将配对后尚未发送的截图上传到即图当前连接的 Mac。")
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult {
        try await PhotoSync.shared.syncScreenshotsFromAutomation()
        return .result()
    }
}

struct SnapRelayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncScreenshotsIntent(),
            phrases: ["用\(.applicationName)同步新截图到 Mac"],
            shortTitle: "同步新截图到 Mac",
            systemImageName: "photo.on.rectangle"
        )
    }
}
