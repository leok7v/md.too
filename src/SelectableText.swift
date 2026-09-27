import SwiftUI

enum AtomicKind: String {
    case code, table, image, math
}

// AppKit subviews of NSTextView do not reliably receive clicks under
// SwiftUI hosting, so the button is overlaid in SwiftUI instead.
struct CopyBlockSpot: Equatable {
    let id: String
    let rect: CGRect
    let copy: String
    // A code fence's language, drawn as a badge beside the glyph.
    var label: String? = nil
    var illustration: PasteboardIllustration? = nil

    // `illustration` is excluded: comparing it would cost only a
    // pointer, but Equatable would constrain the protocol further.
    static func == (a: CopyBlockSpot, b: CopyBlockSpot) -> Bool {
        a.id == b.id && a.rect == b.rect && a.copy == b.copy &&
        a.label == b.label
    }
}

// A CENTRED builder must reserve this on both margins, or a block
// filling its surface leaves the button sitting on the content.
let copyButtonGutter: CGFloat = 26

// AnyObject-constrained so a CopyBlockSpot can hold one without
// carrying its bytes; the PDF is asked for when copy is pressed.
@MainActor
protocol PasteboardIllustration: AnyObject {
    func pdf(dark: Bool) -> Data?
}

let atomicKindKey = NSAttributedString.Key("AtomicKind.kind")
let atomicIdKey = NSAttributedString.Key("AtomicKind.id")
// SOURCE text for the corner Copy button (raw code, or the table's
// monospaced form), present only on code / table runs.
let atomicCopyKey = NSAttributedString.Key("AtomicKind.copy")
// The language a code fence declared, for the badge beside its copy
// button. Present only on code runs that named one.
let atomicLabelKey = NSAttributedString.Key("AtomicKind.label")
// On a code block's first line: the room its tail keeps clear for the
// copy badge, which the box's right edge adds back.
let codeBadgeRoomKey = NSAttributedString.Key("AtomicKind.badgeRoom")

let codeBlockTint: PlatformColor = platformWhite(0.5, alpha: 0.10)

func codeBlockRects(in storage: NSAttributedString,
                    layoutManager lm: NSLayoutManager,
                    container tc: NSTextContainer,
                    within: NSRange,
                    padding: CGFloat, trailing: CGFloat) -> [CGRect] {
    var rects: [CGRect] = []
    let full = NSRange(location: 0, length: storage.length)
    let end = min(NSMaxRange(within), storage.length)
    var pos = min(within.location, end)
    while pos < end {
        var run = NSRange(location: 0, length: 0)
        let kind = storage.attribute(atomicKindKey, at: pos,
                                     longestEffectiveRange: &run,
                                     in: full) as? String
        if kind == AtomicKind.code.rawValue {
            let glyphs = lm.glyphRange(forCharacterRange: run,
                                       actualCharacterRange: nil)
            let para = storage.attribute(.paragraphStyle, at: run.location,
                                         effectiveRange: nil)
                as? NSParagraphStyle
            let head = max((para?.headIndent ?? 0) - padding, 0)
            let tailIndent = para?.tailIndent ?? 0
            let room = (storage.attribute(codeBadgeRoomKey,
                                          at: run.location,
                                          effectiveRange: nil) as? CGFloat) ??
                       0
            var box = CGRect.null
            lm.enumerateLineFragments(forGlyphRange: glyphs) {
                rect, _, _, _, _ in
                box = box.union(rect)
            }
            if !box.isNull {
                // A positive tail is a distance from the leading edge, a
                // negative one from the trailing edge.
                let right = (tailIndent > 0
                    ? box.minX + tailIndent + padding
                    : box.maxX + tailIndent + padding) + room
                box.size.width = right - (box.minX + head)
                box.origin.x += head
                box.size.height -= trailing
                rects.append(box)
            }
        }
        pos = max(NSMaxRange(run), pos + 1)
    }
    return rects
}

struct SelectableText: View {

    let attributed: AttributedString?
    let nsAttributed: NSAttributedString?
    let role: FontRole
    let nowrap: Bool
    let bold: Bool
    let secondary: Bool
    let find: MarkdownFindController?
    @Environment(\.secondaryText) private var envSecondary
    @Environment(\.textZoom) private var textZoom
    @State private var copySpots: [CopyBlockSpot] = []

    init(attributed: AttributedString, role: FontRole = .body,
         nowrap: Bool = false, bold: Bool = false, secondary: Bool = false,
         find: MarkdownFindController? = nil) {
        self.attributed = attributed
        self.nsAttributed = nil
        self.role = role
        self.nowrap = nowrap
        self.bold = bold
        self.secondary = secondary
        self.find = find
    }

    init(nsAttributed: NSAttributedString, role: FontRole = .body,
         nowrap: Bool = false, bold: Bool = false, secondary: Bool = false,
         find: MarkdownFindController? = nil) {
        self.attributed = nil
        self.nsAttributed = nsAttributed
        self.role = role
        self.nowrap = nowrap
        self.bold = bold
        self.secondary = secondary
        self.find = find
    }

    var body: some View {
        NativeText(attributed: attributed,
                   nsAttributed: nsAttributed,
                   role: role,
                   nowrap: nowrap,
                   bold: bold,
                   secondary: secondary || envSecondary,
                   scale: textZoom,
                   find: find,
                   onCopySpots: { spots in
                       if spots != copySpots { copySpots = spots }
                   })
            .fixedSize(horizontal: nowrap, vertical: true)
            .overlay(alignment: .topLeading) { copyOverlays }
    }

    @ViewBuilder
    private var copyOverlays: some View {
        ForEach(copySpots, id: \.id) { spot in
            BlockCopyButton(spot: spot)
                .frame(width: spot.rect.width,
                       height: spot.rect.height)
                .offset(x: spot.rect.minX, y: spot.rect.minY)
        }
    }

}

private struct BlockCopyButton: View {

    let spot: CopyBlockSpot
    @Environment(\.colorScheme) private var scheme
    @State private var copied = false

    // The frame is the 22-point square the bridge reports; the badge
    // overflows it since SwiftUI draws what extends past a view's frame.
    var body: some View {
        Button(action: doCopy) {
            HStack(spacing: 4) {
                if let label = spot.label {
                    Text(label.uppercased())
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, spot.label == nil ? 4 : 7)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .fixedSize()
        }
        .buttonStyle(.plain)
        .frame(width: spot.rect.width, height: spot.rect.height,
               alignment: .trailing)
        .help("Copy")
    }

    // TeX serves anything simple to copy as text; the PDF serves
    // whatever a formula draws that no string can spell.
    private func doCopy() {
        platformSetClipboard(string: spot.copy,
                             pdf: spot.illustration?
                                 .pdf(dark: scheme == .dark))
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
    }

}

struct NativeText {

    let attributed: AttributedString?
    let nsAttributed: NSAttributedString?
    let role: FontRole
    let nowrap: Bool
    let bold: Bool
    let secondary: Bool
    // Stored, not read live inside resolved(): a changed value must flow
    // through the view's own properties for the representable to update.
    let scale: CGFloat
    let find: MarkdownFindController?
    let onCopySpots: (([CopyBlockSpot]) -> Void)?

    func resolved() -> NSAttributedString {
        let result: NSAttributedString
        if let nsAttributed {
            result = nsAttributed
        } else if let attributed {
            result = styled(NSAttributedString(attributed))
        } else {
            result = NSAttributedString(string: "")
        }
        return result
    }

    private func styled(_ source: NSAttributedString) -> NSAttributedString {
        let ns = NSMutableAttributedString(attributedString: source)
        let full = NSRange(location: 0, length: ns.length)
        let baseFont = role.platformFont(scale: scale)
        ns.enumerateAttribute(.font, in: full, options: []) {
            value, range, _ in
            if let f = value as? PlatformFont {
                let merged = platformMergeFontTraits(
                    of: f, into: baseFont, additionalBold: bold)
                ns.addAttribute(.font, value: merged, range: range)
            } else {
                let final = bold ? boldFont(of: baseFont) : baseFont
                ns.addAttribute(.font, value: final, range: range)
            }
        }
        let defaultColor: PlatformColor = secondary ?
            platformSecondaryColor : platformDefaultTextColor
        ns.enumerateAttribute(.foregroundColor,
                              in: full,
                              options: []) { value, range, _ in
            if value == nil {
                ns.addAttribute(.foregroundColor, value: defaultColor,
                                range: range)
            }
        }
        // Last, so it shrinks the font the passes above just settled on
        // rather than being overwritten by them.
        if let attributed {
            applyScriptRuns(ns, from: attributed)
            applySmallRuns(ns, from: attributed)
            applyParagraphAlignment(ns, from: attributed)
        }
        return ns
    }

}

// Replaces only the span between the shared prefix and suffix, so a
// live reload costs O(delta) and any selection outside it survives.

func applyIncremental(_ storage: NSMutableAttributedString,
                      _ next: NSAttributedString) -> Bool {
    let curLen = storage.length
    let nextLen = next.length
    let p = sharedAttributedPrefix(storage, next)
    let s = sharedAttributedSuffix(storage, next, after: p)
    let changed = curLen - p - s > 0 || nextLen - p - s > 0
    if changed {
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: p, length: curLen - p - s),
            with: next.attributedSubstring(
                from: NSRange(location: p, length: nextLen - p - s)))
        storage.endEditing()
    }
    return changed
}

private func sharedAttributedPrefix(_ a: NSAttributedString,
                                    _ b: NSAttributedString) -> Int {
    let sa = a.string as NSString
    let sb = b.string as NSString
    let n = min(a.length, b.length)
    var i = 0
    var scanning = n > 0
    while scanning {
        if sa.character(at: i) != sb.character(at: i) {
            scanning = false
        } else {
            var ra = NSRange(location: 0, length: 0)
            var rb = NSRange(location: 0, length: 0)
            let da = a.attributes(at: i, effectiveRange: &ra) as NSDictionary
            let db = b.attributes(at: i, effectiveRange: &rb) as NSDictionary
            if !da.isEqual(db) {
                scanning = false
            } else {
                let end = min(NSMaxRange(ra), NSMaxRange(rb), n)
                var j = i + 1
                while j < end && sa.character(at: j) == sb.character(at: j) {
                    j += 1
                }
                i = j
                scanning = j >= end && i < n
            }
        }
    }
    return i
}

private func sharedAttributedSuffix(_ a: NSAttributedString,
                                    _ b: NSAttributedString,
                                    after prefix: Int) -> Int {
    let sa = a.string as NSString
    let sb = b.string as NSString
    let cap = min(a.length, b.length) - prefix
    var s = 0
    var scanning = cap > 0
    while scanning {
        let ia = a.length - 1 - s
        let ib = b.length - 1 - s
        if sa.character(at: ia) != sb.character(at: ib) {
            scanning = false
        } else {
            let da = a.attributes(at: ia, effectiveRange: nil) as NSDictionary
            let db = b.attributes(at: ib, effectiveRange: nil) as NSDictionary
            if da.isEqual(db) {
                s += 1
                scanning = s < cap
            } else {
                scanning = false
            }
        }
    }
    return s
}

