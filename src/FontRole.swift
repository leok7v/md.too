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

// A script run is set at roughly seven tenths of its base and shifted off
// the baseline. The two directions are not symmetric: a superscript has
// to clear the x-height of the text beside it, a subscript only has to
// drop clear of the baseline, so raising travels further than lowering.
// Derived from the base font's size rather than fixed, so it tracks zoom,
// heading level and the PDF's own sizes without any of them knowing.

func scriptRunFont(_ level: Int, base: PlatformFont)
    -> (font: PlatformFont, offset: CGFloat) {
    let size = base.pointSize
    let font = platformResizedFont(base, to: (size * 0.72).rounded())
    let offset = level > 0 ? size * 0.33 : -size * 0.14
    return (font, offset)
}

// Stamp the script runs of `attr` onto an NSAttributedString already
// built from it. The base font is read back out rather than recomputed,
// because by this point it carries the role, the zoom and whatever bold
// or italic the run inherited -- all of which the shrunken size must
// keep. For the renderers that walk attr.runs themselves this is
// unnecessary; it exists for the two that hand the whole string to
// NSAttributedString(_:) and lose the custom key on the way.

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

// A <small> run is set at 0.85 of the size it would otherwise have,
// read back off the string the same way a script run is.

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

// A centred paragraph carries its alignment on its runs; here it is
// turned into the paragraph style the text system reads.

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
