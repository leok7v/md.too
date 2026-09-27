import Foundation
import XCTest

@MainActor
final class MathCacheTests: XCTestCase {

    private static let formula =
        "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a} + \\sum_{i=1}^{n} " +
        "\\int_0^\\infty e^{-x^2} \\, dx"

    func testTheSameFormulaIsLaidOutOnce() throws {
        TeX.forgetLayouts()
        let first = try XCTUnwrap(TeX.layout(Self.formula, size: 20))
        let second = try XCTUnwrap(TeX.layout(Self.formula, size: 20))
        XCTAssertTrue(first.box === second.box)
        let other = try XCTUnwrap(TeX.layout(Self.formula, size: 21))
        XCTAssertFalse(first.box === other.box)
        XCTAssertEqual(TeX.cachedLayoutCount, 2)
    }

    func testARefusalIsRememberedToo() {
        TeX.forgetLayouts()
        XCTAssertNil(TeX.layout("\\notarealmacro{x}", size: 20))
        XCTAssertNil(TeX.layout("\\notarealmacro{x}", size: 20))
        XCTAssertEqual(TeX.cachedLayoutCount, 1)
    }

    func testTheLayoutCacheIsBounded() {
        TeX.forgetLayouts()
        for i in 0..<600 { _ = TeX.layout("x_{\(i)}", size: 20) }
        XCTAssertLessThanOrEqual(TeX.cachedLayoutCount, 256)
        XCTAssertGreaterThan(TeX.cachedLayoutCount, 0)
    }

    func testFittedPdfSizesLeaveTheFontCacheBounded() throws {
        let font = try MathFontFile.shared()
        let before = font.cachedFontCount
        var formulas: [String] = []
        for n in 0..<80 {
            let terms = (0...(24 + n)).map { k in "x_{\(k)}" }
            formulas.append("$$" + terms.joined(separator: " + ") + "$$")
        }
        let blocks = Markdown.parse(formulas.joined(separator: "\n\n"))
        XCTAssertEqual(blocks.count, 80)
        XCTAssertNotNil(PDFExport.data(blocks: blocks, title: "t"))
        let grown = font.cachedFontCount - before
        XCTAssertLessThanOrEqual(grown, 3 * 31,
                                 "fonts grown by \(grown) over 80 formulas")
    }
}
