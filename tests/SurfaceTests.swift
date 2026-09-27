import XCTest

// The single surface built for every fixture: a document that parses is
// not yet a document that draws, and a width that comes back infinite
// or a string that comes back empty leaves the window blank without a
// word in any log.
@MainActor
final class SurfaceTests: XCTestCase {

    func testEveryFixtureBuildsASurface() throws {
        for fixture in try Fixtures.all() {
            let blocks = Markdown.parse(fixture.markdown)
            let text = DocumentText.attributed(from: blocks)
            XCTAssertEqual(text.length > 0, !blocks.isEmpty,
                           "\(fixture.name): surface length \(text.length)")
            let width = DocumentText.minimumWidth(of: blocks)
            XCTAssertTrue(width.isFinite && width >= 0,
                          "\(fixture.name): minimum width \(width)")
        }
    }

    func testEveryRunOfTheSurfaceCarriesAFontAndAColour() throws {
        for fixture in try Fixtures.all() {
            let text = DocumentText.attributed(
                from: Markdown.parse(fixture.markdown))
            let full = NSRange(location: 0, length: text.length)
            var bare = 0
            text.enumerateAttributes(in: full, options: []) { attrs, _, _ in
                if attrs[.font] == nil || attrs[.foregroundColor] == nil {
                    bare += 1
                }
            }
            XCTAssertEqual(bare, 0, "\(fixture.name): runs without a font")
        }
    }

    // An inline formula is an attachment on the surface when the style
    // typesets, and the Unicode spelling when it does not; either way
    // the copy key carries the TeX only where there is an attachment.
    func testInlineMathsFollowsTheStyleSwitch() {
        let blocks = Markdown.parse("Euler: $e^{i\\pi} + 1 = 0$, done.")
        var on = MarkdownStyle(bodySize: 13)
        on.typesetInlineMath = true
        var off = on
        off.typesetInlineMath = false
        let typeset = DocumentText.attributed(from: blocks, style: on)
        let spelled = DocumentText.attributed(from: blocks, style: off)
        XCTAssertTrue(typeset.string.contains("\u{FFFC}"))
        XCTAssertFalse(spelled.string.contains("\u{FFFC}"))
        XCTAssertTrue(spelled.string.contains("e(iπ) + 1 = 0"))
        var carried: String? = nil
        typeset.enumerateAttribute(atomicCopyKey,
                                   in: NSRange(location: 0,
                                               length: typeset.length),
                                   options: []) { value, _, _ in
            if let tex = value as? String { carried = tex }
        }
        XCTAssertEqual(carried, "$e^{i\\pi} + 1 = 0$")
    }

    // Every inline formula the engine accepts is an attachment on the
    // surface, over every fixture, and none that it refuses is.
    func testEveryAcceptedInlineFormulaIsTypeset() throws {
        for fixture in try Fixtures.all() {
            let blocks = Markdown.parse(fixture.markdown)
            var accepted = 0
            for block in blocks {
                if case .paragraph(let attr) = block {
                    for run in attr.runs {
                        if let source = run[InlineMathAttribute.self],
                           TeX.layout(TeX.undelimited(source), size: 13,
                                      display: false) != nil {
                            accepted += 1
                        }
                    }
                }
            }
            let surface = DocumentText.attributed(
                from: blocks.filter { block in
                    if case .paragraph = block { true } else { false }
                },
                style: MarkdownStyle(bodySize: 13))
            let drawn = surface.string.filter { ch in ch == "\u{FFFC}" }
            XCTAssertEqual(drawn.count, accepted,
                           "\(fixture.name): formulas typeset")
        }
    }

    // What TextKit lays out, not just what it was handed: a container as
    // wide as a window, every fixture, the used rect has to be real.
    func testEveryFixtureLaysOut() throws {
        for fixture in try Fixtures.all() {
            let text = DocumentText.attributed(
                from: Markdown.parse(fixture.markdown))
            let storage = NSTextStorage(attributedString: text)
            let manager = NSLayoutManager()
            let box = NSTextContainer(size: CGSize(width: 800, height: 1e7))
            box.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(box)
            manager.ensureLayout(for: box)
            let used = manager.usedRect(for: box)
            XCTAssertTrue(used.height.isFinite && used.width.isFinite,
                          "\(fixture.name): used rect \(used)")
            XCTAssertEqual(used.height > 0, text.length > 0,
                           "\(fixture.name): nothing laid out")
        }
    }
}
