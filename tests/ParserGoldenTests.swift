import XCTest

// The parser pinned: every fixture section parsed and dumped in a
// deterministic text form, compared to the recording. Re-record with
// PARSER_GOLDEN_UPDATE=1 after a deliberate change, and read the diff
// before committing it: the dump is the contract.
final class ParserGoldenTests: XCTestCase {

    static func dump(_ blocks: [Block], indent: String = "") -> String {
        var out = ""
        for block in blocks {
            out += indent + line(block, indent: indent) + "\n"
        }
        return out
    }

    private static func line(_ block: Block, indent: String) -> String {
        let deeper = indent + "  "
        let result: String
        switch block {
            case .heading(let level, let text):
                result = "heading \(level): " + inline(text)
            case .paragraph(let text):
                result = "paragraph: " + inline(text)
            case .code(let language, let text):
                result = "code[\(language ?? "")]: " + escape(text)
            case .quote(let inner):
                result = "quote:\n" + dump(inner, indent: deeper)
                    .trimmingTrailingNewline()
            case .list(let items, let tight):
                var s = "list \(tight ? "tight" : "loose"):"
                for item in items {
                    let box = item.checked.map { c in c ? " [x]" : " [ ]" }
                    s += "\n" + deeper + "item " + escape(item.marker) +
                         (box ?? "") + ":\n"
                    s += dump(item.blocks, indent: deeper + "  ")
                        .trimmingTrailingNewline()
                }
                result = s
            case .table(let headers, let rows, let alignments):
                var s = "table \(headers.count)x\(rows.count):"
                if !alignments.isEmpty {
                    s += " " + alignments.map { a in "\(a)" }
                        .joined(separator: ",")
                }
                s += "\n" + deeper + "h: " + cells(headers)
                for row in rows { s += "\n" + deeper + "r: " + cells(row) }
                result = s
            case .math(let tex):
                result = "math: " + escape(tex)
            case .rule:
                result = "rule"
            case .image(let alt, let url, let width, let height):
                result = "image alt=\(escape(alt)) url=\(url.absoluteString)"
                    + " w=\(width.map { w in "\(w)" } ?? "-")"
                    + " h=\(height.map { h in "\(h)" } ?? "-")"
        }
        return result
    }

    private static func cells(_ row: [String]) -> String {
        row.map { cell in "[" + escape(cell) + "]" }.joined(separator: " ")
    }

    // One `text{flags}` per run: b bold, i italic, c code, s strike,
    // u underline, link=URL, sup / sub for the script level.

    static func inline(_ attr: AttributedString) -> String {
        var out = ""
        for run in attr.runs {
            let text = String(attr[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var flags: [String] = []
            if intent.contains(.stronglyEmphasized) { flags.append("b") }
            if intent.contains(.emphasized) { flags.append("i") }
            if intent.contains(.code) { flags.append("c") }
            if intent.contains(.strikethrough) { flags.append("s") }
            if run.underlineStyle != nil { flags.append("u") }
            if let url = run.link {
                flags.append("link=" + url.absoluteString)
            }
            if let level = run[ScriptAttribute.self] {
                flags.append(level > 0 ? "sup" : "sub")
            }
            if run[SmallAttribute.self] == true { flags.append("small") }
            if let tex = run[InlineMathAttribute.self] {
                flags.append("math=" + escape(tex))
            }
            if run[AlignAttribute.self] == .center { flags.append("center") }
            out += escape(text)
            if !flags.isEmpty {
                out += "{" + flags.joined(separator: ",") + "}"
            }
            out += "|"
        }
        return out
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
                case "\n": out += "\\n"
                case "\t": out += "\\t"
                case "\\": out += "\\\\"
                case "|": out += "\\|"
                case "{": out += "\\{"
                case "}": out += "\\}"
                case "\u{2028}": out += "\\u2028"
                case "\u{00A0}": out += "\\u00a0"
                default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func current() throws -> String {
        var out = ""
        for fixture in try Fixtures.all() {
            out += "=== " + fixture.name + "\n"
            out += dump(Markdown.parse(fixture.markdown))
        }
        return out
    }

    func testParseIsUnchanged() throws {
        let now = try Self.current()
        let golden = try Fixtures.golden("parser-golden.txt",
                                         update: "PARSER_GOLDEN_UPDATE",
                                         now: now)
        if golden != now {
            XCTFail("the parse of the fixtures changed:\n" +
                    Fixtures.drift(golden: golden, now: now))
        }
    }

    func testFixturesCoverEveryBlockKind() throws {
        var seen: Set<String> = []
        for fixture in try Fixtures.all() {
            for block in Markdown.parse(fixture.markdown) {
                seen.insert(String(describing: block).prefix(5).description)
            }
        }
        for kind in ["headi", "parag", "code(", "quote", "list(",
                     "table", "math(", "rule", "image"] {
            XCTAssertTrue(seen.contains(kind),
                          "no fixture produces a \(kind) block")
        }
    }
}

private extension String {
    func trimmingTrailingNewline() -> String {
        var s = self
        while s.hasSuffix("\n") { s.removeLast() }
        return s
    }
}
