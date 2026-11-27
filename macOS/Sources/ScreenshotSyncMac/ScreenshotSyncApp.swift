import AppKit
import SwiftUI

@main
struct ScreenshotSyncApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: ReceiverModel
    @StateObject private var capture: LocalCaptureController
    @Environment(\.openWindow) private var openWindow
    private let displayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "即图"

    init() {
        let receiver = ReceiverModel()
        _model = StateObject(wrappedValue: receiver)
        _capture = StateObject(wrappedValue: LocalCaptureController(onSave: receiver.saveLocalScreenshot))
    }

    private var windowTitle: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return displayName }
        return "\(displayName) v\(version)"
    }

    var body: some Scene {
        Window(windowTitle, id: "inbox") {
            GalleryView(model: model, capture: capture)
                .frame(minWidth: 660, minHeight: 515)
        }
        .defaultSize(width: 1_024, height: 712)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("本机截图设置") { openWindow(id: "local-capture-settings") }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        Window("本机截图设置", id: "local-capture-settings") {
            LocalCaptureSettings(capture: capture)
        }
        .windowResizability(.contentSize)

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
            Button("本机截图", action: capture.start)
                .disabled(capture.selecting)
            Button("本机截图设置") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "local-capture-settings")
            }
            Divider()
            Button("退出 \(displayName)") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
