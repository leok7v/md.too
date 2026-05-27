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
    @Environment(\.secondaryText) private var envSecondary

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
                   secondary: secondary || envSecondary)
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

    // The four per-platform helpers (primaryColor, secondaryColor,
    // mergeTraits, boldFont) live in Bridges-macOS.swift and
    // Bridges-iOS.swift, exposed via extensions on NativeText. Each
    // Bridges file is target-membership-gated, so only the right
    // platform's implementation links into each target. This file
    // stays platform-agnostic apart from the AppKit/UIKit import
    // needed for NSAttributedString.Key.font/.foregroundColor.

}

