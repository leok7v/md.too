import XCTest

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

    func testAColumnIndentsProseAndLeavesTables() {
        let md = "A paragraph.\n\n```\ncode\nmore\n```\n\n" +
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
        XCTAssertEqual(seen["code"]?.tailIndent,
                       500 - style.codePadding -
                           DocumentText.codeBadgeRoom(label: nil),
                       "the first line keeps clear of the badge")
        var lastCode: NSParagraphStyle? = nil
        text.enumerateAttribute(.paragraphStyle, in: full,
                                options: []) { value, range, _ in
            let kind = text.attribute(atomicKindKey, at: range.location,
                                      effectiveRange: nil) as? String
            if kind == AtomicKind.code.rawValue {
                lastCode = value as? NSParagraphStyle
            }
        }
        XCTAssertEqual(lastCode?.tailIndent, 500 - style.codePadding,
                       "and only the first line does")
        XCTAssertEqual(seen["table"]?.headIndent, 0)
        XCTAssertEqual(seen["table"]?.tailIndent, 0)
    }

    func testAWideTableAlignsWithTheProseWhenTheSurfaceHasRoom() {
        let style = MarkdownStyle(bodySize: 13)
        let prose = String(repeating: "word ", count: 40)
        let md = "| a | b |\n|---|---|\n| \(prose) | \(prose) |"
        let blocks = Markdown.parse(md)
        let need = DocumentText.minimumWidth(of: blocks, style: style)
        let roomy = DocumentText.Column(inset: 100, width: need - 50,
                                        surface: need + 200)
        let tight = DocumentText.Column(inset: 100, width: need - 50,
                                        surface: need)
        let margin: (DocumentText.Column) -> CGFloat = { column in
            let text = DocumentText.attributed(from: blocks, style: style,
                                               column: column)
            let cell = text.attribute(.paragraphStyle, at: 0,
                                      effectiveRange: nil)
                as? NSParagraphStyle
            let block = cell?.textBlocks.first as? NSTextTableBlock
            return block?.table.width(for: .margin, edge: .minX) ?? -1
        }
        XCTAssertEqual(margin(roomy), 100)
        XCTAssertEqual(margin(tight), 0)
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
        XCTAssertEqual(display?.headIndent, 100,
                       "a display wider than the column starts with the prose")
        XCTAssertEqual(display?.tailIndent, 0,
                       "and keeps the rest of the surface")
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

    // The manager holds storage and view weakly; a table's margin
    // applies only when a text view owns the container.
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

    func testAReloadThatShortensTheTextKeepsTheSelectionInside() {
        let view = NativeText.ResizingTextView()
        let arbiter = NativeText.Coordinator()
        view.delegate = arbiter
        let long = DocumentText.attributed(from: Markdown.parse(
            "Intro.\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n" +
            "```\ncode\nmore\n```"))
        view.applyResolved(long)
        let caret = NSRange(location: long.length - 3, length: 0)
        _ = arbiter.textView(view,
                             willChangeSelectionFromCharacterRange: caret,
                             toCharacterRange: caret)
        view.applyResolved(DocumentText.attributed(
            from: Markdown.parse("Intro.")))
        let length = view.textStorage?.length ?? 0
        let drag = NSRange(location: 2, length: long.length - 2)
        let picked = arbiter.textView(
            view, willChangeSelectionFromCharacterRange: caret,
            toCharacterRange: drag)
        XCTAssertLessThanOrEqual(NSMaxRange(picked), length)
    }

    func testImagesAreFoundInsideQuotesListsAndHeaders() {
        let md = "> ![q](https://e.com/q.png)\n\n- ![l](https://e.com/l.png)" +
                 "\n\n| ![h](https://e.com/h.png) |\n|---|\n| x |"
        let names = ImagePrefetch.collectURLs(in: Markdown.parse(md))
            .map { url in url.lastPathComponent }.sorted()
        XCTAssertEqual(names, ["h.png", "l.png", "q.png"])
    }

    private func paragraphStyle(_ text: NSAttributedString,
                                at i: Int) -> NSParagraphStyle? {
        text.attribute(.paragraphStyle, at: i, effectiveRange: nil)
            as? NSParagraphStyle
    }

    func testAnItemsFirstBlockSharesTheMarkerLine() {
        let style = MarkdownStyle(bodySize: 13)
        let code = DocumentText.attributed(
            from: Markdown.parse("- ```\n  let x = 1\n  ```"), style: style)
        XCTAssertTrue(code.string.hasPrefix("\u{2022}\tlet x = 1\n"),
                      code.string.debugDescription)
        let joined = paragraphStyle(code, at: 0)
        XCTAssertEqual(joined?.firstLineHeadIndent, 0)
        XCTAssertEqual(joined?.tabStops.first?.location,
                       style.listIndent + style.codePadding)
        let nested = DocumentText.attributed(from: Markdown.parse("- - a"),
                                             style: style)
        XCTAssertTrue(nested.string.hasPrefix("\u{2022}\t\u{2022}\ta\n"),
                      nested.string.debugDescription)
    }

    func testAWideOrdinalGetsTheRoomItNeeds() {
        let style = MarkdownStyle(bodySize: 13)
        let text = DocumentText.attributed(
            from: Markdown.parse("100. a\n101. b"), style: style)
        let width = NSAttributedString(string: "100.",
                                       attributes: [.font: style.bodyFont])
            .size().width
        XCTAssertGreaterThan(paragraphStyle(text, at: 0)?.headIndent ?? 0,
                             width)
    }

    func testAListEndingInANestedListSpacesAfterItsLastLine() {
        let style = MarkdownStyle(bodySize: 13)
        let text = DocumentText.attributed(
            from: Markdown.parse("- a\n  - b\n\nAfter."), style: style)
        let ns = text.string as NSString
        let a = paragraphStyle(text, at: 0)
        let b = paragraphStyle(text, at: ns.range(of: "b").location)
        XCTAssertEqual(a?.paragraphSpacing, style.itemSpacing(tight: true))
        XCTAssertEqual(b?.paragraphSpacing, style.blockSpacing)
    }

    func testAdjacentCodeBlocksAreTwoBoxes() {
        let text = DocumentText.attributed(from: Markdown.parse(
            "```swift\nlet a = 1\n```\n```json\n{}\n```"))
        let laid = laidOut(text, width: 600)
        let boxes = codeBlockRects(
            in: laid.storage, layoutManager: laid.manager,
            container: laid.manager.textContainers[0],
            within: NSRange(location: 0, length: text.length),
            padding: 10, trailing: 8)
        XCTAssertEqual(boxes.count, 2)
    }

    func testAnEditReplacesOnlyFromTheEditedBlock() throws {
        let source = try String(contentsOf: Fixtures.root
            .deletingLastPathComponent().appendingPathComponent("EXAMPLE.md"),
                                encoding: .utf8)
        let marker = "## "
        let at = try XCTUnwrap(source.range(of: marker, options: .backwards))
        let edited = source.replacingCharacters(in: at, with: "## Edited ")
        let cache = DocumentText.RenderCache()
        let view = NativeText.ResizingTextView()
        view.applyResolved(DocumentText.attributed(
            from: Markdown.parse(source), cache: cache))
        let storage = try XCTUnwrap(view.textStorage)
        let next = DocumentText.attributed(from: Markdown.parse(edited),
                                           cache: cache)
        let replaced = incrementalRange(storage, next)
        let title = String(source[at.upperBound...]
            .prefix { ch in ch != "\n" })
        let heading = (storage.string as NSString)
            .range(of: title, options: .backwards).location
        XCTAssertEqual(replaced.location, heading,
                       "the splice starts before the edited block")
        _ = applyIncremental(storage, next)
        XCTAssertEqual(storage.string, next.string)
    }

    func testDisplaysAndPlaceholdersSpaceLikeParagraphs() {
        let style = MarkdownStyle(bodySize: 13)
        let text = DocumentText.attributed(
            from: Markdown.parse("A.\n\n$$x$$\n\n![p](https://e.com/p.png)"),
            style: style)
        let ns = text.string as NSString
        let display = ns.range(of: "\u{FFFC}").location
        XCTAssertEqual(paragraphStyle(text, at: display)?
            .paragraphSpacingBefore, 0)
        XCTAssertFalse(text.string.contains("]\n\n"))
    }

    func testTextIsReadInWhateverEncodingItCameIn() {
        XCTAssertEqual(Markdown.text(from: Data("Café".utf8)), "Café")
        XCTAssertEqual(Markdown.text(from: Data([0x43, 0x61, 0x66, 0xE9])),
                       "Café")
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("Café".data(using: .utf16LittleEndian) ?? Data())
        XCTAssertEqual(Markdown.text(from: utf16), "Café")
        XCTAssertEqual(Markdown.parse("one\r\rtwo").count, 2)
    }

    private func ink(_ code: String, _ language: String,
                     at needle: String) -> PlatformColor? {
        let text = Highlight.attribute(code, language: language,
                                       baseFont: monoFont(at: 12))
        let at = (code as NSString).range(of: needle).location
        return text.attribute(.foregroundColor, at: at,
                              effectiveRange: nil) as? PlatformColor
    }

    func testTheHighlighterReadsCommentsStringsAndKeysInOrder() {
        let js = "let u = \"http://e.com\"; // note"
        XCTAssertEqual(ink(js, "js", at: "//e.com"), ink(js, "js", at: "\""))
        XCTAssertNotEqual(ink(js, "js", at: "note"), ink(js, "js", at: "\""))
        let json = "{\"key\": \"value\"}"
        XCTAssertNotEqual(ink(json, "json", at: "key"),
                          ink(json, "json", at: "value"))
        let ruby = "s = 'it\\'s' + 'x' # note"
        XCTAssertNotEqual(ink(ruby, "ruby", at: "+ '"),
                          ink(ruby, "ruby", at: "it"),
                          "the escaped quote ended the string")
        XCTAssertNotEqual(ink(ruby, "ruby", at: "note"),
                          ink(ruby, "ruby", at: "it"))
        XCTAssertEqual(ink("x = 1", "rs", at: "1"), ink("x = 1", "rust",
                                                          at: "1"))
        let quoted = "/* it's */ s = 'abc';"
        XCTAssertEqual(ink(quoted, "js", at: "abc"),
                       ink("q = 'z';", "js", at: "z"))
    }

    func testALongDigitRunHighlightsInLinearTime() {
        let digits = String(repeating: "7", count: 20_000) + "x"
        let start = ContinuousClock.now
        _ = Highlight.attribute(digits, language: "c",
                                baseFont: monoFont(at: 12))
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testQuickLookMeasuresACellAsItIsShown() {
        XCTAssertEqual(TableMeasure.shown("**bold** [l](http://e.com/long)"),
                       "bold l")
        XCTAssertEqual(TableMeasure.shown("![p](http://e.com/p.png)"), "")
    }

    func testEveryExportGetsItsOwnTag() {
        XCTAssertNotEqual(TempPDFs.nextTag(), TempPDFs.nextTag())
    }

    private final class CountingView: FindableTextView {
        var count = 5
        func findAll(_ query: String, caseSensitive: Bool) -> Int { count }
        func setActive(_ index: Int?) {}
        func clearFind() {}
        var liveFindCount: Int { count }
        func activeMatchFraction() -> CGFloat? { nil }
        func activeMatchOnScreen() -> Bool { true }
        func revealActiveMatch() {}
    }

    func testTheFindCounterStaysWithinTheMatches() async throws {
        let find = MarkdownFindController()
        let view = CountingView()
        find.register(view)
        find.find("x")
        for _ in 0..<4 { find.findNext() }
        XCTAssertEqual(find.currentMatch, 5)
        view.count = 3
        find.viewDidReapply()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(find.matchCount, 3)
        XCTAssertLessThanOrEqual(find.currentMatch, find.matchCount)
    }

    private func scratchFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("a.md")
        try "# a".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    func testAWatcherFollowsAMove() throws {
        let file = try scratchFile()
        let moved = file.deletingLastPathComponent()
            .appendingPathComponent("b.md")
        let watcher = FileWatcher(url: file) { _ in }
        watcher.presentedItemDidMove(to: moved)
        XCTAssertEqual(watcher.presentedItemURL, moved)
        watcher.stop()
        try? FileManager.default.removeItem(
            at: file.deletingLastPathComponent())
    }

    func testAStoppedWatcherIsFreed() async throws {
        let file = try scratchFile()
        weak var released: FileWatcher? = nil
        do {
            let watcher = FileWatcher(url: file) { _ in }
            watcher.stop()
            released = watcher
        }
        var waited = 0
        while released != nil, waited < 40 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        XCTAssertNil(released, "a stopped watcher is still alive")
        try? FileManager.default.removeItem(
            at: file.deletingLastPathComponent())
    }

    func testDeepNestingParsesAndRendersWithinTheCap() {
        let quotes = String(repeating: "> ", count: 100_000) + "deep"
        let items = String(repeating: "- ", count: 100_000) + "deep"
        for source in [quotes, items] {
            let blocks = Markdown.parse(source)
            XCTAssertLessThanOrEqual(Self.nesting(blocks),
                                     Markdown.maxNesting + 1)
            XCTAssertGreaterThan(
                DocumentText.attributed(from: blocks).length, 0)
            XCTAssertFalse(PlainExport.render(blocks).isEmpty)
            XCTAssertFalse(HtmlExport.renderFragment(blocks).isEmpty)
        }
    }

    private static func nesting(_ blocks: [Block]) -> Int {
        var deepest = 0
        for block in blocks {
            var inner = 0
            switch block {
                case .quote(let body): inner = 1 + nesting(body)
                case .list(let list, _):
                    for item in list {
                        inner = max(inner, 1 + nesting(item.blocks))
                    }
                default: inner = 0
            }
            deepest = max(deepest, inner)
        }
        return deepest
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
