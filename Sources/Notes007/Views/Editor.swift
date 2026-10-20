import AppKit
import SwiftUI

/// The text view used for notes: Markdown look, formatting shortcuts, clickable checkboxes.
final class NoteTextView: NSTextView {
    static weak var active: NoteTextView?

    override func becomeFirstResponder() -> Bool {
        NoteTextView.active = self
        return super.becomeFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, isEditable else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case (.command, "b"): MarkdownStyle.toggle("**", "**", in: self); return true
        case (.command, "i"): MarkdownStyle.toggle("*", "*", in: self); return true
        case (.command, "u"): MarkdownStyle.toggle("<u>", "</u>", in: self); return true
        case ([.command, .shift], "x"): MarkdownStyle.toggle("~~", "~~", in: self); return true
        case ([.command, .shift], "l"): MarkdownStyle.toggleChecklist(in: self); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if isEditable {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            if MarkdownStyle.toggleCheckbox(at: index, in: self) { return }
        }
        super.mouseDown(with: event)
    }

    /// Continue lists and checklists when pressing Return.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let text = ns.substring(with: NSRange(location: line.location, length: sel.location - line.location))
        let full = NSRange(location: 0, length: (text as NSString).length)
        if let m = MarkdownStyle.checkbox.firstMatch(in: text, range: full) {
            if m.range(at: 4).length == 0 { clearLine(line, to: sel.location); return }
            let indent = (text as NSString).substring(to: m.range(at: 1).location + m.range(at: 1).length - 1)
            insertText("\n" + indent + "[ ] ", replacementRange: sel)
            return
        }
        if let m = MarkdownStyle.bullet.firstMatch(in: text, range: full) {
            let prefix = (text as NSString).substring(with: m.range)
            if (text as NSString).length == m.range.length { clearLine(line, to: sel.location); return }
            var next = prefix
            if let num = Int(prefix.trimmingCharacters(in: .whitespaces).dropLast()) {
                next = prefix.replacingOccurrences(of: "\(num).", with: "\(num + 1).")
            }
            insertText("\n" + next, replacementRange: sel)
            return
        }
        super.insertNewline(sender)
    }

    private func clearLine(_ line: NSRange, to end: Int) {
        let r = NSRange(location: line.location, length: end - line.location)
        if shouldChangeText(in: r, replacementString: "") {
            textStorage?.replaceCharacters(in: r, with: "")
            didChangeText()
        }
    }
}

struct NoteEditor: NSViewRepresentable {
    let noteId: UUID
    let text: String
    let editable: Bool
    let focusToken: Int
    let onChange: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let tv = NoteTextView(frame: .zero)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.insertionPointColor = .white
        tv.selectedTextAttributes = [.backgroundColor: NSColor(calibratedRed: 0.25, green: 0.45, blue: 0.85, alpha: 0.55)]
        tv.linkTextAttributes = [.foregroundColor: MarkdownStyle.linkColor, .cursor: NSCursor.pointingHand]
        tv.textContainerInset = NSSize(width: 26, height: 20)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.typingAttributes = MarkdownStyle.baseAttributes
        tv.delegate = context.coordinator
        tv.textStorage?.delegate = context.coordinator

        scroll.documentView = tv
        context.coordinator.textView = tv
        load(tv, context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        tv.isEditable = editable
        if c.noteId != noteId {
            load(tv, c)
        } else if tv.string != text && text != c.lastSent {
            // Updated from the server while open: keep the cursor where it was.
            let sel = tv.selectedRange()
            c.applying = true
            tv.string = text
            restyleAll(tv)
            c.applying = false
            c.lastSent = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
        }
        if c.focusToken != focusToken {
            c.focusToken = focusToken
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        }
    }

    private func load(_ tv: NSTextView, _ c: Coordinator) {
        c.applying = true
        tv.string = text
        restyleAll(tv)
        c.applying = false
        c.noteId = noteId
        c.lastSent = text
        tv.undoManager?.removeAllActions()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.scrollToBeginningOfDocument(nil)
    }

    private func restyleAll(_ tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        storage.beginEditing()
        MarkdownStyle.apply(to: storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        tv.typingAttributes = MarkdownStyle.baseAttributes
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: NoteEditor
        weak var textView: NSTextView?
        var noteId: UUID?
        var lastSent = ""
        var applying = false
        var focusToken = 0

        init(_ parent: NoteEditor) {
            self.parent = parent
            self.focusToken = parent.focusToken
        }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MarkdownStyle.apply(to: textStorage, in: editedRange)
        }

        func textDidChange(_ notification: Notification) {
            guard !applying, let tv = textView else { return }
            tv.typingAttributes = MarkdownStyle.baseAttributes
            lastSent = tv.string
            parent.onChange(tv.string)
        }
    }
}
