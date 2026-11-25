import AppKit
import CoreGraphics
import SwiftUI

@MainActor
final class LocalCaptureController: NSObject, ObservableObject, NSWindowDelegate {
    let shortcut: CaptureShortcut
    @Published private(set) var selecting = false
    @Published private(set) var hasScreenAccess = false
    private let region = RegionCapture()
    private let onSave: (CGImage) async throws -> Void
    private var editorWindows = Set<NSWindow>()

    init(onSave: @escaping (CGImage) async throws -> Void) {
        self.onSave = onSave
        shortcut = CaptureShortcut()
        super.init()
        shortcut.onTrigger = { [weak self] in self?.start() }
        NotificationCenter.default.addObserver(self, selector: #selector(prepareToQuit),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    func updateAccess() { hasScreenAccess = CGPreflightScreenCaptureAccess() }

    func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestAccess() {
        hasScreenAccess = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        if !hasScreenAccess { openPermissions() }
    }

    func start() {
        guard !selecting else { return }
        selecting = true
        hasScreenAccess = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        guard hasScreenAccess else {
            defer { selecting = false }
            let alert = NSAlert()
            alert.messageText = "允许即图截取屏幕"
            alert.informativeText = "在系统设置的「隐私与安全性」中，允许即图录制屏幕，再开始截图。"
            alert.addButton(withTitle: "打开系统设置")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { openPermissions() }
            return
        }
        Task {
            defer { selecting = false }
            do {
                if let image = try await selectRegion() { presentEditor(image) }
            } catch {
                let alert = NSAlert(error: error)
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private func selectRegion() async throws -> CGImage? {
        let visible = NSApp.orderedWindows.filter {
            editorWindows.contains($0) && $0.isVisible && $0.isOnActiveSpace && !$0.isMiniaturized
        }
        let key = NSApp.isActive ? NSApp.keyWindow : nil
        for window in visible { window.orderOut(nil) }
        defer {
            for window in visible where editorWindows.contains(window) { window.orderBack(nil) }
            if let key, visible.contains(key), editorWindows.contains(key) { key.makeKeyAndOrderFront(nil) }
        }
        return try await region.select()
    }

    private func presentEditor(_ image: CGImage) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 570),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        let editor = LocalScreenshotEditor(image: image, onSave: onSave) { [weak window] in
            window?.close()
        }
        window.contentViewController = NSHostingController(rootView: editor)
        window.title = "编辑本机截图"
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentMinSize = NSSize(width: 550, height: 335)
        window.setContentSize(NSSize(width: 820, height: 570))
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        editorWindows.insert(window)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { editorWindows.remove(window) }
    }

    @objc private func prepareToQuit() { region.cancel() }
}

struct LocalCaptureSettings: View {
    @ObservedObject var capture: LocalCaptureController

    var body: some View {
        Form {
            Section("全局截图快捷键") {
                CaptureShortcutSettings(shortcut: capture.shortcut)
            }
            Section("屏幕录制权限") {
                HStack {
                    Label(capture.hasScreenAccess ? "已允许截屏" : "需要授权才能截屏",
                          systemImage: capture.hasScreenAccess ? "checkmark.circle" : "lock")
                    Spacer()
                    if !capture.hasScreenAccess {
                        Button("去授权", action: capture.requestAccess)
                            .accessibilityIdentifier("local-capture-permission")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: capture.updateAccess)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            capture.updateAccess()
        }
    }
}
