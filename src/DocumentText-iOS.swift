import Foundation
import UIKit

extension DocumentText {

    private struct RasterKey: Hashable {
        let box: ObjectIdentifier
        let scale: CGFloat
        let inset: CGFloat
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

    static func mathAttachment(_ layout: MathLayout,
                               inset: CGFloat = 4,
                               scalesToLine: Bool) -> NSTextAttachment {
        let attachment = MathAttachment(descent: layout.descent,
                                        scalesToLine: scalesToLine)
        attachment.image = raster(layout, scale: UIScreen.main.scale,
                                  inset: inset,
                                  ink: platformDefaultTextColor.cgColor)
        attachment.bounds = CGRect(x: 0, y: -layout.descent,
                                   width: layout.width + inset * 2,
                                   height: layout.height)
        return attachment
    }

    // A tab-stop table is a paragraph, so a cell moves the way a
    // paragraph does and its stops travel with it.

    static func movedCell(_ existing: NSParagraphStyle?, by amount: CGFloat,
                          tables: inout [ObjectIdentifier: MovedTable])
        -> NSMutableParagraphStyle {
        shifted(existing, by: amount)
    }

    static func attachmentWidth(_ attachment: NSTextAttachment) -> CGFloat {
        attachment.bounds.width
    }

    // The raster entry keeps its layout so the box the key names cannot
    // be freed and reused by a different formula behind the key's back.
    private static func raster(_ layout: MathLayout, scale: CGFloat,
                               inset: CGFloat, ink: CGColor) -> UIImage? {
        let key = RasterKey(box: ObjectIdentifier(layout.box), scale: scale,
                            inset: inset)
        var result: UIImage? = nil
        if let hit = rasters[key], hit.layout.box === layout.box,
           CFEqual(hit.ink, ink) {
            result = hit.image
        } else if let cg = layout.cgImage(scale: scale, padding: inset,
                                          background: nil, color: ink) {
            let image = UIImage(cgImage: cg, scale: scale, orientation: .up)
            if rasters.count >= rasterCapacity { rasters.removeAll() }
            rasters[key] = Raster(layout: layout, ink: ink, image: image)
            result = image
        }
        return result
    }

    // A horizontal rule as an attachment that sizes itself to the line
    // it sits on and draws a hairline across it.

    static func ruleAttachment(height: CGFloat) -> NSTextAttachment {
        RuleAttachment(height: height)
    }

    // A row is one paragraph with a stop per column, each stop at the
    // far edge of the column before it, so a table is as wide as the
    // same content widths the macOS table draws with. A cell truncates
    // rather than wraps: a tab stop has no second line.

    static func table(_ cells: TableCells, id: String,
                      style: MarkdownStyle,
                      budget: CGFloat) -> NSAttributedString {
        let m = NSMutableAttributedString()
        if cells.cols > 0 {
            let atomicId = id
            let widths = tableWidths(cells, budget: budget)
            let pad = cellPadding(style)
            var stops: [NSTextTab] = []
            var x: CGFloat = 0
            for (col, w) in widths.enumerated() {
                x += w + pad * 2
                stops.append(NSTextTab(
                    textAlignment: tabAlignment(cells.alignment(col + 1)),
                    location: x))
            }
            if !cells.header.isEmpty {
                m.append(tableRowTabStops(cells: cells.header, stops: stops,
                                          style: style, bold: true,
                                          tint: platformWhite(0.5, alpha: 0.14),
                                          atomicId: atomicId))
            }
            for (idx, row) in cells.body.enumerated() {
                let tint: PlatformColor = idx % 2 == 1
                    ? platformWhite(0.5, alpha: 0.07) : platformClearColor
                m.append(tableRowTabStops(cells: row, stops: stops,
                                          style: style, bold: false,
                                          tint: tint,
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
                               headers: cells.headers, rows: cells.rows,
                               alignments: cells.alignments),
                           range: content)
            m.append(NSAttributedString(string: "\n"))
        }
        return m
    }

    // A tab stop aligns the text that follows it, so the first column
    // has none and the stop after column c carries column c + 1's.

    private static func tabAlignment(_ a: Alignment) -> NSTextAlignment {
        let result: NSTextAlignment
        switch a {
            case .center: result = .center
            case .right: result = .right
            case .left, .none: result = .left
        }
        return result
    }

    private static func tableRowTabStops(cells: [TableCell],
                                         stops: [NSTextTab],
                                         style: MarkdownStyle,
                                         bold: Bool,
                                         tint: PlatformColor,
                                         atomicId: String)
        -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.tabStops = stops
        para.lineBreakMode = .byTruncatingTail
        let body = style.bodyFont
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

// A display scales to the line it is offered, since it has no break to
// give and TextKit would clip it; an inline formula wraps like a word
// instead. The image is drawn into whatever bounds are answered here.

final class MathAttachment: NSTextAttachment {

    private let descent: CGFloat
    private let scalesToLine: Bool

    init(descent: CGFloat, scalesToLine: Bool) {
        self.descent = descent
        self.scalesToLine = scalesToLine
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("MathAttachment is not decodable")
    }

    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex: Int) -> CGRect {
        var result = bounds
        if scalesToLine {
            let fitted = DocumentText.mathFit(
                natural: bounds.size,
                available: DocumentText.mathRoom(in: lineFrag.width))
            let scale = bounds.width > 0 ? fitted.width / bounds.width : 1
            result = CGRect(x: 0, y: -descent * scale,
                            width: fitted.width, height: fitted.height)
        }
        return result
    }

}

// TextKit 1 asks for the image on every draw when none is stored, so
// the last one is kept by the width and appearance it was drawn for.

final class RuleAttachment: NSTextAttachment {

    private let height: CGFloat
    private var cachedWidth: CGFloat = 0
    private var cachedStyle: UIUserInterfaceStyle = .unspecified
    private var cached: UIImage? = nil

    init(height: CGFloat) {
        self.height = height
        super.init(data: nil, ofType: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("RuleAttachment is not decodable")
    }

    override func attachmentBounds(for textContainer: NSTextContainer?,
                                   proposedLineFragment lineFrag: CGRect,
                                   glyphPosition position: CGPoint,
                                   characterIndex: Int) -> CGRect {
        CGRect(x: 0, y: 0, width: max(lineFrag.width - position.x, 1),
               height: height)
    }

    override func image(forBounds imageBounds: CGRect,
                        textContainer: NSTextContainer?,
                        characterIndex: Int) -> UIImage? {
        let appearance = UITraitCollection.current.userInterfaceStyle
        if cached == nil || cachedWidth != imageBounds.width ||
           cachedStyle != appearance {
            let renderer = UIGraphicsImageRenderer(size: imageBounds.size)
            cached = renderer.image { ctx in
                UIColor.separator.setFill()
                ctx.fill(CGRect(x: 0, y: imageBounds.height / 2 - 0.5,
                                width: imageBounds.width, height: 1))
            }
            cachedWidth = imageBounds.width
            cachedStyle = appearance
        }
        return cached
    }

}
