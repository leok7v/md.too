import SwiftUI
import UIKit

extension NativeText: UIViewRepresentable {

    func makeUIView(context: Context) -> ResizingUITextView {
        // TextKit 1 (`usingTextLayoutManager: false`) - the iOS 16+
        // default of TextKit 2 truncates long documents at an
        // internal layout limit, which is what stops EXAMPLE.md
        // rendering at the Dockerfile block and leaves the rest
        // (including images further down) blank. TextKit 1 lays out
        // the full attributed string reliably for any document
        // length we ship.
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
            // BlockView.CodeBlock wraps the text view in a horizontal
            // ScrollView and asks for nowrap layout. UITextView's
            // default text container tracks the view's width, so
            // inside an unconstrained-width horizontal ScrollView
            // its width resolves to 0 and the layout manager lays
            // out nothing - which is why the code block rendered as
            // an empty card. Detach the container's width from the
            // view's width and let it grow as wide as the content
            // requires; the outer horizontal ScrollView handles the
            // overflow.
            v.textContainer.widthTracksTextView = false
            v.textContainer.size = CGSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
        }
        return v
    }

    func updateUIView(_ v: ResizingUITextView, context: Context) {
        let next = resolved()
        if v.attributedText?.isEqual(to: next) != true {
            v.attributedText = next
            v.invalidateIntrinsicContentSize()
        }
    }

    final class ResizingUITextView: UITextView {

        var nowrap: Bool = false
        private var lastWidth: CGFloat = 0

        // SwiftUI's UIViewRepresentable wrapper relies on
        // intrinsicContentSize to size a non-scrolling UITextView
        // inside the outer ScrollView. UIKit's default computes
        // intrinsic size only after layout - for tall attributed
        // strings the first pass returns a stale (too small) height
        // and SwiftUI never asks again. Force the TextKit 1 layout
        // manager to lay out the whole textContainer, then return
        // the used height + insets so SwiftUI gets the real size.
        // For nowrap mode (code blocks in horizontal scroll), the
        // container's width is unbounded, so report the used width
        // back to SwiftUI too - otherwise SwiftUI gives the view a
        // zero-width frame and the code block renders as empty card.
        override var intrinsicContentSize: CGSize {
            var result = super.intrinsicContentSize
            layoutManager.ensureLayout(for: textContainer)
            let r = layoutManager.usedRect(for: textContainer)
            let h = r.height + textContainerInset.top
                            + textContainerInset.bottom
            let w: CGFloat
            if nowrap {
                w = r.width + textContainerInset.left
                            + textContainerInset.right
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
        }
    }

}

extension NativeText {

    var primaryColor: UIColor { UIColor.label }
    var secondaryColor: UIColor { UIColor.secondaryLabel }

    func mergeTraits(of source: UIFont, into base: UIFont,
                     bold: Bool) -> UIFont {
        var result = base
        var traits = source.fontDescriptor.symbolicTraits
        traits.formUnion(base.fontDescriptor.symbolicTraits)
        if bold { traits.insert(.traitBold) }
        if let descriptor = base.fontDescriptor
            .withSymbolicTraits(traits) {
            result = UIFont(descriptor: descriptor,
                            size: base.pointSize)
        }
        return result
    }

    func boldFont(_ f: UIFont) -> UIFont {
        var result = f
        var traits = f.fontDescriptor.symbolicTraits
        traits.insert(.traitBold)
        if let d = f.fontDescriptor.withSymbolicTraits(traits) {
            result = UIFont(descriptor: d, size: f.pointSize)
        }
        return result
    }

}
