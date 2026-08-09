import SwiftUI

enum AtomicKind: String {
    case code, table, image, math
}

// A copyable block's Copy-button frame and source text, reported by
// the platform text view after layout so SwiftUI can overlay a real
// Copy button there (AppKit subviews of NSTextView do not reliably
// receive clicks under SwiftUI hosting).
struct CopyBlockSpot: Equatable {
    let id: String
    let rect: CGRect
    let copy: String
}

let atomicKindKey = NSAttributedString.Key("AtomicKind.kind")
let atomicIdKey = NSAttributedString.Key("AtomicKind.id")
// The block's SOURCE text for the corner Copy button (raw code, or the
// monospaced table serialization) so Copy yields the original markdown,
// not the flattened on-screen render. Present only on code / table runs.
let atomicCopyKey = NSAttributedString.Key("AtomicKind.copy")

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
                   onCopySpots: { spots in copySpots = spots })
            .fixedSize(horizontal: nowrap, vertical: true)
            .overlay(alignment: .topLeading) { copyOverlays }
    }

    @ViewBuilder
    private var copyOverlays: some View {
        ForEach(copySpots, id: \.id) { spot in
            BlockCopyButton(copy: spot.copy)
                .frame(width: spot.rect.width,
                       height: spot.rect.height)
                .offset(x: spot.rect.minX, y: spot.rect.minY)
        }
    }

}

private struct BlockCopyButton: View {

    let copy: String
    @State private var copied = false

    var body: some View {
        Button(action: doCopy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(4)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help("Copy")
    }

    private func doCopy() {
        platformSetClipboardString(copy)
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
    // The zoom this text is rendered at. Stored, not read from the
    // defaults inside resolved(), so a changed notch changes the
    // representable and the bridges are asked to update.
    let scale: CGFloat
    let find: MarkdownFindController?
    let onCopySpots: (([CopyBlockSpot]) -> Void)?

    func resolved() -> NSAttributedString {
        let ns: NSMutableAttributedString
        if let nsAttributed {
            ns = NSMutableAttributedString(attributedString: nsAttributed)
        } else if let attributed {
            ns = NSMutableAttributedString(
                attributedString: NSAttributedString(attributed))
        } else {
            ns = NSMutableAttributedString(string: "")
        }
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
        if let attributed { applyScriptRuns(ns, from: attributed) }
        return ns
    }

}

// Splice `next` into `storage` by replacing ONLY the span that changed --
// the longest shared attributed prefix and suffix are kept -- so a live
// file reload re-lays out O(delta), not the whole document, and any
// selection outside the edit survives. The bridges call this on every
// update instead of setAttributedString.

func applyIncremental(_ storage: NSMutableAttributedString,
                      _ next: NSAttributedString) {
    let curLen = storage.length
    let nextLen = next.length
    let p = sharedAttributedPrefix(storage, next)
    let s = sharedAttributedSuffix(storage, next, after: p)
    storage.replaceCharacters(
        in: NSRange(location: p, length: curLen - p - s),
        with: next.attributedSubstring(
            from: NSRange(location: p, length: nextLen - p - s)))
}

// Length of the leading run where BOTH the characters and their
// attributes match, stepping by attribute run so the dictionary compare
// is per-run, not per-character. `scanning` is the loop's termination
// predicate, not a status flag read at the exit.

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

