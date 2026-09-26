import Foundation
import XCTest

// TeX.replaceTokens is one scan over the source; the oracle here is the
// pass-per-token substitution it replaced, kept in the test so the two
// can be compared on every span the golden corpus and the tricky list
// hold. The one deliberate difference is asserted on its own.
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

    // The scan reads a control word to its end before looking it up, so
    // `\ne` inside `\nesin` is never substituted; the sequential passes
    // would, and that is the bug the scan fixed.

    func testAnOperatorNameDoesNotBlockTheWordBeforeIt() {
        XCTAssertEqual(TeX.replaceTokens("a\\ne\\sin b"), "a\u{2260}\\sin b")
        XCTAssertEqual(TeX.replaceTokens("\\le\\ln x"), "\u{2264}\\ln x")
        XCTAssertEqual(TeX.replaceTokens("\\newcommand x"),
                       "\\newcommand x")
    }
}
