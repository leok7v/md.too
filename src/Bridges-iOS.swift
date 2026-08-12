import SwiftUI
import UIKit

extension NativeText: UIViewRepresentable {

    func makeUIView(context: Context) -> ResizingUITextView {
        let v = ResizingUITextView(usingTextLayoutManager: false)
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.adjustsFontForContentSizeCategory = true
        v.linkTextAttributes = [
            .foregroundColor: UIColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        v.setContentCompressionResistancePriority(.defaultLow,
                                                  for: .horizontal)
        v.nowrap = nowrap
        if nowrap {
            v.textContainer.widthTracksTextView = false
            v.textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
        }
        v.onCopySpots = onCopySpots
        return v
    }

    func updateUIView(_ v: ResizingUITextView, context: Context) {
        v.nowrap = nowrap
        v.onCopySpots = onCopySpots
        let next = resolved()
        if !v.textStorage.isEqual(to: next) {
            v.textStorage.beginEditing()
            applyIncremental(v.textStorage, next)
            v.textStorage.endEditing()
            v.invalidateIntrinsicContentSize()
        }
    }

    // Height measured for the PROPOSED width rather than left to the
    // intrinsic-size dance: SwiftUI keeps the height it already has for
    // a representable whose invalidation lands after its width settled,
    // so text that grows -- a zoom step -- renders into the frame the
    // smaller font was measured at and every block is clipped. nowrap
    // (code inside a horizontal scroller) keeps its natural width.

    func sizeThatFits(_ proposal: ProposedViewSize,
                      uiView v: ResizingUITextView,
                      context: Context) -> CGSize? {
        var result: CGSize? = nil
        if !nowrap, let w = proposal.width, w > 0, w.isFinite {
            let fit = v.sizeThatFits(
                CGSize(width: w, height: .greatestFiniteMagnitude))
            result = CGSize(width: w, height: ceil(fit.height))
        }
        return result
    }

    final class ResizingUITextView: UITextView {

        var nowrap: Bool = false
        var onCopySpots: (([CopyBlockSpot]) -> Void)?
        private var lastWidth: CGFloat = 0

        override var intrinsicContentSize: CGSize {
            var result = super.intrinsicContentSize
            layoutManager.ensureLayout(for: textContainer)
            let r = layoutManager.usedRect(for: textContainer)
            let h = r.height + textContainerInset.top +
                               textContainerInset.bottom
            let w: CGFloat
            if nowrap {
                w = r.width + textContainerInset.left +
                              textContainerInset.right
            } else {
                w = UIView.noIntrinsicMetric
            }
            result = CGSize(width: w, height: h)
            return result
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size.width != lastWidth {
                lastWidth = bounds.size.width
                invalidateIntrinsicContentSize()
            }
            computeCopySpots()
        }

        // Walk MAXIMAL atomic runs (longestEffectiveRange; the plain
        // enumeration fragments at each cell's style boundary) and
        // report each copyable block's corner rect + source up to
        // SwiftUI, which overlays the actual Copy button there. Same
        // contract as the macOS sibling, so one button serves both
        // single-surface builders. The report is async: layoutSubviews()
        // can run inside a SwiftUI update, where setting @State directly
        // is illegal.
        //
        // Nothing is remembered here between passes, and the macOS
        // sibling's stored previous report has NO twin on this side.
        // UIKit lays this view out while its Swift stored properties are
        // still the zeroes alloc left: a Bool reads false and an
        // Optional closure reads nil, both harmless, but a non-optional
        // Array reads as a NULL buffer and traps the instant anything
        // asks for its count. SelectableText compares before it stores,
        // which is where that state can be held safely.
        //
        // No illustration ever: the iOS builder rasterizes a formula
        // into the attachment's image rather than drawing through a
        // cell, so there is no vector page to offer the pasteboard.
        private func computeCopySpots() {
            var spots: [CopyBlockSpot] = []
            let ts = textStorage
            let lm = layoutManager
            let tc = textContainer
            lm.ensureLayout(for: tc)
            let inset = textContainerInset
            let full = NSRange(location: 0, length: ts.length)
            var pos = 0
            while pos < ts.length {
                var run = NSRange(location: 0, length: 0)
                let id = ts.attribute(atomicIdKey, at: pos,
                                      longestEffectiveRange: &run,
                                      in: full) as? String
                let copy = id == nil ? nil
                    : ts.attribute(atomicCopyKey, at: run.location,
                                   effectiveRange: nil) as? String
                let kind = id == nil ? nil
                    : ts.attribute(atomicKindKey, at: run.location,
                                   effectiveRange: nil) as? String
                if let id, let copy {
                    let gr = lm.glyphRange(forCharacterRange: run,
                                           actualCharacterRange: nil)
                    let block = lm.boundingRect(forGlyphRange: gr, in: tc)
                    // Centre the button on the FIRST line fragment, not
                    // the block's overall top: anchored to the block top
                    // the glyph reads as sitting on the first line's
                    // baseline, lower still for a table whose header row
                    // starts below its cell padding.
                    let line = lm.lineFragmentUsedRect(
                        forGlyphAt: gr.location, effectiveRange: nil)
                    // A code fence and a table start at the left margin,
                    // so a button set just inside their right edge lands
                    // in empty corner. A display is CENTRED, so that same
                    // inset lands on the formula -- it has to go out to
                    // the margin instead, which is the line fragment
                    // rather than the ink.
                    let right = kind == AtomicKind.math.rawValue
                        ? lm.lineFragmentRect(
                            forGlyphAt: gr.location,
                            effectiveRange: nil).maxX
                        : block.maxX
                    let x = right + inset.left - copyButtonGutter
                    let y = line.minY + inset.top + (line.height - 22) / 2
                    spots.append(CopyBlockSpot(
                        id: id,
                        rect: CGRect(x: x, y: y, width: 22, height: 22),
                        copy: copy))
                }
                pos = max(NSMaxRange(run), pos + 1)
            }
            let report = spots
            DispatchQueue.main.async { [weak self] in
                self?.onCopySpots?(report)
            }
        }
    }

}

struct WindowAppearanceApplier: UIViewRepresentable {

    let scheme: ColorScheme?

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        apply(to: v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        apply(to: uiView)
    }

    private func apply(to view: UIView) {
        var style: UIUserInterfaceStyle = .unspecified
        switch scheme {
            case .none: style = .unspecified
            case .light: style = .light
            case .dark: style = .dark
            @unknown default: style = .unspecified
        }
        DispatchQueue.main.async {
            view.window?.overrideUserInterfaceStyle = style
        }
    }

}
