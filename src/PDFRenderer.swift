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
                drawText(attr, font: bodyFont(), color: textColor)
            case .code(let language, let text):
                drawCode(text, language: language)
            case .quote(let blocks): drawQuote(blocks)
            case .list(let items, let tight):
                drawList(items, tight: tight)
            case .table(let headers, let rows):
                drawTable(headers: headers, rows: rows)
            case .math(let tex): drawMath(tex)
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
        drawText(text, font: bold, color: textColor)
    }

    // Takes the AttributedString rather than a converted one because the
    // script level rides a custom key that NSAttributedString(_:) drops;
    // the runs have to still be reachable when the fonts are settled.

    private func drawText(_ attr: AttributedString,
                          font: CTFont,
                          color: CGColor) {
        let m = NSMutableAttributedString(
            attributedString: NSAttributedString(attr))
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
        applyScriptRuns(m, from: attr)
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
            let saved = tableScale
            tableScale = fittingScale(headers: headers, rows: rows,
                                      cols: cols)
            drawTableImpl(headers: headers, rows: rows, cols: cols)
            tableScale = saved
        }
    }

    // A page cannot grow, so a table too wide for it has to give
    // something up; type size is the one concession that costs no
    // information, where a squeezed column costs a broken number. Only
    // as much as the overflow actually needs, and never past three
    // quarters -- below that the table is legible in the sense that a
    // magnifier would fix, which is not the sense that matters. Padding
    // shrinks with it, and on a wide table that is most of the saving:
    // eleven columns spend a quarter of the page on their own margins.

    // Measured, not solved. Only half the padding is type -- the other
    // half is a flat 4pt no font size reclaims -- and glyph widths do
    // not scale linearly with point size, so a closed form lands the
    // table a hair over the page and the tightest column pays for it in
    // a broken number. Re-measuring at each candidate converges in two
    // or three passes and ends BELOW the page by construction.

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

    // The width below which a column starts breaking text it had no way
    // to break: the widest token it must hold, plus its own padding.
    // Measured on tokens rather than whole cells because a heading wraps
    // at its spaces and hyphens for free, and charging the table for the
    // unwrapped width buys room nothing needs.

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
            // The point of slack is not decoration: CTLine reports a
            // typographic width and the framesetter makes its own
            // wrapping decision, and the two disagree by a fraction --
            // enough for a column sized to the report to break the very
            // token it was sized for.
            floors.append(widest + 2 * pad + 1)
        }
        return floors
    }

    // Break opportunities per UAX #14: a space, and a hyphen BETWEEN
    // WORDS. "Pre-training" is two tokens, "NEUCOM'24" is one, and
    // "-0.614" is one -- a hyphen stays welded to the number after it,
    // so a column sized as though a negative value could split renders
    // it as "-0.61" over "4".

    private func longestTokenWidth(_ text: String, bold: Bool) -> CGFloat {
        var widest: CGFloat = 0
        var token = ""
        var tokens: [String] = []
        // An image cell has no words to break. Its size is settled
        // further down against the drawn bitmap; measuring the markdown
        // would read the URL as one enormous unbreakable token and
        // shrink the whole table to make room for text nobody sees.
        let source = ImagePrefetch.imageInCell(text) == nil ? text : ""
        let chars = Array(source)
        for (i, ch) in chars.enumerated() {
            if ch == " " {
                if !token.isEmpty { tokens.append(token); token = "" }
            } else {
                token.append(ch)
                if ch == "-", hyphenBreaks(after: i, in: chars) {
                    tokens.append(token)
                    token = ""
                }
            }
        }
        if !token.isEmpty { tokens.append(token) }
        for t in tokens {
            let w = cellRenderedWidth(t, bold: bold)
            if w > widest { widest = w }
        }
        return widest
    }

    private func hyphenBreaks(after i: Int, in chars: [Character]) -> Bool {
        var result = false
        if i + 1 < chars.count {
            let next = chars[i + 1]
            result = !next.isNumber && next != " " && next != "-"
        }
        return result
    }

    private func drawTableImpl(headers: [String], rows: [[String]],
                                  cols: Int) {
        // Horizontal inset only. The gutter between two columns is the
        // previous cell's right margin plus the next cell's left one, so
        // half an average character on each side buys a full character of
        // separation without the row band growing taller.
        let cellPad = cellPadding()
        let minWidths = columnFloors(headers: headers, rows: rows,
                                     cols: cols)
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
            var rowH: CGFloat = scaledBodySize * 1.3
            for c in 0..<cols {
                let txt = c < cells.count ? cells[c] : ""
                let cellW = colWidths[c] - 2 * cellPad
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
                let xL = x + cellPad
                let cellW = colWidths[c] - 2 * cellPad
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
            // Interior column dividers, thinner than the row rules so the
            // grid reads as columns first. The band starts at the previous
            // row's rule (savedY + rowPad) so consecutive rows join into
            // one line, clamped at contentTop for a row that page-broke.
            let bandTop = min(savedY + rowPad, contentTop)
            ctx.setLineWidth(0.25)
            var divider = contentLeft
            for c in 0..<max(cols - 1, 0) {
                divider += colWidths[c]
                ctx.move(to: CGPoint(x: divider, y: bandTop))
                ctx.addLine(to: CGPoint(x: divider, y: y))
            }
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
            var runFont = styledRunFont(intent: intent, base: base,
                                        size: baseSize,
                                        additionalBold: bold)
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: textColor,
            ]
            if let level = run[ScriptAttribute.self] {
                let script = scriptRunFont(level, base: runFont)
                runFont = script.font
                attrs[.baselineOffset] = script.offset
            }
            attrs[.font] = runFont
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

    // Measured off the lowercase alphabet rather than asked of the font:
    // a proportional face has no single advance to report, and the letters
    // a reader actually meets are what the gutter should be scaled to.

    private func averageCharWidth(_ font: CTFont) -> CGFloat {
        let sample = "abcdefghijklmnopqrstuvwxyz"
        let attr = NSAttributedString(string: sample,
                                      attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attr)
        let width = CTLineGetBoundsWithOptions(line, []).width
        return width / CGFloat(sample.count)
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

    // Straight into the page context, so the formula is vector in the
    // PDF rather than a picture of one. A page cannot scroll, so a
    // display wider than the column is re-laid at a smaller size --
    // the same concession wide tables make -- and centred once it fits.

    private func drawMath(_ tex: String) {
        let layout = fittedMath(tex)
        if let layout {
            ensureSpace(layout.height + bodySize)
            let slack = contentWidth - layout.width
            let x = contentLeft + max(slack / 2, 0)
            layout.draw(in: ctx, at: CGPoint(x: x, y: y), color: textColor)
            y -= layout.height
        } else {
            drawText(TeX.render(tex, display: true),
                     font: bodyFontItalic(), color: textColor)
        }
    }

    private func fittedMath(_ tex: String) -> MathLayout? {
        let wanted = TeX.displaySize(body: bodySize)
        var result = TeX.layout(tex, size: wanted)
        if let first = result, first.width > contentWidth, first.width > 0 {
            let fitted = wanted * contentWidth / first.width
            result = TeX.layout(tex, size: max(fitted, wanted * 0.5))
        }
        return result
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

    // Padding tracks the type, so shrinking the font on a wide table
    // reclaims its margins too.

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

