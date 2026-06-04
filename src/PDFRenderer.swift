import Foundation
import CoreText
import CoreGraphics
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum TempPDFs {

    static let dirName = "Markdown.Preview-Exports"

    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(dirName, isDirectory: true)
    }

    static func cleanOnLaunch() {
        let dir = directory
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
    }
}

// Async prefetch + decode helper for the single-text-surface path
// (DocumentText). Mirrors PDFExport.prefetchImages but returns
// platform images (NSImage / UIImage) suitable for NSTextAttachment.
func prefetchDocumentImages(in blocks: [Block])
    async -> [URL: DocumentText.DocumentImage] {
    let urls = ImagePrefetch.collectURLs(in: blocks)
    let datas = await ImagePrefetch.fetch(urls)
    var result: [URL: DocumentText.DocumentImage] = [:]
    for (url, data) in datas {
        #if os(macOS)
        if let img = NSImage(data: data) { result[url] = img }
        #else
        if let img = UIImage(data: data) { result[url] = img }
        #endif
    }
    return result
}

// Sync PDF render for the pasteboard's lazy .pdf flavor (no image
// prefetch - the request callback is sync). Async exportPDF (below)
// is the path for Save / Share which DO prefetch images.
func exportPDFDataSync(text: String, title: String) -> Data? {
    let blocks = Markdown.parse(text)
    return PDFExport.data(blocks: blocks, title: title)
}

func exportPDF(text: String, title: String) async -> URL? {
    let blocks = Markdown.parse(text)
    let images = await PDFExport.prefetchImages(in: blocks)
    let safe = title
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    let dir = TempPDFs.directory
    try? FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    let temp = dir.appendingPathComponent("\(safe).pdf")
    try? FileManager.default.removeItem(at: temp)
    var result: URL? = nil
    do {
        try PDFExport.write(blocks: blocks,
                            to: temp,
                            title: title,
                            images: images)
        result = temp
    } catch {
        result = nil
    }
    return result
}

enum PDFExport {

    static func write(blocks: [Block],
                      to url: URL,
                       title: String,
                      images: [URL: CGImage] = [:]) throws {
        var thrown: Error?
        let body = {
            do {
                try writeImpl(blocks: blocks, to: url,
                              title: title, images: images)
            } catch {
                thrown = error
            }
        }
        #if os(macOS)
        if let aqua = NSAppearance(named: .aqua) {
            aqua.performAsCurrentDrawingAppearance(body)
        } else {
            body()
        }
        #else
        let light = UITraitCollection(userInterfaceStyle: .light)
        light.performAsCurrent(body)
        #endif
        if let e = thrown { throw e }
    }

    private static func writeImpl(blocks: [Block],
                                  to url: URL,
                                   title: String,
                                  images: [URL: CGImage]) throws {
        let pageSize = paperSize()
        var media = CGRect(origin: .zero, size: pageSize)
        if let consumer = CGDataConsumer(url: url as CFURL),
           let ctx = CGContext(consumer: consumer,
                               mediaBox: &media, nil) {
            let r = PDFRenderer(ctx: ctx, pageSize: pageSize,
                                title: title, images: images)
            r.startPage()
            for block in blocks { r.draw(block) }
            r.endPage()
            ctx.closePDF()
        } else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func prefetchImages(in blocks: [Block]) async -> [URL: CGImage] {
        let urls = ImagePrefetch.collectURLs(in: blocks)
        let datas = await ImagePrefetch.fetch(urls)
        return datas.compactMapValues { d in decode(d) }
    }

    // Sync sibling of `write` that returns Data via CGDataConsumer over
    // NSMutableData. Used by the pasteboard's lazy .pdf flavor where the
    // request callback is synchronous, so there is no time to prefetch
    // images - any missing image renders as its alt-text placeholder.
    static func data(blocks: [Block], title: String,
                     images: [URL: CGImage] = [:]) -> Data? {
        var result: Data? = nil
        let body = {
            let buffer = NSMutableData()
            let pageSize = paperSize()
            var media = CGRect(origin: .zero, size: pageSize)
            if let consumer = CGDataConsumer(data: buffer),
               let ctx = CGContext(consumer: consumer,
                                   mediaBox: &media, nil) {
                let r = PDFRenderer(ctx: ctx, pageSize: pageSize,
                                    title: title, images: images)
                r.startPage()
                for block in blocks { r.draw(block) }
                r.endPage()
                ctx.closePDF()
                result = buffer as Data
            }
        }
        #if os(macOS)
        if let aqua = NSAppearance(named: .aqua) {
            aqua.performAsCurrentDrawingAppearance(body)
        } else {
            body()
        }
        #else
        let light = UITraitCollection(userInterfaceStyle: .light)
        light.performAsCurrent(body)
        #endif
        return result
    }

    private static func decode(_ data: Data) -> CGImage? {
        var result: CGImage? = nil
        #if os(macOS)
        result = NSImage(data: data)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        result = UIImage(data: data)?.cgImage
        #endif
        return result
    }

    private static func paperSize() -> CGSize {
        let a4 = CGSize(width: 595, height: 842)
        let letter = CGSize(width: 612, height: 792)
        let letterRegions: Set<String> = [
            "US", "CA", "MX", "PH", "PR", "CL", "CO", "CR", "PA", "PE", "VE",
        ]
        let region = Locale.current.region?.identifier ?? ""
        return letterRegions.contains(region) ? letter : a4
    }
}

private final class PDFRenderer {

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
    var pageNumber = 0
    var y: CGFloat = 0
    // Left inset for content nested inside lists / quotes. Header and
    // footer ignore it (they pin to the true margin).
    var listIndent: CGFloat = 0

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
        endPage()
        startPage()
    }

    func ensureSpace(_ minHeight: CGFloat) {
        if remaining < minHeight { newPage() }
    }

    func draw(_ block: Block) {
        switch block {
            case .heading(let level, let text):
                drawHeading(level: level, text: text)
            case .paragraph(let attr):
                drawText(NSAttributedString(attr),
                         font: bodyFont(), color: textColor)
            case .code(let language, let text):
                drawCode(text, language: language)
            case .quote(let blocks): drawQuote(blocks)
            case .list(let items, let tight):
                drawList(items, tight: tight)
            case .table(let headers, let rows):
                drawTable(headers: headers, rows: rows)
            case .rule: drawRule()
            case .image(let alt, let url, let width, _):
                if let cg = images[url] {
                    drawImage(cg, alt: alt, explicitWidth: width)
                } else {
                    drawImagePlaceholder(alt: alt, url: url)
                }
        }
        y -= blockGap
    }

    private func drawImage(_ cg: CGImage,
                            alt: String,
                  explicitWidth: CGFloat?) {
        let imgW = CGFloat(cg.width)
        let imgH = CGFloat(cg.height)
        if imgW > 0, imgH > 0 {
            let aspect = imgW / imgH
            let maxW = contentWidth
            let maxH = pageSize.height - margin * 2 -
                       headerH - footerH - bodySize * 2
            var drawW: CGFloat
            if let explicitWidth { drawW = min(maxW, explicitWidth) }
            else { drawW = min(maxW, imgW * 0.5) }
            var drawH = drawW / aspect
            if drawH > maxH {
                drawH = maxH
                drawW = drawH * aspect
            }
            ensureSpace(drawH + bodySize * 1.6)
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
        let ns = NSAttributedString(text)
        drawText(ns, font: bold, color: textColor)
    }

    private func drawText(_ attr: NSAttributedString,
                          font: CTFont,
                          color: CGColor) {
        let m = NSMutableAttributedString(attributedString: attr)
        let full = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.font, in: full, options: []) { v, range, _ in
            if v == nil {
                m.addAttribute(.font, value: font, range: range)
            } else if let existing = v as? PlatformFont {
                let sized = resizeFont(existing, to: CTFontGetSize(font))
                m.addAttribute(.font, value: sized, range: range)
            }
        }
        m.enumerateAttribute(.foregroundColor, in: full,
                             options: []) { v, range, _ in
            if v == nil {
                m.addAttribute(.foregroundColor, value: color,
                               range: range)
            }
        }
        flow(m)
    }

    private func resizeFont(_ f: PlatformFont,
                            to size: CGFloat) -> PlatformFont {
        var result = f
        #if os(macOS)
        if let r = NSFont(descriptor: f.fontDescriptor, size: size) {
            result = r
        }
        #else
        result = UIFont(descriptor: f.fontDescriptor, size: size)
        #endif
        return result
    }

    private func flow(_ attr: NSAttributedString) {
        if attr.length > 0 {
            let fs = CTFramesetterCreateWithAttributedString(attr)
            var consumed = 0
            while consumed < attr.length {
                ensureSpace(20)
                let avail = remaining
                let rem = CFRange(location: consumed,
                                  length: attr.length - consumed)
                let rect = CGRect(x: contentLeft, y: contentBottom,
                                  width: contentWidth, height: avail)
                let path = CGPath(rect: rect, transform: nil)
                let frame = CTFramesetterCreateFrame(fs, rem, path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                if visible.length == 0 {
                    newPage()
                } else {
                    let used = lineHeightUsed(frame: frame, in: rect)
                    CTFrameDraw(frame, ctx)
                    y -= used
                    consumed = visible.location + visible.length
                    if consumed < attr.length { newPage() }
                }
            }
        }
    }

    private func lineHeightUsed(frame: CTFrame,
                                in rect: CGRect) -> CGFloat {
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
            let used = rect.height - lastBaselineFromRectBottom
                + descent - topPadding
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
        // Core Text honors only CGColor; the highlighter emits NSColor.
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
                                  y: contentBottom,
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
                CTFrameDraw(frame, ctx)
                y -= used + 2 * inset
                consumed = visible.location + visible.length
                if consumed < m.length { newPage() }
            }
        }
    }

    // Quote content is full block content, drawn at a deeper indent
    // with a vertical bar. The bar is drawn per page region so a quote
    // that spans a page break still gets a bar on each page.
    private func drawQuote(_ blocks: [Block]) {
        let saved = listIndent
        let barX = margin + saved
        var startY = y
        var startPage = pageNumber
        listIndent = saved + 16
        for b in blocks {
            draw(b)
            if pageNumber != startPage {
                startPage = pageNumber
                startY = contentTop
            }
        }
        listIndent = saved
        if startY > y {
            ctx.setFillColor(secondaryColor)
            ctx.fill(CGRect(x: barX, y: y, width: 2, height: startY - y))
        }
    }

    // A list draws each item's marker at the current indent, then
    // renders the item's blocks one gutter deeper via draw(), so nested
    // lists, paragraphs, code, quotes, and tables all compose. The
    // marker shares the first content line's baseline.
    private func drawList(_ items: [ListItem], tight: Bool) {
        let saved = listIndent
        let gutter: CGFloat = 20
        for item in items {
            ensureSpace(bodySize * 2)
            let glyph = item.checked == nil ? item.marker
                : (item.checked == true ? "☑︎" : "☐")
            let markerAttr = NSAttributedString(string: glyph, attributes: [
                .font: bodyFont(),
                .foregroundColor: textColor,
            ])
            let line = CTLineCreateWithAttributedString(markerAttr)
            ctx.textPosition = CGPoint(x: margin + saved, y: y - bodySize)
            CTLineDraw(line, ctx)
            listIndent = saved + gutter
            if item.blocks.isEmpty {
                y -= bodySize * 1.4
            } else {
                for b in item.blocks { draw(b) }
            }
            listIndent = saved
        }
    }

    private func drawTable(headers: [String], rows: [[String]]) {
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        if cols > 0 {
            drawTableImpl(headers: headers, rows: rows, cols: cols)
        }
    }

    private func drawTableImpl(headers: [String],
                                  rows: [[String]],
                                  cols: Int) {
        let rowPad: CGFloat = 4
        // Per-column minimum widths derived from the longest single
        // word in each column's header + cells, measured in the bold
        // body font (header is bold; data text is the same size and
        // breaks against the same character widths). Plus 2 * rowPad
        // for the cell's left/right inset. Without this, the
        // sqrt(charWidth)-weighted distribution starves columns whose
        // content is short OVERALL but whose single longest token
        // (e.g. the header word "Rating") needs more width than the
        // weighted share allocates - CT framesetter then breaks the
        // word mid-letter.
        let minWidths: [CGFloat] = (0..<cols).map { c in
            let word = TableMetrics.longestWord(headers: headers,
                                                rows: rows, col: c)
            let attr = NSAttributedString(string: word,
                attributes: [.font: bodyFontBold()])
            let line = CTLineCreateWithAttributedString(attr)
            return CTLineGetBoundsWithOptions(line, []).width
                   + 2 * rowPad
        }
        // Char-weighted text shares from the shared metric (same recipe
        // as the on-screen table), with min-widths above as the floor.
        // Image cells then push their column to at least their
        // image-aware width, and we re-fit if that pushed the total
        // over contentWidth.
        var colWidths = TableMetrics.pointWidths(headers: headers,
                                                 rows: rows,
                                                 available: contentWidth,
                                                 minimums: minWidths)
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
                    else { w = min(contentWidth / CGFloat(cols),
                                   imgW * 0.5) }
                    if w > colWidths[c] { colWidths[c] = w }
                }
            }
        }
        let total = colWidths.reduce(0, +)
        if total > contentWidth, total > 0 {
            let scale = contentWidth / total
            colWidths = colWidths.map { v in v * scale }
        }
        func drawRow(_ cells: [String], bold: Bool, shade: CGColor?) {
            var rowH: CGFloat = bodySize * 1.3
            for c in 0..<cols {
                let txt = c < cells.count ? cells[c] : ""
                let cellW = colWidths[c] - 2 * rowPad
                var h: CGFloat = 0
                if let info = ImagePrefetch.imageInCell(txt),
                   let cg = images[info.0] {
                    h = predictImageHeight(
                        cg, maxWidth: cellW,
                        explicitWidth: info.1, explicitHeight: info.2)
                } else {
                    h = textCellHeight(txt, bold: bold, width: cellW)
                }
                if h > rowH { rowH = h }
            }
            ensureSpace(rowH + rowPad * 2)
            let savedY = y
            // Fill the shade band BEFORE the cells so the text draws on
            // top of it (normal blend). The earlier destinationOver
            // approach hid shaded rows: PDF contexts don't reliably
            // composite-under, so the opaque band painted over the text.
            if let shade {
                ctx.setFillColor(shade)
                ctx.fill(CGRect(x: contentLeft,
                                y: savedY - rowH - rowPad,
                                width: contentWidth,
                                height: rowH + 2 * rowPad))
            }
            var maxUsed: CGFloat = 0
            var x = contentLeft
            for c in 0..<cols {
                let txt = c < cells.count ? cells[c] : ""
                let xL = x + rowPad
                let cellW = colWidths[c] - 2 * rowPad
                if let info = ImagePrefetch.imageInCell(txt),
                   let cg = images[info.0] {
                    let used = drawCellImage(
                        cg, x: xL, topY: savedY,
                        maxWidth: cellW,
                        explicitWidth: info.1, explicitHeight: info.2)
                    if used > maxUsed { maxUsed = used }
                } else {
                    let inner = cellAttributed(txt, bold: bold)
                    let fs = CTFramesetterCreateWithAttributedString(inner)
                    let rect = CGRect(x: xL, y: contentBottom,
                                      width: cellW,
                                      height: savedY - contentBottom)
                    let path = CGPath(rect: rect, transform: nil)
                    let frame = CTFramesetterCreateFrame(
                        fs, CFRange(location: 0, length: 0),
                        path, nil)
                    let used = lineHeightUsed(frame: frame, in: rect)
                    CTFrameDraw(frame, ctx)
                    if used > maxUsed { maxUsed = used }
                }
                x += colWidths[c]
            }
            y = savedY - maxUsed - rowPad
            ctx.setStrokeColor(secondaryColor)
            ctx.setLineWidth(0.5)
            ctx.move(to: CGPoint(x: contentLeft, y: y))
            ctx.addLine(to: CGPoint(x: contentRight, y: y))
            ctx.strokePath()
            y -= rowPad
        }
        if !headers.isEmpty {
            drawRow(headers, bold: true, shade: headerShadeColor)
        }
        for (idx, row) in rows.enumerated() {
            drawRow(row, bold: false,
                    shade: idx % 2 == 1 ? rowShadeColor : nil)
        }
    }

    private func imageDrawSize(_ cg: CGImage,
                            maxWidth: CGFloat,
                       explicitWidth: CGFloat?,
                      explicitHeight: CGFloat?) -> CGSize {
        var result: CGSize = .zero
        let imgW = CGFloat(cg.width)
        let imgH = CGFloat(cg.height)
        if imgW > 0, imgH > 0 {
            let aspect = imgW / imgH
            var drawW: CGFloat
            var drawH: CGFloat
            if let w = explicitWidth, let h = explicitHeight {
                drawW = w
                drawH = h
            } else if let w = explicitWidth {
                drawW = w
                drawH = w / aspect
            } else if let h = explicitHeight {
                drawH = h
                drawW = h * aspect
            } else {
                drawW = min(maxWidth, imgW * 0.5)
                drawH = drawW / aspect
            }
            if drawW > maxWidth {
                drawW = maxWidth
                drawH = drawW / aspect
            }
            result = CGSize(width: drawW, height: drawH)
        }
        return result
    }

    private func predictImageHeight(_ cg: CGImage,
                                maxWidth: CGFloat,
                           explicitWidth: CGFloat?,
                          explicitHeight: CGFloat?) -> CGFloat {
        imageDrawSize(cg, maxWidth: maxWidth,
                      explicitWidth: explicitWidth,
                      explicitHeight: explicitHeight).height
    }

    // Parse the cell as Markdown and bake each inline run's intent
    // (bold, italic, code, strikethrough) into explicit Core Text
    // attributes. AttributedString(markdown:) only records the intent;
    // NSTextView interprets it, but Core Text honors only .font and
    // .strikethroughStyle, so the traits must be resolved here.
    private func cellAttributed(_ text: String,
                                bold: Bool) -> NSAttributedString {
        let parsed = Markdown.parse(text)
        var attr = AttributedString(text)
        if let first = parsed.first, case .paragraph(let a) = first {
            attr = a
        }
        let base = bold ? bodyFontBold() : bodyFont()
        let baseSize = CTFontGetSize(base)
        let m = NSMutableAttributedString()
        for run in attr.runs {
            let intent = run.inlinePresentationIntent ?? []
            let runFont = cellRunFont(intent: intent, base: base,
                                      size: baseSize, baseBold: bold)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: textColor,
            ]
            if intent.contains(.code) {
                attrs[.backgroundColor] = codeBgColor
            }
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] =
                    NSUnderlineStyle.single.rawValue
                attrs[.strikethroughColor] = textColor
            }
            let segment = String(attr[run.range].characters)
            m.append(NSAttributedString(string: segment,
                                        attributes: attrs))
        }
        return m
    }

    private func cellRunFont(intent: InlinePresentationIntent,
                             base: PlatformFont, size: CGFloat,
                             baseBold: Bool) -> PlatformFont {
        var result = base
        if intent.contains(.code) {
            #if os(macOS)
            result = NSFont.monospacedSystemFont(ofSize: size,
                                                 weight: .regular)
            #else
            result = UIFont.monospacedSystemFont(ofSize: size,
                                                 weight: .regular)
            #endif
        } else {
            var traits = base.fontDescriptor.symbolicTraits
            #if os(macOS)
            if baseBold || intent.contains(.stronglyEmphasized) {
                traits.insert(.bold)
            }
            if intent.contains(.emphasized) { traits.insert(.italic) }
            let d = base.fontDescriptor.withSymbolicTraits(traits)
            result = NSFont(descriptor: d, size: size) ?? base
            #else
            if baseBold || intent.contains(.stronglyEmphasized) {
                traits.insert(.traitBold)
            }
            if intent.contains(.emphasized) {
                traits.insert(.traitItalic)
            }
            if let d = base.fontDescriptor.withSymbolicTraits(traits) {
                result = UIFont(descriptor: d, size: size)
            }
            #endif
        }
        return result
    }

    // Lay a text cell into a tall scratch frame to learn its rendered
    // height, so a row's shade band can be filled before the cells draw.
    private func textCellHeight(_ txt: String, bold: Bool,
                                width: CGFloat) -> CGFloat {
        let inner = cellAttributed(txt, bold: bold)
        let fs = CTFramesetterCreateWithAttributedString(inner)
        let rect = CGRect(x: 0, y: 0, width: width,
                          height: pageSize.height)
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
                                 explicitWidth: explicitWidth,
                                 explicitHeight: explicitHeight)
        if size.height > 0 {
            ctx.draw(cg, in: CGRect(x: x, y: topY - size.height,
                                    width: size.width,
                                    height: size.height))
        }
        return size.height
    }

    private func drawRule() {
        ensureSpace(8)
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
    }

    private func bodyFont() -> CTFont {
        return CTFontCreateUIFontForLanguage(.system, bodySize, nil) ??
               CTFontCreateWithName("Helvetica" as CFString,
                                    bodySize, nil)
    }

    private func bodyFontBold() -> CTFont {
        let base = bodyFont()
        return CTFontCreateCopyWithSymbolicTraits(
            base, bodySize, nil, .traitBold, .traitBold) ?? base
    }

    private func bodyFontItalic() -> CTFont {
        let base = bodyFont()
        return CTFontCreateCopyWithSymbolicTraits(
            base, bodySize, nil, .traitItalic, .traitItalic) ?? base
    }

    private func smallFont() -> CTFont {
        return CTFontCreateUIFontForLanguage(.system, 9, nil) ??
               CTFontCreateWithName("Helvetica" as CFString, 9, nil)
    }

    private func monoCTFont() -> CTFont {
        return CTFontCreateWithName("Menlo" as CFString, monoSize, nil)
    }

    private func monoFontPlatform() -> PlatformFont {
        #if os(macOS)
        return NSFont.monospacedSystemFont(ofSize: monoSize,
                                           weight: .regular)
        #else
        return UIFont.monospacedSystemFont(ofSize: monoSize,
                                           weight: .regular)
        #endif
    }

    private var textColor: CGColor {
        return CGColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1.0)
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

    // Slightly stronger than rowShadeColor, mirroring the on-screen
    // header's Color.primary.opacity(0.07) vs the zebra's 0.04.
    private var headerShadeColor: CGColor {
        return CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1.0)
    }

}

// HtmlExport and PlainExport live next to PDFExport because the three
// are companion serializers over the same [Block] tree (and HtmlExport
// reuses ImagePrefetch / TableMetrics). Kept here while the surface is
// small; can split into their own file once they outgrow.

// Theme-neutral HTML: no body background, no body foreground (inherit
// the destination's), only rgba(128,128,128,...) grays for stripes and
// borders, no near-white / near-black, no JS, no external references.
// Images render only when their bytes were prefetched and inlined as
// base64; otherwise they fall back to a styled alt-text placeholder.
//
// Styles inline on every element instead of a <style> block: paste
// targets (Gmail, Mail, Safari contenteditable) strip <style> and
// <head> on sanitize; TextEdit's HTML-to-RTF converter ignores most
// selectors. Inline survives all of them, at the cost of payload size.
enum HtmlExport {

    static func render(_ blocks: [Block], title: String,
                       images: [URL: Data] = [:]) -> String {
        var head = "<!DOCTYPE html>\n<html>\n<head>\n"
        head += "<meta charset=\"utf-8\">\n"
        head += "<title>\(esc(title))</title>\n"
        head += "</head>\n<body>\n"
        var body = ""
        for block in blocks {
            body += renderBlock(block, images: images)
        }
        return head + body + "</body>\n</html>\n"
    }

    static func renderFragment(_ blocks: [Block],
                               images: [URL: Data] = [:]) -> String {
        var out = ""
        for block in blocks {
            out += renderBlock(block, images: images)
        }
        return out
    }

    static func prefetchImages(in blocks: [Block]) async -> [URL: Data] {
        let urls = ImagePrefetch.collectURLs(in: blocks)
        return await ImagePrefetch.fetch(urls)
    }

    private static func renderBlock(_ block: Block,
                                    images: [URL: Data]) -> String {
        switch block {
            case .heading(let level, let text):
                return "<h\(level)>\(renderInline(text))</h\(level)>\n"
            case .paragraph(let text):
                return "<p>\(renderInline(text))</p>\n"
            case .code(let lang, let text):
                return renderCode(lang: lang, text: text)
            case .quote(let inner):
                var s = "<blockquote style=\"\(quoteStyle)\">\n"
                for b in inner { s += renderBlock(b, images: images) }
                return s + "</blockquote>\n"
            case .list(let items, let tight):
                return renderList(items, tight: tight, images: images)
            case .table(let headers, let rows):
                return renderTable(headers: headers, rows: rows)
            case .rule:
                return "<hr style=\"\(ruleStyle)\">\n"
            case .image(let alt, let url, let w, let h):
                return renderImage(alt: alt, url: url, w: w, h: h,
                                   images: images)
        }
    }

    private static func renderInline(_ attr: AttributedString) -> String {
        var out = ""
        for run in attr.runs {
            let segment = esc(String(attr[run.range].characters))
            let intent = run.inlinePresentationIntent ?? []
            var open: [String] = []
            var close: [String] = []
            if let url = run.link {
                open.append("<a href=\"\(escAttr(url.absoluteString))\">")
                close.insert("</a>", at: 0)
            }
            if intent.contains(.code) {
                open.append("<code style=\"\(inlineCodeStyle)\">")
                close.insert("</code>", at: 0)
            }
            if intent.contains(.stronglyEmphasized) {
                open.append("<strong>")
                close.insert("</strong>", at: 0)
            }
            if intent.contains(.emphasized) {
                open.append("<em>")
                close.insert("</em>", at: 0)
            }
            if intent.contains(.strikethrough) {
                open.append("<del>")
                close.insert("</del>", at: 0)
            }
            out += open.joined() + segment + close.joined()
        }
        return out
    }

    private static func renderCode(lang: String?, text: String) -> String {
        let body = esc(text)
        var cls = ""
        if let lang { cls = " class=\"language-\(escAttr(lang))\"" }
        return "<pre style=\"\(codeBlockStyle)\">" +
               "<code\(cls)>\(body)</code></pre>\n"
    }

    private static func renderList(_ items: [ListItem], tight: Bool,
                                   images: [URL: Data]) -> String {
        var ordered = false
        if let first = items.first, let c = first.marker.first {
            ordered = c.isNumber
        }
        let tag = ordered ? "ol" : "ul"
        let style = tight ? listStyleTight : listStyleLoose
        var out = "<\(tag) style=\"\(style)\">\n"
        for item in items {
            out += renderItem(item, images: images)
        }
        return out + "</\(tag)>\n"
    }

    private static func renderItem(_ item: ListItem,
                                   images: [URL: Data]) -> String {
        var mark = ""
        if let c = item.checked {
            mark = "<span style=\"margin-right:0.4em\">" +
                   "\(c ? "&#9745;" : "&#9744;")</span>"
        }
        var out = "<li>\(mark)"
        for b in item.blocks {
            out += renderBlock(b, images: images)
        }
        return out + "</li>\n"
    }

    private static func renderTable(headers: [String],
                                    rows: [[String]]) -> String {
        let n = TableMetrics.columnCount(headers: headers, rows: rows)
        var out = "<table style=\"\(tableStyle)\">\n"
        if !headers.isEmpty {
            out += "<thead><tr style=\"\(rowHeaderStyle)\">\n"
            for i in 0..<n {
                let cell = i < headers.count ? headers[i] : ""
                out += "<th style=\"\(thStyle)\">" +
                       "\(inlineFromCell(cell))</th>\n"
            }
            out += "</tr></thead>\n"
        }
        out += "<tbody>\n"
        for (idx, row) in rows.enumerated() {
            let shade = idx % 2 == 1
            let rowOpen = shade
                ? "<tr style=\"\(rowShadeStyle)\">"
                : "<tr>"
            out += rowOpen + "\n"
            for i in 0..<n {
                let cell = i < row.count ? row[i] : ""
                out += "<td style=\"\(tdStyle)\">" +
                       "\(inlineFromCell(cell))</td>\n"
            }
            out += "</tr>\n"
        }
        return out + "</tbody>\n</table>\n"
    }

    private static func inlineFromCell(_ raw: String) -> String {
        let parsed = Markdown.parse(raw)
        var attr = AttributedString(raw)
        if let first = parsed.first, case .paragraph(let a) = first {
            attr = a
        }
        return renderInline(attr)
    }

    private static func renderImage(alt: String, url: URL,
                                    w: CGFloat?, h: CGFloat?,
                                    images: [URL: Data]) -> String {
        var style = "max-width:100%;"
        if let w { style += "width:\(Int(w))px;" }
        if let h { style += "height:\(Int(h))px;" }
        var result = ""
        if let data = images[url] {
            let src = dataURI(data)
            result = "<p><img alt=\"\(escAttr(alt))\" " +
                     "src=\"\(src)\" style=\"\(style)\"></p>\n"
        } else {
            // No external <img src=URL>: the plan rule is "absolutely
            // no external references". Without inlined bytes, emit a
            // styled placeholder so paste targets still see the alt.
            let label = alt.isEmpty ? url.absoluteString : alt
            result = "<p style=\"\(imagePlaceholderStyle)\">" +
                     "[\(esc(label))]</p>\n"
        }
        return result
    }

    private static func dataURI(_ data: Data) -> String {
        let mime = detectMime(data)
        let b64 = data.base64EncodedString()
        return "data:\(mime);base64,\(b64)"
    }

    private static func detectMime(_ data: Data) -> String {
        var result = "application/octet-stream"
        let b = [UInt8](data.prefix(4))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF {
            result = "image/jpeg"
        } else if b.count >= 4, b[0] == 0x89, b[1] == 0x50,
                                b[2] == 0x4E, b[3] == 0x47 {
            result = "image/png"
        } else if b.count >= 3, b[0] == 0x47, b[1] == 0x49, b[2] == 0x46 {
            result = "image/gif"
        } else if b.count >= 4, b[0] == 0x52, b[1] == 0x49,
                                b[2] == 0x46, b[3] == 0x46 {
            result = "image/webp"
        }
        return result
    }

    private static func esc(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                default: out.append(c)
            }
        }
        return out
    }

    private static func escAttr(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
                case "&": out += "&amp;"
                case "<": out += "&lt;"
                case ">": out += "&gt;"
                case "\"": out += "&quot;"
                case "'": out += "&#39;"
                default: out.append(c)
            }
        }
        return out
    }

    private static let codeBlockStyle =
        "background:rgba(128,128,128,0.10);" +
        "padding:8px 12px;" +
        "border-radius:4px;" +
        "font-family:ui-monospace,SFMono-Regular,Menlo,monospace;" +
        "font-size:0.92em;" +
        "overflow-x:auto;" +
        "white-space:pre;"

    private static let inlineCodeStyle =
        "background:rgba(128,128,128,0.14);" +
        "padding:1px 4px;" +
        "border-radius:3px;" +
        "font-family:ui-monospace,SFMono-Regular,Menlo,monospace;" +
        "font-size:0.92em;"

    private static let quoteStyle =
        "border-left:3px solid rgba(128,128,128,0.5);" +
        "padding-left:12px;" +
        "margin-left:0;" +
        "opacity:0.85;"

    private static let ruleStyle =
        "border:none;" +
        "border-top:1px solid rgba(128,128,128,0.3);" +
        "margin:1em 0;"

    private static let tableStyle =
        "border-collapse:collapse;" +
        "margin:0.5em 0;"

    private static let thStyle =
        "padding:6px 10px;" +
        "text-align:left;" +
        "border-bottom:1px solid rgba(128,128,128,0.3);"

    private static let tdStyle =
        "padding:6px 10px;" +
        "border-bottom:1px solid rgba(128,128,128,0.12);"

    private static let rowHeaderStyle =
        "background:rgba(128,128,128,0.14);"

    private static let rowShadeStyle =
        "background:rgba(128,128,128,0.07);"

    private static let listStyleTight =
        "margin:0.2em 0;" +
        "padding-left:1.5em;"

    private static let listStyleLoose =
        "margin:0.5em 0;" +
        "padding-left:1.5em;"

    private static let imagePlaceholderStyle =
        "color:rgba(128,128,128,0.7);" +
        "font-style:italic;"
}

// Plaintext serializer for the pasteboard's .string flavor. Tables use
// TableMetrics.serializeMonospaced so columns line up; everything else
// renders as readable Markdown-flavored text the user can drop into a
// terminal or a plain-text editor.
enum PlainExport {

    static func render(_ blocks: [Block]) -> String {
        var out = ""
        for (i, b) in blocks.enumerated() {
            out += renderBlock(b)
            if i < blocks.count - 1 { out += "\n" }
        }
        return out
    }

    private static func renderBlock(_ block: Block) -> String {
        switch block {
            case .heading(let level, let text):
                let prefix = String(repeating: "#", count: level)
                return "\(prefix) \(plain(text))\n"
            case .paragraph(let text):
                return "\(plain(text))\n"
            case .code(_, let text):
                return text + "\n"
            case .quote(let inner):
                let body = render(inner)
                let lines = body.split(
                    separator: "\n", omittingEmptySubsequences: false)
                return lines.map { line in "> \(line)" }
                    .joined(separator: "\n") + "\n"
            case .list(let items, _):
                return renderList(items)
            case .table(let h, let rows):
                return TableMetrics.serializeMonospaced(
                    headers: h, rows: rows)
            case .rule:
                return "---\n"
            case .image(let alt, let url, _, _):
                return "![\(alt)](\(url.absoluteString))\n"
        }
    }

    private static func renderList(_ items: [ListItem]) -> String {
        var out = ""
        for item in items {
            var mark = item.marker
            if let c = item.checked { mark = c ? "[x]" : "[ ]" }
            let inner = render(item.blocks)
            let lines = inner.split(
                separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            if let first = lines.first {
                out += "\(mark) \(first)\n"
                for rest in lines.dropFirst() where !rest.isEmpty {
                    out += "  \(rest)\n"
                }
            }
        }
        return out
    }

    private static func plain(_ a: AttributedString) -> String {
        String(a.characters)
    }
}

// PLAN-TABLES Step 2: single text surface. Walks [Block] and produces
// one NSAttributedString that an NSTextView / UITextView can render
// with native continuous selection. ROUND 1 covers paragraph +
// heading + rule with inline-intent translation (bold / italic / code
// / strike / link); other block types fall back to PlainExport raw
// text until later rounds style them. Behind a `singleSurface`
// AppStorage flag in MarkdownView, default off. See
// single-text-surface-intent.md for the staged rounds.
enum DocumentText {

    // Atomic-range tag values. PLAN-SELECTION's arbiter reads these
    // to decide when to snap a selection that crosses a block to the
    // whole block. Absence of the tag means "inline" (paragraph /
    // heading / list-item / quote-content); presence means "atomic"
    // (the user can range-select inside the block but a selection
    // that started outside snaps to whole).
    enum AtomicKind: String {
        case code
        case table
        case image
    }

    #if os(macOS)
    typealias DocumentImage = NSImage
    #elseif os(iOS)
    typealias DocumentImage = UIImage
    #endif

    static let atomicKindKey =
        NSAttributedString.Key("DocumentText.atomicKind")
    static let atomicIdKey =
        NSAttributedString.Key("DocumentText.atomicId")

    static func attributed(from blocks: [Block],
                           images: [URL: DocumentImage] = [:])
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        for block in blocks {
            m.append(render(block, images: images))
        }
        return m
    }

    private static func render(_ block: Block,
                               images: [URL: DocumentImage])
        -> NSAttributedString {
        var result: NSAttributedString
        switch block {
            case .paragraph(let attr):
                result = paragraph(attr)
            case .heading(let level, let attr):
                result = heading(level: level, text: attr)
            case .code(let lang, let text):
                result = code(language: lang, text: text)
            case .quote(let inner):
                result = quote(inner, images: images)
            case .list(let items, let tight):
                result = list(items: items, tight: tight, depth: 0,
                              images: images)
            case .table(let headers, let rows):
                result = table(headers: headers, rows: rows,
                               images: images)
            case .rule:
                result = rule()
            case .image(let alt, let url, let w, let h):
                result = image(alt: alt, url: url, width: w, height: h,
                               images: images)
        }
        return result
    }

    // NSTextTable tables. Each cell is one paragraph whose paragraph
    // style carries an NSTextTableBlock anchoring it into the right
    // (row, column) of a shared NSTextTable. NSTextView reads those
    // textBlocks at layout time and lays out the table with real cell
    // boxes: cells WRAP within their column, columns proportion to
    // content via `automaticLayoutAlgorithm`, the whole table reflows
    // when the view's width changes. Headers are bold with a stronger
    // background tint; data rows alternate with a subtler tint via the
    // cell's backgroundColor (rendered as the cell's box fill, not a
    // range-attribute background, so it covers the whole wrapped cell
    // even on multi-line content).
    //
    // Cells go through `tableCell` for inline Markdown
    // (`**bold**` / `*italic*` / `` `code` `` / `~~strike~~` /
    // `[link](url)`). Every cell carries `atomicKindKey = table` plus
    // a shared `atomicId` so PLAN-SELECTION's arbiter still treats the
    // whole table as one atomic block.
    //
    // The earlier tab-stop model (Option A in the original fork) is
    // gone - tab tables couldn't wrap within a column, so cells with
    // long content (PROMPT-RESULTS.md's Response column) truncated
    // with `.byTruncatingTail`. NSTextTable is the proper Cocoa text-
    // table API and was the answer the intent doc didn't consider.
    // `relayoutTables` retired with the tab-stop model: NSTextTable
    // handles its own view-width-aware layout.
    private static func table(headers: [String], rows: [[String]],
                              images: [URL: DocumentImage])
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        if cols > 0 {
            let atomicId = UUID().uuidString
            #if os(macOS)
            let textTable = NSTextTable()
            textTable.numberOfColumns = cols
            // fixedLayoutAlgorithm respects the explicit width on each
            // NSTextTableBlock; automatic layout ignores widths and
            // defaults to roughly-equal columns at narrow widths, which
            // is what produced the 33/33/33 look in early testing.
            textTable.layoutAlgorithm = .fixedLayoutAlgorithm
            // Per-column percentage shares from TableMetrics so the
            // narrow-content column (Rating) stays narrow and the
            // long-content column (Response) gets the lion's share -
            // matches the block-tree TableBlock's sqrt-weighted model.
            // Asking for available=100 normalises the result to
            // percentages.
            let shares = TableMetrics.pointWidths(headers: headers,
                                                  rows: rows,
                                                  available: 100)
            var rowIdx = 0
            if !headers.isEmpty {
                m.append(tableRow(cells: headers, table: textTable,
                                  rowIdx: rowIdx, cols: cols,
                                  shares: shares,
                                  bold: true,
                                  tint: tableHeaderTint(),
                                  atomicId: atomicId,
                                  images: images))
                rowIdx += 1
            }
            for (idx, row) in rows.enumerated() {
                let tint: PlatformColor = idx % 2 == 1
                    ? tableZebraTint() : clearColor()
                m.append(tableRow(cells: row, table: textTable,
                                  rowIdx: rowIdx, cols: cols,
                                  shares: shares,
                                  bold: false, tint: tint,
                                  atomicId: atomicId,
                                  images: images))
                rowIdx += 1
            }
            m.append(NSAttributedString(string: "\n"))
            #else
            // iOS fallback: NSTextTable is AppKit-only, so on iOS we
            // emit tab-stop paragraphs (one row = one paragraph, cells
            // tab-separated). Cells line up across rows via the same
            // sqrt-weighted point widths the macOS path uses, but they
            // TRUNCATE at column boundaries instead of wrapping
            // (lineBreakMode = .byTruncatingTail). Acceptable for short
            // cells; long-cell tables surface truncation. The richer
            // NSTextTable model is not available without rolling our
            // own table layout, which is out of scope.
            let widths = TableMetrics.pointWidths(headers: headers,
                                                  rows: rows,
                                                  available: 320)
            var stops: [NSTextTab] = []
            var x: CGFloat = 0
            for w in widths {
                x += w
                stops.append(NSTextTab(textAlignment: .left,
                                       location: x))
            }
            if !headers.isEmpty {
                m.append(tableRowTabStops(cells: headers,
                                          stops: stops, bold: true,
                                          tint: tableHeaderTint(),
                                          atomicId: atomicId,
                                          images: images))
            }
            for (idx, row) in rows.enumerated() {
                let tint: PlatformColor = idx % 2 == 1
                    ? tableZebraTint() : clearColor()
                m.append(tableRowTabStops(cells: row, stops: stops,
                                          bold: false, tint: tint,
                                          atomicId: atomicId,
                                          images: images))
            }
            m.append(NSAttributedString(string: "\n"))
            #endif
        }
        return m
    }

    #if os(macOS)
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
        let base = bold ? boldFont(of: bodyFont()) : bodyFont()
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
            block.setWidth(6, type: .absoluteValueType, for: .padding)
            block.backgroundColor = tint
            let para = NSMutableParagraphStyle()
            para.textBlocks = [block]
            let cellAttr = NSMutableAttributedString(
                attributedString: tableCell(cellText, base: base,
                                            images: images))
            if cellAttr.length == 0 {
                // Empty cell still needs at least one character so the
                // paragraph exists and the cell box renders. A no-break
                // space is the invisible placeholder.
                cellAttr.append(NSAttributedString(
                    string: "\u{00A0}",
                    attributes: [.font: base,
                                 .foregroundColor: textColor()]))
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
    #else
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
        let base = bold ? boldFont(of: bodyFont()) : bodyFont()
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
    #endif

    // Parse a cell as one paragraph of Markdown and translate each
    // inline run's intent (bold / italic / code / strikethrough / link)
    // into explicit Core-Text-honored attributes on top of `base` (the
    // row's font, which already carries .bold for header rows). Mirrors
    // PDFRenderer.cellAttributed; the difference is that the result
    // composes into one cell paragraph instead of its own framesetter.
    //
    // When the cell is a block-level image (`![alt](url){height=NNN}`)
    // the parser yields `.image(...)` rather than `.paragraph(...)`;
    // emit an `NSTextAttachment` for it (using the prefetched image
    // from `images` when available, a `[Image: alt]` placeholder
    // otherwise). Without this branch the raw markdown text leaks
    // into the cell as literal source.
    private static func tableCell(_ text: String,
                                  base: PlatformFont,
                                  images: [URL: DocumentImage])
        -> NSAttributedString {
        let parsed = Markdown.parse(text)
        let m = NSMutableAttributedString()
        if let first = parsed.first {
            switch first {
                case .image(let alt, let url, let w, let h):
                    if let img = images[url] {
                        let attachment = NSTextAttachment()
                        attachment.image = img
                        attachment.bounds = imageBounds(img,
                                                        width: w,
                                                        height: h)
                        m.append(NSAttributedString(
                            attachment: attachment))
                    } else {
                        let label = alt.isEmpty
                            ? url.absoluteString : alt
                        m.append(NSAttributedString(
                            string: "[Image: \(label)]",
                            attributes: [
                                .font: base,
                                .foregroundColor: secondaryColor(),
                            ]))
                    }
                case .paragraph(let attr):
                    appendInlineRuns(attr, base: base, into: m)
                default:
                    // Other block kinds in a cell (rare - a fenced code
                    // block inside a table cell, etc) fall back to the
                    // raw cell text in the row's body font. Keeps the
                    // table from breaking; the cell content surfaces.
                    m.append(NSAttributedString(
                        string: text,
                        attributes: [
                            .font: base,
                            .foregroundColor: textColor(),
                        ]))
            }
        }
        return m
    }

    private static func appendInlineRuns(_ attr: AttributedString,
                                         base: PlatformFont,
                                         into m: NSMutableAttributedString) {
        for run in attr.runs {
            let segment = String(attr[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let runFont = inlineRunFont(intent: intent, base: base)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: textColor(),
            ]
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] =
                    NSUnderlineStyle.single.rawValue
            }
            if let url = run.link {
                attrs[.link] = url
            }
            m.append(NSAttributedString(string: segment,
                                        attributes: attrs))
        }
    }

    private static func tableHeaderTint() -> PlatformColor {
        #if os(macOS)
        return NSColor(white: 0.5, alpha: 0.14)
        #else
        return UIColor(white: 0.5, alpha: 0.14)
        #endif
    }

    private static func tableZebraTint() -> PlatformColor {
        #if os(macOS)
        return NSColor(white: 0.5, alpha: 0.07)
        #else
        return UIColor(white: 0.5, alpha: 0.07)
        #endif
    }

    private static func clearColor() -> PlatformColor {
        #if os(macOS)
        return NSColor.clear
        #else
        return UIColor.clear
        #endif
    }

    // Apply quote indent on top of any existing paragraph indent
    // (so a list / heading inside a quote keeps its own indent and
    // gains the quote shift on top), and tint behind the whole range.
    private static func quote(_ blocks: [Block],
                              images: [URL: DocumentImage])
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        for inner in blocks {
            m.append(render(inner, images: images))
        }
        let full = NSRange(location: 0, length: m.length)
        m.enumerateAttribute(.paragraphStyle,
                             in: full, options: []) { value, range, _ in
            let merged = NSMutableParagraphStyle()
            if let existing = value as? NSParagraphStyle {
                merged.setParagraphStyle(existing)
            }
            merged.headIndent += 18
            merged.firstLineHeadIndent += 18
            m.addAttribute(.paragraphStyle, value: merged, range: range)
        }
        m.addAttribute(.backgroundColor, value: quoteBackgroundColor(),
                       range: full)
        return m
    }

    // Single-paragraph items get marker + tab + body on one paragraph
    // with the item's paragraph style; nested lists recurse at deeper
    // depth. Multi-block items get the continuation indent merged into
    // each non-list block past the first via `listItem`, so a follow-up
    // paragraph or fence sits under the bullet body, not at the left
    // margin.
    private static func list(items: [ListItem], tight: Bool,
                             depth: Int,
                             images: [URL: DocumentImage])
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        let indent = CGFloat(depth + 1) * 20
        let para = NSMutableParagraphStyle()
        para.headIndent = indent
        para.firstLineHeadIndent = indent - 20
        para.tabStops = [NSTextTab(textAlignment: .left,
                                   location: indent)]
        para.paragraphSpacing = tight ? 2 : 8
        para.paragraphSpacingBefore = tight ? 2 : 4
        for item in items {
            m.append(listItem(item, para: para, tight: tight,
                              depth: depth, images: images))
        }
        return m
    }

    private static func listItem(_ item: ListItem,
                                 para: NSParagraphStyle,
                                 tight: Bool,
                                 depth: Int,
                                 images: [URL: DocumentImage])
        -> NSAttributedString {
        let marker: String
        if let c = item.checked {
            marker = c ? "\u{2611}" : "\u{2610}"
        } else {
            marker = item.marker
        }
        let prefix: [NSAttributedString.Key: Any] = [
            .font: bodyFont(),
            .foregroundColor: secondaryColor(),
            .paragraphStyle: para,
        ]
        let line = NSMutableAttributedString(
            string: "\(marker)\t", attributes: prefix)
        var headHandled = false
        if let first = item.blocks.first {
            switch first {
                case .paragraph(let attr):
                    let body = NSMutableAttributedString()
                    translateInline(attr, base: bodyFont(), into: body)
                    let r = NSRange(location: 0, length: body.length)
                    body.addAttribute(.paragraphStyle, value: para,
                                      range: r)
                    line.append(body)
                    headHandled = true
                case .list(let inner, let innerTight):
                    line.append(list(items: inner, tight: innerTight,
                                     depth: depth + 1,
                                     images: images))
                    headHandled = true
                default:
                    break
            }
        }
        if !headHandled, let first = item.blocks.first {
            line.append(render(first, images: images))
        }
        line.append(NSAttributedString(string: "\n"))
        // Continuation indent for the item's second-and-later blocks.
        // Same additive-merge pattern as `quote`: a follow-up paragraph,
        // fence, image, or quote sits flush with the head body (column =
        // list's headIndent), not at the left margin. Without it the
        // continuation visually escapes the bullet and reads as
        // top-level content. Nested lists own their own indent in
        // `list(depth: depth + 1)` so they bypass the merge.
        let contIndent = para.headIndent
        for rest in item.blocks.dropFirst() {
            if case .list(let inner, let innerTight) = rest {
                line.append(list(items: inner, tight: innerTight,
                                 depth: depth + 1,
                                 images: images))
            } else {
                let rendered = NSMutableAttributedString(
                    attributedString: render(rest, images: images))
                let full = NSRange(location: 0, length: rendered.length)
                rendered.enumerateAttribute(.paragraphStyle, in: full,
                                            options: []) { value, r, _ in
                    let merged = NSMutableParagraphStyle()
                    if let existing = value as? NSParagraphStyle {
                        merged.setParagraphStyle(existing)
                    }
                    merged.headIndent += contIndent
                    merged.firstLineHeadIndent += contIndent
                    rendered.addAttribute(.paragraphStyle,
                                          value: merged, range: r)
                }
                line.append(rendered)
            }
        }
        return line
    }

    // NSTextAttachment for inlined images. Placeholder text when the
    // image data has not been prefetched yet; MarkdownView's .task
    // prefetches asynchronously and re-renders with the real images
    // once they arrive.
    private static func image(alt: String, url: URL,
                              width: CGFloat?, height: CGFloat?,
                              images: [URL: DocumentImage])
        -> NSAttributedString {
        var result: NSAttributedString
        if let img = images[url] {
            let attachment = NSTextAttachment()
            attachment.image = img
            attachment.bounds = imageBounds(img, width: width,
                                            height: height)
            let m = NSMutableAttributedString(attachment: attachment)
            let full = NSRange(location: 0, length: m.length)
            m.addAttribute(atomicKindKey,
                           value: AtomicKind.image.rawValue,
                           range: full)
            m.addAttribute(atomicIdKey, value: UUID().uuidString,
                           range: full)
            m.append(NSAttributedString(string: "\n\n"))
            result = m
        } else {
            let label = alt.isEmpty ? url.absoluteString : alt
            let attrs: [NSAttributedString.Key: Any] = [
                .font: bodyFont(),
                .foregroundColor: secondaryColor(),
                atomicKindKey: AtomicKind.image.rawValue,
                atomicIdKey: UUID().uuidString,
            ]
            result = NSAttributedString(
                string: "[Image: \(label)]\n\n", attributes: attrs)
        }
        return result
    }

    private static func imageBounds(_ img: DocumentImage,
                                    width: CGFloat?,
                                    height: CGFloat?) -> CGRect {
        var w = img.size.width
        var h = img.size.height
        let aspect = w > 0 ? h / w : 1
        if let pw = width, let ph = height {
            w = pw; h = ph
        } else if let pw = width {
            w = pw; h = w * aspect
        } else if let ph = height, aspect > 0 {
            h = ph; w = h / aspect
        } else {
            let cap: CGFloat = 320
            if w > cap { w = cap; h = w * aspect }
        }
        return CGRect(x: 0, y: 0, width: w, height: h)
    }

    private static func quoteBackgroundColor() -> PlatformColor {
        #if os(macOS)
        return NSColor(white: 0.5, alpha: 0.06)
        #else
        return UIColor(white: 0.5, alpha: 0.06)
        #endif
    }

    private static func code(language: String?, text: String) -> NSAttributedString {
        let baseFont = monospaceFont()
        let highlighted = Highlight.attribute(text, language: language,
                                              baseFont: baseFont)
        let m = NSMutableAttributedString(attributedString: highlighted)
        let full = NSRange(location: 0, length: m.length)
        // Subtle code-block tint; theme-neutral via low-alpha gray
        // (darkens on light, lightens on dark).
        m.addAttribute(.backgroundColor, value: codeBackgroundColor(),
                       range: full)
        // Atomic tags so PLAN-SELECTION's arbiter can snap to whole
        // when a drag from outside crosses this fence's boundary.
        m.addAttribute(atomicKindKey,
                       value: AtomicKind.code.rawValue, range: full)
        m.addAttribute(atomicIdKey, value: UUID().uuidString,
                       range: full)
        m.append(NSAttributedString(string: "\n\n"))
        return m
    }

    private static func monospaceFont() -> PlatformFont {
        let bodySize = PlatformFont.preferredFont(forTextStyle: .body)
            .pointSize
        return monoFont(at: bodySize - 1)
    }

    private static func codeBackgroundColor() -> PlatformColor {
        #if os(macOS)
        return NSColor(white: 0.5, alpha: 0.10)
        #else
        return UIColor(white: 0.5, alpha: 0.10)
        #endif
    }

    private static func paragraph(_ attr: AttributedString)
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        translateInline(attr, base: bodyFont(), into: m)
        m.append(NSAttributedString(string: "\n\n"))
        return m
    }

    private static func heading(level: Int,
                                text: AttributedString)
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        translateInline(text, base: headingFont(level: level), into: m)
        m.append(NSAttributedString(string: "\n\n"))
        return m
    }

    private static func rule() -> NSAttributedString {
        // ASCII-ish horizontal rule for Round 1; a real divider with
        // custom paragraph drawing lands in a later round.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: bodyFont(),
            .foregroundColor: secondaryColor(),
        ]
        return NSAttributedString(
            string: "\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\u{2500}\n\n",
            attributes: attrs)
    }

    private static func placeholder(for block: Block) -> NSAttributedString {
        // Round 1 placeholder for as-yet-unstyled block types. Later
        // rounds replace these one at a time (code, lists+quotes,
        // tables, images).
        let raw = PlainExport.render([block])
        return NSAttributedString(string: raw,
                                  attributes: [
                                    .font: bodyFont(),
                                    .foregroundColor: textColor(),
                                  ])
    }

    // Walk AttributedString runs, baking inlinePresentationIntent
    // into explicit .font / .strikethrough / .link attributes. NSText
    // View interprets intent at draw time, but Core Text and any
    // downstream serialization (RTF, PDF) honor only the explicit
    // attributes - same lesson as PDFRenderer.cellRunFont.
    private static func translateInline(_ attr: AttributedString,
                                        base: PlatformFont,
                                        into m: NSMutableAttributedString) {
        for run in attr.runs {
            let segment = String(attr[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            let runFont = inlineRunFont(intent: intent, base: base)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: textColor(),
            ]
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] =
                    NSUnderlineStyle.single.rawValue
            }
            if let url = run.link {
                attrs[.link] = url
            }
            m.append(NSAttributedString(string: segment,
                                        attributes: attrs))
        }
    }

    private static func inlineRunFont(intent: InlinePresentationIntent,
                                      base: PlatformFont) -> PlatformFont {
        var result = base
        if intent.contains(.code) {
            #if os(macOS)
            result = NSFont.monospacedSystemFont(ofSize: base.pointSize,
                                                 weight: .regular)
            #else
            result = UIFont.monospacedSystemFont(ofSize: base.pointSize,
                                                 weight: .regular)
            #endif
        } else {
            var traits = base.fontDescriptor.symbolicTraits
            #if os(macOS)
            if intent.contains(.stronglyEmphasized) {
                traits.insert(.bold)
            }
            if intent.contains(.emphasized) {
                traits.insert(.italic)
            }
            let d = base.fontDescriptor.withSymbolicTraits(traits)
            result = NSFont(descriptor: d, size: base.pointSize) ?? base
            #else
            if intent.contains(.stronglyEmphasized) {
                traits.insert(.traitBold)
            }
            if intent.contains(.emphasized) {
                traits.insert(.traitItalic)
            }
            if let d = base.fontDescriptor.withSymbolicTraits(traits) {
                result = UIFont(descriptor: d, size: base.pointSize)
            }
            #endif
        }
        return result
    }

    private static func bodyFont() -> PlatformFont {
        return PlatformFont.preferredFont(forTextStyle: .body)
    }

    private static func headingFont(level: Int) -> PlatformFont {
        let styles: [Int: PlatformFont.TextStyle] = [
            1: .largeTitle, 2: .title1, 3: .title2, 4: .title3,
            5: .headline, 6: .subheadline,
        ]
        let style = styles[level] ?? .body
        let base = PlatformFont.preferredFont(forTextStyle: style)
        return boldFont(of: base)
    }

    private static func textColor() -> PlatformColor {
        #if os(macOS)
        return NSColor.textColor
        #else
        return UIColor.label
        #endif
    }

    private static func secondaryColor() -> PlatformColor {
        #if os(macOS)
        return NSColor.secondaryLabelColor
        #else
        return UIColor.secondaryLabel
        #endif
    }

}
