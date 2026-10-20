import AppKit

/// Live Markdown look for a plain-text note (the text itself stays plain Markdown).
/// ~~gone~~ is struck through, **bold**, *italic*, <u>underline</u>, # headings, - [ ] checklists,
/// `code` and links get their style; the markers themselves are shown faintly.
enum MarkdownStyle {
    static let fontSize: CGFloat = 15
    static let textColor = NSColor(white: 0.93, alpha: 1)
    static let markerColor = NSColor(white: 1, alpha: 0.30)
    static let doneColor = NSColor(white: 1, alpha: 0.50)
    static let linkColor = NSColor(calibratedRed: 0.45, green: 0.72, blue: 1, alpha: 1)

    static var baseFont: NSFont { .systemFont(ofSize: fontSize) }

    static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = 2
        return p
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: textColor, .paragraphStyle: paragraph]
    }

    private static func rx(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines])
    }

    static let heading = rx(#"^(#{1,6})[ \t]+(.+)$"#)
    static let bold = rx(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    static let italic = rx(#"(?<![\*\w])(\*|_)(?=[^\s\*_])(.+?)(?<=[^\s\*_])\1(?![\*\w])"#)
    static let strike = rx(#"(~~)(?=\S)(.+?)(?<=\S)(~~)"#)
    static let underline = rx(#"(<u>)(.+?)(</u>)"#)
    static let code = rx(#"(`)([^`\n]+)(`)"#)
    static let checkbox = rx(#"^([ \t]*[-*+][ \t]+\[)([ xX])(\][ \t]+)(.*)$"#)
    static let bullet = rx(#"^[ \t]*([-*+]|\d+\.)[ \t]+"#)
    static let quote = rx(#"^>[ \t]?.*$"#)
    static let mdLink = rx(#"\[([^\]\n]+)\]\(([^)\s]+)\)"#)
    static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Re-styles the given range (whole lines). Only attributes change, never the text.
    static func apply(to storage: NSTextStorage, in range: NSRange) {
        let ns = storage.string as NSString
        let r = ns.paragraphRange(for: NSRange(location: min(range.location, ns.length),
                                               length: min(range.length, ns.length - min(range.location, ns.length))))
        let s = storage.string
        storage.setAttributes(baseAttributes, range: r)

        func dim(_ x: NSRange) { if x.location != NSNotFound { storage.addAttribute(.foregroundColor, value: markerColor, range: x) } }
        func addTrait(_ trait: NSFontTraitMask, _ x: NSRange) {
            storage.enumerateAttribute(.font, in: x) { value, sub, _ in
                let f = (value as? NSFont) ?? baseFont
                storage.addAttribute(.font, value: NSFontManager.shared.convert(f, toHaveTrait: trait), range: sub)
            }
        }
        func each(_ re: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            re.enumerateMatches(in: s, range: r) { m, _, _ in if let m { body(m) } }
        }

        each(heading) { m in
            let level = m.range(at: 1).length
            let size: CGFloat = [22, 19, 17, 16, 15, 15][min(level, 6) - 1]
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: .bold), range: m.range)
            dim(m.range(at: 1))
        }
        each(quote) { m in
            storage.addAttribute(.foregroundColor, value: NSColor(white: 1, alpha: 0.65), range: m.range)
            addTrait(.italicFontMask, m.range)
        }
        each(bullet) { m in dim(m.range(at: 1)) }
        each(checkbox) { m in
            dim(m.range(at: 1)); dim(m.range(at: 3))
            let done = (ns.substring(with: m.range(at: 2)).lowercased() == "x")
            storage.addAttribute(.foregroundColor, value: done ? linkColor : markerColor, range: m.range(at: 2))
            if done {
                storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                       .foregroundColor: doneColor], range: m.range(at: 4))
            }
        }
        each(bold) { m in
            addTrait(.boldFontMask, m.range(at: 2))
            dim(NSRange(location: m.range.location, length: 2))
            dim(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        each(italic) { m in
            addTrait(.italicFontMask, m.range(at: 2))
            dim(NSRange(location: m.range.location, length: 1))
            dim(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        each(strike) { m in
            storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .strikethroughColor: NSColor(white: 1, alpha: 0.75),
                                   .foregroundColor: doneColor], range: m.range(at: 2))
            dim(m.range(at: 1)); dim(m.range(at: 3))
        }
        each(underline) { m in
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: m.range(at: 2))
            dim(m.range(at: 1)); dim(m.range(at: 3))
        }
        each(code) { m in
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular),
                                   .backgroundColor: NSColor(white: 1, alpha: 0.08)], range: m.range(at: 2))
            dim(m.range(at: 1)); dim(m.range(at: 3))
        }
        each(mdLink) { m in
            if let url = URL(string: ns.substring(with: m.range(at: 2))) {
                storage.addAttributes([.link: url, .foregroundColor: linkColor], range: m.range(at: 1))
            }
            dim(m.range(at: 2))
        }
        detector?.enumerateMatches(in: s, range: r) { m, _, _ in
            guard let m, let url = m.url else { return }
            storage.addAttributes([.link: url, .foregroundColor: linkColor], range: m.range)
        }
        // The "object replacement" box some apps leave behind: make it invisible.
        (s as NSString).enumerateSubstrings(in: r, options: .byComposedCharacterSequences) { sub, sr, _, _ in
            if sub == "\u{FFFC}" { storage.addAttribute(.foregroundColor, value: NSColor.clear, range: sr) }
        }
    }

    // MARK: Formatting commands

    /// Wraps the selection in markers, or removes them if it's already wrapped.
    /// Without a selection the current line (after any list marker) is used.
    static func toggle(_ open: String, _ close: String, in tv: NSTextView) {
        let ns = tv.string as NSString
        var sel = tv.selectedRange()
        if sel.length == 0 {
            let line = ns.lineRange(for: sel)
            var start = line.location, end = NSMaxRange(line)
            if end > start, ns.substring(with: NSRange(location: end - 1, length: 1)) == "\n" { end -= 1 }
            let text = ns.substring(with: NSRange(location: start, length: end - start)) as NSString
            if let m = checkbox.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) {
                start += m.range(at: 4).location
            } else if let m = bullet.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) {
                start += m.range.length
            }
            sel = NSRange(location: start, length: max(0, end - start))
        }
        let selected = ns.substring(with: sel)
        let o = (open as NSString).length, c = (close as NSString).length

        let replacement: String, newSel: NSRange, target: NSRange
        if selected.hasPrefix(open) && selected.hasSuffix(close) && (selected as NSString).length >= o + c {
            let inner = (selected as NSString).substring(with: NSRange(location: o, length: (selected as NSString).length - o - c))
            target = sel; replacement = inner
            newSel = NSRange(location: sel.location, length: (inner as NSString).length)
        } else if sel.location >= o, NSMaxRange(sel) + c <= ns.length,
                  ns.substring(with: NSRange(location: sel.location - o, length: o)) == open,
                  ns.substring(with: NSRange(location: NSMaxRange(sel), length: c)) == close {
            target = NSRange(location: sel.location - o, length: sel.length + o + c); replacement = selected
            newSel = NSRange(location: sel.location - o, length: sel.length)
        } else {
            target = sel; replacement = open + selected + close
            newSel = NSRange(location: sel.location + o, length: sel.length)
        }
        if tv.shouldChangeText(in: target, replacementString: replacement) {
            tv.textStorage?.replaceCharacters(in: target, with: replacement)
            tv.didChangeText()
            tv.setSelectedRange(newSel)
        }
    }

    /// Turns the current line into a checklist item, or removes the checkbox.
    static func toggleChecklist(in tv: NSTextView) {
        let ns = tv.string as NSString
        let line = ns.lineRange(for: tv.selectedRange())
        let text = ns.substring(with: line)
        let full = NSRange(location: 0, length: (text as NSString).length)
        let replacement: String
        if let m = checkbox.firstMatch(in: text, range: full) {
            replacement = (text as NSString).replacingCharacters(in: NSRange(location: 0, length: m.range(at: 4).location), with: "")
        } else if let m = bullet.firstMatch(in: text, range: full) {
            replacement = "- [ ] " + (text as NSString).substring(from: m.range.length)
        } else {
            replacement = "- [ ] " + text
        }
        if tv.shouldChangeText(in: line, replacementString: replacement) {
            tv.textStorage?.replaceCharacters(in: line, with: replacement)
            tv.didChangeText()
            let end = line.location + (replacement as NSString).length - (replacement.hasSuffix("\n") ? 1 : 0)
            tv.setSelectedRange(NSRange(location: end, length: 0))
        }
    }

    /// Clicking the [ ] / [x] of a checklist item ticks it.
    static func toggleCheckbox(at index: Int, in tv: NSTextView) -> Bool {
        let ns = tv.string as NSString
        guard index <= ns.length else { return false }
        let line = ns.lineRange(for: NSRange(location: min(index, max(ns.length - 1, 0)), length: 0))
        let text = ns.substring(with: line)
        guard let m = checkbox.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) else { return false }
        let mark = NSRange(location: line.location + m.range(at: 2).location, length: 1)
        guard index >= mark.location - 1 && index <= mark.location + 1 else { return false }
        let done = ns.substring(with: mark).lowercased() == "x"
        if tv.shouldChangeText(in: mark, replacementString: done ? " " : "x") {
            tv.textStorage?.replaceCharacters(in: mark, with: done ? " " : "x")
            tv.didChangeText()
        }
        return true
    }
}
