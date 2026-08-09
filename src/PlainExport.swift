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
            case .code(_, let text):
                return text + "\n"
            case .quote(let inner):
                let body = render(inner)
                let lines = body.split(
                    separator: "\n", omittingEmptySubsequences: false)
                return lines.map { line in "> \(line)" }
                    .joined(separator: "\n") + "\n"
            case .list(let items, _):
                return renderList(items)
            case .table(let h, let rows):
                return TableMetrics.serializeMonospaced(
                    headers: h, rows: rows)
            case .rule:
                return "---\n"
            case .image(let alt, let url, _, _):
                return "![\(alt)](\(url.absoluteString))\n"
        }
    }

    private static func renderList(_ items: [ListItem]) -> String {
        var out = ""
        for item in items {
            var mark = item.marker
            if let c = item.checked { mark = c ? "[x]" : "[ ]" }
            let inner = render(item.blocks)
            let lines = inner.split(
                separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if let first = lines.first {
                out += "\(mark) \(first)\n"
                for rest in lines.dropFirst() where !rest.isEmpty {
                    out += "  \(rest)\n"
                }
            }
        }
        return out
    }

    // Plain text has no baseline to offset, so a script run spends the
    // Unicode the TeX renderer already keeps tables of: "m2" would lose
    // the distinction the source went out of its way to make.

    private static func plain(_ a: AttributedString) -> String {
        var out = ""
        for run in a.runs {
            let segment = String(a[run.range].characters)
            if let level = run[ScriptAttribute.self] {
                out += TeX.unicodeScript(segment, superscript: level > 0)
            } else {
                out += segment
            }
        }
        return out
    }

}
