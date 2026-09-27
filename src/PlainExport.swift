import Foundation

enum PlainExport {

    static func render(_ blocks: [Block]) -> String {
        var out = ""
        for (i, b) in blocks.enumerated() {
            out += renderBlock(b)
            if i < blocks.count - 1 { out += "\n" }
        }
        return out
    }

    private static func renderBlock(_ block: Block) -> String {
        switch block {
            case .heading(let level, let text):
                let prefix = String(repeating: "#", count: level)
                return "\(prefix) \(plain(text))\n"
            case .paragraph(let text):
                return "\(plain(text))\n"
            case .code(let language, let text):
                return "```" + (language ?? "") + "\n" + text + "\n```\n"
            case .quote(let inner):
                let body = render(inner)
                let lines = body.split(
                    separator: "\n", omittingEmptySubsequences: false)
                return lines.map { line in "> \(line)" }
                    .joined(separator: "\n") + "\n"
            case .list(let items, let tight):
                return renderList(items, tight: tight)
            case .table(let h, let rows, let alignments):
                return TableMetrics.serializeMonospaced(
                    headers: h, rows: rows, alignments: alignments)
            case .math(let tex):
                // The source, not the rendering. Everything else this
                // exporter emits is markdown -- # for headings, > for
                // quotes, ![]() for images -- so a display belongs here
                // in the spelling it was written in, ready to paste back.
                return "$$\n\(tex)\n$$\n"
            case .rule:
                return "---\n"
            case .image(let alt, let url, _, _):
                return "![\(alt)](\(url.absoluteString))\n"
        }
    }

    private static func renderList(_ items: [ListItem],
                                   tight: Bool) -> String {
        var out = ""
        for (index, item) in items.enumerated() {
            let head = item.marker == "\u{2022}" ? "-" : item.marker
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
                // Continuation lines sit under the item's text, so the
                // indent is the marker's width plus its space: "2." needs
                // three, "-" two, or the parser hands them back to the
                // top level. The task box is not part of the marker: the
                // parser strips it after the marker has set the offset.
                let indent = String(repeating: " ", count: head.count + 1)
                for rest in body {
                    out += rest.isEmpty ? "\n" : indent + rest + "\n"
                }
            }
            if !tight, index < items.count - 1 { out += "\n" }
        }
        return out
    }

    // A nested list follows its item's text without a blank line,
    // because a blank line inside an item makes the parser read the
    // whole list as loose; every other block keeps the blank between.

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

    // Plain text has no baseline to offset, so a script run spends the
    // Unicode the TeX renderer already keeps tables of: "m2" would lose
    // the distinction the source went out of its way to make. A hard
    // break goes back out as the two trailing spaces it was written
    // with, and a code span keeps its backticks, so the text parses to
    // the same paragraph it came from: a backslash that was literal
    // inside the span stays literal instead of becoming an escape.

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

    // The characters the parser would read as markup go back out
    // escaped, so "an escaped \*star\*" is not italic on the way back.
    // An underscore between two letters is left alone: the parser does
    // not emphasise inside a word, and snake_case in prose is common.

    private static func escaped(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        for (i, ch) in chars.enumerated() {
            let inWord = i > 0 && i + 1 < chars.count &&
                         chars[i - 1].isLetter && chars[i + 1].isLetter
            let special = ch == "\\" || ch == "*" || ch == "`" ||
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
