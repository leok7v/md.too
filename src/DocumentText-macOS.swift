import Foundation
import AppKit

// A cell rather than an image, so the formula stays vector and picks up
// NSColor.textColor at DRAW time. An attachment holding a rasterized
// formula bakes one theme's ink into the document and has to be rebuilt
// when the theme flips; this one just redraws.

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

    // A display scales to the line it is offered, since it has no break
    // to give and TextKit would clip it. An inline formula does not: a
    // line's remainder is not its measure, it wraps to the next line
    // like a word. Asked more than once per layout, so it answers from
    // the width offered and remembers nothing between calls.
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

// A formula as a PDF page, for the pasteboard. Vector rather than a raster,
// so it stays crisp wherever it lands and prints properly.
//
// It carries NO background. The ink is the ink of the document it was copied
// from, and the same glyphs are stroked underneath in that document's PAPER
// colour. Pasted onto a page of the same theme the outline is the colour of
// that page and disappears, leaving clean solid ink; pasted onto the opposite
// theme the ink sinks into the ground and the outline, now the only thing
// contrasting with it, traces the glyphs instead.
//
// This replaced a feathered patch of paper. The patch worked, but it is a
// rectangle on someone else's page and it has to be blended away at every
// rim; an outline is only visible where it is needed and needs no blending.
//
// What cannot work, tested rather than assumed: white ink in a Difference
// blend, which would invert against anything behind it. The blend mode does
// reach the file -- /BM /Difference is in the PDF -- but a PDF page composites
// as an ISOLATED transparency group, so its backdrop is its own emptiness and
// never the host's page. White stayed white: perfect on dark, invisible on
// light.
//
// `dark` comes from the VIEW being copied from, never from the process:
// NSAppearance.currentDrawing() outside a drawing cycle answers for the
// process, so on a dark Mac every copy came out dark however the app was set.
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
        // `at` is the TOP-LEFT of the bounding box and draw subtracts the
        // ascent, so the top edge is padding + height in this y-up page.
        // Passing the descent instead puts the baseline below the media box
        // and cuts every formula off.
        let top = CGPoint(x: padding, y: padding + layout.height)
        // The outline goes down first so the ink sits on top of it and the
        // glyph keeps its own weight; a stroke drawn after the fill would
        // eat into the letterforms from both sides.
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

// A horizontal rule as a cell that asks TextKit for the width of the
// line it sits on and strokes a hairline across it, so the rule spans
// the column at any width and follows the separator colour.

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

    // A display gets four points of air each side; an inline formula
    // one, so it sits in its sentence like a word.
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

    // Every cell is given its column's width in points, so the table is
    // exactly as wide as its content asked for and sits at the leading
    // edge; a percentage would stretch a two-column table across the
    // surface and hand the first column most of it. Automatic, not
    // fixed, layout: a fixed cell whose content outgrows its width
    // spills over the next column instead of widening.

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
            // Word wrapping is safe here only because no column is ever
            // narrower than its widest unbreakable run: NSTextTable
            // cannot lay out a row holding a run wider than its column
            // -- it widens that column, gives up on the rest, and stacks
            // every remaining cell at the widened column's origin, so
            // the row reads as overlapping glyphs. No column-width
            // spelling avoids it; only never posing the question does.
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

    // A table cell moved right: a paragraph indent on a cell indents
    // inside the cell, so the table's own leading margin carries the
    // shift. The table and the cell's block are rebuilt on the moved
    // margin rather than changed in place, so the string the cell came
    // from keeps its geometry; `tables` maps each original table to its
    // moved copy so every cell of one table lands in one copy.

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

    // An attachment drawn through a cell has no bounds of its own; the
    // cell knows its size. Bounds first: an image's bounds are the fit
    // the document asked for, and a cell AppKit made from the image
    // would answer the picture's own size.

    static func attachmentWidth(_ attachment: NSTextAttachment) -> CGFloat {
        let cell = attachment.attachmentCell as? NSTextAttachmentCell
        return attachment.bounds.width > 0
            ? attachment.bounds.width
            : cell?.cellSize().width ?? 0
    }

}
