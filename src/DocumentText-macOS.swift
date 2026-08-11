import Foundation
import AppKit

// A cell rather than an image, so the formula stays vector and picks up
// NSColor.textColor at DRAW time. An attachment holding a rasterized
// formula bakes one theme's ink into the document and has to be rebuilt
// when the theme flips; this one just redraws.

final class MathAttachmentCell: NSTextAttachmentCell,
                              PasteboardIllustration {

    private let layout: MathLayout
    private let inset: CGFloat = 4

    init(layout: MathLayout) {
        self.layout = layout
        super.init()
    }

    // Never archived: the attachment is built fresh from the markdown
    // every time the document is laid out.
    required init(coder: NSCoder) {
        fatalError("MathAttachmentCell is not decodable")
    }

    // The formula as a PDF page, rendered on demand and kept, so building
    // a document costs nothing and only a copy pays -- and it is real bytes
    // before the pasteboard sees them, never a promise the app has to still
    // be alive to honour.
    private var pdfData: Data?
    private var pdfDark = false

    func pdf(dark: Bool) -> Data? {
        if pdfData == nil || pdfDark != dark {
            pdfData = mathPDF(layout, dark: dark)
            pdfDark = dark
        }
        return pdfData
    }

    override func cellSize() -> NSSize {
        NSSize(width: layout.width + inset * 2, height: layout.height)
    }

    // The formula sits on the text baseline like a very tall glyph, so
    // its descent is what hangs below.
    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -layout.descent)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        if let ctx = NSGraphicsContext.current?.cgContext {
            let origin = CGPoint(x: cellFrame.minX + inset, y: cellFrame.minY)
            layout.draw(in: ctx, at: origin,
                        color: NSColor.textColor.cgColor,
                        flipped: controlView?.isFlipped ?? true)
        }
    }

}

// An alpha mask that is opaque in the middle and fades to nothing within
// `feather` of every edge.
//
// Written pixel by pixel rather than drawn. A ramp of inset rectangles is
// the obvious way and it bands: each rectangle is one flat tone, so a
// 14-point margin built from two dozen fills shows two dozen stripes. Here
// every pixel gets its own value from its distance to the nearest edge, so
// the fade is as smooth as 8 bits allow.
//
// A radial gradient cannot do this either. Its fade is a circle, so on a box
// wider than it is tall the top and bottom edges stay fully opaque and only
// the corners soften, which reads as a hard-edged card.
private func featherMask(_ size: CGSize, feather: CGFloat) -> CGImage? {
    let w = Int(size.width.rounded(.up))
    let h = Int(size.height.rounded(.up))
    // Rows aligned, because CGContext wants a stride it likes and the
    // buffer has to be sized to the one it is given.
    let stride = (w + 15) / 16 * 16
    var result: CGImage? = nil
    if w > 0, h > 0, feather > 0 {
        var pixels = [UInt8](repeating: 0, count: stride * h)
        for y in 0..<h {
            let dy = CGFloat(min(y, h - 1 - y))
            for x in 0..<w {
                let dx = CGFloat(min(x, w - 1 - x))
                let t = min(min(dx, dy) / feather, 1)
                // Smoothstep, not the bare ratio: a linear ramp meets the
                // page at an angle and leaves a visible seam where the
                // fade starts and stops. This one arrives flat at both.
                let eased = t * t * (3 - 2 * t)
                pixels[y * stride + x] = UInt8((eased * 255).rounded())
            }
        }
        result = pixels.withUnsafeMutableBytes { raw -> CGImage? in
            var image: CGImage? = nil
            if let ctx = CGContext(
                data: raw.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: stride,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) {
                image = ctx.makeImage()
            }
            return image
        }
    }
    return result
}

// A formula as a PDF page, for the pasteboard. Vector rather than a raster so
// it stays crisp wherever it lands and prints properly.
//
// `dark` comes from the VIEW being copied from, never from the process:
// NSAppearance.currentDrawing() outside a drawing cycle answers for the
// process, so on a dark Mac every copy came out dark however the app was set.
func mathPDF(_ layout: MathLayout, dark: Bool,
             padding: CGFloat = 14) -> Data? {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: layout.width + padding * 2,
                     height: layout.height + padding * 2)
    var result: Data? = nil
    // 0.07 rather than a lighter grey: a dark document is nearer black than
    // an app's own transcript, and a patch lighter than the page reads as a
    // card where a slightly darker one disappears.
    let paper: CGFloat = dark ? 0.07 : 0.98
    let ink: CGFloat = dark ? 0.95 : 0.05
    if let consumer = CGDataConsumer(data: data),
       let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) {
        ctx.beginPDFPage(nil)
        // Paper under the ink, fading to nothing at every rim. Pasted into a
        // document of the SAME theme the patch disappears and the formula
        // reads as native text; pasted into the opposite one it is a soft
        // patch that keeps the formula legible instead of black on black.
        //
        // The fade occupies the PADDING band exactly, so the formula sits on
        // paper at full opacity and only the margin dissolves.
        if let mask = featherMask(box.size, feather: padding) {
            ctx.saveGState()
            ctx.clip(to: box, mask: mask)
            ctx.setFillColor(CGColor(gray: paper, alpha: 1))
            ctx.fill(box)
            ctx.restoreGState()
        }
        // `at` is the TOP-LEFT of the bounding box and draw subtracts the
        // ascent, so the top edge is padding + height in this y-up page.
        // Passing the descent instead puts the baseline below the media box
        // and cuts every formula off.
        let top = CGPoint(x: padding, y: padding + layout.height)
        layout.draw(in: ctx, at: top, color: CGColor(gray: ink, alpha: 1))
        ctx.endPDFPage()
        ctx.closePDF()
        result = data as Data
    }
    return result
}

extension DocumentText {

    static func mathAttachment(_ layout: MathLayout) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MathAttachmentCell(layout: layout)
        return attachment
    }

    // Horizontal cell padding, as a percentage of the table width so it
    // can be subtracted from the column-share budget in the same unit.
    private static var cellPad: CGFloat { 0.6 }

    // Solved against the SHARES the table will actually be built with,
    // not against the bare sum of the minimums. A column's share is a
    // fixed fraction of the table width, so the width at which column c
    // finally holds its widest token is min[c] / share[c], and the table
    // needs the largest of those. Summing the minimums instead answers a
    // question nobody asked -- the shares are weighted by character
    // count, so the sum can be reached with a column still starved.

    static func tableMinimumWidth(headers: [String],
                                  rows: [[String]]) -> CGFloat {
        var result: CGFloat = 0
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        if cols > 0 {
            let mins = columnMinimums(headers: headers, rows: rows,
                                      cols: cols)
            let fractions = TableMetrics.pointWidths(
                headers: headers, rows: rows,
                available: contentBudget(cols: cols) / 100)
            for c in 0..<cols where c < fractions.count
                                    && fractions[c] > 0 {
                let need = mins[c] / fractions[c]
                if need > result { result = need }
            }
            result = ceil(result)
        }
        return result
    }

    private static func contentBudget(cols: Int) -> CGFloat {
        max(100 - CGFloat(cols) * cellPad * 2, 50)
    }

    static func table(headers: [String], rows: [[String]],
                      images: [URL: DocumentImage]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        if cols > 0 {
            let atomicId = UUID().uuidString
            let textTable = NSTextTable()
            textTable.numberOfColumns = cols
            // Automatic, not fixed: fixed layout is CSS table-layout:
            // fixed, where a cell whose content outgrows its declared
            // width spills OVER the next column instead of widening --
            // headers printed on top of each other. The column shares
            // below are weighted by character count and cannot know the
            // rendered size, so any font the widths were not computed
            // for (a zoom step, a narrow window) overflowed them.
            textTable.layoutAlgorithm = .automaticLayoutAlgorithm
            // The shares have to leave room for the padding, or the
            // table demands 100% plus cellPad * 2 * cols and the last
            // columns are squeezed off the edge. Percentage padding
            // keeps that arithmetic in one unit.
            let budget = contentBudget(cols: cols)
            let shares = TableMetrics.pointWidths(headers: headers,
                                                  rows: rows,
                                                  available: budget)
            var rowIdx = 0
            if !headers.isEmpty {
                m.append(tableRow(cells: headers, table: textTable,
                                  rowIdx: rowIdx, cols: cols,
                                  shares: shares,
                                  bold: true,
                                  tint: platformWhite(0.5, alpha: 0.14),
                                  atomicId: atomicId,
                                  images: images))
                rowIdx += 1
            }
            for (idx, row) in rows.enumerated() {
                let tint: PlatformColor = idx % 2 == 1
                    ? platformWhite(0.5, alpha: 0.07) : platformClearColor
                m.append(tableRow(cells: row, table: textTable,
                                  rowIdx: rowIdx, cols: cols,
                                  shares: shares,
                                  bold: false, tint: tint,
                                  atomicId: atomicId,
                                  images: images))
                rowIdx += 1
            }
            // One contiguous atomic kind / id / copy over the whole table
            // (cells plus the separators, which carry none per-cell) so
            // selection-snap sees one unit and the copy overlay yields ONE
            // button. Stamped before the trailing newline so a drag past
            // the table stops at the table edge.
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

    private static func tableRow(cells: [String],
                                 table: NSTextTable,
                                 rowIdx: Int, cols: Int,
                                 shares: [CGFloat],
                                 bold: Bool,
                                 tint: PlatformColor,
                                 atomicId: String,
                                 images: [URL: DocumentImage])
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        let base = bold ? boldFont(of: FontRole.body.platformFont) : FontRole.body.platformFont
        for col in 0..<cols {
            let cellText = col < cells.count ? cells[col] : ""
            let block = NSTextTableBlock(table: table,
                                         startingRow: rowIdx, rowSpan: 1,
                                         startingColumn: col,
                                         columnSpan: 1)
            if col < shares.count {
                block.setValue(shares[col],
                               type: .percentageValueType,
                               for: .width)
            }
            block.setWidth(cellPad, type: .percentageValueType,
                           for: .padding, edge: .minX)
            block.setWidth(cellPad, type: .percentageValueType,
                           for: .padding, edge: .maxX)
            block.setWidth(3, type: .absoluteValueType,
                           for: .padding, edge: .minY)
            block.setWidth(3, type: .absoluteValueType,
                           for: .padding, edge: .maxY)
            block.backgroundColor = tint
            let para = NSMutableParagraphStyle()
            // Word wrapping is safe here only because the view refuses
            // to be narrower than tableMinimumWidth: NSTextTable cannot
            // lay out a row holding a token wider than its column -- it
            // widens that column, gives up on the rest, and stacks every
            // remaining cell at the widened column's origin, so the row
            // reads as overlapping glyphs. No column-width spelling
            // avoids it (percentage, absolute, none at all, fixed
            // algorithm, minimumWidth -- all collapse alike); only never
            // posing the question does.
            para.lineBreakMode = .byWordWrapping
            para.textBlocks = [block]
            let cellAttr = NSMutableAttributedString(
                attributedString: tableCell(cellText, base: base,
                                            images: images))
            if cellAttr.length == 0 {
                cellAttr.append(NSAttributedString(
                    string: "\u{00A0}",
                    attributes: [.font: base,
                                 .foregroundColor: platformDefaultTextColor]))
            }
            let full = NSRange(location: 0, length: cellAttr.length)
            cellAttr.addAttribute(.paragraphStyle, value: para,
                                  range: full)
            cellAttr.addAttribute(atomicKindKey,
                                  value: AtomicKind.table.rawValue,
                                  range: full)
            cellAttr.addAttribute(atomicIdKey, value: atomicId,
                                  range: full)
            m.append(cellAttr)
            m.append(NSAttributedString(string: "\n"))
        }
        return m
    }

}
