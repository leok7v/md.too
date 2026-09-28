import XCTest

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

    static let corners: [(source: String, parse: String)] = [
        ("[Note]: do not run this.",
         "paragraph: [Note]: do not run this.|\n"),
        ("[^1]: a footnote", "paragraph: [^1]: a footnote|\n"),
        ("    [x]: http://example.com",
         "code[]: [x]: http://example.com\n"),
        ("[ok]: http://example.com \"Title\"\n\nSee [ok].",
         "paragraph: See |ok{link=http://example.com}|.|\n"),
        ("<!-- one line --> text after", "paragraph: text after|\n"),
        ("A &lt;sub&gt;tag&lt;/sub&gt; and \\<sup>escaped\\</sup>.",
         "paragraph: A <sub>tag</sub> and <sup>escaped</sup>.|\n"),
        ("    # not a heading\n    ---",
         "code[]: # not a heading\\n---\n"),
        ("Para\n    # still para", "paragraph: Para # still para|\n"),
        ("````\n```\ninner\n```\n````\nafter",
         "code[]: ```\\ninner\\n```\nparagraph: after|\n"),
        ("Last line  ", "paragraph: Last line|\n"),
        ("In the year\n1984. Things.",
         "paragraph: In the year 1984. Things.|\n"),
        ("$$a$$ is the area", "math: a\nparagraph: is the area|\n"),
        ("$$x$$ $$y$$", "math: x\nmath: y\n"),
        ("Price $5 and $10.", "paragraph: Price $5 and $10.|\n"),
        ("<div align=\"center\">\nA line </p>\nstill centred\n</div>\n" +
         "After.",
         "paragraph: A line {center}|</p>{center}| still centred{center}|\n" +
         "paragraph: After.|\n"),
        ("<details><summary>Outer</summary>\n" +
         "<details><summary>Inner</summary>\nDeep.\n</details>\n" +
         "Still outer.\n</details>\nOut.",
         "paragraph: Outer{b}|\nparagraph: Inner{b}|\n" +
         "paragraph: Deep.|\nparagraph: Still outer.|\n" +
         "paragraph: Out.|\n"),
        ("Hard\\\nbreak", "paragraph: Hard\\u2028break|\n"),
        ("[cost](http://e.com/$5$x) and $y$.",
         "paragraph: cost{link=http://e.com/$5$x}| and |y{math=$y$}|.|\n"),
        ("Title\n=====", "heading 1: Title|\n"),
        ("Sub title\nwraps\n---", "heading 2: Sub title wraps|\n"),
        ("## Closed ##\n# C# #", "heading 2: Closed|\nheading 1: C#|\n"),
        ("Text\n- - -", "paragraph: Text|\nrule\n"),
        ("> foo\n===", "quote:\n  paragraph: foo|\nparagraph: ===|\n"),
        ("---\ntitle: Hello\n---\n# Body",
         "code[yaml]: title: Hello\nheading 1: Body|\n"),
        ("$$x$$    y", "math: x\nparagraph: y|\n"),
        ("<!-- c -->    text", "paragraph: text|\n"),
        ("$$a$$$$\nnext", "math: a\nparagraph: next|\n"),
        ("x \\\\<sup>2</sup>", "paragraph: x \\\\|2{sup}|\n"),
        ("a <sup>b", "paragraph: a b|\n"),
        ("1 &lt; 2", "paragraph: 1 < 2|\n"),
        ("&#60;u>x&#60;/u> y", "paragraph: x{u}| y|\n"),
        ("Pay $\\$5 + x$ now.",
         "paragraph: Pay |$5 + x{math=$\\\\$5 + x$}| now.|\n"),
    ]

    func testCornerCasesParseAsCommonMarkReadsThem() {
        for corner in Self.corners {
            XCTAssertEqual(Self.dump(Markdown.parse(corner.source)),
                           corner.parse, corner.source)
        }
    }

    func testAnEscapedAngleInsideMathsShowsAsAnAngle() {
        for source in ["a $x &lt; y$ b", "a $x \\< y$ b"] {
            var shown = ""
            var sources: [String] = []
            if case .paragraph(let text)? = Markdown.parse(source).first {
                shown = String(text.characters)
                sources = text.runs.compactMap { run in
                    run[InlineMathAttribute.self]
                }
            }
            XCTAssertEqual(shown, "a x < y b", source)
            XCTAssertEqual(sources, ["$x < y$"], source)
        }
    }

    func testLongParagraphsParseInLinearTime() {
        for piece in ["$5 ", "a &lt; b ", "<u>a</u> ", "<u>", "<b>",
                      "x <!-- y ", "<!-- c --> ", "$$x$$ ", "$b$ "] {
            let start = ContinuousClock.now
            _ = Markdown.parse(String(repeating: piece, count: 8000))
            XCTAssertLessThan(ContinuousClock.now - start, .seconds(2),
                              piece)
        }
    }

    func testTheSpelledFallbackIsBoundedOnHugeSources() {
        let start = ContinuousClock.now
        _ = TeX.render(String(repeating: "\\frac{", count: 40_000),
                       display: true)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
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
