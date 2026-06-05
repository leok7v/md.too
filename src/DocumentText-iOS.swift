import Foundation
import UIKit

extension DocumentText {

    static func table(headers: [String], rows: [[String]],
                      images: [URL: DocumentImage]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        if cols > 0 {
            let atomicId = UUID().uuidString
            let widths = TableMetrics.pointWidths(headers: headers,
                                                  rows: rows,
                                                  available: 320)
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
