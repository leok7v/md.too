import Foundation
import AppKit

final class MathAttachmentCell: NSTextAttachmentCell,
                              PasteboardIllustration {

    private let layout: MathLayout
    private let inset: CGFloat
    private let scalesToLine: Bool

    init(layout: MathLayout, inset: CGFloat, scalesToLine: Bool) {
        self.layout = layout
        self.inset = inset
        self.scalesToLine = scalesToLine
        super.init()
    }

    // Never archived: the attachment is built fresh from the markdown
    // every time the document is laid out.
    required init(coder: NSCoder) {
        fatalError("MathAttachmentCell is not decodable")
    }

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

    override func cellFrame(for textContainer: NSTextContainer,
                            proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint,
                            characterIndex: Int) -> NSRect {
        var size = cellSize()
        if scalesToLine {
            size = DocumentText.mathFit(
                natural: size,
                available: DocumentText.mathRoom(in: lineFrag.width))
        }
        // The frame's origin is the baseline offset, so the descent
        // hangs below the line at the same scale as the rest.
        let scale = cellSize().width > 0 ? size.width / cellSize().width : 1
        return NSRect(origin: NSPoint(x: 0, y: -layout.descent * scale),
                      size: size)
    }

    // The scale is read back off the frame, since draw is never told
    // the width the frame was fitted to.
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        if let ctx = NSGraphicsContext.current?.cgContext {
            let natural = cellSize().width
            let scale = natural > 0 ? cellFrame.width / natural : 1
            ctx.saveGState()
            ctx.translateBy(x: cellFrame.minX, y: cellFrame.minY)
            ctx.scaleBy(x: scale, y: scale)
            layout.draw(in: ctx, at: CGPoint(x: inset, y: 0),
                        color: NSColor.textColor.cgColor,
                        flipped: controlView?.isFlipped ?? true)
            ctx.restoreGState()
        }
    }

}

// `dark` must come from the view being copied from: process-wide
// NSAppearance.currentDrawing() misreports outside a drawing cycle.
func mathPDF(_ layout: MathLayout, dark: Bool,
             padding: CGFloat = 8) -> Data? {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: layout.width + padding * 2,
                     height: layout.height + padding * 2)
    var result: Data? = nil
    let ink = CGColor(gray: dark ? 0.95 : 0.05, alpha: 1)
    let ground = CGColor(gray: dark ? 0.07 : 0.98, alpha: 1)
    if let consumer = CGDataConsumer(data: data),
       let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) {
        ctx.beginPDFPage(nil)
        // `at` is TOP-LEFT of the bounding box in this y-up page; draw
        // subtracts the ascent, so passing descent instead clips the glyph.
        let top = CGPoint(x: padding, y: padding + layout.height)
        // Stroke drawn before fill so ink sits on top; stroking after
        // would eat into the letterforms from both sides.
        ctx.setLineWidth(2.2)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(ground)
        ctx.setTextDrawingMode(.stroke)
        layout.draw(in: ctx, at: top, color: ground)
        ctx.setTextDrawingMode(.fill)
        layout.draw(in: ctx, at: top, color: ink)
        ctx.endPDFPage()
        ctx.closePDF()
        result = data as Data
    }
    return result
}

final class RuleAttachmentCell: NSTextAttachmentCell {

    private let height: CGFloat

    init(height: CGFloat) {
        self.height = height
        super.init()
    }

    required init(coder: NSCoder) {
        fatalError("RuleAttachmentCell is not decodable")
    }

    override func cellSize() -> NSSize {
        NSSize(width: 1, height: height)
    }

    override func cellFrame(for textContainer: NSTextContainer,
                            proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint,
                            characterIndex: Int) -> NSRect {
        NSRect(x: 0, y: 0, width: max(lineFrag.width - position.x, 1),
               height: height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        NSColor.separatorColor.setFill()
        NSRect(x: cellFrame.minX, y: cellFrame.midY - 0.5,
               width: cellFrame.width, height: 1).fill()
    }

}

extension DocumentText {

    static func mathAttachment(_ layout: MathLayout,
                               inset: CGFloat = 4,
                               scalesToLine: Bool) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = MathAttachmentCell(
            layout: layout, inset: inset, scalesToLine: scalesToLine)
        return attachment
    }

    static func ruleAttachment(height: CGFloat) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        attachment.attachmentCell = RuleAttachmentCell(height: height)
        return attachment
    }

    static func table(_ cells: TableCells, id: String,
                      style: MarkdownStyle,
                      budget: CGFloat) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let cols = cells.cols
        if cols > 0 {
            let atomicId = id
            let textTable = NSTextTable()
            textTable.numberOfColumns = cols
            textTable.layoutAlgorithm = .automaticLayoutAlgorithm
            let widths = tableWidths(cells, budget: budget)
            var rowIdx = 0
            if !cells.header.isEmpty {
                m.append(tableRow(cells: cells.header, table: textTable,
                                  rowIdx: rowIdx, cols: cols,
                                  widths: widths, layout: cells,
                                  bold: true,
                                  tint: platformWhite(0.5, alpha: 0.14),
                                  atomicId: atomicId))
                rowIdx += 1
            }
            for (idx, row) in cells.body.enumerated() {
                let tint: PlatformColor = idx % 2 == 1
                    ? platformWhite(0.5, alpha: 0.07) : platformClearColor
                m.append(tableRow(cells: row, table: textTable,
                                  rowIdx: rowIdx, cols: cols,
                                  widths: widths, layout: cells,
                                  bold: false, tint: tint,
                                  atomicId: atomicId))
                rowIdx += 1
            }
            let content = NSRange(location: 0, length: m.length)
            m.addAttribute(atomicKindKey,
                           value: AtomicKind.table.rawValue, range: content)
            m.addAttribute(atomicIdKey, value: atomicId, range: content)
            m.addAttribute(atomicCopyKey,
                           value: TableMetrics.serializeMonospaced(
                               headers: cells.headers, rows: cells.rows,
                               alignments: cells.alignments),
                           range: content)
            m.append(NSAttributedString(string: "\n"))
        }
        return m
    }

    private static func nsAlignment(_ a: Alignment) -> NSTextAlignment {
        let result: NSTextAlignment
        switch a {
            case .center: result = .center
            case .right: result = .right
            case .left, .none: result = .natural
        }
        return result
    }

    private static func tableRow(cells: [TableCell],
                                 table: NSTextTable,
                                 rowIdx: Int, cols: Int,
                                 widths: [CGFloat],
                                 layout: TableCells,
                                 bold: Bool,
                                 tint: PlatformColor,
                                 atomicId: String)
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        let body = layout.style.bodyFont
        let base = bold ? boldFont(of: body) : body
        let pad = cellPadding(layout.style)
        for col in 0..<cols {
            let text = col < cells.count ? cells[col].text
                                         : NSAttributedString()
            let block = NSTextTableBlock(table: table,
                                         startingRow: rowIdx, rowSpan: 1,
                                         startingColumn: col,
                                         columnSpan: 1)
            if col < widths.count {
                block.setValue(widths[col], type: .absoluteValueType,
                               for: .width)
            }
            block.setWidth(pad, type: .absoluteValueType,
                           for: .padding, edge: .minX)
            block.setWidth(col == cols - 1 ? pad + tableButtonRoom : pad,
                           type: .absoluteValueType,
                           for: .padding, edge: .maxX)
            block.setWidth(3, type: .absoluteValueType,
                           for: .padding, edge: .minY)
            block.setWidth(3, type: .absoluteValueType,
                           for: .padding, edge: .maxY)
            block.backgroundColor = tint
            let para = NSMutableParagraphStyle()
            para.lineBreakMode = .byWordWrapping
            para.textBlocks = [block]
            para.alignment = nsAlignment(layout.alignment(col))
            let cellAttr = NSMutableAttributedString(attributedString: text)
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

    static func movedCell(_ existing: NSParagraphStyle?, by amount: CGFloat,
                          tables: inout [ObjectIdentifier: MovedTable])
        -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        if let existing { para.setParagraphStyle(existing) }
        if let block = existing?.textBlocks.first as? NSTextTableBlock {
            let key = ObjectIdentifier(block.table)
            let moved = tables[key]?.moved as? NSTextTable ??
                        movedTable(block.table, by: amount)
            tables[key] = MovedTable(original: block.table, moved: moved)
            para.textBlocks = [rebased(block, onto: moved)]
        }
        return para
    }

    private static func movedTable(_ table: NSTextTable,
                                   by amount: CGFloat) -> NSTextTable {
        let moved = NSTextTable()
        moved.numberOfColumns = table.numberOfColumns
        moved.layoutAlgorithm = table.layoutAlgorithm
        let margin = table.width(for: .margin, edge: .minX)
        moved.setWidth(margin + amount, type: .absoluteValueType,
                       for: .margin, edge: .minX)
        return moved
    }

    private static func rebased(_ block: NSTextTableBlock,
                                onto table: NSTextTable) -> NSTextTableBlock {
        let copy = NSTextTableBlock(table: table,
                                    startingRow: block.startingRow,
                                    rowSpan: block.rowSpan,
                                    startingColumn: block.startingColumn,
                                    columnSpan: block.columnSpan)
        copy.setValue(block.value(for: .width),
                      type: block.valueType(for: .width), for: .width)
        for edge in [NSRectEdge.minX, .maxX, .minY, .maxY] {
            copy.setWidth(block.width(for: .padding, edge: edge),
                          type: block.widthValueType(for: .padding,
                                                     edge: edge),
                          for: .padding, edge: edge)
        }
        copy.backgroundColor = block.backgroundColor
        return copy
    }

    // `bounds` is empty for a cell-drawn attachment; a cell AppKit made
    // from the image would answer the picture's own size, not the fit.

    static func attachmentWidth(_ attachment: NSTextAttachment) -> CGFloat {
        let cell = attachment.attachmentCell as? NSTextAttachmentCell
        return attachment.bounds.width > 0
            ? attachment.bounds.width
            : cell?.cellSize().width ?? 0
    }

}
