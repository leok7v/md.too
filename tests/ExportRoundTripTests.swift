import PDFKit
import XCTest

final class ExportRoundTripTests: XCTestCase {

    func testPlainExportIsAFixedPoint() throws {
        for fixture in try Fixtures.all() {
            let once = PlainExport.render(Markdown.parse(fixture.markdown))
            let twice = PlainExport.render(Markdown.parse(once))
            XCTAssertEqual(twice, once,
                           "\(fixture.name): plain export is not a fixed point")
        }
    }

    func testPlainExportKeepsEveryHeadingAndCodeLine() throws {
        for fixture in try Fixtures.all() {
            let blocks = Markdown.parse(fixture.markdown)
            let plain = PlainExport.render(blocks)
            for block in blocks {
                switch block {
                    case .heading(_, let text):
                        // Compared run by run: markers around an italic
                        // or code run split the heading into pieces.
                        for words in Self.spelledRuns(text) {
                            XCTAssertTrue(plain.contains(words),
                                          "\(fixture.name): heading lost: " +
                                          words)
                        }
                    case .code(_, let text):
                        XCTAssertTrue(plain.contains(text),
                                      "\(fixture.name): code body lost")
                    default:
                        break
                }
            }
        }
    }

    // What the plain export writes for a run: the TeX an inline formula
    // came from, the characters otherwise.
    static func spelledRuns(_ text: AttributedString) -> [String] {
        var out: [String] = []
        for run in text.runs {
            if let source = run[InlineMathAttribute.self] {
                out.append(source)
            } else {
                out.append(String(text[run.range].characters))
            }
        }
        return out
    }

    static func currentHtml() throws -> String {
        var out = ""
        for fixture in try Fixtures.all() {
            out += "=== " + fixture.name + "\n"
            out += HtmlExport.renderFragment(Markdown.parse(fixture.markdown))
        }
        return out
    }

    static let plainCorners = """
        \\# not a heading

        \\$x$ is not maths, and \\> not a quote, a < b.

        1984\\. was a year.

        ```
        a fence ``` inside
        ```

        ````md
        ```swift
        let x = 1
        ```
        ````

        ![alt](http://example.com/a.png){width=200 height=100}

        - one

        * two

        1. a

        2) b
        """

    func testPlainExportParsesBackToTheSameBlocks() {
        let blocks = Markdown.parse(Self.plainCorners)
        let plain = PlainExport.render(blocks)
        XCTAssertEqual(ParserGoldenTests.dump(Markdown.parse(plain)),
                       ParserGoldenTests.dump(blocks), plain)
        for block in blocks {
            let alone = PlainExport.render([block])
            XCTAssertEqual(ParserGoldenTests.dump(Markdown.parse(alone)),
                           ParserGoldenTests.dump([block]), alone)
        }
    }

    func testHtmlLinksKeepOnlySafeSchemes() {
        let html = HtmlExport.renderFragment(Markdown.parse(
            "[a](https://a.b) [m](mailto:a@b) [r](../x.md) [f](#top) " +
            "[bad](javascript:alert(1))"))
        for href in ["https://a.b", "mailto:a@b", "../x.md", "#top"] {
            XCTAssertTrue(html.contains("href=\"\(href)\""), href)
        }
        XCTAssertFalse(html.contains("javascript"), html)
    }

    func testHtmlOrderedListKeepsItsStart() {
        let html = HtmlExport.renderFragment(Markdown.parse("3. c\n4. d"))
        XCTAssertTrue(html.contains("<ol start=\"3\""), html)
        XCTAssertFalse(HtmlExport.renderFragment(Markdown.parse("1. a"))
            .contains("start="))
    }

    func testTableCellsKeepReferenceLinksAndPictures() throws {
        let md = "[ref]: https://example.com\n\n| a | b |\n|---|---|\n" +
                 "| [ref] | ![p](https://example.com/p.png) |"
        let blocks = Markdown.parse(md)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let html = HtmlExport.renderFragment(
            blocks, images: [try XCTUnwrap(
                URL(string: "https://example.com/p.png")): png])
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">ref"),
                      html)
        XCTAssertTrue(html.contains("<img alt=\"p\""), html)
    }

    private func pdf(_ markdown: String) throws -> PDFDocument {
        let data = try XCTUnwrap(PDFExport.data(
            blocks: Markdown.parse(markdown), title: "t"))
        return try XCTUnwrap(PDFDocument(data: data))
    }

    private func links(_ page: PDFPage) -> [String] {
        page.annotations.compactMap { note in note.url?.absoluteString }
    }

    func testEveryPdfPageCarriesTheCreditLink() throws {
        let long = (1...200).map { n in "Paragraph \(n)." }
            .joined(separator: "\n\n")
        let doc = try pdf(long)
        XCTAssertGreaterThan(doc.pageCount, 1)
        for index in 0..<doc.pageCount {
            let page = try XCTUnwrap(doc.page(at: index))
            XCTAssertTrue(page.string?.contains("Made with md.too") == true)
            XCTAssertTrue(links(page).contains(
                "https://leok7v.github.io/md.too/"), "page \(index + 1)")
        }
    }

    func testPdfTextKeepsItsLinksAndEmphasis() throws {
        let doc = try pdf("See **bold** and [the site](https://example.com).")
        let page = try XCTUnwrap(doc.page(at: 0))
        XCTAssertTrue(links(page).contains("https://example.com"))
        let buffer = NSMutableData()
        var media = CGRect(x: 0, y: 0, width: 600, height: 800)
        let consumer = try XCTUnwrap(CGDataConsumer(data: buffer))
        let ctx = try XCTUnwrap(CGContext(consumer: consumer,
                                          mediaBox: &media, nil))
        let renderer = PDFRenderer(ctx: ctx, pageSize: media.size,
                                   title: "t")
        let paragraph = Markdown.parse("See **bold** here.")
        var bold = false
        if case .paragraph(let attr)? = paragraph.first {
            let text = renderer.styled(attr, base: CTFontCreateWithName(
                "Helvetica" as CFString, 11, nil), bold: false, para: nil,
                                       numerics: false)
            let at = (text.string as NSString).range(of: "bold").location
            let font = text.attribute(.font, at: at, effectiveRange: nil)
                as? NSFont
            bold = font?.fontDescriptor.symbolicTraits.contains(.bold) ??
                   false
        }
        XCTAssertTrue(bold, "the bold run lost its weight")
    }

    func testATableRowTallerThanAPageKeepsAllItsText() throws {
        let lines = (1...300).map { n in "line \(n)" }
            .joined(separator: "<br>")
        let doc = try pdf("| a | b |\n|---|---|\n| \(lines) | x |")
        let text = (0..<doc.pageCount).compactMap { index in
            doc.page(at: index)?.string
        }.joined()
        XCTAssertTrue(text.contains("line 300"), "the row was cut off")
    }

    func testADisplayTallerThanAPageFitsOnOne() throws {
        let rows = (1...160).map { n in String(n) }
            .joined(separator: " \\\\ ")
        let doc = try pdf("$$\\begin{matrix} " + rows + " \\end{matrix}$$")
        XCTAssertEqual(doc.pageCount, 1)
    }

    func testAnInlineFormulaTallerThanAPageTakesOnePage() throws {
        let rows = (1...160).map { n in String(n) }
            .joined(separator: " \\\\ ")
        let tex = "\\begin{matrix} " + rows + " \\end{matrix}"
        let layout = try XCTUnwrap(TeX.layout(tex, size: 11, display: false))
        XCTAssertGreaterThan(layout.height, 900)
        let blocks = Markdown.parse("Before $" + tex + "$ after.")
        let data = try XCTUnwrap(PDFExport.data(blocks: blocks, title: "t"))
        let pages = try XCTUnwrap(PDFDocument(data: data)).pageCount
        XCTAssertLessThanOrEqual(pages, 3)
    }

    func testHtmlExportIsUnchanged() throws {
        let now = try Self.currentHtml()
        let golden = try Fixtures.golden("html-golden.txt",
                                         update: "HTML_GOLDEN_UPDATE",
                                         now: now)
        if golden != now {
            XCTFail("the HTML export of the fixtures changed:\n" +
                    Fixtures.drift(golden: golden, now: now))
        }
    }
}
