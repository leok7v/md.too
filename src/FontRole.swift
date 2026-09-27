import SwiftUI

enum FontRole {

    case body
    case heading(Int)
    case mono

    // Reads the stored notch. A view that must re-render when the notch
    // changes passes it as a parameter through platformFont(scale:).

    var platformFont: PlatformFont {
        platformFont(in: MarkdownStyle.current)
    }

    func platformFont(scale zoom: CGFloat) -> PlatformFont {
        platformFont(in: MarkdownStyle.at(zoom: zoom))
    }

    func platformFont(in style: MarkdownStyle) -> PlatformFont {
        let result: PlatformFont
        switch self {
            case .body: result = style.bodyFont
            case .heading(let n): result = style.headingFont(n)
            case .mono: result = style.codeFont
        }
        return result
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

func scriptRunFont(_ level: Int, base: PlatformFont)
    -> (font: PlatformFont, offset: CGFloat) {
    let size = base.pointSize
    let font = platformResizedFont(base, to: (size * 0.72).rounded())
    let offset = level > 0 ? size * 0.33 : -size * 0.14
    return (font, offset)
}

// NSAttributedString(_:) drops AttributedString's custom keys, so the
// zoomed, bold/italic base font is re-read from `m` instead of recomputed.

func applyScriptRuns(_ m: NSMutableAttributedString,
                     from attr: AttributedString) {
    for run in attr.runs {
        let level = run[ScriptAttribute.self]
        let r = NSRange(run.range, in: attr)
        if let level, r.length > 0, NSMaxRange(r) <= m.length {
            stampScript(m, level: level, range: r)
        }
    }
}

func smallRunFont(base: PlatformFont) -> PlatformFont {
    platformResizedFont(base, to: (base.pointSize * 0.85).rounded())
}

func applySmallRuns(_ m: NSMutableAttributedString,
                    from attr: AttributedString) {
    for run in attr.runs {
        let r = NSRange(run.range, in: attr)
        if run[SmallAttribute.self] == true, r.length > 0,
           NSMaxRange(r) <= m.length,
           let base = m.attribute(.font, at: r.location,
                                  effectiveRange: nil) as? PlatformFont {
            m.addAttribute(.font, value: smallRunFont(base: base), range: r)
        }
    }
}

func applyParagraphAlignment(_ m: NSMutableAttributedString,
                             from attr: AttributedString) {
    if attr.runs.first?[AlignAttribute.self] == .center, m.length > 0 {
        let full = NSRange(location: 0, length: m.length)
        let existing = m.attribute(.paragraphStyle, at: 0,
                                   effectiveRange: nil) as? NSParagraphStyle
        let para = NSMutableParagraphStyle()
        if let existing { para.setParagraphStyle(existing) }
        para.alignment = .center
        m.addAttribute(.paragraphStyle, value: para, range: full)
    }
}

private func stampScript(_ m: NSMutableAttributedString,
                         level: Int, range: NSRange) {
    let base = m.attribute(.font, at: range.location,
                           effectiveRange: nil) as? PlatformFont
    if let base {
        let script = scriptRunFont(level, base: base)
        m.addAttribute(.font, value: script.font, range: range)
        m.addAttribute(.baselineOffset, value: script.offset, range: range)
    }
}
