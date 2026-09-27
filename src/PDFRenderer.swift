import Foundation
import CoreText
import CoreGraphics

final class PDFRenderer {

    let ctx: CGContext
    let pageSize: CGSize
    let title: String
    let images: [URL: CGImage]
    let margin: CGFloat = 54
    let headerH: CGFloat = 28
    let footerH: CGFloat = 28
    let blockGap: CGFloat = 10
    let bodySize: CGFloat = 11
    let monoSize: CGFloat = 10
    let rowPad: CGFloat = 4
    var pageNumber = 0
    var y: CGFloat = 0
    var listIndent: CGFloat = 0
    // 1 everywhere but inside a table too wide for the page, and only
    // for the span of that one table.
    var tableScale: CGFloat = 1
    private var quoteBars: [QuoteBar] = []
    private var pendingMarkers: [PendingMarker] = []

    private struct QuoteBar {
        let x: CGFloat
        let top: CGFloat
    }

    private struct PendingMarker {
        let glyph: String
        let x: CGFloat
    }

    init(ctx: CGContext,
         pageSize: CGSize,
         title: String,
         images: [URL: CGImage] = [:]) {
        self.ctx = ctx
        self.pageSize = pageSize
        self.title = title
        self.images = images
    }

    var contentLeft: CGFloat { margin + listIndent }
    var contentRight: CGFloat { pageSize.width - margin }
    var contentWidth: CGFloat { contentRight - contentLeft }
    var contentTop: CGFloat { pageSize.height - margin - headerH }
    var contentBottom: CGFloat { margin + footerH }
    var remaining: CGFloat { y - contentBottom }

    func startPage() {
        ctx.beginPDFPage(nil)
        pageNumber += 1
        y = contentTop
        drawHeader()
        drawFooter()
    }

    func endPage() { ctx.endPDFPage() }

    func newPage() {
        for bar in quoteBars { fillBar(bar) }
        endPage()
        startPage()
        quoteBars = quoteBars.map { bar in QuoteBar(x: bar.x, top: y) }
    }

    private func fillBar(_ bar: QuoteBar) {
        let bottom = max(y, contentBottom)
        if bar.top > bottom {
            ctx.setFillColor(secondaryColor)
            ctx.fill(CGRect(x: bar.x, y: bottom, width: 2,
                            height: bar.top - bottom))
        }
    }

    private func placeMarkers(baseline: CGFloat) {
        for marker in pendingMarkers {
            let attr = NSAttributedString(string: marker.glyph, attributes: [
                .font: bodyFont(),
                .foregroundColor: textColor,
            ])
            ctx.textPosition = CGPoint(x: marker.x, y: baseline)
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        pendingMarkers = []
    }

    private func placeMarkers(top: CGFloat) {
        placeMarkers(baseline: top - bodySize)
    }

    func ensureSpace(_ minHeight: CGFloat) {
        if remaining < minHeight { newPage() }
    }

    func draw(_ block: Block) {
        switch block {
            case .heading(let level, let text):
                drawHeading(level: level, text: text)
            case .paragraph(let attr):
                drawText(attr, font: bodyFont())
            case .code(let language, let text):
                drawCode(text, language: language)
            case .quote(let blocks): drawQuote(blocks)
            case .list(let items, let tight):
                drawList(items, tight: tight)
            case .table(let headers, let rows, let alignments):
                drawTable(headers: headers, rows: rows,
                          alignments: alignments)
            case .math(let tex): drawMath(tex)
            case .rule: drawRule()
            case .image(let alt, let url, let width, let height):
                if let cg = images[url] {
                    drawImage(cg, alt: alt, explicitWidth: width,
                              explicitHeight: height)
                } else {
                    drawImagePlaceholder(alt: alt, url: url)
                }
        }
        y -= blockGap
    }

    private func drawImage(_ cg: CGImage, alt: String,
                           explicitWidth: CGFloat?,
                           explicitHeight: CGFloat?) {
        let imgW = CGFloat(cg.width)
        let imgH = CGFloat(cg.height)
        if imgW > 0, imgH > 0 {
            let maxH = pageSize.height - margin * 2 -
                       headerH - footerH - bodySize * 2
            let size = imageDrawSize(cg, maxWidth: contentWidth,
                                     maxHeight: maxH,
                                     explicitWidth: explicitWidth,
                                     explicitHeight: explicitHeight)
            let drawW = size.width
            let drawH = size.height
            ensureSpace(drawH + bodySize * 1.6)
            placeMarkers(top: y)
            let originX = contentLeft + (contentWidth - drawW) / 2
            let originY = y - drawH
            ctx.draw(cg, in: CGRect(x: originX, y: originY,
                                    width: drawW, height: drawH))
            y -= drawH
            if !alt.isEmpty {
                let cap = NSAttributedString(string: alt, attributes: [
                    .font: bodyFontItalic(),
                    .foregroundColor: secondaryColor,
                ])
                let line = CTLineCreateWithAttributedString(cap)
                let bounds = CTLineGetBoundsWithOptions(line, [])
                let cx = contentLeft + (contentWidth - bounds.width) / 2
                ctx.textPosition = CGPoint(x: cx, y: y - bodySize - 4)
                CTLineDraw(line, ctx)
                y -= bodySize * 1.6
            }
        }
    }

    private func drawHeading(level: Int, text: AttributedString) {
        let sizes: [Int: CGFloat] = [
            1: 22, 2: 18, 3: 16, 4: 14, 5: 12, 6: 11,
        ]
        let size = sizes[level] ?? 11
        let font = CTFontCreateUIFontForLanguage(.system, size, nil) ??
                   CTFontCreateWithName("Helvetica-Bold" as CFString,
                                        size, nil)
        let bold = CTFontCreateCopyWithSymbolicTraits(
            font, size, nil, .traitBold, .traitBold) ?? font
        ensureSpace(size * 1.4 + bodySize * 3)
        drawText(text, font: bold)
    }

    private func drawText(_ attr: AttributedString, font: CTFont) {
        let m = styled(attr, base: font, bold: false, para: nil,
                       numerics: false)
        applyParagraphAlignment(m, from: attr)
        flow(m)
    }

    private final class InlineMathBox {
        let layout: MathLayout
        init(_ layout: MathLayout) { self.layout = layout }
    }

    private static let runDelegateKey =
        NSAttributedString.Key(kCTRunDelegateAttributeName as String)

    private static let inlineMathInset: CGFloat = 1

    private func inlineFormula(_ source: String, size: CGFloat,
                               attrs: [NSAttributedString.Key: Any])
        -> NSAttributedString? {
        var result: NSAttributedString? = nil
        if let layout = TeX.layout(TeX.undelimited(source), size: size,
                                   display: false),
           let delegate = PDFRenderer.runDelegate(InlineMathBox(layout)) {
            var placed = attrs
            placed[PDFRenderer.runDelegateKey] = delegate
            result = NSAttributedString(string: "\u{FFFC}",
                                        attributes: placed)
        }
        return result
    }

    // The retained box is released by CoreText via the dealloc callback;
    // the draw pass reads the same box back off the delegate.

    private static func runDelegate(_ box: InlineMathBox) -> CTRunDelegate? {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateCurrentVersion,
            dealloc: { refcon in
                Unmanaged<InlineMathBox>.fromOpaque(refcon).release()
            },
            getAscent: { refcon in
                Unmanaged<InlineMathBox>.fromOpaque(refcon)
                    .takeUnretainedValue().layout.ascent
            },
            getDescent: { refcon in
                Unmanaged<InlineMathBox>.fromOpaque(refcon)
                    .takeUnretainedValue().layout.descent
            },
            getWidth: { refcon in
                Unmanaged<InlineMathBox>.fromOpaque(refcon)
                    .takeUnretainedValue().layout.width +
                    PDFRenderer.inlineMathInset * 2
            })
        return CTRunDelegateCreate(&callbacks,
                                   Unmanaged.passRetained(box).toOpaque())
    }

    private func drawInlineMath(in frame: CTFrame, rect: CGRect) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0),
                              &origins)
        for (line, origin) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let value = attrs[PDFRenderer.runDelegateKey]
                if let value, CFGetTypeID(value as CFTypeRef) ==
                    CTRunDelegateGetTypeID() {
                    let delegate = value as! CTRunDelegate
                    let box = Unmanaged<InlineMathBox>
                        .fromOpaque(CTRunDelegateGetRefCon(delegate))
                        .takeUnretainedValue()
                    var position = CGPoint.zero
                    CTRunGetPositions(run, CFRange(location: 0, length: 1),
                                      &position)
                    let x = rect.minX + origin.x + position.x +
                            PDFRenderer.inlineMathInset
                    let baseline = CGPoint(x: x, y: rect.minY + origin.y)
                    box.layout.draw(in: ctx, baseline: baseline,
                                    color: textColor)
                }
            }
        }
    }

    private func flow(_ attr: NSAttributedString) {
        if attr.length > 0 {
            let fs = CTFramesetterCreateWithAttributedString(attr)
            var consumed = 0
            while consumed < attr.length {
                ensureSpace(20)
                let avail = remaining
                let fresh = y >= contentTop
                let line = fresh ? firstLine(fs, attr, from: consumed) : 0
                let rem = CFRange(location: consumed,
                                  length: attr.length - consumed)
                var rect = CGRect(x: contentLeft, y: contentBottom,
                                  width: contentWidth, height: avail)
                var frame = CTFramesetterCreateFrame(
                    fs, rem, CGPath(rect: rect, transform: nil), nil)
                var visible = CTFrameGetVisibleStringRange(frame)
                if visible.length == 0, line > 0 {
                    let tall: CGFloat = 1_000_000
                    rect = CGRect(x: contentLeft, y: y - tall,
                                  width: contentWidth, height: tall)
                    frame = CTFramesetterCreateFrame(
                        fs, CFRange(location: consumed, length: line),
                        CGPath(rect: rect, transform: nil), nil)
                    visible = CTFrameGetVisibleStringRange(frame)
                }
                if visible.length == 0 {
                    newPage()
                } else {
                    let used = lineHeightUsed(frame: frame, in: rect)
                    placeMarkers(baseline: rect.minY +
                                           firstBaseline(frame))
                    CTFrameDraw(frame, ctx)
                    drawInlineMath(in: frame, rect: rect)
                    annotateLinks(in: frame, rect: rect)
                    y -= used
                    consumed = visible.location + visible.length
                    if consumed < attr.length { newPage() }
                }
            }
        }
    }

    private func firstBaseline(_ frame: CTFrame) -> CGFloat {
        var origin = CGPoint.zero
        if CFArrayGetCount(CTFrameGetLines(frame)) > 0 {
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 1),
                                  &origin)
        }
        return origin.y
    }

    private func firstLine(_ fs: CTFramesetter, _ attr: NSAttributedString,
                           from start: Int) -> Int {
        let typesetter = CTFramesetterGetTypesetter(fs)
        let count = CTTypesetterSuggestLineBreak(typesetter, start,
                                                 Double(contentWidth))
        return min(max(count, 1), attr.length - start)
    }

    private func lineHeightUsed(frame: CTFrame, in rect: CGRect) -> CGFloat {
        var result: CGFloat = 0
        let lines = CTFrameGetLines(frame) as! [CTLine]
        if !lines.isEmpty {
            var origins = [CGPoint](repeating: .zero,
                                    count: lines.count)
            CTFrameGetLineOrigins(frame,
                                  CFRange(location: 0, length: 0),
                                  &origins)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            _ = CTLineGetTypographicBounds(lines[0],
                                           &ascent, &descent, &leading)
            let topPadding = rect.height - origins[0].y - ascent
            let lastIdx = lines.count - 1
            _ = CTLineGetTypographicBounds(lines[lastIdx],
                                           &ascent, &descent, &leading)
            let lastBaselineFromRectBottom = origins[lastIdx].y
            let used = rect.height - lastBaselineFromRectBottom +
                       descent - topPadding
            result = max(used, 0)
        }
        return result
    }

    private func drawCode(_ text: String, language: String?) {
        let ns = Highlight.attribute(text, language: language,
                                     baseFont: monoFontPlatform())
        let m = NSMutableAttributedString(attributedString: ns)
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(.font, value: monoCTFont(), range: full)
        m.enumerateAttribute(.foregroundColor, in: full,
                             options: []) { value, range, _ in
            if let c = value as? PlatformColor {
                m.addAttribute(.foregroundColor, value: c.cgColor,
                               range: range)
            }
        }
        let fs = CTFramesetterCreateWithAttributedString(m)
        var consumed = 0
        while consumed < m.length {
            ensureSpace(20)
            let avail = remaining
            let rem = CFRange(location: consumed,
                              length: m.length - consumed)
            let inset: CGFloat = 6
            let textRect = CGRect(x: contentLeft + inset,
                                  y: contentBottom + inset,
                                  width: contentWidth - 2 * inset,
                                  height: avail - 2 * inset)
            let path = CGPath(rect: textRect, transform: nil)
            let frame = CTFramesetterCreateFrame(fs, rem, path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            if visible.length == 0 {
                newPage()
            } else {
                let used = lineHeightUsed(frame: frame, in: textRect)
                let bgRect = CGRect(x: contentLeft,
                                    y: y - used - 2 * inset,
                                    width: contentWidth,
                                    height: used + 2 * inset)
                ctx.setFillColor(codeBgColor)
                ctx.fill(bgRect)
                placeMarkers(top: y - inset)
                CTFrameDraw(frame, ctx)
                y -= used + 2 * inset
                consumed = visible.location + visible.length
                if consumed < m.length { newPage() }
            }
        }
    }

    private func drawQuote(_ blocks: [Block]) {
        let saved = listIndent
        quoteBars.append(QuoteBar(x: margin + saved, top: y))
        listIndent = saved + 16
        for b in blocks { draw(b) }
        listIndent = saved
        if let bar = quoteBars.popLast() { fillBar(bar) }
    }

    private func drawList(_ items: [ListItem], tight: Bool) {
        let saved = listIndent
        let widest = items.map { item in
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(
                NSAttributedString(string: item.marker,
                                   attributes: [.font: bodyFont()])),
                nil, nil, nil)
        }.max() ?? 0
        let gutter = max(20, ceil(CGFloat(widest)) + 6)
        for item in items {
            ensureSpace(bodySize * 2)
            let glyph = item.checked == nil ? item.marker
                : (item.checked == true ? "☑︎" : "☐")
            pendingMarkers.append(PendingMarker(glyph: glyph,
                                                x: margin + saved))
            listIndent = saved + gutter
            for b in item.blocks { draw(b) }
            if tight, !item.blocks.isEmpty { y += blockGap * 0.6 }
            if !pendingMarkers.isEmpty {
                placeMarkers(top: y)
                y -= bodySize * 1.4
            }
            listIndent = saved
        }
    }

    private func drawTable(headers: [String], rows: [[String]],
                           alignments: [Alignment]) {
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        if cols > 0 {
            let saved = tableScale
            tableScale = fittingScale(headers: headers, rows: rows,
                                      cols: cols)
            drawTableImpl(headers: headers, rows: rows, cols: cols,
                          alignments: alignments)
            tableScale = saved
        }
    }

    private func fittingScale(headers: [String], rows: [[String]],
                              cols: Int) -> CGFloat {
        let saved = tableScale
        var scale: CGFloat = 1
        var passes = 0
        var settling = true
        while settling {
            tableScale = scale
            let demand = columnFloors(headers: headers, rows: rows,
                                      cols: cols).reduce(0, +)
            passes += 1
            if demand > contentWidth, contentWidth > 0,
               scale > 0.75, passes < 6 {
                scale = max(scale * contentWidth / demand, 0.75)
            } else {
                settling = false
            }
        }
        tableScale = saved
        return scale
    }

    private func columnFloors(headers: [String], rows: [[String]],
                              cols: Int) -> [CGFloat] {
        let pad = cellPadding()
        var floors: [CGFloat] = []
        for c in 0..<cols {
            var widest: CGFloat = 0
            if c < headers.count {
                let w = longestTokenWidth(headers[c], bold: true)
                if w > widest { widest = w }
            }
            for row in rows where c < row.count {
                let w = longestTokenWidth(row[c], bold: false)
                if w > widest { widest = w }
            }
            // CTLine's reported width and the framesetter's wrap decision
            // disagree by a fraction; the extra point covers it.
            floors.append(widest + 2 * pad + 1)
        }
        return floors
    }

    private func columnNaturals(headers: [String], rows: [[String]],
                                cols: Int) -> [CGFloat] {
        let pad = cellPadding()
        var naturals: [CGFloat] = []
        for c in 0..<cols {
            var widest: CGFloat = 0
            if c < headers.count, ImagePrefetch.imageInCell(headers[c]) == nil {
                let w = cellRenderedWidth(headers[c], bold: true)
                if w > widest { widest = w }
            }
            for row in rows where c < row.count &&
                                  ImagePrefetch.imageInCell(row[c]) == nil {
                let w = cellRenderedWidth(row[c], bold: false)
                if w > widest { widest = w }
            }
            naturals.append(widest + 2 * pad + 1)
        }
        return naturals
    }

    // An image cell has no token to measure; its source collapses to ""
    // so the URL is never charged as one huge unbreakable run.

    private func longestTokenWidth(_ text: String, bold: Bool) -> CGFloat {
        var widest: CGFloat = 0
        let source = ImagePrefetch.imageInCell(text) == nil ? text : ""
        let ns = source as NSString
        for run in TableMetrics.unbreakableRuns(ns) {
            let w = cellRenderedWidth(ns.substring(with: run), bold: bold)
            if w > widest { widest = w }
        }
        return widest
    }

    private func drawTableImpl(headers: [String], rows: [[String]],
                               cols: Int, alignments: [Alignment]) {
        let cellPad = cellPadding()
        let minWidths = columnFloors(headers: headers, rows: rows,
                                     cols: cols)
        var colWidths = TableMetrics.columnLayout(
            headers: headers, rows: rows,
            naturals: columnNaturals(headers: headers, rows: rows,
                                     cols: cols),
            minimums: minWidths, available: contentWidth)
        let allRows: [[String]] = headers.isEmpty ? rows : [headers] + rows
        for r in allRows {
            for c in 0..<cols where c < r.count {
                if let info = ImagePrefetch.imageInCell(r[c]),
                   let cg = images[info.0] {
                    let imgW = CGFloat(cg.width)
                    let imgH = CGFloat(cg.height)
                    let aspect = imgH > 0 ? imgW / imgH : 1
                    var w: CGFloat = 0
                    if let ew = info.1 { w = ew }
                    else if let eh = info.2 { w = eh * aspect }
                    else { w = min(contentWidth / CGFloat(cols), imgW * 0.5) }
                    if w > colWidths[c] { colWidths[c] = w }
                }
            }
        }
        let total = colWidths.reduce(0, +)
        if total > contentWidth, total > 0 {
            let scale = contentWidth / total
            colWidths = colWidths.map { v in v * scale }
        }
        let table = TableFrame(widths: colWidths,
                               right: contentLeft + colWidths.reduce(0, +),
                               pad: cellPad)
        let build = { (cells: [String], bold: Bool) in
            (0..<cols).map { c in
                self.cellContent(c < cells.count ? cells[c] : "",
                                 bold: bold,
                                 alignment: c < alignments.count
                                     ? alignments[c] : .none)
            }
        }
        if !headers.isEmpty {
            drawRow(build(headers, true), shade: headerShadeColor,
                    table: table)
        }
        for (idx, row) in rows.enumerated() {
            drawRow(build(row, false),
                    shade: idx % 2 == 1 ? rowShadeColor : nil, table: table)
        }
    }

    private struct TableFrame {
        let widths: [CGFloat]
        let right: CGFloat
        let pad: CGFloat
    }

    private struct CellSlice {
        let frame: CTFrame?
        let rect: CGRect
        let used: CGFloat
        let taken: Int
    }

    private var tallestCell: CGFloat {
        contentTop - contentBottom - 2 * rowPad
    }

    private func rowHeight(_ built: [CellContent],
                           _ table: TableFrame) -> CGFloat {
        var rowH: CGFloat = scaledBodySize * 1.3
        for (c, cell) in built.enumerated() {
            let cellW = table.widths[c] - 2 * table.pad
            var h: CGFloat = 0
            switch cell {
                case .picture(let cg, let ew, let eh):
                    h = imageDrawSize(cg, maxWidth: cellW,
                                      maxHeight: tallestCell,
                                      explicitWidth: ew,
                                      explicitHeight: eh).height
                case .text(let inner):
                    h = textCellHeight(inner, width: cellW)
            }
            if h > rowH { rowH = h }
        }
        return rowH
    }

    private func drawRow(_ built: [CellContent], shade: CGColor?,
                         table: TableFrame) {
        let rowH = rowHeight(built, table)
        if rowH + rowPad * 2 > remaining, y < contentTop { newPage() }
        var consumed = [Int](repeating: 0, count: built.count)
        var first = true
        var pending = true
        while pending {
            let top = y
            placeMarkers(top: top - rowPad)
            var slices: [CellSlice] = []
            var x = contentLeft
            for (c, cell) in built.enumerated() {
                let cellW = table.widths[c] - 2 * table.pad
                slices.append(slice(cell, from: consumed[c], first: first,
                                    x: x + table.pad, top: top,
                                    width: cellW))
                x += table.widths[c]
            }
            let maxUsed = slices.map { one in one.used }.max() ?? 0
            if let shade {
                ctx.setFillColor(shade)
                ctx.fill(CGRect(x: contentLeft, y: top - maxUsed - rowPad,
                                width: table.right - contentLeft,
                                height: maxUsed + 2 * rowPad))
            }
            x = contentLeft
            for (c, cell) in built.enumerated() {
                drawSlice(cell, slices[c], first: first, x: x + table.pad,
                          top: top, width: table.widths[c] - 2 * table.pad)
                consumed[c] += slices[c].taken
                x += table.widths[c]
            }
            y = top - maxUsed - rowPad
            drawRowRules(top: top, table: table)
            y -= rowPad
            let progressed = slices.contains { one in one.taken > 0 }
            pending = progressed && built.enumerated().contains { c, cell in
                if case .text(let inner) = cell {
                    consumed[c] < inner.length
                } else {
                    false
                }
            }
            if pending { newPage() }
            first = false
        }
    }

    private func slice(_ cell: CellContent, from start: Int, first: Bool,
                       x: CGFloat, top: CGFloat, width: CGFloat)
        -> CellSlice {
        var result = CellSlice(frame: nil, rect: .zero, used: 0, taken: 0)
        switch cell {
            case .picture(let cg, let ew, let eh):
                let h = imageDrawSize(cg, maxWidth: width,
                                      maxHeight: tallestCell,
                                      explicitWidth: ew,
                                      explicitHeight: eh).height
                result = CellSlice(frame: nil, rect: .zero,
                                   used: first ? h : 0, taken: 0)
            case .text(let inner):
                if start < inner.length {
                    let fs = CTFramesetterCreateWithAttributedString(inner)
                    let rect = CGRect(x: x, y: contentBottom, width: width,
                                      height: top - contentBottom)
                    let frame = CTFramesetterCreateFrame(
                        fs, CFRange(location: start, length: 0),
                        CGPath(rect: rect, transform: nil), nil)
                    result = CellSlice(
                        frame: frame, rect: rect,
                        used: lineHeightUsed(frame: frame, in: rect),
                        taken: CTFrameGetVisibleStringRange(frame).length)
                }
        }
        return result
    }

    private func drawSlice(_ cell: CellContent, _ slice: CellSlice,
                           first: Bool, x: CGFloat, top: CGFloat,
                           width: CGFloat) {
        switch cell {
            case .picture(let cg, let ew, let eh):
                if first {
                    _ = drawCellImage(cg, x: x, topY: top, maxWidth: width,
                                      explicitWidth: ew,
                                      explicitHeight: eh)
                }
            case .text:
                if let frame = slice.frame {
                    CTFrameDraw(frame, ctx)
                    drawInlineMath(in: frame, rect: slice.rect)
                    annotateLinks(in: frame, rect: slice.rect)
                }
        }
    }

    private func drawRowRules(top: CGFloat, table: TableFrame) {
        ctx.setStrokeColor(secondaryColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: contentLeft, y: y))
        ctx.addLine(to: CGPoint(x: table.right, y: y))
        ctx.strokePath()
        let bandTop = min(top + rowPad, contentTop)
        ctx.setLineWidth(0.25)
        var divider = contentLeft
        for c in 0..<max(table.widths.count - 1, 0) {
            divider += table.widths[c]
            ctx.move(to: CGPoint(x: divider, y: bandTop))
            ctx.addLine(to: CGPoint(x: divider, y: y))
        }
        ctx.strokePath()
    }

    private enum CellContent {
        case text(NSAttributedString)
        case picture(CGImage, CGFloat?, CGFloat?)
    }

    private func cellContent(_ txt: String, bold: Bool,
                             alignment: Alignment) -> CellContent {
        var result: CellContent
        if let info = ImagePrefetch.imageInCell(txt),
           let cg = images[info.0] {
            result = .picture(cg, info.1, info.2)
        } else {
            result = .text(cellAttributed(txt, bold: bold,
                                          alignment: alignment))
        }
        return result
    }

    private func imageDrawSize(_ cg: CGImage, maxWidth: CGFloat,
                               maxHeight: CGFloat,
                               explicitWidth: CGFloat?,
                               explicitHeight: CGFloat?) -> CGSize {
        let fit = aspectFit(intrinsicWidth: CGFloat(cg.width),
                            intrinsicHeight: CGFloat(cg.height),
                            explicitWidth: explicitWidth,
                            explicitHeight: explicitHeight,
                            defaultScale: 0.5, maxWidth: maxWidth)
        let shrink = fit.height > maxHeight ? maxHeight / fit.height : 1
        return CGSize(width: fit.width * shrink,
                      height: fit.height * shrink)
    }

    private static let numericTokenRE: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"\d[\d.,]*\d"#)

    // Wraps '.' and ',' between digits with U+2060 so CoreText cannot
    // split a number like "1,234.56" across a narrow column.

    private func protectNumerics(_ s: String) -> String {
        var result = s
        if let re = Self.numericTokenRE {
            let ns = s as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = re.matches(in: s, range: full)
            if !matches.isEmpty {
                let m = NSMutableString(string: s)
                for match in matches.reversed() {
                    let token = ns.substring(with: match.range)
                    let joined = token
                        .replacingOccurrences(
                            of: ".", with: "\u{2060}.\u{2060}")
                        .replacingOccurrences(
                            of: ",", with: "\u{2060},\u{2060}")
                    m.replaceCharacters(in: match.range, with: joined)
                }
                result = m as String
            }
        }
        return result
    }

    private func cellAttributed(_ text: String, bold: Bool,
                                alignment: Alignment)
        -> NSAttributedString {
        let parsed = Markdown.parseCell(text)
        var attr = AttributedString(text)
        if let first = parsed.first, case .paragraph(let a) = first {
            attr = a
        }
        let para = NSMutableParagraphStyle()
        switch alignment {
            case .center: para.alignment = .center
            case .right: para.alignment = .right
            case .left, .none: para.alignment = .natural
        }
        return styled(attr, base: bold ? bodyFontBold() : bodyFont(),
                      bold: bold, para: para, numerics: true)
    }

    func styled(_ attr: AttributedString, base: CTFont, bold: Bool,
                para: NSParagraphStyle?, numerics: Bool)
        -> NSMutableAttributedString {
        let baseSize = CTFontGetSize(base)
        let m = NSMutableAttributedString()
        for run in attr.runs {
            let intent = run.inlinePresentationIntent ?? []
            var runFont = styledRunFont(intent: intent, base: base,
                                        size: baseSize,
                                        additionalBold: bold)
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: textColor,
            ]
            if let para { attrs[.paragraphStyle] = para }
            if run[SmallAttribute.self] == true {
                runFont = smallRunFont(base: runFont)
            }
            if let level = run[ScriptAttribute.self] {
                let script = scriptRunFont(level, base: runFont)
                runFont = script.font
                attrs[.baselineOffset] = script.offset
            }
            attrs[.font] = runFont
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] =
                    NSUnderlineStyle.single.rawValue
                attrs[.strikethroughColor] = textColor
            }
            if run.underlineStyle != nil {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link, HtmlExport.safeLink(url) {
                attrs[.link] = url
                attrs[.foregroundColor] = linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            let formula = run[InlineMathAttribute.self].flatMap { source in
                inlineFormula(source, size: runFont.pointSize, attrs: attrs)
            }
            if let formula {
                m.append(formula)
            } else {
                let text = String(attr[run.range].characters)
                m.append(NSAttributedString(
                    string: numerics ? protectNumerics(text) : text,
                    attributes: attrs))
            }
        }
        return m
    }

    private func annotateLinks(in frame: CTFrame, rect: CGRect) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0),
                              &origins)
        for (line, origin) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attrs = CTRunGetAttributes(run) as NSDictionary
                if let url = attrs[NSAttributedString.Key.link] as? URL {
                    var ascent: CGFloat = 0
                    var descent: CGFloat = 0
                    let width = CTRunGetTypographicBounds(
                        run, CFRange(location: 0, length: 0),
                        &ascent, &descent, nil)
                    var position = CGPoint.zero
                    CTRunGetPositions(run, CFRange(location: 0, length: 1),
                                      &position)
                    ctx.setURL(url as CFURL, for: CGRect(
                        x: rect.minX + origin.x + position.x,
                        y: rect.minY + origin.y - descent,
                        width: CGFloat(width), height: ascent + descent))
                }
            }
        }
    }

    private func cellRenderedWidth(_ text: String, bold: Bool) -> CGFloat {
        let attr = cellAttributed(text, bold: bold, alignment: .none)
        let line = CTLineCreateWithAttributedString(attr)
        return CTLineGetBoundsWithOptions(line, []).width
    }

    // A proportional font has no single advance to report; the lowercase
    // alphabet approximates the width a reader actually meets.

    private func averageCharWidth(_ font: CTFont) -> CGFloat {
        let sample = "abcdefghijklmnopqrstuvwxyz"
        let attr = NSAttributedString(string: sample,
                                      attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        let width = CTLineGetBoundsWithOptions(line, []).width
        return width / CGFloat(sample.count)
    }

    private func textCellHeight(_ inner: NSAttributedString,
                                width: CGFloat) -> CGFloat {
        let fs = CTFramesetterCreateWithAttributedString(inner)
        let rect = CGRect(x: 0, y: 0, width: width, height: pageSize.height)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            fs, CFRange(location: 0, length: 0), path, nil)
        return lineHeightUsed(frame: frame, in: rect)
    }

    private func drawCellImage(_ cg: CGImage,
                                  x: CGFloat,
                               topY: CGFloat,
                           maxWidth: CGFloat,
                      explicitWidth: CGFloat?,
                     explicitHeight: CGFloat?) -> CGFloat {
        let size = imageDrawSize(cg, maxWidth: maxWidth,
                                 maxHeight: tallestCell,
                                 explicitWidth: explicitWidth,
                                 explicitHeight: explicitHeight)
        if size.height > 0 {
            ctx.draw(cg, in: CGRect(x: x, y: topY - size.height,
                                    width: size.width,
                                    height: size.height))
        }
        return size.height
    }

    // Drawn straight into the page context, so the formula stays vector
    // in the PDF rather than a rasterized picture.

    private func drawMath(_ tex: String) {
        let layout = fittedMath(tex)
        if let layout {
            ensureSpace(layout.height + bodySize)
            placeMarkers(top: y)
            let slack = contentWidth - layout.width
            let x = contentLeft + max(slack / 2, 0)
            layout.draw(in: ctx, at: CGPoint(x: x, y: y), color: textColor)
            y -= layout.height
        } else {
            drawText(TeX.render(tex, display: true), font: bodyFontItalic())
        }
    }

    private func fittedMath(_ tex: String) -> MathLayout? {
        let wanted = TeX.displaySize(body: bodySize)
        var result = TeX.layout(tex, size: wanted)
        let tallest = contentTop - contentBottom - bodySize
        if let first = result, first.width > 0, first.height > 0,
           first.width > contentWidth || first.height > tallest {
            let wide = first.width > contentWidth
                ? max(contentWidth / first.width, 0.5) : 1
            let tall = min(tallest / first.height, 1)
            let fitted = wanted * min(wide, tall)
            let step: CGFloat = 0.25
            result = TeX.layout(tex, size: max((fitted / step)
                                                   .rounded(.down) * step,
                                               step))
        }
        return result
    }

    private func drawRule() {
        ensureSpace(8)
        placeMarkers(top: y)
        ctx.setStrokeColor(secondaryColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: contentLeft, y: y - 4))
        ctx.addLine(to: CGPoint(x: contentRight, y: y - 4))
        ctx.strokePath()
        y -= 8
    }

    private func drawImagePlaceholder(alt: String, url: URL) {
        let label = alt.isEmpty ? url.absoluteString : alt
        let attr = NSAttributedString(string: "🖼  \(label)", attributes: [
            .font: bodyFontItalic(),
            .foregroundColor: secondaryColor,
        ])
        ensureSpace(bodySize * 2)
        placeMarkers(top: y)
        let inset: CGFloat = 8
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let h = bounds.height + 2 * inset
        ctx.setFillColor(codeBgColor)
        ctx.fill(CGRect(x: contentLeft, y: y - h,
                        width: contentWidth, height: h))
        let baselineY = y - inset - bounds.size.height - bounds.minY
        ctx.textPosition = CGPoint(x: contentLeft + inset, y: baselineY)
        CTLineDraw(line, ctx)
        y -= h
    }

    private func drawHeader() {
        let attr = NSAttributedString(string: title, attributes: [
            .font: smallFont(),
            .foregroundColor: secondaryColor,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        ctx.textPosition = CGPoint(x: margin,
                                   y: pageSize.height - margin - 14)
        CTLineDraw(line, ctx)
        ctx.setStrokeColor(secondaryColor)
        ctx.setLineWidth(0.3)
        let lineY = pageSize.height - margin - 18
        ctx.move(to: CGPoint(x: margin, y: lineY))
        ctx.addLine(to: CGPoint(x: pageSize.width - margin, y: lineY))
        ctx.strokePath()
    }

    private func drawFooter() {
        let attr = NSAttributedString(string: "\(pageNumber)", attributes: [
            .font: smallFont(),
            .foregroundColor: secondaryColor,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let x = (pageSize.width - bounds.width) / 2
        ctx.textPosition = CGPoint(x: x, y: margin + 6)
        CTLineDraw(line, ctx)
        drawCredit()
    }

    static let home = URL(string: "https://leok7v.github.io/md.too/")

    private func drawCredit() {
        let credit = NSMutableAttributedString(string: "Made with ",
                                               attributes: [
            .font: smallFont(),
            .foregroundColor: secondaryColor,
        ])
        credit.append(NSAttributedString(string: "md.too", attributes: [
            .font: CTFontCreateCopyWithSymbolicTraits(
                smallFont(), 9, nil, .traitBold, .traitBold) ?? smallFont(),
            .foregroundColor: linkColor,
        ]))
        let line = CTLineCreateWithAttributedString(credit)
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let x = pageSize.width - margin - bounds.width
        ctx.textPosition = CGPoint(x: x, y: margin + 6)
        CTLineDraw(line, ctx)
        if let home = PDFRenderer.home {
            ctx.setURL(home as CFURL, for: CGRect(
                x: x, y: margin + 6 + bounds.minY - 2,
                width: bounds.width, height: bounds.height + 4))
        }
    }

    private var scaledBodySize: CGFloat { bodySize * tableScale }

    private func bodyFont() -> CTFont {
        let size = scaledBodySize
        return CTFontCreateUIFontForLanguage(.system, size, nil) ??
               CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    private func bodyFontBold() -> CTFont {
        let base = bodyFont()
        return CTFontCreateCopyWithSymbolicTraits(base, scaledBodySize, nil,
                       .traitBold, .traitBold) ?? base
    }

    private func bodyFontItalic() -> CTFont {
        let base = bodyFont()
        return CTFontCreateCopyWithSymbolicTraits(
            base, scaledBodySize, nil, .traitItalic, .traitItalic) ?? base
    }

    // Half an average character on each side yields a full character of
    // gutter between adjacent cells without growing the row band.

    private func cellPadding() -> CGFloat {
        rowPad + averageCharWidth(bodyFont()) / 2
    }

    private func smallFont() -> CTFont {
        return CTFontCreateUIFontForLanguage(.system, 9, nil) ??
               CTFontCreateWithName("Helvetica" as CFString, 9, nil)
    }

    private func monoCTFont() -> CTFont {
        return CTFontCreateWithName("Menlo" as CFString, monoSize, nil)
    }

    private func monoFontPlatform() -> PlatformFont {
        monoFont(at: monoSize)
    }

    private var textColor: CGColor {
        return CGColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
    }

    private var linkColor: CGColor {
        CGColor(srgbRed: 0.10, green: 0.36, blue: 0.80, alpha: 1.0)
    }

    private var secondaryColor: CGColor {
        return CGColor(srgbRed: 0.40, green: 0.40, blue: 0.43, alpha: 1.0)
    }

    private var codeBgColor: CGColor {
        return CGColor(srgbRed: 0.95, green: 0.95, blue: 0.95, alpha: 1.0)
    }

    private var rowShadeColor: CGColor {
        return CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
    }

    private var headerShadeColor: CGColor {
        return CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1.0)
    }

}

