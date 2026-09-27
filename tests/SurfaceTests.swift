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

    // A table is as wide as its content: two short columns lay out well
    // short of the container, at the sum of their naturals plus the
    // padding, with the first column no wider than its widest cell.
    func testANarrowTableStaysNarrow() {
        let md = "| Hesse | |\n|---|---|\n| Hermann Hesse | Author |\n" +
                 "| Hessian matrix | Matrix |"
        let style = MarkdownStyle(bodySize: 13)
        let blocks = Markdown.parse(md)
        let text = DocumentText.attributed(from: blocks, style: style,
                                           budget: 600)
        let laid = laidOut(text, width: 800)
        let used = laid.manager.usedRect(for: laid.manager.textContainers[0])
        let cells = DocumentText.tableCells(
            headers: ["Hesse", ""],
            rows: [["Hermann Hesse", "Author"], ["Hessian matrix", "Matrix"]],
            alignments: [.none, .none], style: style, images: [:])
        let expected = cells.naturals.reduce(0, +) +
                       DocumentText.cellPadding(style) * 4 +
                       DocumentText.tableButtonRoom
        XCTAssertLessThan(used.width, 300)
        XCTAssertEqual(used.width, expected, accuracy: 2)
        XCTAssertLessThan(DocumentText.minimumWidth(of: blocks, style: style),
                          expected)
    }

    // A table whose naturals exceed the budget wraps into it, and one
    // whose minimums exceed it takes the minimums and widens the surface.
    func testAWideTableWrapsToTheBudgetOrWidensPastIt() {
        let style = MarkdownStyle(bodySize: 13)
        let prose = String(repeating: "word ", count: 30)
        let cells = DocumentText.tableCells(
            headers: ["a", "b"], rows: [[prose, prose]],
            alignments: [], style: style, images: [:])
        let taken = DocumentText.cellPadding(style) * 4 +
                    DocumentText.tableButtonRoom
        let wrapped = DocumentText.tableWidths(cells, budget: 400)
        XCTAssertEqual(wrapped.reduce(0, +), 400 - taken, accuracy: 1)
        let floor = DocumentText.tableWidths(cells, budget: 40)
        XCTAssertEqual(floor, cells.minimums)
        XCTAssertEqual(DocumentText.tableMinimumWidth(cells),
                       cells.minimums.reduce(0, +) + taken)
    }

    // A display asks the surface for half its width, no more: it scales
    // to the line down to that, and past it the surface widens.
    func testADisplayScalesToHalfBeforeWideningTheSurface() throws {
        let style = MarkdownStyle(bodySize: 13)
        let tex = "\\sum_{i=1}^{n} x_i + y_i + z_i + w_i + v_i + u_i"
        let blocks = Markdown.parse("$$" + tex + "$$")
        let size = TeX.displaySize(body: style.bodySize)
        let layout = try XCTUnwrap(TeX.layout(tex, size: size))
        let natural = CGSize(width: layout.width, height: layout.height)
        let fitted = DocumentText.mathFit(natural: natural,
                                          available: natural.width / 4)
        XCTAssertEqual(fitted.width, natural.width / 2, accuracy: 0.01)
        XCTAssertEqual(DocumentText.mathFit(natural: natural,
                                            available: natural.width * 2),
                       natural)
        XCTAssertLessThan(DocumentText.minimumWidth(of: blocks,
                                                    style: style),
                          natural.width)
    }

    // The maths cell's frame origin is its baseline offset: the descent
    // hangs below the line, scaled with the formula.
    func testAMathsCellFrameKeepsItsBaseline() throws {
        let layout = try XCTUnwrap(TeX.layout("\\frac{a}{b}", size: 20))
        let cell = MathAttachmentCell(layout: layout, inset: 4,
                                      scalesToLine: true)
        let box = NSTextContainer(size: CGSize(width: 800, height: 100))
        let whole = cell.cellFrame(for: box,
                                   proposedLineFragment: NSRect(
                                       x: 0, y: 0, width: 800, height: 40),
                                   glyphPosition: .zero, characterIndex: 0)
        XCTAssertEqual(whole.origin.y, -layout.descent, accuracy: 0.01)
        let squeezed = cell.cellFrame(for: box,
                                      proposedLineFragment: NSRect(
                                          x: 0, y: 0, width: 1, height: 40),
                                      glyphPosition: .zero,
                                      characterIndex: 0)
        XCTAssertEqual(squeezed.width, cell.cellSize().width / 2,
                       accuracy: 0.01)
        XCTAssertEqual(squeezed.origin.y, -layout.descent / 2,
                       accuracy: 0.01)
    }

    // A table inside a quote moves by the quote's indent as a whole:
    // its first cell starts at the indent and no cell is indented inside.
    func testAQuotedTableMovesByItsMargin() {
        let style = MarkdownStyle(bodySize: 13)
        let blocks = Markdown.parse("> | a | b |\n> |---|---|\n> | 1 | 2 |")
        let text = DocumentText.attributed(from: blocks, style: style)
        let cell = text.attribute(.paragraphStyle, at: 0,
                                  effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(cell?.headIndent, 0)
        let block = cell?.textBlocks.first as? NSTextTableBlock
        XCTAssertEqual(block?.table.width(for: .margin, edge: .minX),
                       style.quoteIndent, "the table carries the shift")
        let laid = laidOut(text, width: 800)
        let first = laid.manager.lineFragmentRect(forGlyphAt: 0,
                                                  effectiveRange: nil)
        XCTAssertEqual(first.minX,
                       style.quoteIndent + DocumentText.cellPadding(style),
                       accuracy: 1)
    }

    // A cell breaks at a space and after a hyphen between words, never
    // inside a negative number; a share past a column's natural goes to
    // the columns still short.
    func testUnbreakableRunsAndCappedShares() {
        let runs = TableMetrics.unbreakableRuns("pre-training -0.614 a/b")
            .map { r in ("pre-training -0.614 a/b" as NSString)
                .substring(with: r) }
        XCTAssertEqual(runs, ["pre-", "training", "-0.614", "a/", "b"])
        let widths = TableMetrics.columnLayout(
            headers: ["a", "b"], rows: [["x", "y"]],
            naturals: [50, 300], minimums: [20, 100], available: 200)
        XCTAssertEqual(widths[0], 50)
        XCTAssertEqual(widths[1], 150, accuracy: 0.01)
        XCTAssertEqual(TableMetrics.columnLayout(
            headers: ["a", "b"], rows: [], naturals: [50, 60],
            minimums: [20, 20], available: 200), [50, 60])
    }

    // The storage and the view are handed back with the manager, which
    // holds both weakly: a manager whose storage has gone answers zero
    // for every rect, and a table's margin is applied only when a text
    // view owns the container, as one does in the app.
    private struct Laid {
        let storage: NSTextStorage
        let view: NSTextView
        let manager: NSLayoutManager
    }

    // Find reads past case and accents: "cafe" finds "Cafe" and "cafe"
    // alike, and an empty query finds nothing.
    func testFindIgnoresCaseAndDiacritics() {
        let text = "Cafe, caf\u{E9}, and a CAF\u{C9}."
        let hits = markdownFindRanges(in: text, query: "cafe",
                                      caseSensitive: false)
        XCTAssertEqual(hits.map { r in r.location }, [0, 6, 18])
        XCTAssertEqual(markdownFindRanges(in: text, query: "cafe",
                                          caseSensitive: true).count, 1)
        XCTAssertEqual(markdownFindRanges(in: "aaa", query: "",
                                          caseSensitive: false), [])
    }

    private func laidOut(_ text: NSAttributedString,
                         width: CGFloat) -> Laid {
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let box = NSTextContainer(size: CGSize(width: width, height: 1e6))
        box.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(box)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width,
                                            height: 100),
                              textContainer: box)
        view.isHorizontallyResizable = false
        manager.ensureLayout(for: box)
        return Laid(storage: storage, view: view, manager: manager)
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
