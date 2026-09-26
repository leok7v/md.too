import Foundation

enum DocumentText {

    // Blocks separate by paragraph spacing, not by a blank line: a blank
    // line is a full line height and list items are a few points apart, so
    // the two scales never agreed.
    static let blockSpacing: CGFloat = 6

    static func blockParagraph() -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = blockSpacing
        return para
    }

    typealias DocumentImage = PlatformImage

    // Keyed by the block's position, so a block that did not change keeps
    // the text it was built into, atomic id included, and the splice into
    // the text view stays O(delta).
    final class RenderCache {
        struct Entry {
            let block: Block
            let bodySize: CGFloat
            let images: [URL: ObjectIdentifier]
            let text: NSAttributedString
        }

        struct Minimum {
            let block: Block
            let bodySize: CGFloat
            let width: CGFloat
        }

        struct Table {
            let block: Block
            let bodySize: CGFloat
            let images: [URL: ObjectIdentifier]
            let cells: TableCells
        }

        var entries: [Int: Entry] = [:]
        var minimums: [Int: Minimum] = [:]
        var tables: [Int: Table] = [:]
    }

    static func attributed(from blocks: [Block],
                           images: [URL: DocumentImage] = [:],
                           cache: RenderCache? = nil)
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        let bodySize = FontRole.body.platformFont.pointSize
        let seen = images.mapValues { image in ObjectIdentifier(image) }
        var live: [Int: RenderCache.Entry] = [:]
        for (i, block) in blocks.enumerated() {
            var entry = cache?.entries[i]
            let stale = entry?.block != block ||
                        entry?.bodySize != bodySize || entry?.images != seen
            if stale {
                entry = RenderCache.Entry(
                    block: block, bodySize: bodySize, images: seen,
                    text: completed(render(block, at: i, images: images,
                                           seen: seen, cache: cache)))
            }
            if let entry {
                live[i] = entry
                m.append(entry.text)
            }
        }
        if let cache {
            cache.entries = live
            cache.tables = cache.tables.filter { pair in
                live[pair.key] != nil
            }
        }
        return m
    }

    // Every run leaves here with a font and a colour, so the text view
    // takes the string as it is: the separators and the attachments the
    // builders append bare would otherwise fall to TextKit's defaults.

    private static func completed(_ text: NSAttributedString)
        -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: m.length)
        let base = FontRole.body.platformFont
        m.enumerateAttribute(.font, in: full, options: []) { value, r, _ in
            if value == nil { m.addAttribute(.font, value: base, range: r) }
        }
        m.enumerateAttribute(.foregroundColor, in: full,
                             options: []) { value, r, _ in
            if value == nil {
                m.addAttribute(.foregroundColor,
                               value: platformDefaultTextColor, range: r)
            }
        }
        return m
    }

    // A top-level table's cells are built once and read by the measure
    // and the render alike; a table nested in a quote or a list builds
    // its own on the way through render(_:id:images:).

    private static func render(_ block: Block, at i: Int,
                               images: [URL: DocumentImage],
                               seen: [URL: ObjectIdentifier],
                               cache: RenderCache?) -> NSAttributedString {
        let result: NSAttributedString
        if let cells = tableCells(of: block, at: i, images: images,
                                  seen: seen, cache: cache) {
            result = table(cells, id: String(i))
        } else {
            result = render(block, id: String(i), images: images)
        }
        return result
    }

    private static func tableCells(of block: Block, at i: Int,
                                   images: [URL: DocumentImage],
                                   seen: [URL: ObjectIdentifier],
                                   cache: RenderCache?) -> TableCells? {
        var result: TableCells? = nil
        if case .table(let headers, let rows, let alignments) = block {
            let bodySize = FontRole.body.platformFont.pointSize
            var known = cache?.tables[i]
            let stale = known?.block != block ||
                        known?.bodySize != bodySize || known?.images != seen
            if stale {
                known = RenderCache.Table(
                    block: block, bodySize: bodySize, images: seen,
                    cells: tableCells(headers: headers, rows: rows,
                                      alignments: alignments,
                                      images: images))
                cache?.tables[i] = known
            }
            result = known?.cells
        }
        return result
    }

    // The narrowest this document can be drawn before a table or a
    // formula is asked for less room than its content can occupy. One
    // text view holds the whole document, so there is no per-block
    // escape here the way the block renderer has: the answer is a single
    // width for everything, and the caller scrolls horizontally when the
    // viewport is smaller. Zero for a document with neither, which is
    // the common case and leaves the text width-aligned to the window.

    static func minimumWidth(of blocks: [Block],
                             images: [URL: DocumentImage] = [:],
                             cache: RenderCache? = nil) -> CGFloat {
        var widest: CGFloat = 0
        let bodySize = FontRole.body.platformFont.pointSize
        let seen = images.mapValues { image in ObjectIdentifier(image) }
        var live: [Int: RenderCache.Minimum] = [:]
        for (i, block) in blocks.enumerated() {
            var known = cache?.minimums[i]
            let stale = known?.block != block || known?.bodySize != bodySize
            if stale {
                known = RenderCache.Minimum(
                    block: block, bodySize: bodySize,
                    width: minimumWidth(of: block, at: i, images: images,
                                        seen: seen, cache: cache))
            }
            if let known {
                live[i] = known
                if known.width > widest { widest = known.width }
            }
        }
        cache?.minimums = live
        return widest
    }

    private static func minimumWidth(of block: Block, at i: Int,
                                     images: [URL: DocumentImage],
                                     seen: [URL: ObjectIdentifier],
                                     cache: RenderCache?) -> CGFloat {
        let result: CGFloat
        if let cells = tableCells(of: block, at: i, images: images,
                                  seen: seen, cache: cache) {
            result = tableMinimumWidth(cells)
        } else {
            result = minimumWidth(ofBlock: block)
        }
        return result
    }

    private static func widestMinimum(in blocks: [Block]) -> CGFloat {
        var widest: CGFloat = 0
        for block in blocks {
            let w = minimumWidth(ofBlock: block)
            if w > widest { widest = w }
        }
        return widest
    }

    private static func minimumWidth(ofBlock block: Block) -> CGFloat {
        var result: CGFloat = 0
        switch block {
            case .table(let headers, let rows, _):
                result = tableMinimumWidth(headers: headers, rows: rows)
            case .math(let tex):
                result = mathMinimumWidth(tex)
            case .quote(let inner):
                result = indented(widestMinimum(in: inner), by: 18)
            case .list(let items, _):
                for item in items {
                    let w = indented(widestMinimum(in: item.blocks), by: 20)
                    if w > result { result = w }
                }
            default:
                result = 0
        }
        return result
    }

    // A formula has no line breaks to give and the single surface has
    // no way to scroll one on its own, so the surface has to be wide
    // enough to hold it whole -- the same bargain the tables strike.
    //
    // Wide enough for the copy button too. The paragraph is centred, so
    // the slack is split between the two margins and a gutter on the
    // right costs the same on the left; without it, a formula that
    // exactly fills the surface leaves the button sitting on top of it.

    private static func mathMinimumWidth(_ tex: String) -> CGFloat {
        let base = FontRole.body.platformFont
        let size = TeX.displaySize(body: base.pointSize)
        var result: CGFloat = 0
        if let layout = TeX.layout(tex, size: size) {
            result = ceil(layout.width) + 8 + copyButtonGutter * 2
        }
        return result
    }

    // An indent only widens a document that had something to widen it;
    // a quote full of prose still asks for nothing.

    private static func indented(_ inner: CGFloat,
                                 by amount: CGFloat) -> CGFloat {
        inner > 0 ? inner + amount : 0
    }

    static func tableMinimumWidth(headers: [String],
                                  rows: [[String]]) -> CGFloat {
        tableMinimumWidth(tableCells(headers: headers, rows: rows,
                                     alignments: [], images: [:]))
    }

    static func table(headers: [String], rows: [[String]],
                      alignments: [Alignment], id: String,
                      images: [URL: DocumentImage]) -> NSAttributedString {
        table(tableCells(headers: headers, rows: rows,
                         alignments: alignments, images: images),
              id: id)
    }

    struct TableCell {
        let text: NSAttributedString
        let minimum: CGFloat
    }

    struct TableCells {
        let headers: [String]
        let rows: [[String]]
        let alignments: [Alignment]
        let cols: Int
        let header: [TableCell]
        let body: [[TableCell]]
        let minimums: [CGFloat]

        // The column's alignment, or leading where the row said nothing.

        func alignment(_ col: Int) -> Alignment {
            col < alignments.count ? alignments[col] : .none
        }
    }

    static func tableCells(headers: [String], rows: [[String]],
                           alignments: [Alignment],
                           images: [URL: DocumentImage]) -> TableCells {
        let body = FontRole.body.platformFont
        let bold = boldFont(of: body)
        let cols = max(headers.count, rows.map { r in r.count }.max() ?? 0)
        let header = headers.map { cell in
            tableCell(cell, base: bold, images: images)
        }
        let built = rows.map { row in
            row.map { cell in tableCell(cell, base: body, images: images) }
        }
        var minimums = [CGFloat](repeating: 0, count: cols)
        for row in [header] + built {
            for (c, cell) in row.enumerated() where c < cols {
                if cell.minimum > minimums[c] { minimums[c] = cell.minimum }
            }
        }
        return TableCells(headers: headers, rows: rows,
                          alignments: alignments, cols: cols,
                          header: header, body: built,
                          minimums: minimums.map { w in ceil(w) })
    }

    // The minimum is the widest token the cell will DRAW, not the markdown
    // that was typed: a link shows its label, not its href, and a cell
    // holding an image shows no words at all. Measuring the source instead
    // turns one image URL into a demand for two thousand points.

    static func tableCell(_ text: String, base: PlatformFont,
                          images: [URL: DocumentImage]) -> TableCell {
        let m = NSMutableAttributedString()
        var drawn = TeX.scriptsToUnicode(text)
        if let first = Markdown.parseCell(text).first {
            switch first {
                case .image(let alt, let url, let w, let h):
                    appendImage(alt: alt, url: url, width: w, height: h,
                                base: base, images: images, into: m)
                    drawn = ""
                case .paragraph(let attr):
                    translateInline(attr, base: base, into: m)
                    drawn = String(attr.characters)
                default:
                    m.append(NSAttributedString(
                        string: text,
                        attributes: [
                            .font: base,
                            .foregroundColor: platformDefaultTextColor,
                        ]))
            }
        }
        return TableCell(text: m,
                         minimum: longestWordWidth(drawn, font: base))
    }

    private static func appendImage(alt: String, url: URL, width: CGFloat?,
                                    height: CGFloat?, base: PlatformFont,
                                    images: [URL: DocumentImage],
                                    into m: NSMutableAttributedString) {
        if let img = images[url] {
            let attachment = NSTextAttachment()
            attachment.image = img
            attachment.bounds = imageBounds(img, width: width,
                                            height: height)
            m.append(NSAttributedString(attachment: attachment))
        } else {
            let label = alt.isEmpty ? url.absoluteString : alt
            m.append(NSAttributedString(
                string: "[Image: \(label)]",
                attributes: [
                    .font: base,
                    .foregroundColor: platformSecondaryColor,
                ]))
        }
    }

    // Measured against the WIDEST face the cell could end up in, not the
    // one it probably will. A run marked as code becomes monospaced and
    // one marked strong becomes bold, either of which outgrows the plain
    // body face -- and a token that outgrows its column is exactly the
    // thing this number exists to prevent.

    private static func longestWordWidth(_ drawn: String,
                                         font: PlatformFont) -> CGFloat {
        var widest: CGFloat = 0
        let faces = widestFaces(of: font)
        for word in drawn.split(separator: " ") {
            let ns = String(word) as NSString
            for face in faces {
                let w = ns.size(withAttributes: [.font: face]).width
                if w > widest { widest = w }
            }
        }
        return widest
    }

    private static func widestFaces(of base: PlatformFont)
        -> [PlatformFont] {
        [platformBoldItalicFont(of: base, bold: true, italic: true),
         monoFont(at: base.pointSize)]
    }

    private static func render(_ block: Block, id: String,
                               images: [URL: DocumentImage])
                               -> NSAttributedString {
        var result: NSAttributedString
        switch block {
            case .paragraph(let attr):
                result = paragraph(attr)
            case .heading(let level, let attr):
                result = heading(level: level, text: attr)
            case .code(let lang, let text):
                result = code(language: lang, text: text, id: id)
            case .quote(let inner):
                result = quote(inner, id: id, images: images)
            case .list(let items, let tight):
                result = list(items: items, tight: tight, depth: 0, id: id,
                              images: images)
            case .table(let headers, let rows, let alignments):
                result = table(headers: headers, rows: rows,
                               alignments: alignments, id: id,
                               images: images)
            case .math(let tex):
                result = math(tex, id: id)
            case .rule:
                result = rule()
            case .image(let alt, let url, let w, let h):
                result = image(alt: alt, url: url, width: w, height: h,
                               id: id, images: images)
        }
        return result
    }

    // A display sits in its own centred paragraph, carrying the TeX it
    // came from on atomicCopyKey so Copy yields the formula rather than
    // the object-replacement character an attachment would otherwise
    // hand over. Same contract as a code fence or a table, so the copy
    // overlay needs nothing new.

    private static func math(_ tex: String, id: String) -> NSAttributedString {
        let base = FontRole.body.platformFont
        let m = NSMutableAttributedString()
        let size = TeX.displaySize(body: base.pointSize)
        if let layout = TeX.layout(tex, size: size) {
            m.append(NSAttributedString(attachment: mathAttachment(layout)))
        } else {
            translateInline(TeX.render(tex, display: true), base: base,
                            into: m)
        }
        let content = NSRange(location: 0, length: m.length)
        m.addAttribute(atomicKindKey,
                       value: AtomicKind.math.rawValue, range: content)
        m.addAttribute(atomicIdKey, value: id, range: content)
        m.addAttribute(atomicCopyKey, value: tex, range: content)
        m.append(NSAttributedString(string: "\n"))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6
        para.paragraphSpacingBefore = 6
        m.addAttribute(.paragraphStyle, value: para,
                       range: NSRange(location: 0, length: m.length))
        return m
    }

    private static func quote(_ blocks: [Block], id: String,
                              images: [URL: DocumentImage])
                              -> NSAttributedString {
        let m = NSMutableAttributedString()
        for (i, inner) in blocks.enumerated() {
            m.append(render(inner, id: id + "." + String(i), images: images))
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
        m.addAttribute(.backgroundColor,
                       value: platformWhite(0.5, alpha: 0.06),
                       range: full)
        return m
    }

    private static func list(items: [ListItem], tight: Bool, depth: Int,
                             id: String, images: [URL: DocumentImage])
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        let indent = CGFloat(depth + 1) * 20
        for (idx, item) in items.enumerated() {
            let para = NSMutableParagraphStyle()
            para.headIndent = indent
            para.firstLineHeadIndent = indent - 20
            para.tabStops = [NSTextTab(textAlignment: .left,
                                       location: indent)]
            para.paragraphSpacing = tight ? 2 : 8
            para.paragraphSpacingBefore = tight ? 2 : 4
            if idx == items.count - 1, depth == 0 {
                para.paragraphSpacing = blockSpacing
            }
            m.append(listItem(item, para: para, tight: tight,
                              depth: depth, id: id + "." + String(idx),
                              images: images))
        }
        return m
    }

    private static func listItem(_ item: ListItem, para: NSParagraphStyle,
                                 tight: Bool, depth: Int, id: String,
                                 images: [URL: DocumentImage])
        -> NSAttributedString {
        let marker: String
        if let c = item.checked {
            marker = c ? "\u{2611}" : "\u{2610}"
        } else {
            marker = item.marker
        }
        let prefix: [NSAttributedString.Key: Any] = [
            .font: FontRole.body.platformFont,
            .foregroundColor: platformSecondaryColor,
            .paragraphStyle: para,
        ]
        let line = NSMutableAttributedString(
            string: "\(marker)\t", attributes: prefix)
        var headHandled = false
        if let first = item.blocks.first {
            switch first {
                case .paragraph(let attr):
                    let body = NSMutableAttributedString()
                    translateInline(attr, base: FontRole.body.platformFont,
                                          into: body)
                    let r = NSRange(location: 0, length: body.length)
                    body.addAttribute(.paragraphStyle, value: para,
                                      range: r)
                    line.append(body)
                    headHandled = true
                case .list(let inner, let innerTight):
                    line.append(list(items: inner, tight: innerTight,
                                     depth: depth + 1, id: id + ".0",
                                     images: images))
                    headHandled = true
                default:
                    break
            }
        }
        if !headHandled, let first = item.blocks.first {
            line.append(render(first, id: id + ".0", images: images))
        }
        line.append(NSAttributedString(string: "\n"))
        let contIndent = para.headIndent
        for (k, rest) in item.blocks.enumerated().dropFirst() {
            let restId = id + "." + String(k)
            if case .list(let inner, let innerTight) = rest {
                line.append(list(items: inner, tight: innerTight,
                                 depth: depth + 1, id: restId,
                                 images: images))
            } else {
                let rendered = NSMutableAttributedString(
                    attributedString: render(rest, id: restId,
                                             images: images))
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

    private static func image(alt: String, url: URL, width: CGFloat?,
                              height: CGFloat?, id: String,
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
                           value: AtomicKind.image.rawValue, range: full)
            m.addAttribute(atomicIdKey, value: id, range: full)
            m.addAttribute(.paragraphStyle, value: blockParagraph(),
                           range: full)
            m.append(NSAttributedString(string: "\n"))
            result = m
        } else {
            let label = alt.isEmpty ? url.absoluteString : alt
            let attrs: [NSAttributedString.Key: Any] = [
                .font: FontRole.body.platformFont,
                .foregroundColor: platformSecondaryColor,
                atomicKindKey: AtomicKind.image.rawValue,
                atomicIdKey: id,
            ]
            result = NSAttributedString(
                string: "[Image: \(label)]\n\n", attributes: attrs)
        }
        return result
    }

    private static func imageBounds(_ img: DocumentImage,
                                    width: CGFloat?, height: CGFloat?)
                                    -> CGRect {
        let fit = aspectFit(intrinsicWidth: img.size.width,
                            intrinsicHeight: img.size.height,
                            explicitWidth: width,
                            explicitHeight: height,
                            maxWidth: 320)
        return CGRect(x: 0, y: 0, width: fit.width, height: fit.height)
    }

    private static func code(language: String?, text: String, id: String)
                                    -> NSAttributedString {
        let baseFont = monospaceFont()
        let highlighted = Highlight.attribute(text, language: language,
                                              baseFont: baseFont)
        let m = NSMutableAttributedString(attributedString: highlighted)
        // A trailing newline INSIDE the tinted range so the last code
        // line's background paints: NSTextView draws no line-fragment
        // background for a run's final line when it abuts a plain
        // paragraph break.
        if !text.hasSuffix("\n") {
            m.append(NSAttributedString(string: "\n",
                                        attributes: [.font: baseFont]))
        }
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(.backgroundColor,
                       value: platformWhite(0.5, alpha: 0.10), range: full)
        m.addAttribute(atomicKindKey,
                       value: AtomicKind.code.rawValue, range: full)
        m.addAttribute(atomicIdKey, value: id, range: full)
        m.addAttribute(atomicCopyKey, value: text, range: full)
        m.append(NSAttributedString(string: "\n"))
        return m
    }

    // A point under body, and zoomed with it -- the one size here that
    // does not come from FontRole, so it applies the multiplier itself.
    private static func monospaceFont() -> PlatformFont {
        let bodySize = PlatformFont.preferredFont(forTextStyle: .body)
            .pointSize
        return monoFont(at: (bodySize - 1) * Zoom.current)
    }

    private static func paragraph(_ attr: AttributedString)
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        translateInline(attr, base: FontRole.body.platformFont, into: m)
        let para = blockParagraph()
        para.alignment = textAlignment(attr)
        m.addAttribute(.paragraphStyle, value: para,
                       range: NSRange(location: 0, length: m.length))
        m.append(NSAttributedString(string: "\n"))
        return m
    }

    private static func heading(level: Int,
                                text: AttributedString)
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        translateInline(text, base: FontRole.heading(level).platformFont,
                              into: m)
        let para = blockParagraph()
        para.paragraphSpacingBefore = blockSpacing
        para.alignment = textAlignment(text)
        m.addAttribute(.paragraphStyle, value: para,
                       range: NSRange(location: 0, length: m.length))
        m.append(NSAttributedString(string: "\n"))
        return m
    }

    private static func textAlignment(_ attr: AttributedString)
        -> NSTextAlignment {
        attr.runs.first?[AlignAttribute.self] == .center ? .center : .natural
    }

    private static func rule() -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: FontRole.body.platformFont,
            .foregroundColor: platformSecondaryColor,
        ]
        return NSAttributedString(
            string: "\u{2500}\u{2500}\u{2500}\u{2500}" +
                    "\u{2500}\u{2500}\u{2500}\u{2500}\n\n",
            attributes: attrs)
    }

    private static func translateInline(_ attr: AttributedString,
                                        base: PlatformFont,
                                        into m: NSMutableAttributedString) {
        for run in attr.runs {
            let segment = String(attr[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var runFont = styledRunFont(intent: intent, base: base)
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: platformDefaultTextColor,
            ]
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
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if run.underlineStyle != nil {
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link { attrs[.link] = url }
            m.append(NSAttributedString(string: segment, attributes: attrs))
        }
    }

}
