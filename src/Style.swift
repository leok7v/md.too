import Foundation

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
    var columnWidth: CGFloat
    var typesetInlineMath: Bool

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
        columnWidth = (bodySize * 42).rounded()
        typesetInlineMath = true
    }

    static var current: MarkdownStyle {
        MarkdownStyle(bodySize: systemBodySize * Zoom.current)
    }

    static func at(zoom: CGFloat) -> MarkdownStyle {
        MarkdownStyle(bodySize: systemBodySize * zoom)
    }

    private static var systemBodySize: CGFloat {
        PlatformFont.preferredFont(forTextStyle: .body).pointSize
    }

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

    // Subtracts blockSpacing: TextKit adds the previous paragraph's
    // spacing to this one's spacing-before, so the raw em would double it.

    func headingSpacingBefore(_ level: Int) -> CGFloat {
        max(headingSize(level) - blockSpacing, blockSpacing).rounded()
    }

    func headingSpacingAfter(_ level: Int) -> CGFloat {
        (headingSize(level) * 0.4).rounded()
    }

    func itemSpacing(tight: Bool) -> CGFloat {
        tight ? (bodySize * 0.15).rounded() : paragraphSpacing
    }

}
