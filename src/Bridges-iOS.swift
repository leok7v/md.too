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
