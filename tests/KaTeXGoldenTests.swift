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
