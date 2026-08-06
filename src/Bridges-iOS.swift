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
        v.nowrap = nowrap
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
