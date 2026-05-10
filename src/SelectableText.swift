import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct SelectableText: View {

    let attributed: AttributedString?
    let nsAttributed: NSAttributedString?
    let role: FontRole
    let nowrap: Bool
    let bold: Bool
    let secondary: Bool

    init(attributed: AttributedString, role: FontRole = .body,
         nowrap: Bool = false, bold: Bool = false, secondary: Bool = false) {
        self.attributed = attributed
        self.nsAttributed = nil
        self.role = role
        self.nowrap = nowrap
        self.bold = bold
        self.secondary = secondary
    }

    init(nsAttributed: NSAttributedString, role: FontRole = .body,
         nowrap: Bool = false, bold: Bool = false, secondary: Bool = false) {
        self.attributed = nil
        self.nsAttributed = nsAttributed
        self.role = role
        self.nowrap = nowrap
        self.bold = bold
        self.secondary = secondary
    }

    var body: some View {
        NativeText(attributed: attributed,
                   nsAttributed: nsAttributed,
                   role: role,
                   nowrap: nowrap,
                   bold: bold,
                   secondary: secondary)
            .fixedSize(horizontal: nowrap, vertical: true)
    }
}

struct NativeText {

    let attributed: AttributedString?
    let nsAttributed: NSAttributedString?
    let role: FontRole
    let nowrap: Bool
    let bold: Bool
    let secondary: Bool

    func resolved() -> NSAttributedString {
        let ns: NSMutableAttributedString
        if let nsAttributed {
            ns = NSMutableAttributedString(
                attributedString: nsAttributed)
        } else if let attributed {
            ns = NSMutableAttributedString(
                attributedString: NSAttributedString(attributed))
        } else {
            ns = NSMutableAttributedString(string: "")
        }
        let full = NSRange(location: 0, length: ns.length)
        let baseFont = role.platformFont
        ns.enumerateAttribute(.font,
                              in: full,
                              options: []) { value, range, _ in
            if let f = value as? PlatformFont {
                let merged = mergeTraits(of: f, into: baseFont,
                                         bold: bold)
                ns.addAttribute(.font, value: merged, range: range)
            } else {
                let final = bold ? boldFont(baseFont) : baseFont
                ns.addAttribute(.font, value: final, range: range)
            }
        }
        let defaultColor = secondary ? secondaryColor : primaryColor
        ns.enumerateAttribute(.foregroundColor,
                              in: full,
                              options: []) { value, range, _ in
            if value == nil {
                ns.addAttribute(.foregroundColor,
                                value: defaultColor,
                                range: range)
            }
        }
        return ns
    }

    private var primaryColor: PlatformColor {
        #if os(macOS)
        return NSColor.textColor
        #else
        return UIColor.label
        #endif
    }

    private var secondaryColor: PlatformColor {
        #if os(macOS)
        return NSColor.secondaryLabelColor
        #else
        return UIColor.secondaryLabel
        #endif
    }

    private func mergeTraits(of source: PlatformFont,
                             into base: PlatformFont,
                             bold: Bool) -> PlatformFont {
        var result = base
        #if os(macOS)
        var traits = source.fontDescriptor.symbolicTraits
        traits.formUnion(base.fontDescriptor.symbolicTraits)
        if bold { traits.insert(.bold) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        result = NSFont(descriptor: descriptor,
                        size: base.pointSize) ?? base
        #else
        var traits = source.fontDescriptor.symbolicTraits
        traits.formUnion(base.fontDescriptor.symbolicTraits)
        if bold { traits.insert(.traitBold) }
        if let descriptor = base.fontDescriptor
            .withSymbolicTraits(traits) {
            result = UIFont(descriptor: descriptor,
                            size: base.pointSize)
        }
        #endif
        return result
    }

    private func boldFont(_ f: PlatformFont) -> PlatformFont {
        var result = f
        #if os(macOS)
        var traits = f.fontDescriptor.symbolicTraits
        traits.insert(.bold)
        let d = f.fontDescriptor.withSymbolicTraits(traits)
        result = NSFont(descriptor: d, size: f.pointSize) ?? f
        #else
        var traits = f.fontDescriptor.symbolicTraits
        traits.insert(.traitBold)
        if let d = f.fontDescriptor.withSymbolicTraits(traits) {
            result = UIFont(descriptor: d, size: f.pointSize)
        }
        #endif
        return result
    }
}

