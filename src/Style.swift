import Foundation

// The look of a document in one value: every size in points derived from
// the body size and every spacing a fraction of it, so a zoom step or a
// platform's text size moves the whole page together instead of leaving
// six points of air between text that grew. md.too has one instance,
// read from the zoom; a host with a theme of its own builds another.
// Same shape as ChatOKF's MarkdownStyle, so a change on either side is
// a copy on the other.

struct MarkdownStyle: Equatable {

    var bodySize: CGFloat
    var codeSize: CGFloat
    var headingSizes: [CGFloat]
    var blockSpacing: CGFloat
    var paragraphSpacing: CGFloat
    var listIndent: CGFloat
    var quoteIndent: CGFloat
    var codePadding: CGFloat
    var cornerRadius: CGFloat
    // Inline $...$ drawn by the typesetter as an attachment on the
    // baseline, or left as the Unicode spelling that flows and searches
    // as text. On here; a host whose text must stay text turns it off.
    var typesetInlineMath: Bool

    // The ladder of the six heading levels as multiples of the body,
    // even at every zoom: browsers use 2, 1.5, 1.17, 1, 0.83, 0.67 and
    // ChatOKF 1.87 to 0.87, and a viewer wants the top of that range
    // without the tail dropping under the prose.
    static let headingLadder: [CGFloat] = [2.0, 1.5, 1.25, 1.1, 1.0, 0.9]

    init(bodySize: CGFloat) {
        self.bodySize = bodySize
        codeSize = (bodySize * 0.92).rounded()
        headingSizes = MarkdownStyle.headingLadder.map { m in
            (bodySize * m).rounded()
        }
        blockSpacing = (bodySize * 0.6).rounded()
        paragraphSpacing = (bodySize * 0.3).rounded()
        listIndent = (bodySize * 1.5).rounded()
        quoteIndent = (bodySize * 1.4).rounded()
        codePadding = (bodySize * 0.8).rounded()
        cornerRadius = 6
        typesetInlineMath = true
    }

    // The one style this app draws with: the platform's body size, which
    // follows Dynamic Type on iOS, times the zoom notch.
    static var current: MarkdownStyle {
        MarkdownStyle(bodySize: systemBodySize * Zoom.current)
    }

    static func at(zoom: CGFloat) -> MarkdownStyle {
        MarkdownStyle(bodySize: systemBodySize * zoom)
    }

    private static var systemBodySize: CGFloat {
        PlatformFont.preferredFont(forTextStyle: .body).pointSize
    }

    // Clamp to the six heading levels; anything past h6 keeps the h6 size.

    func headingSize(_ level: Int) -> CGFloat {
        headingSizes[min(max(level, 1), 6) - 1]
    }

    var bodyFont: PlatformFont {
        platformResizedFont(PlatformFont.preferredFont(forTextStyle: .body),
                            to: bodySize)
    }

    func headingFont(_ level: Int) -> PlatformFont {
        boldFont(of: platformResizedFont(
            PlatformFont.preferredFont(forTextStyle: .body),
            to: headingSize(level)))
    }

    var codeFont: PlatformFont { monoFont(at: codeSize) }

    // Space a heading claims: a full em of its own size above, counting
    // the block spacing TextKit adds from the paragraph before, so a
    // section opens with air; and less than half an em below, so the
    // heading sits on the paragraph it names rather than floating
    // between two.

    func headingSpacingBefore(_ level: Int) -> CGFloat {
        max(headingSize(level) - blockSpacing, blockSpacing).rounded()
    }

    func headingSpacingAfter(_ level: Int) -> CGFloat {
        (headingSize(level) * 0.4).rounded()
    }

    // List items sit a sliver apart in a tight list and a paragraph's
    // worth apart in a loose one.

    func itemSpacing(tight: Bool) -> CGFloat {
        tight ? (bodySize * 0.15).rounded() : paragraphSpacing
    }

}
