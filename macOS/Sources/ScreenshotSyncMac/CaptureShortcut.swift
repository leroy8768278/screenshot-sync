import AppKit
import Carbon
import SwiftUI

private struct ShortcutKey: Codable, Equatable {
    let code: UInt32
    let modifiers: UInt32
    let label: String

    static let standard = Self(code: UInt32(kVK_ANSI_S), modifiers: UInt32(controlKey | optionKey), label: "S")

    var displayName: String {
        var prefix = ""
        for (flag, symbol) in [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")] {
            if modifiers & UInt32(flag) != 0 { prefix += symbol }
        }
        return prefix + label
    }

    init(code: UInt32, modifiers: UInt32, label: String) {
        self.code = code
        self.modifiers = modifiers
        self.label = label
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        let special: [Int: String] = [kVK_Space: "空格", kVK_Tab: "⇥", kVK_Return: "↩", kVK_Delete: "⌫",
                                      kVK_ForwardDelete: "⌦", kVK_LeftArrow: "←", kVK_RightArrow: "→",
                                      kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "Home", kVK_End: "End",
                                      kVK_PageUp: "PgUp", kVK_PageDown: "PgDn"]
        let text: String
        if let name = special[Int(event.keyCode)] {
            text = name
        } else if let chars = event.characters(byApplyingModifiers: []), chars.count == 1,
                  let scalar = chars.unicodeScalars.first {
            if (0xF704...0xF717).contains(scalar.value) {
                text = "F\(scalar.value - 0xF704 + 1)"
            } else {
                guard !CharacterSet.controlCharacters.contains(scalar),
                      scalar.properties.generalCategory != .privateUse else { return nil }
                text = chars.uppercased()
            }
        } else {
            return nil
        }
        var modifiers: UInt32 = 0
        for (flag, carbon) in [(NSEvent.ModifierFlags.control, controlKey), (.option, optionKey),
                               (.shift, shiftKey), (.command, cmdKey)] where flags.contains(flag) {
            modifiers |= UInt32(carbon)
        }
        self.init(code: UInt32(event.keyCode), modifiers: modifiers, label: text)
    }
}

@MainActor
final class CaptureShortcut: ObservableObject {
    private struct Configuration: Codable {
        var key = ShortcutKey.standard
        var enabled = true
    }

    private static let defaultsKey = "macCaptureShortcut"
    private static let signature: OSType = 0x4A695475 // JiTu
    private static var nextID: UInt32 = 0
    private let defaults: UserDefaults
    @Published private var configuration: Configuration
    @Published fileprivate var recording = false
    @Published fileprivate private(set) var message: String?
    private var handler: EventHandlerRef?
    private var registered: EventHotKeyRef?
    private var registeredID: UInt32?

    var displayName: String {
        guard configuration.enabled else { return "已停用" }
        return registered == nil ? "\(configuration.key.displayName)（不可用）" : configuration.key.displayName
    }
    fileprivate var enabled: Bool { configuration.enabled }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(Configuration.self, from: $0) } ?? Configuration()
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var keyID = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &keyID)
            guard result == noErr else { return result }
            return MainActor.assumeIsolated {
                let shortcut = Unmanaged<CaptureShortcut>.fromOpaque(context).takeUnretainedValue()
                guard keyID.signature == CaptureShortcut.signature, keyID.id == shortcut.registeredID else {
                    return OSStatus(eventNotHandledErr)
                }
                if shortcut.recording {
                    shortcut.cancelRecording()
                } else {
                    shortcut.onTrigger?()
                }
                return noErr
            }
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr {
            message = "无法启用全局快捷键。"
        } else if configuration.enabled {
            activate(configuration.key)
        }
    }

    var onTrigger: (() -> Void)?

    isolated deinit {
        if let registered { UnregisterEventHotKey(registered) }
        if let handler { RemoveEventHandler(handler) }
    }

    fileprivate func beginRecording() {
        message = nil
        recording = true
    }

    fileprivate func cancelRecording() {
        recording = false
        message = nil
    }

    fileprivate func accept(_ event: NSEvent) {
        guard recording, !event.isARepeat else { return }
        if Int(event.keyCode) == kVK_Escape {
            cancelRecording()
        } else if let key = ShortcutKey(event: event) {
            recording = false
            activate(key)
        } else {
            message = "请同时按住 ⌘、⌥ 或 ⌃ 中的至少一个键。"
        }
    }

    fileprivate func toggle() {
        cancelRecording()
        if enabled {
            if let registered { UnregisterEventHotKey(registered) }
            registered = nil
            registeredID = nil
            configuration.enabled = false
            save()
        } else {
            activate(configuration.key)
        }
    }

    fileprivate func restoreDefault() {
        cancelRecording()
        activate(.standard)
    }

    private func activate(_ key: ShortcutKey) {
        guard handler != nil else { message = "无法启用全局快捷键。"; return }
        if registered != nil, key.code == configuration.key.code, key.modifiers == configuration.key.modifiers { return }
        Self.nextID &+= 1
        let keyID = EventHotKeyID(signature: Self.signature, id: Self.nextID)
        var candidate: EventHotKeyRef?
        let status = RegisterEventHotKey(key.code, key.modifiers, keyID, GetApplicationEventTarget(),
                                         OptionBits(kEventHotKeyExclusive), &candidate)
        guard status == noErr, let candidate else {
            message = "快捷键 \(key.displayName) 不可用，请选择其他组合。"
            return
        }
        // Keep the current registration live until the new combination succeeds.
        if let registered { UnregisterEventHotKey(registered) }
        registered = candidate
        registeredID = keyID.id
        configuration = Configuration(key: key, enabled: true)
        message = nil
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(configuration) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}

struct CaptureShortcutSettings: View {
    @ObservedObject var shortcut: CaptureShortcut

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("全局快捷键")
                Spacer()
                if shortcut.recording {
                    Button("取消录制") { shortcut.cancelRecording() }
                        .overlay { ShortcutInput(shortcut: shortcut).allowsHitTesting(false) }
                        .accessibilityIdentifier("capture-shortcut-cancel")
                } else {
                    Button(shortcut.displayName) { shortcut.beginRecording() }
                        .help("点按后按下新的截图快捷键")
                        .accessibilityLabel("更改截图快捷键，当前\(shortcut.displayName)")
                        .accessibilityIdentifier("capture-shortcut-edit")
                }
                Menu {
                    Button(shortcut.enabled ? "停用快捷键" : "启用快捷键") { shortcut.toggle() }
                    Button("恢复默认 ⌃⌥S") { shortcut.restoreDefault() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("快捷键选项")
                .accessibilityIdentifier("capture-shortcut-options")
            }
            if let message = shortcut.message {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if shortcut.recording {
                Text("按下新的组合键，按 Esc 取消。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onDisappear { if shortcut.recording { shortcut.cancelRecording() } }
    }
}

private struct ShortcutInput: NSViewRepresentable {
    let shortcut: CaptureShortcut

    func makeNSView(context: Context) -> Field {
        let view = Field()
        view.shortcut = shortcut
        return view
    }

    func updateNSView(_ nsView: Field, context: Context) {}

    final class Field: NSView {
        weak var shortcut: CaptureShortcut?
        private var eventMonitor: Any?
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus),
                                                   name: NSWindow.didResignKeyNotification, object: window)
            window.makeFirstResponder(self)
            // Catch menu key equivalents before AppKit dispatches them to the app's menu.
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window, window.isKeyWindow,
                      window.firstResponder === self, self.shortcut?.recording == true else { return event }
                self.shortcut?.accept(event)
                return nil
            }
        }

        @objc private func windowLostFocus() { shortcut?.cancelRecording() }

        isolated deinit {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        }

        override func resignFirstResponder() -> Bool {
            if shortcut?.recording == true { shortcut?.cancelRecording() }
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) { shortcut?.accept(event) }

    }
}
