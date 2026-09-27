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

    // A column moves every paragraph but a table's: head indents grow by
    // the inset, tails end at the column's far edge, and a tail measured
    // from the trailing edge, a code block's, keeps its distance.
    func testAColumnIndentsProseAndLeavesTables() {
        let md = "A paragraph.\n\n```\ncode\n```\n\n" +
                 "| a | b |\n|---|---|\n| 1 | 2 |"
        let style = MarkdownStyle(bodySize: 13)
        let column = DocumentText.Column(inset: 100, width: 400)
        let text = DocumentText.attributed(from: Markdown.parse(md),
                                           style: style, column: column)
        var seen: [String: NSParagraphStyle] = [:]
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.paragraphStyle, in: full,
                                options: []) { value, range, _ in
            let kind = text.attribute(atomicKindKey, at: range.location,
                                      effectiveRange: nil) as? String
            if let para = value as? NSParagraphStyle,
               seen[kind ?? "prose"] == nil {
                seen[kind ?? "prose"] = para
            }
        }
        XCTAssertEqual(seen["prose"]?.headIndent, 100)
        XCTAssertEqual(seen["prose"]?.tailIndent, 500)
        XCTAssertEqual(seen["code"]?.headIndent, 100 + style.codePadding)
        XCTAssertEqual(seen["code"]?.tailIndent, 500 - style.codePadding)
        XCTAssertEqual(seen["table"]?.headIndent, 0)
        XCTAssertEqual(seen["table"]?.tailIndent, 0)
    }

    // A list's tab stop travels with its indent, a display wider than
    // the column takes the surface whole, and a rule spans the column.
    func testAColumnMovesTabStopsAndSparesWideBlocks() {
        let md = "- item\n\n" +
                 "$$\\sum_{i=1}^{n} x_i + y_i + z_i + w_i + v_i$$\n\n---"
        let style = MarkdownStyle(bodySize: 13)
        let column = DocumentText.Column(inset: 100, width: 120)
        let blocks = Markdown.parse(md)
        let text = DocumentText.attributed(from: blocks, style: style,
                                           column: column)
        let item = text.attribute(.paragraphStyle, at: 0,
                                  effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(item?.headIndent, 100 + style.listIndent)
        XCTAssertEqual(item?.tabStops.first?.location,
                       100 + style.listIndent)
        var display: NSParagraphStyle? = nil
        var rule: CGRect = .zero
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(atomicKindKey, in: full,
                                options: []) { value, range, _ in
            if value as? String == AtomicKind.math.rawValue {
                display = text.attribute(.paragraphStyle, at: range.location,
                                         effectiveRange: nil)
                    as? NSParagraphStyle
            }
        }
        XCTAssertEqual(display?.headIndent, 0,
                       "a display wider than the column keeps the surface")
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let box = NSTextContainer(size: CGSize(width: 800, height: 1e6))
        box.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(box)
        manager.ensureLayout(for: box)
        text.enumerateAttribute(atomicCopyKey, in: full,
                                options: []) { value, range, _ in
            if value as? String == "---" {
                let glyphs = manager.glyphRange(forCharacterRange: range,
                                                actualCharacterRange: nil)
                rule = manager.boundingRect(forGlyphRange: glyphs, in: box)
            }
        }
        XCTAssertEqual(rule.minX, 100, accuracy: 1)
        XCTAssertEqual(rule.width, 120, accuracy: 1,
                       "the rule spans the column, not the surface")
    }

    // A list inside a quote tabs its body to a stop that moved with the
    // quote's indent, not to the stop it had at the top level.
    func testANestedListsTabStopMovesWithItsIndent() {
        let style = MarkdownStyle(bodySize: 13)
        let text = DocumentText.attributed(from: Markdown.parse("> - item"),
                                           style: style)
        let item = text.attribute(.paragraphStyle, at: 0,
                                  effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(item?.tabStops.first?.location,
                       style.quoteIndent + style.listIndent)
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
