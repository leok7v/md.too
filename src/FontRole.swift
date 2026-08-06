import SwiftUI

enum FontRole {

    case body
    case heading(Int)
    case mono

    // Every on-screen size passes through here, so the zoom multiplier
    // is applied once at this single origin. The PDF and HTML exports
    // carry their own sizes and are deliberately left alone: they render
    // a document, not the view someone happens to be reading it at.
    //
    // The property reads the stored notch, for builders that run outside
    // the view tree (DocumentText assembling a document). A view that
    // must re-render when the notch changes passes the scale it holds as
    // an environment dependency instead -- see platformFont(scale:).

    var platformFont: PlatformFont {
        platformFont(scale: Zoom.current)
    }

    func platformFont(scale zoom: CGFloat) -> PlatformFont {
        switch self {
            case .body:
                let base = PlatformFont.preferredFont(forTextStyle: .body)
                return platformResizedFont(base,
                                           to: base.pointSize * zoom)
            case .heading(let n):
                let style: PlatformFont.TextStyle
                switch n {
                    case 1: style = .largeTitle
                    case 2: style = .title1
                    case 3: style = .title2
                    case 4: style = .title3
                    case 5: style = .headline
                    default: style = .subheadline
                }
                let base = PlatformFont.preferredFont(forTextStyle: style)
                let sized = platformResizedFont(base,
                                                to: base.pointSize * zoom)
                return boldFont(of: sized)
            case .mono:
                let size = PlatformFont
                    .preferredFont(forTextStyle: .body).pointSize
                return monoFont(at: size * zoom)
        }
    }

}

func styledRunFont(intent: InlinePresentationIntent,
                   base: PlatformFont,
                   size: CGFloat? = nil,
                   additionalBold: Bool = false) -> PlatformFont {
    let s = size ?? base.pointSize
    var result = base
    if intent.contains(.code) {
        result = monoFont(at: s)
    } else {
        result = platformBoldItalicFont(
            of: base,
            bold: additionalBold || intent.contains(.stronglyEmphasized),
            italic: intent.contains(.emphasized))
    }
    return result
}
