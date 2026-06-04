import SwiftUI
import AppKit

extension NativeText: NSViewRepresentable {

    final class Coordinator: NSObject, NSTextViewDelegate {

        #if !QUICKLOOK_EXTENSION
        private var anchor: Int = 0
        private var anchorScope: NSRange? = nil
        #endif

        func textView(_ tv: NSTextView, clickedOnLink link: Any,
                        at: Int) -> Bool {
            var url: URL? = nil
            switch link {
                case let u as URL: url = u
                case let s as String: url = URL(string: s)
                default: url = nil
            }
            var handled = false
            if let url {
                NSWorkspace.shared.open(url)
                handled = true
            }
            return handled
        }

        #if !QUICKLOOK_EXTENSION
        func textView(_ textView: NSTextView,
                      willChangeSelectionFromCharacterRange
                                  oldRange: NSRange,
                      toCharacterRange newRange: NSRange) -> NSRange {
            var result = newRange
            if let storage = textView.textStorage {
                if newRange.length == 0 {
                    anchor = newRange.location
                    anchorScope = atomicScope(at: anchor, in: storage)
                } else if let scope = anchorScope {
                    let endLo = newRange.location
                    let endHi = newRange.location + newRange.length
                    let scopeLo = scope.location
                    let scopeHi = scope.location + scope.length
                    let endInScope = endLo >= scopeLo && endHi <= scopeHi
                    if !endInScope {
                        let lo = min(endLo, scopeLo)
                        let hi = max(endHi, scopeHi)
                        result = NSRange(location: lo,
                                         length: hi - lo)
                        result = expandToAtomicBoundaries(
                            result, in: storage)
                    }
                } else {
                    result = expandToAtomicBoundaries(result,
                                                     in: storage)
                }
            }
            return result
        }

        private func atomicScope(at pos: Int,
                                 in storage: NSTextStorage) -> NSRange? {
            var result: NSRange? = nil
            if pos >= 0, pos < storage.length {
                var effective = NSRange(location: 0, length: 0)
                let value = storage.attribute(
                    DocumentText.atomicKindKey,
                    at: pos, effectiveRange: &effective)
                if value != nil { result = effective }
            }
            return result
        }

        private func expandToAtomicBoundaries(_ range: NSRange,
                                              in storage: NSTextStorage)
            -> NSRange {
            var lo = range.location
            var hi = range.location + range.length
            storage.enumerateAttribute(DocumentText.atomicKindKey,
                                       in: range,
                                       options: []) { value, r, _ in
                if value != nil {
                    if r.location < lo { lo = r.location }
                    let end = r.location + r.length
                    if end > hi { hi = end }
                }
            }
            return NSRange(location: lo, length: hi - lo)
        }
        #endif

    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ResizingTextView {
        let v = ResizingTextView()
        v.delegate = context.coordinator
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = !nowrap
        if nowrap {
            v.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
        }
        v.isVerticallyResizable = true
        v.isHorizontallyResizable = nowrap
        v.setContentCompressionResistancePriority(.defaultLow,
                                                  for: .horizontal)
        v.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return v
    }

    func updateNSView(_ v: ResizingTextView, context: Context) {
        v.nowrap = nowrap
        let next = resolved()
        if v.textStorage?.isEqual(to: next) != true {
            v.textStorage?.setAttributedString(next)
            v.invalidateIntrinsicContentSize()
        }
    }

    final class ResizingTextView: NSTextView {

        var nowrap: Bool = false
        private var lastBounds: NSSize = .zero

        override var intrinsicContentSize: NSSize {
            var result = super.intrinsicContentSize
            if let lm = layoutManager, let tc = textContainer {
                lm.ensureLayout(for: tc)
                let r = lm.usedRect(for: tc)
                let inset = textContainerInset
                let w: CGFloat
                if nowrap {
                    w = r.width + inset.width * 2
                } else {
                    w = NSView.noIntrinsicMetric
                }
                let h = r.height + inset.height * 2
                result = NSSize(width: w, height: h)
            }
            return result
        }

        override func layout() {
            super.layout()
            if bounds.size != lastBounds {
                lastBounds = bounds.size
                invalidateIntrinsicContentSize()
            }
        }
    }

}

extension NativeText {

    var primaryColor: NSColor { NSColor.textColor }
    var secondaryColor: NSColor { NSColor.secondaryLabelColor }

    func mergeTraits(of source: NSFont, into base: NSFont,
                     bold: Bool) -> NSFont {
        var result = base
        var traits = source.fontDescriptor.symbolicTraits
        traits.formUnion(base.fontDescriptor.symbolicTraits)
        if bold { traits.insert(.bold) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        result = NSFont(descriptor: descriptor,
                        size: base.pointSize) ?? base
        return result
    }

    func boldFont(_ f: NSFont) -> NSFont {
        var result = f
        var traits = f.fontDescriptor.symbolicTraits
        traits.insert(.bold)
        let d = f.fontDescriptor.withSymbolicTraits(traits)
        result = NSFont(descriptor: d, size: f.pointSize) ?? f
        return result
    }

}
