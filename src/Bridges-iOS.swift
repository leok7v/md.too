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
