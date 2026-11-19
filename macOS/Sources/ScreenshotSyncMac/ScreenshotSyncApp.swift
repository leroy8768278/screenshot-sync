import AppKit
import SwiftUI

@main
struct ScreenshotSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = ReceiverModel()
    @Environment(\.openWindow) private var openWindow
    private let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "即图"

    var body: some Scene {
        Window(displayName, id: "inbox") {
            GalleryView(model: model)
                .frame(minWidth: 660, minHeight: 515)
        }
        .defaultSize(width: 1_015, height: 690)
        .windowToolbarStyle(.unified)

        MenuBarExtra(displayName, systemImage: model.status.isRunning ? "tray.and.arrow.down.fill" : "tray") {
            Text(model.status.label)
            Button("显示 \(displayName)") {
                openWindow(id: "inbox")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(model.status.isRunning ? "暂停接收" : "开启接收", action: model.toggleReceiver)
                .disabled(!model.status.canToggle)
            Button("打开截图文件夹", action: model.openFolder)
            Divider()
            Button("退出 \(displayName)") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
