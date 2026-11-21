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
        // The code boxes are drawn by the view itself, so a new frame
        // must draw again rather than stretch the old bitmap.
        v.contentMode = .redraw
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
        v.applyResolved(resolved())
    }

    // SwiftUI can keep this view's old height across a width change,
    // so height is computed for the offered width instead of reused.

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
        private var contentGeneration = 0
        private var overlayGeneration = -1

        private var lastApplied: NSAttributedString? = nil

        // The render cache returns the same instance when unchanged,
        // so reference equality alone is enough to skip the splice.
        func applyResolved(_ next: NSAttributedString) {
            if next !== lastApplied {
                lastApplied = next
                if applyIncremental(textStorage, next) {
                    contentGeneration += 1
                    invalidateIntrinsicContentSize()
                    setNeedsLayout()
                    setNeedsDisplay()
                }
            }
        }

        // UITextView draws its text in a private subview, so a fill
        // here in draw(_:) paints underneath it automatically.
        override func draw(_ rect: CGRect) {
            let style = MarkdownStyle.current
            let inset = textContainerInset
            let shown = rect.offsetBy(dx: -inset.left, dy: -inset.top)
            let glyphs = layoutManager.glyphRange(forBoundingRect: shown,
                                                  in: textContainer)
            let chars = layoutManager.characterRange(
                forGlyphRange: glyphs, actualGlyphRange: nil)
            codeBlockTint.setFill()
            for box in codeBlockRects(in: textStorage,
                                      layoutManager: layoutManager,
                                      container: textContainer,
                                      within: chars,
                                      padding: style.codePadding,
                                      trailing: style.blockSpacing) {
                UIBezierPath(roundedRect: box.offsetBy(dx: inset.left,
                                                       dy: inset.top),
                             cornerRadius: style.cornerRadius).fill()
            }
            super.draw(rect)
        }

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
            let resized = bounds.size.width != lastWidth
            if resized {
                lastWidth = bounds.size.width
                invalidateIntrinsicContentSize()
            }
            if resized || overlayGeneration != contentGeneration {
                overlayGeneration = contentGeneration
                computeCopySpots()
            }
        }

        // layoutSubviews() can run inside a SwiftUI update, where
        // setting @State directly is illegal, so the report is async.
        // UIKit can lay this view out before Swift's init runs, and a
        // stored non-optional Array here would read a zeroed buffer.
        private func computeCopySpots() {
            layoutManager.ensureLayout(for: textContainer)
            let report = atomicRuns(in: textStorage).map { run in
                copySpot(for: run)
            }
            DispatchQueue.main.async { [weak self] in
                self?.onCopySpots?(report)
            }
        }

        private func copySpot(for run: AtomicRun) -> CopyBlockSpot {
            let lm = layoutManager
            let tc = textContainer
            let inset = textContainerInset
            let gr = lm.glyphRange(forCharacterRange: run.range,
                                   actualCharacterRange: nil)
            let block = lm.boundingRect(forGlyphRange: gr, in: tc)
            let line = lm.lineFragmentUsedRect(forGlyphAt: gr.location,
                                               effectiveRange: nil)
            let right = copyRight(of: run, glyphs: gr, block: block)
            let beside = run.kind == AtomicKind.table.rawValue &&
                block.maxX + 4 + copyButtonSide <= tc.size.width
            let x = beside
                ? block.maxX + inset.left + 4
                : right + inset.left - copyButtonGutter
            let y = line.minY + inset.top +
                    (line.height - copyButtonSide) / 2
            return CopyBlockSpot(
                id: run.id,
                rect: CGRect(x: x, y: y, width: copyButtonSide,
                             height: copyButtonSide),
                copy: run.copy, label: run.label)
        }

        private func copyRight(of run: AtomicRun, glyphs gr: NSRange,
                               block: CGRect) -> CGFloat {
            let style = MarkdownStyle.current
            let right: CGFloat
            if run.kind == AtomicKind.math.rawValue {
                right = layoutManager.lineFragmentRect(
                    forGlyphAt: gr.location, effectiveRange: nil).maxX
            } else if run.kind == AtomicKind.code.rawValue {
                right = codeBlockRects(
                    in: textStorage, layoutManager: layoutManager,
                    container: textContainer, within: run.range,
                    padding: style.codePadding,
                    trailing: style.blockSpacing)
                    .first?.maxX ?? block.maxX
            } else {
                right = block.maxX
            }
            return right
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
