import AppKit
import SwiftUI

struct ConversationDraftField: NSViewRepresentable {
    @Binding var text: String
    let onSend: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBezeled = false
        field.drawsBackground = false
        field.font = .preferredFont(forTextStyle: .body)
        field.lineBreakMode = .byWordWrapping
        field.cell?.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.placeholderString = "输入或粘贴文字…"
        field.setAccessibilityLabel("对话文字")
        field.setAccessibilityIdentifier("conversation-draft")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.displayDraft(in: field)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0, let cell = field.cell, let font = field.font else { return nil }
        let line = ceil(font.ascender - font.descender + font.leading)
        let bounds = CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        let height = cell.cellSize(forBounds: bounds).height
        return CGSize(width: width, height: min(max(height, line * 2), line * 4))
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: ConversationDraftField

        init(_ parent: ConversationDraftField) { self.parent = parent }

        func displayDraft(in field: NSTextField) {
            let draft = parent.text
            if let editor = field.currentEditor() as? NSTextView {
                guard !editor.hasMarkedText(), editor.string != draft else { return }
                editor.string = draft
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
            } else if field.stringValue != draft {
                field.stringValue = draft
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.currentEditor()?.string ?? field.stringValue
            field.invalidateIntrinsicContentSize()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard command == #selector(NSResponder.insertNewline(_:)) else { return false }
            // The input method gets first use of Return to confirm a candidate.
            guard !textView.hasMarkedText() else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.shift, .control, .option, .command]) ?? []
            if modifiers == .shift {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else if modifiers.isEmpty || modifiers == .command {
                parent.onSend()
                if let field = control as? NSTextField { displayDraft(in: field) }
            } else {
                return false
            }
            // Keep the field editor active so the next message can be typed immediately.
            return true
        }
    }
}
