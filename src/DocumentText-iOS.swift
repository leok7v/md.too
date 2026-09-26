import Foundation
import UIKit

extension DocumentText {

    private struct RasterKey: Hashable {
        let box: ObjectIdentifier
        let scale: CGFloat
    }

    private struct Raster {
        let layout: MathLayout
        let ink: CGColor
        let image: UIImage
    }

    private static var rasters: [RasterKey: Raster] = [:]
    private static let rasterCapacity = 32

    // UIKit has no attachment cell to draw through, so the formula is
    // rasterized with the ink current when the document was built. Single
    // surface is off by default on iOS; when that changes, this wants a
    // rebuild on trait change or an NSTextAttachmentViewProvider.

    static func mathAttachment(_ layout: MathLayout) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.image = raster(layout, scale: UIScreen.main.scale,
                                  ink: platformDefaultTextColor.cgColor)
        attachment.bounds = CGRect(x: 0, y: -layout.descent,
                                   width: layout.width + 8,
                                   height: layout.height)
        return attachment
    }

    // The raster entry keeps its layout so the box the key names cannot
    // be freed and reused by a different formula behind the key's back.
    private static func raster(_ layout: MathLayout, scale: CGFloat,
                               ink: CGColor) -> UIImage? {
        let key = RasterKey(box: ObjectIdentifier(layout.box), scale: scale)
        var result: UIImage? = nil
        if let hit = rasters[key], hit.layout.box === layout.box,
           CFEqual(hit.ink, ink) {
            result = hit.image
        } else if let cg = layout.cgImage(scale: scale, padding: 4,
                                          background: nil, color: ink) {
            let image = UIImage(cgImage: cg, scale: scale, orientation: .up)
            if rasters.count >= rasterCapacity { rasters.removeAll() }
            rasters[key] = Raster(layout: layout, ink: ink, image: image)
            result = image
        }
        return result
    }

    // What this builder actually lays out, not what the content would
    // like: the tab stops below are pinned to tabStopExtent whatever the
    // view is, and cells truncate rather than overflow, so asking the
    // view to be wider than that would buy empty space and nothing else.
    // Single surface is off by default on iOS; when that changes, the
    // stops want deriving from the cell minimums and this with them.

    private static var tabStopExtent: CGFloat { 320 }

    static func tableMinimumWidth(_ cells: TableCells) -> CGFloat {
        cells.cols > 0 ? tabStopExtent : 0
    }

    static func table(_ cells: TableCells, id: String) -> NSAttributedString {
        let m = NSMutableAttributedString()
        if cells.cols > 0 {
            let atomicId = id
            let widths = TableMetrics.pointWidths(headers: cells.headers,
                                                  rows: cells.rows,
                                                  available: tabStopExtent)
            var stops: [NSTextTab] = []
            var x: CGFloat = 0
            for w in widths {
                x += w
                stops.append(NSTextTab(textAlignment: .left, location: x))
            }
            if !cells.header.isEmpty {
                m.append(tableRowTabStops(cells: cells.header, stops: stops,
                                          bold: true,
                                          tint: platformWhite(0.5, alpha: 0.14),
                                          atomicId: atomicId))
            }
            for (idx, row) in cells.body.enumerated() {
                let tint: PlatformColor = idx % 2 == 1
                    ? platformWhite(0.5, alpha: 0.07) : platformClearColor
                m.append(tableRowTabStops(cells: row, stops: stops,
                                          bold: false, tint: tint,
                                          atomicId: atomicId))
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
                               headers: cells.headers, rows: cells.rows),
                           range: content)
            m.append(NSAttributedString(string: "\n"))
        }
        return m
    }

    private static func tableRowTabStops(cells: [TableCell],
                                         stops: [NSTextTab],
                                         bold: Bool,
                                         tint: PlatformColor,
                                         atomicId: String)
        -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.tabStops = stops
        para.lineBreakMode = .byTruncatingTail
        let body = FontRole.body.platformFont
        let base = bold ? boldFont(of: body) : body
        let m = NSMutableAttributedString()
        for (i, cell) in cells.enumerated() {
            if i > 0 {
                m.append(NSAttributedString(
                    string: "\t", attributes: [.font: base]))
            }
            m.append(cell.text)
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
