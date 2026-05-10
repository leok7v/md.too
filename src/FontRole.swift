import SwiftUI

enum FontRole {

    case body
    case heading(Int)
    case mono

    var platformFont: PlatformFont {
        switch self {
            case .body:
                return PlatformFont.preferredFont(forTextStyle: .body)
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
                return boldFont(of: base)
            case .mono:
                let size = PlatformFont
                    .preferredFont(forTextStyle: .body).pointSize
                return monoFont(at: size)
        }
    }
}
