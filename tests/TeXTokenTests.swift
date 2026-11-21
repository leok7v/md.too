import Foundation
import XCTest

@MainActor
final class TeXTokenTests: XCTestCase {

    private enum Rule {
        case bounded(NSRegularExpression, String)
        case literal(String, String)
    }

    private static let rules: [Rule] = TeX.tokenMap
        .sorted { a, b in
            a.key.count > b.key.count ||
            (a.key.count == b.key.count && a.key > b.key)
        }
        .compactMap { pair in rule(pair.key, pair.value) }

    private static func rule(_ key: String, _ value: String) -> Rule? {
        var result: Rule? = nil
        if let last = key.last, last.isLetter {
            let pattern = NSRegularExpression.escapedPattern(for: key) +
                          "(?![A-Za-z])"
            if let re = try? NSRegularExpression(pattern: pattern) {
                result = .bounded(
                    re, NSRegularExpression.escapedTemplate(for: value))
            }
        } else {
            result = .literal(key, value)
        }
        return result
    }

    private static func sequential(_ s: String) -> String {
        var out = s
        for rule in rules {
            switch rule {
                case .bounded(let re, let template):
                    let ns = out as NSString
                    out = re.stringByReplacingMatches(
                        in: out,
                        range: NSRange(location: 0, length: ns.length),
                        withTemplate: template)
                case .literal(let key, let value):
                    out = out.replacingOccurrences(of: key, with: value)
            }
        }
        return out
    }

    private static let tricky: [String] = [
        "\\alpha\\beta\\gamma", "\\ne\\alpha", "\\alpha\\ne",
        "\\mathbb{R}\\mathbb{X}\\mathbb {R} \\mathbb{N}\\mathbb{Z}",
        "\\newcommand\\ne1", "\\ne 1 \\neq 2",
        "\\,\\;\\ \\quad\\qquad\\!\\:", "a\\,b\\;c\\quad d\\qquad e",
        "\\frac{\\partial u}{\\partial t}",
        "\\alpha\u{0301}", "\\ne\u{03B1}", "x\\to\\infty",
        "a\\leq b\\geq c\\le d\\ge e", "\\{x\\}", "\\\\", "trailing\\",
        "\\ ", "\\", "", "no commands at all",
        "\\mathbfx \\mathbf{x}\\mathrm{d}x", "\\sqrt{2}\\int_0^\\infty",
        "\\varepsilon\\epsilon\\vartheta\\theta\\varphi\\phi",
        "\\Rightarrow\\rightarrow\\to\\leftrightarrow\\Leftrightarrow",
        "\\cdots\\dots\\ldots\\vdots", "\\foo\\alpha\\bar{x}\\baz",
        "\\Mathbb{R}", "\\MATHBB{R}", "\\mathbb{RR}", "\\mathbb{",
        "\\alphabet\\betamax", "\\pi r^2 \\mu\\nu",
        "\\$ 5 \\% \\& \\#", "\\left( \\frac{a}{b} \\right)",
        "\\int\\oint\\sum\\prod",
        "\\in\\notin\\subset\\supseteq\\cup\\cap\\emptyset\\varnothing",
        "\\lnot\\neg\\land\\lor\\forall\\exists\\nexists",
        "\\hbar\\ell\\Re\\Im\\nabla\\partial\\perp\\parallel\\angle",
        "\\times\\cdot\\div\\pm\\mp",
        "\\approx\\equiv\\sim\\propto", "\\Gamma\\Delta\\Theta\\Omega",
        "\\alpha\n\\beta\t\\gamma", "e^{i\\pi} + 1 = 0",
        "\\vec{v} \\cdot \\vec{w} = |v||w|\\cos\\theta",
    ]

    private static var spans: [String] {
        KaTeXGoldenTests.corpus.map { entry in entry.tex } + tricky
    }

    func testOneScanMatchesTheSequentialPasses() {
        for span in Self.spans {
            XCTAssertEqual(TeX.replaceTokens(span), Self.sequential(span),
                           span.debugDescription)
        }
    }

    // Reads a control word to its end before lookup, so `\ne` inside
    // `\nesin` is never substituted, unlike Self.sequential.

    func testAnOperatorNameDoesNotBlockTheWordBeforeIt() {
        XCTAssertEqual(TeX.replaceTokens("a\\ne\\sin b"), "a\u{2260}\\sin b")
        XCTAssertEqual(TeX.replaceTokens("\\le\\ln x"), "\u{2264}\\ln x")
        XCTAssertEqual(TeX.replaceTokens("\\newcommand x"),
                       "\\newcommand x")
    }

    private static func mathsIn(_ line: String) -> [String] {
        TeX.split(line).compactMap { segment in
            if case .math(let body, let display, _) = segment {
                (display ? "D:" : "I:") + body
            } else {
                nil
            }
        }
    }

    func testBracketDelimitersAreMathsOnlyWhenTheBodyIs() {
        XCTAssertEqual(Self.mathsIn("where \\( x \\) is the input"),
                       ["I: x "])
        XCTAssertEqual(Self.mathsIn("so \\[ E = mc^2 \\] holds"),
                       ["D: E = mc^2 "])
        XCTAssertEqual(Self.mathsIn("\\[\\alpha\\] and \\(\\beta_1\\)"),
                       ["D:\\alpha", "I:\\beta_1"])
        XCTAssertEqual(Self.mathsIn("a slash \\\\\\(x\\) then maths"),
                       ["I:x"])
        XCTAssertEqual(Self.mathsIn("\\[a+b\\]"), ["D:a+b"])
        for prose in ["he said \\[sic\\] twice", "see \\[1\\] and \\[x\\]",
                      "\\[citation needed\\]", "\\[TODO\\]",
                      "see \\[1-3\\] and \\[2, 4-6\\]", "\\[*\\]",
                      "\\(see above\\)", "an unclosed \\( x",
                      "an escaped \\\\[ x = 1 \\\\]", "\\[\\]", "\\( \\)"] {
            XCTAssertEqual(Self.mathsIn(prose), [], prose)
        }
    }

    func testABracketDisplayOnItsOwnLinesIsABlock() {
        let blocks = Markdown.parse(
            "The formula:\n\\[\nE = mc^2\n\\]\nholds.\n\n\\[sic\\]")
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[1], .math("E = mc^2"))
        if case .paragraph(let tail) = blocks[3] {
            XCTAssertEqual(String(tail.characters), "[sic]")
        } else {
            XCTFail("\\[sic\\] is a paragraph, not \(blocks[3])")
        }
    }
}
