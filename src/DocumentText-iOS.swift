import Foundation
import UIKit

extension DocumentText {

    // UIKit has no attachment cell to draw through, so the formula is
    // rasterized with the ink current when the document was built. Single
    // surface is off by default on iOS; when that changes, this wants a
    // rebuild on trait change or an NSTextAttachmentViewProvider.

    static func mathAttachment(_ layout: MathLayout) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let scale = UIScreen.main.scale
        let ink = platformDefaultTextColor.cgColor
        if let cg = layout.cgImage(scale: scale, padding: 4,
                                   background: nil, color: ink) {
            attachment.image = UIImage(cgImage: cg, scale: scale,
                                       orientation: .up)
        }
        attachment.bounds = CGRect(x: 0, y: -layout.descent,
                                   width: layout.width + 8,
                                   height: layout.height)
        return attachment
    }

    // What this builder actually lays out, not what the content would
    // like: the tab stops below are pinned to tabStopExtent whatever the
    // view is, and cells truncate rather than overflow, so asking the
    // view to be wider than that would buy empty space and nothing else.
    // Single surface is off by default on iOS; when that changes, the
    // stops want deriving from columnMinimums and this with them.

    private static var tabStopExtent: CGFloat { 320 }

    static func tableMinimumWidth(headers: [String],
                                  rows: [[String]]) -> CGFloat {
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        return cols > 0 ? tabStopExtent : 0
    }

    static func table(headers: [String], rows: [[String]],
                      images: [URL: DocumentImage]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        if cols > 0 {
            let atomicId = UUID().uuidString
            let widths = TableMetrics.pointWidths(headers: headers,
                                                  rows: rows,
                                                  available: tabStopExtent)
            var stops: [NSTextTab] = []
            var x: CGFloat = 0
            for w in widths {
                x += w
                stops.append(NSTextTab(textAlignment: .left, location: x))
            }
            if !headers.isEmpty {
                m.append(tableRowTabStops(cells: headers, stops: stops,
                                          bold: true,
                                          tint: platformWhite(0.5, alpha: 0.14),
                                          atomicId: atomicId,
                                          images: images))
            }
            for (idx, row) in rows.enumerated() {
                let tint: PlatformColor = idx % 2 == 1
                    ? platformWhite(0.5, alpha: 0.07) : platformClearColor
                m.append(tableRowTabStops(cells: row, stops: stops,
                                          bold: false, tint: tint,
                                          atomicId: atomicId,
                                          images: images))
            }
            // One contiguous atomic kind / id / copy over the whole table,
            // stamped before the trailing newline, mirroring the macOS
            // sibling so both single-surface builders carry the same
            // copy-source contract.
            let content = NSRange(location: 0, length: m.length)
            m.addAttribute(atomicKindKey,
                           value: AtomicKind.table.rawValue, range: content)
            m.addAttribute(atomicIdKey, value: atomicId, range: content)
            m.addAttribute(atomicCopyKey,
                           value: TableMetrics.serializeMonospaced(
                               headers: headers, rows: rows),
                           range: content)
            m.append(NSAttributedString(string: "\n"))
        }
        return m
    }

    private static func tableRowTabStops(cells: [String],
                                         stops: [NSTextTab],
                                         bold: Bool,
                                         tint: PlatformColor,
                                         atomicId: String,
                                         images: [URL: DocumentImage])
        -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.tabStops = stops
        para.lineBreakMode = .byTruncatingTail
        let base = bold ? boldFont(of: FontRole.body.platformFont) : FontRole.body.platformFont
        let m = NSMutableAttributedString()
        for (i, cell) in cells.enumerated() {
            if i > 0 {
                m.append(NSAttributedString(
                    string: "\t", attributes: [.font: base]))
            }
            m.append(tableCell(cell, base: base, images: images))
        }
        m.append(NSAttributedString(string: "\n",
                                    attributes: [.font: base]))
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(.paragraphStyle, value: para, range: full)
        m.addAttribute(.backgroundColor, value: tint, range: full)
        m.addAttribute(atomicKindKey,
                       value: AtomicKind.table.rawValue, range: full)
        m.addAttribute(atomicIdKey, value: atomicId, range: full)
        return m
    }

}
