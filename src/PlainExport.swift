import Foundation

enum PlainExport {

    static func render(_ blocks: [Block]) -> String {
        var out = ""
        var bullets = false
        for (i, b) in blocks.enumerated() {
            var list = false
            if case .list = b { list = true }
            bullets = list && !bullets
            out += renderBlock(b, other: !bullets)
            if i < blocks.count - 1 { out += "\n" }
        }
        return out
    }

    private static func renderBlock(_ block: Block,
                                    other: Bool = false) -> String {
        switch block {
            case .heading(let level, let text):
                let prefix = String(repeating: "#", count: level)
                return "\(prefix) \(plain(text))\n"
            case .paragraph(let text):
                return "\(guarded(plain(text)))\n"
            case .code(let language, let text):
                let fence = String(repeating: "`",
                                   count: max(longestRun(of: "`", in: text) + 1,
                                              3))
                return fence + (language ?? "") + "\n" + text + "\n" +
                       fence + "\n"
            case .quote(let inner):
                let body = render(inner)
                let lines = body.split(
                    separator: "\n", omittingEmptySubsequences: false)
                return lines.map { line in "> \(line)" }
                    .joined(separator: "\n") + "\n"
            case .list(let items, let tight):
                return renderList(items, tight: tight, other: other)
            case .table(let h, let rows, let alignments):
                return TableMetrics.serializeMonospaced(
                    headers: h, rows: rows, alignments: alignments)
            case .math(let tex):
                return "$$\n\(tex)\n$$\n"
            case .rule:
                return "---\n"
            case .image(let alt, let url, let width, let height):
                return "![\(alt)](\(url.absoluteString))" +
                       sized(width: width, height: height) + "\n"
        }
    }

    private static func sized(width: CGFloat?, height: CGFloat?) -> String {
        let named = [("width", width), ("height", height)]
            .compactMap { pair in
                pair.1.map { v in pair.0 + "=" + number(v) }
            }
        return named.isEmpty ? "" : "{" + named.joined(separator: " ") + "}"
    }

    private static func number(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(Double(v))
    }

    private static func longestRun(of mark: Character,
                                   in text: String) -> Int {
        var longest = 0
        var run = 0
        for ch in text {
            run = ch == mark ? run + 1 : 0
            if run > longest { longest = run }
        }
        return longest
    }

    private static func renderList(_ items: [ListItem], tight: Bool,
                                   other: Bool) -> String {
        var out = ""
        for (index, item) in items.enumerated() {
            let head = marker(item.marker, other: other)
            var mark = head
            if let c = item.checked { mark += c ? " [x]" : " [ ]" }
            let inner = itemBody(item.blocks)
            let lines = inner.split(
                separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if let first = lines.first {
                out += first.isEmpty ? mark + "\n" : "\(mark) \(first)\n"
                var body = Array(lines.dropFirst())
                while let last = body.last, last.isEmpty { body.removeLast() }
                // Continuation lines indent under the marker plus its
                // space, or the parser hands them back to the top level.
                let indent = String(repeating: " ", count: head.count + 1)
                for rest in body {
                    out += rest.isEmpty ? "\n" : indent + rest + "\n"
                }
            }
            if !tight, index < items.count - 1 { out += "\n" }
        }
        return out
    }

    private static func marker(_ label: String, other: Bool) -> String {
        var result = label
        if label == "\u{2022}" {
            result = other ? "*" : "-"
        } else if other, label.hasSuffix(".") {
            result = String(label.dropLast()) + ")"
        }
        return result
    }

    private static let blockStart = try? NSRegularExpression(pattern:
        #"^(#{1,6}(\s|$)|>|[-+*](\s|$)|```|~~~|\$\$|<!--|![\[]|"# +
        #"<(details|center|div|p)\b|([-*_]\s*){3,}$)"#,
        options: .caseInsensitive)

    private static let orderedStart = try? NSRegularExpression(pattern:
        #"^\d{1,9}(?=[.)](\s|$))"#)

    private static func guarded(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in guardedLine(String(line)) }
            .joined(separator: "\n")
    }

    private static func guardedLine(_ line: String) -> String {
        let ns = line as NSString
        let full = NSRange(location: 0, length: ns.length)
        var result = line
        if let m = orderedStart?.firstMatch(in: line, range: full) {
            result = ns.replacingCharacters(
                in: NSRange(location: m.range.length, length: 0),
                with: "\\")
        } else if blockStart?.firstMatch(in: line, range: full) != nil {
            result = "\\" + line
        }
        return result
    }

    // A nested list follows its item's text with no blank line, or the
    // parser reads the whole list as loose; every other block keeps one.

    private static func itemBody(_ blocks: [Block]) -> String {
        var out = ""
        for (i, b) in blocks.enumerated() {
            var joined = false
            if case .list = b { joined = true }
            if i > 0, !joined { out += "\n" }
            out += renderBlock(b)
        }
        return out
    }

    // A script run spends TeX's Unicode table since plain text has no
    // baseline; a code span keeps its own backtick fence unescaped.

    private static func plain(_ a: AttributedString) -> String {
        var out = ""
        for run in a.runs {
            let segment = String(a[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            if let source = run[InlineMathAttribute.self] {
                out += source
            } else if let level = run[ScriptAttribute.self] {
                out += TeX.unicodeScript(segment, superscript: level > 0)
            } else if intent.contains(.code) {
                out += fenced(segment)
            } else {
                out += escaped(segment)
            }
        }
        return out.replacingOccurrences(of: "[ \t]*\u{2028}[ \t]*",
                                        with: "  \n",
                                        options: .regularExpression)
    }

    // An underscore between two letters is left unescaped: the parser
    // does not emphasise inside a word, and snake_case in prose is common.

    private static func escaped(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            let inWord = i > 0 && i + 1 < chars.count &&
                         chars[i - 1].isLetter && chars[i + 1].isLetter
            let special = ch == "\\" || ch == "*" || ch == "`" ||
                          ch == "$" || ch == "<" ||
                          (ch == "_" && !inWord)
            if special { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    // A span is fenced by one more backtick than its longest run inside,
    // and padded with a space when it starts or ends with one, which is
    // how CommonMark spells a code span that contains its own delimiter.

    private static func fenced(_ segment: String) -> String {
        var longest = 0
        var run = 0
        for ch in segment {
            run = ch == "`" ? run + 1 : 0
            if run > longest { longest = run }
        }
        let fence = String(repeating: "`", count: longest + 1)
        let padded = segment.hasPrefix("`") || segment.hasSuffix("`")
        let pad = padded ? " " : ""
        return fence + pad + segment + pad + fence
    }

}
