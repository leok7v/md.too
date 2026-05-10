import SwiftUI

#if os(macOS)
import AppKit

typealias PlatformFont = NSFont
typealias PlatformColor = NSColor

func monoFont(at size: CGFloat) -> PlatformFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

func boldFont(of f: PlatformFont) -> PlatformFont {
    var traits = f.fontDescriptor.symbolicTraits
    traits.insert(.bold)
    let d = f.fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: d, size: f.pointSize) ?? f
}

#elseif os(iOS)
import UIKit

typealias PlatformFont = UIFont
typealias PlatformColor = UIColor

func monoFont(at size: CGFloat) -> PlatformFont {
    UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

func boldFont(of f: PlatformFont) -> PlatformFont {
    var traits = f.fontDescriptor.symbolicTraits
    traits.insert(.traitBold)
    if let d = f.fontDescriptor.withSymbolicTraits(traits) {
        return UIFont(descriptor: d, size: f.pointSize)
    }
    return f
}
#endif
