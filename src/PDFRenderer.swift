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
    var pageNumber = 0
    var y: CGFloat = 0
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

    private func drawImage(_ cg: CGImage, alt: String,
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
        platformResizedFont(f, to: size)
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

    private func drawTableImpl(headers: [String], rows: [[String]],
                                  cols: Int) {
        let rowPad: CGFloat = 4
        let minWidths: [CGFloat] = (0..<cols).map { c in
            var widest: CGFloat = 0
            if c < headers.count {
                let w = cellRenderedWidth(headers[c], bold: true)
                if w > widest { widest = w }
            }
            for row in rows where c < row.count {
                let w = cellRenderedWidth(row[c], bold: false)
                if w > widest { widest = w }
            }
            return widest + 2 * rowPad
        }
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
        func drawRow(_ cells: [String], bold: Bool, shade: CGColor?) {
            var rowH: CGFloat = bodySize * 1.3
            for c in 0..<cols {
                let txt = c < cells.count ? cells[c] : ""
                let cellW = colWidths[c] - 2 * rowPad
                var h: CGFloat = 0
                if let info = ImagePrefetch.imageInCell(txt),
                   let cg = images[info.0] {
                    h = predictImageHeight(cg, maxWidth: cellW,
                        explicitWidth: info.1, explicitHeight: info.2)
                } else {
                    h = textCellHeight(txt, bold: bold, width: cellW)
                }
                if h > rowH { rowH = h }
            }
            ensureSpace(rowH + rowPad * 2)
            let savedY = y
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
                    let used = drawCellImage(cg, x: xL, topY: savedY,
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
                    let frame = CTFramesetterCreateFrame(fs,
                        CFRange(location: 0, length: 0), path, nil)
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

    private func imageDrawSize(_ cg: CGImage, maxWidth: CGFloat,
                      explicitWidth: CGFloat?, explicitHeight: CGFloat?)
                                  -> CGSize {
        let fit = aspectFit(intrinsicWidth: CGFloat(cg.width),
                            intrinsicHeight: CGFloat(cg.height),
                            explicitWidth: explicitWidth,
                            explicitHeight: explicitHeight,
                            defaultScale: 0.5, maxWidth: maxWidth)
        return CGSize(width: fit.width, height: fit.height)
    }

    private func predictImageHeight(_ cg: CGImage, maxWidth: CGFloat,
                           explicitWidth: CGFloat?, explicitHeight: CGFloat?)
                                       -> CGFloat {
        imageDrawSize(cg, maxWidth: maxWidth, explicitWidth: explicitWidth,
                      explicitHeight: explicitHeight).height
    }

    private static let numericTokenRE: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"\d[\d.,]*\d"#)

    // Wrap '.' and ',' between digits with U+2060 (WORD JOINER) so
    // CoreText cannot split a number like "70.1" or "1,234.56" across
    // lines when a table cell is narrower than the natural numeric
    // width. Locale-independent on purpose: we render the .md as
    // typed, so the pattern protects both decimal conventions.

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
            let runFont = styledRunFont(intent: intent, base: base,
                                        size: baseSize,
                                        additionalBold: bold)
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
            let segment = protectNumerics(
                String(attr[run.range].characters))
            m.append(NSAttributedString(string: segment, attributes: attrs))
        }
        return m
    }


    private func cellRenderedWidth(_ text: String, bold: Bool) -> CGFloat {
        let attr = cellAttributed(text, bold: bold)
        let line = CTLineCreateWithAttributedString(attr)
        return CTLineGetBoundsWithOptions(line, []).width
    }

    private func textCellHeight(_ txt: String, bold: Bool,
                                width: CGFloat) -> CGFloat {
        let inner = cellAttributed(txt, bold: bold)
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
               CTFontCreateWithName("Helvetica" as CFString, bodySize, nil)
    }

    private func bodyFontBold() -> CTFont {
        let base = bodyFont()
        return CTFontCreateCopyWithSymbolicTraits(base, bodySize, nil,
                       .traitBold, .traitBold) ?? base
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
        monoFont(at: monoSize)
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

    private var headerShadeColor: CGColor {
        return CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1.0)
    }

}

