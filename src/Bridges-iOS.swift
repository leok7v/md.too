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
        v.registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (view: ResizingUITextView, _: UITraitCollection) in
            view.refreshCodeLayers()
        }
        v.nowrap = nowrap
        if nowrap {
            v.textContainer.widthTracksTextView = false
            v.textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
        }
        v.findController = find
        if let find { find.register(v) }
        v.onCopySpots = onCopySpots
        return v
    }

    static func dismantleUIView(_ v: ResizingUITextView,
                                coordinator: ()) {
        v.findController?.unregister(v)
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

    final class ResizingUITextView: UITextView, FindableTextView {

        var nowrap: Bool = false
        weak var findController: MarkdownFindController?
        var onCopySpots: (([CopyBlockSpot]) -> Void)?
        private var lastWidth: CGFloat = 0
        private var contentGeneration = 0
        private var overlayGeneration = -1

        private var lastApplied: NSAttributedString? = nil
        private var findMatches: [NSRange]? = nil
        private var activeIndex: Int? = nil
        private var findQuery: String? = nil
        private var matchLayers: [CALayer]? = nil
        private var codeLayers: [CALayer]? = nil
        private static let matchWindow = 500

        var liveFindCount: Int { findMatches?.count ?? 0 }

        // The render cache returns the same instance when unchanged,
        // so reference equality alone is enough to skip the splice.
        func applyResolved(_ next: NSAttributedString) {
            if next !== lastApplied {
                lastApplied = next
                if applyIncremental(textStorage, next) {
                    contentGeneration += 1
                    invalidateIntrinsicContentSize()
                    setNeedsLayout()
                    reapplyFind()
                }
            }
        }

        func findAll(_ query: String) -> Int {
            findQuery = query
            findMatches = markdownFindRanges(in: textStorage.string,
                                             query: query,
                                             caseSensitive: false)
            activeIndex = nil
            refreshMatchLayers()
            return findMatches?.count ?? 0
        }

        func setActive(_ index: Int) {
            activeIndex = index
            refreshMatchLayers()
        }

        func clearFind() {
            findQuery = nil
            findMatches = nil
            activeIndex = nil
            refreshMatchLayers()
        }

        func reapplyFind() {
            if let query = findQuery {
                findMatches = markdownFindRanges(in: textStorage.string,
                                                 query: query,
                                                 caseSensitive: false)
                if let a = activeIndex, a >= findMatches?.count ?? 0 {
                    activeIndex = nil
                }
                refreshMatchLayers()
                findController?.viewDidReapply()
            }
        }

        func activeMatchFraction() -> CGFloat? {
            var result: CGFloat? = nil
            if let rect = activeMatchRect() {
                let used = layoutManager.usedRect(for: textContainer)
                if used.height > 0 { result = rect.midY / used.height }
            }
            return result
        }

        func activeMatchOnScreen() -> Bool {
            var result = false
            if let rect = activeMatchRect() {
                result = shows(rect, through: superview)
            }
            return result
        }

        func revealActiveMatch() {
            if let range = activeRange() { scrollRangeToVisible(range) }
        }

        override func scrollRangeToVisible(_ range: NSRange) {
            reveal(range)
        }

        private func reveal(_ range: NSRange) {
            if range.location >= 0, NSMaxRange(range) <= textStorage.length {
                let glyphs = layoutManager.glyphRange(
                    forCharacterRange: range, actualCharacterRange: nil)
                let rect = layoutManager.boundingRect(forGlyphRange: glyphs,
                                                      in: textContainer)
                    .offsetBy(dx: textContainerInset.left,
                              dy: textContainerInset.top)
                scroll(to: rect.insetBy(dx: 0, dy: -40), through: superview)
            }
        }

        private func scroll(to rect: CGRect, through view: UIView?) {
            if let view {
                if let scroller = view as? UIScrollView {
                    let r = convert(rect, to: scroller)
                    scroller.scrollRectToVisible(
                        CGRect(x: scroller.contentOffset.x, y: r.minY,
                               width: scroller.bounds.width,
                               height: r.height),
                        animated: true)
                }
                scroll(to: rect, through: view.superview)
            }
        }

        private func shows(_ rect: CGRect, through view: UIView?) -> Bool {
            var result = true
            if let view {
                if let scroll = view as? UIScrollView {
                    let seen = scroll.bounds.inset(
                        by: scroll.adjustedContentInset)
                    result = seen.contains(convert(rect, to: scroll))
                }
                result = result && shows(rect, through: view.superview)
            }
            return result
        }

        private func activeRange() -> NSRange? {
            var result: NSRange? = nil
            if let i = activeIndex, let all = findMatches,
               i >= 0, i < all.count,
               NSMaxRange(all[i]) <= textStorage.length {
                result = all[i]
            }
            return result
        }

        private func activeMatchRect() -> CGRect? {
            var result: CGRect? = nil
            if let range = activeRange() {
                let glyphs = layoutManager.glyphRange(
                    forCharacterRange: range, actualCharacterRange: nil)
                result = layoutManager.boundingRect(forGlyphRange: glyphs,
                                                    in: textContainer)
                    .offsetBy(dx: textContainerInset.left,
                              dy: textContainerInset.top)
            }
            return result
        }

        func refreshCodeLayers() {
            let style = MarkdownStyle.current
            let inset = textContainerInset
            let color = codeBlockTint
                .resolvedColor(with: traitCollection).cgColor
            let boxes = codeBlockRects(
                in: textStorage, layoutManager: layoutManager,
                container: textContainer,
                within: NSRange(location: 0, length: textStorage.length),
                padding: style.codePadding, hang: style.codeHang,
                trailing: style.blockSpacing)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for old in codeLayers ?? [] { old.removeFromSuperlayer() }
            let fresh = boxes.map { box in
                let tint = CALayer()
                tint.backgroundColor = color
                tint.cornerRadius = style.cornerRadius
                tint.zPosition = -2
                tint.frame = box.offsetBy(dx: inset.left, dy: inset.top)
                return tint
            }
            for tint in fresh { layer.insertSublayer(tint, at: 0) }
            codeLayers = fresh
            CATransaction.commit()
        }

        private func refreshMatchLayers() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for old in matchLayers ?? [] { old.removeFromSuperlayer() }
            var fresh: [CALayer] = []
            if let all = findMatches {
                let first = max((activeIndex ?? 0) - Self.matchWindow / 2, 0)
                for (i, r) in all.enumerated().dropFirst(first)
                    .prefix(Self.matchWindow) {
                    fresh += tintLayers(for: r, active: i == activeIndex)
                }
            }
            for tint in fresh { layer.insertSublayer(tint, at: 0) }
            matchLayers = fresh
            CATransaction.commit()
        }

        private func tintLayers(for range: NSRange,
                                active: Bool) -> [CALayer] {
            var result: [CALayer] = []
            if NSMaxRange(range) <= textStorage.length {
                let lm = layoutManager
                let tc = textContainer
                let inset = textContainerInset
                let color = (active ? activeTint : findTint).cgColor
                let glyphs = lm.glyphRange(forCharacterRange: range,
                                           actualCharacterRange: nil)
                lm.enumerateLineFragments(forGlyphRange: glyphs) {
                    _, _, _, lineGlyphs, _ in
                    let part = NSIntersectionRange(lineGlyphs, glyphs)
                    let box = lm.boundingRect(forGlyphRange: part, in: tc)
                    let tint = CALayer()
                    tint.backgroundColor = color
                    tint.cornerRadius = 2
                    tint.zPosition = -1
                    tint.frame = box.offsetBy(dx: inset.left, dy: inset.top)
                    result.append(tint)
                }
            }
            return result
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
                refreshMatchLayers()
            }
            if resized || overlayGeneration != contentGeneration {
                overlayGeneration = contentGeneration
                refreshCodeLayers()
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
                    padding: style.codePadding, hang: style.codeHang,
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
