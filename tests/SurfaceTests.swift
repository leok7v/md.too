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
