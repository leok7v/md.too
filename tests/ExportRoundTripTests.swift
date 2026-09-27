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
