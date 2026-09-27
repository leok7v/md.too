import CryptoKit
import XCTest

@MainActor
final class KaTeXGoldenTests: XCTestCase {

    // Chosen to reach every builder with its own layout rule at least
    // once, plus the shapes that arrive from real documents.

    static let corpus: [(name: String, tex: String)] = [
        ("plain", "a + b = c"),
        ("frac", "\\frac{a}{b}"),
        ("nested-frac", "\\frac{\\frac{a}{b}}{\\frac{c}{d}}"),
        ("sqrt", "\\sqrt{x}"),
        ("root", "\\sqrt[3]{x}"),
        ("sup", "x^2"),
        ("sub", "x_i"),
        ("supsub", "x_i^2"),
        ("deep-script", "e^{x^{y^{z}}}"),
        ("sum", "\\sum_{i=1}^{n} i"),
        ("int", "\\int_0^\\infty e^{-x} dx"),
        ("prod", "\\prod_{k=1}^{n} k"),
        ("lim", "\\lim_{x \\to 0} \\frac{\\sin x}{x}"),
        ("delims", "\\left( \\frac{a}{b} \\right)"),
        ("big-delims", "\\left[ \\sum_{i=1}^{n} x_i \\right]"),
        ("braces", "\\left\\{ x : x > 0 \\right\\}"),
        ("greek", "\\alpha \\beta \\gamma \\Delta \\Omega"),
        ("operators", "a \\times b \\div c \\pm d \\cdot e"),
        ("relations", "a \\le b \\ge c \\neq d \\approx e"),
        ("accents", "\\hat{x} \\bar{y} \\vec{z} \\dot{w}"),
        ("text", "\\text{if } x > 0 \\text{ then}"),
        ("mathbb", "\\mathbb{R} \\mathbb{N} \\mathbb{Z}"),
        ("mathcal", "\\mathcal{L} \\mathcal{F}"),
        ("matrix", "\\begin{matrix} a & b \\\\ c & d \\end{matrix}"),
        ("pmatrix", "\\begin{pmatrix} 1 & 0 \\\\ 0 & 1 \\end{pmatrix}"),
        ("aligned", "\\begin{aligned} x &= 1 \\\\ y &= 2 \\end{aligned}"),
        ("under-over", "\\underline{x + y} \\overline{z}"),
        ("brace-limits",
         "\\overbrace{a + b}^{n} + \\underbrace{c + d}_{m}"),
        ("stacks", "\\overset{?}{=} \\underset{x}{\\max} \\stackrel{def}{=}"),
        ("boxed", "\\boxed{E = mc^2}"),
        ("phantoms",
         "a \\phantom{bb} c \\hphantom{x} d \\vphantom{\\frac{a}{b}} e"),
        ("colour", "\\color{red} x + \\textcolor{#0000ff}{y}"),
        ("extensible", "A \\xrightarrow{f} B \\xleftarrow[g]{h} C"),
        ("middle", "\\left( a \\middle| b \\right)"),
        ("struck", "a \\not= b \\cancel{x + y}"),
        ("rule-smash", "\\rule{1em}{0.5pt} \\smash{y} \\smash[t]{z}"),
        ("cases", "\\begin{cases} a & x > 0 \\\\ b & x \\le 0 \\end{cases}"),
        ("binom", "\\binom{n}{k}"),
        ("overline", "\\overline{a + b}"),
        ("underline", "\\underline{a + b}"),
        ("stacked", "\\frac{\\sum_{i} x_i}{\\sqrt{n}}"),
        ("quadratic", "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"),
        ("implicit-rows", "a \\\\ b \\\\ c"),
        ("implicit-align", "x &= 1 \\\\ y &= 2"),
        ("spacing", "a \\, b \\; c \\quad d \\qquad e"),
        ("styles", "\\displaystyle \\frac{a}{b} \\textstyle \\frac{c}{d}"),
        ("array-spec",
         "\\begin{array}{lcr} a & b & c \\\\ dd & ee & ff \\end{array}"),
        ("operatorname", "\\operatorname*{arg\\,max}_x f(x)"),
        ("delimiter-sizes", "\\big( \\Big( \\bigg( \\Bigg("),
        ("angles", "\\left< x \\right>"),
        ("logic", "P \\iff Q \\land R \\lor S \\implies T"),
        ("modular", "a \\bmod b \\quad x \\equiv 1 \\pmod{n}"),
        ("infix", "{a \\over b} + {n \\choose k}"),
        ("long-brace",
         "\\overbrace{a+b+c+d+e+f+g+h+i+j+k+l+m}^{n}"),
        ("long-arrow", "A \\xrightarrow[\\text{a long label}]{f} B"),
    ]

    static var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("katex-golden.txt")
    }

    // A descent a hair below zero is snapped to zero: "-0.0000" would
    // flip on the next optimiser without a glyph moving.

    static func fingerprint(_ tex: String) -> String {
        var result = "REFUSED"
        if let layout = TeX.layout(tex, size: 20) {
            let metrics = String(format: "%.4f %.4f %.4f %.4f",
                                 snapped(layout.width),
                                 snapped(layout.ascent),
                                 snapped(layout.descent),
                                 snapped(layout.bodyOrigin))
            var pixels = "no-image"
            if let cg = layout.cgImage(scale: 2, padding: 8,
                                       background: nil, color: nil),
               let data = cg.dataProvider?.data as Data? {
                let digest = SHA256.hash(data: data)
                pixels = digest.map { b in String(format: "%02x", b) }
                    .joined().prefix(16).description
            }
            result = metrics + " " + pixels
        }
        return result
    }

    private static func snapped(_ v: CGFloat) -> CGFloat {
        abs(v) < 0.00005 ? 0 : v
    }

    static func current() -> String {
        var lines: [String] = []
        for entry in corpus {
            lines.append(entry.name + "  " + fingerprint(entry.tex))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func testLayoutIsUnchanged() throws {
        let now = Self.current()
        let updating = ProcessInfo.processInfo
            .environment["KATEX_GOLDEN_UPDATE"] != nil
        if updating {
            try now.write(to: Self.goldenURL, atomically: true,
                          encoding: .utf8)
        }
        let golden = try String(contentsOf: Self.goldenURL, encoding: .utf8)
        if golden != now {
            XCTFail("KaTeX layout changed:\n" +
                    Fixtures.drift(golden: golden, now: now))
        }
    }

    private func measured(_ tex: String,
                          display: Bool = true) throws -> MathLayout {
        try XCTUnwrap(TeX.layout(tex, size: 20, display: display), tex)
    }

    private static func rules(in box: Box) -> [Box] {
        var found: [Box] = []
        if case .rule = box.kind { found.append(box) }
        for child in box.children { found += rules(in: child.box) }
        return found
    }

    func testTextIsUprightAndOverlineIsARule() throws {
        XCTAssertEqual(try measured("\\text{ab}").width,
                       try measured("\\mathrm{ab}").width, accuracy: 0.01)
        let base = try measured("abc").width
        let bars = Self.rules(in: try measured("\\overline{abc}").box)
        XCTAssertTrue(bars.contains { bar in bar.width >= base - 0.01 })
    }

    func testArraysReadTheirSpecAndDropATrailingRow() throws {
        XCTAssertEqual(
            try measured("\\begin{array}{cc} a & b \\end{array}").width,
            try measured("\\begin{matrix} a & b \\end{matrix}").width,
            accuracy: 0.01)
        XCTAssertEqual(try measured("a \\\\ b \\\\").height,
                       try measured("a \\\\ b").height, accuracy: 0.01)
        XCTAssertEqual(
            try measured("\\begin{array}{c} a \\\\ \\hline b \\\\ " +
                         "\\hline \\end{array}").height,
            try measured("\\begin{array}{c} a \\\\ b \\end{array}").height,
            accuracy: 0.01)
        XCTAssertEqual(
            try measured("\\begin{matrix} a \\\\ b \\\\ \\end{matrix}")
                .height,
            try measured("\\begin{matrix} a \\\\ b \\end{matrix}").height,
            accuracy: 0.01)
    }

    func testLimitsDelimitersAndOperatorNames() throws {
        XCTAssertGreaterThan(
            try measured("\\int\\limits_0^1 x", display: false).height,
            try measured("\\int_0^1 x", display: false).height)
        XCTAssertNotNil(TeX.layout("\\sqrt[{n}]{x}", size: 20))
        XCTAssertEqual(try measured("\\left< x \\right>").width,
                       try measured("\\left\\langle x \\right\\rangle").width,
                       accuracy: 0.01)
        XCTAssertGreaterThan(try measured("\\operatorname*{max}_x y").height,
                             try measured("\\operatorname{max}_x y").height)
        XCTAssertGreaterThan(try measured("\\Bigg(").height,
                             try measured("\\bigg(").height)
    }

    func testAlignedBinariesCjkTextAndUnclosedOptions() throws {
        XCTAssertEqual(
            try measured("\\begin{aligned} a &+ b \\end{aligned}").width,
            try measured("\\begin{aligned} a &{}+ b \\end{aligned}").width,
            accuracy: 0.01)
        let cjk = try measured("\\text{\u{4E2D}\u{6587}}")
        var lines = 0
        func walk(_ box: Box) {
            if case .line = box.kind { lines += 1 }
            for child in box.children { walk(child.box) }
        }
        walk(cjk.box)
        XCTAssertEqual(lines, 2)
        let long = String(repeating: "\\smash[x ", count: 6000)
        let started = ContinuousClock.now
        _ = TeX.layout(long, size: 20)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
        let unclosed = String(repeating: "a \\\\[", count: 3000)
        let start = ContinuousClock.now
        _ = TeX.layout(unclosed, size: 20)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testCommonCommandsAreAccepted() {
        let commands = [
            "\\iff", "\\land", "\\lor", "a \\bmod b", "\\pmod{n}",
            "f\\colon A", "\\Longrightarrow", "\\gets", "\\leqslant",
            "\\overrightarrow{AB}", "\\dbinom{n}{k}", "\\texttt{x}",
            "\\mathbin{\\#}", "{a \\over b}",
            "\\begin{array}{c} a \\\\ \\hline b \\end{array}",
            "\\begin{equation} x \\end{equation}",
            "\\begin{smallmatrix} a \\end{smallmatrix}",
            "\\begin{Vmatrix} a \\end{Vmatrix}",
            "\\begin{dcases} a & b \\end{dcases}",
        ]
        let refused = commands.filter { tex in
            TeX.layout(tex, size: 20) == nil
        }
        XCTAssertEqual(refused, [])
    }

    func testALongBraceStretchesPastTheWidestGlyph() throws {
        let body = "a+b+c+d+e+f+g+h+i+j+k+l+m+n+o+p"
        let brace = try measured("\\overbrace{" + body + "}")
        let base = try measured(body)
        var widest: CGFloat = 0
        func walk(_ box: Box, _ lifted: Bool) {
            if lifted, box.width > widest, box.children.count > 1 {
                widest = box.width
            }
            for child in box.children { walk(child.box, child.dy > 0) }
        }
        walk(brace.box, false)
        XCTAssertGreaterThanOrEqual(widest, base.width - 1)
    }

    func testTheFallbackSpellsNoTeX() {
        let spelled = String(TeX.render("e^\\pi \\mathrm{d}x \\foo{y}",
                                        display: false).characters)
        XCTAssertFalse(spelled.contains("\\"), spelled)
        XCTAssertTrue(spelled.contains("dx"), spelled)
    }

    // Pins: a corpus that is mostly refusals gates nothing.

    func testCorpusActuallyTypesets() {
        let refused = Self.corpus.filter { entry in
            TeX.layout(entry.tex, size: 20) == nil
        }
        let names = refused.map { one in one.name }.joined(separator: ", ")
        XCTAssertLessThanOrEqual(
            refused.count, 2,
            "the gate is mostly refusals, so it gates almost nothing: " +
            names)
    }
}
