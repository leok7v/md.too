import Foundation

enum DocumentText {

    // Blocks separate by paragraph spacing, not by a blank line: a blank
    // line is a full line height and list items are a few points apart, so
    // the two scales never agreed. The spacing is the style's, a fraction
    // of the body size, so it grows with the text.

    static func blockParagraph(_ style: MarkdownStyle)
        -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = style.blockSpacing
        return para
    }

    typealias DocumentImage = PlatformImage

    // Where prose sits on a surface wider than its measure: `inset`
    // points in from the leading edge and `width` points across. Nil
    // means the whole surface is the measure. Tables ignore it and take
    // the surface, which is what lets a wide table break out of the
    // column while the paragraphs around it keep their line length.
    // Both numbers come from the document and the style, never from the
    // viewport, so a window resize leaves the string alone.
    struct Column: Equatable {
        let inset: CGFloat
        let width: CGFloat
    }

    // Keyed by the block's position, so a block that did not change keeps
    // the text it was built into, atomic id included, and the splice into
    // the text view stays O(delta).
    final class RenderCache {
        struct Entry {
            let block: Block
            let style: MarkdownStyle
            let column: Column?
            let images: [URL: ObjectIdentifier]
            // The width a table in the block was laid out for; zero for
            // a block holding none, so a budget change leaves it alone.
            let budget: CGFloat
            // The block as rendered, and the same moved into the column;
            // a column change re-stamps the first, it does not render.
            let plain: NSAttributedString
            let text: NSAttributedString
        }

        struct Minimum {
            let block: Block
            let style: MarkdownStyle
            // A cell holding an image is as wide as the image once it
            // has arrived and as its placeholder text before.
            let images: [URL: ObjectIdentifier]
            let width: CGFloat
        }

        struct Table {
            let block: Block
            let style: MarkdownStyle
            let images: [URL: ObjectIdentifier]
            let cells: TableCells
        }

        var entries: [Int: Entry] = [:]
        var minimums: [Int: Minimum] = [:]
        var tables: [Int: Table] = [:]
    }

    static func attributed(from blocks: [Block],
                           images: [URL: DocumentImage] = [:],
                           cache: RenderCache? = nil,
                           style: MarkdownStyle = .current,
                           budget: CGFloat? = nil,
                           column: Column? = nil)
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        let seen = images.mapValues { image in ObjectIdentifier(image) }
        let measure = budget ?? style.columnWidth
        var live: [Int: RenderCache.Entry] = [:]
        for (i, block) in blocks.enumerated() {
            var entry = cache?.entries[i]
            let owed = tableBudget(block, measure)
            let stale = entry?.block != block ||
                        entry?.style != style || entry?.images != seen ||
                        entry?.budget != owed
            if stale || entry?.column != column {
                let plain = stale
                    ? completed(render(block, at: i, style: style,
                                       images: images, seen: seen,
                                       cache: cache, budget: measure),
                                style: style)
                    : entry?.plain ?? NSAttributedString()
                let wide = column.map { c in
                    minimumWidth(of: block, at: i, style: style,
                                 images: images, seen: seen,
                                 cache: cache) > c.width
                } ?? false
                entry = RenderCache.Entry(
                    block: block, style: style, column: column,
                    images: seen, budget: owed, plain: plain,
                    text: wide ? plain : columned(plain, column: column))
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

    private static func completed(_ text: NSAttributedString,
                                  style: MarkdownStyle)
        -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: text)
        let full = NSRange(location: 0, length: m.length)
        let base = style.bodyFont
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

    // Every paragraph of a block moves into the column by the inset,
    // and every tail ends at the column's far edge. A tail that was
    // measured from the trailing edge, the way a code block's is, keeps
    // its distance from the new edge instead. A block whose minimum
    // exceeds the column never comes here and takes the surface whole.

    private static func columned(_ text: NSAttributedString,
                                 column: Column?) -> NSAttributedString {
        var result = text
        if let column {
            let m = NSMutableAttributedString(attributedString: text)
            move(m, by: column.inset, column: column)
            result = m
        }
        return result
    }

    // Every paragraph in `m` moved right by `amount`: head indents and
    // tab stops together, since a stop is measured from the line's edge
    // and a list item's body sits at one. A table cell goes through the
    // platform's own move, because on macOS an indent on a cell indents
    // inside the cell and the table has to carry the shift itself; one
    // moved table serves every cell of the original. With a column, a
    // paragraph's tail is set to the column's far edge as well.

    // A moved table beside the one it was built from: the original is
    // held so the identity the map is keyed on cannot be recycled while
    // the move is under way.

    struct MovedTable {
        let original: AnyObject
        let moved: AnyObject
    }

    static func move(_ m: NSMutableAttributedString, by amount: CGFloat,
                     column: Column? = nil) {
        let full = NSRange(location: 0, length: m.length)
        var tables: [ObjectIdentifier: MovedTable] = [:]
        m.enumerateAttribute(.paragraphStyle, in: full,
                             options: []) { value, range, _ in
            let kind = m.attribute(atomicKindKey, at: range.location,
                                   effectiveRange: nil) as? String
            let existing = value as? NSParagraphStyle
            let para: NSMutableParagraphStyle
            if kind == AtomicKind.table.rawValue {
                para = movedCell(existing, by: amount, tables: &tables)
            } else {
                para = shifted(existing, by: amount)
                if let column {
                    let trailing = para.tailIndent < 0 ? -para.tailIndent : 0
                    para.tailIndent = column.inset + column.width - trailing
                }
            }
            m.addAttribute(.paragraphStyle, value: para, range: range)
        }
    }

    static func shifted(_ existing: NSParagraphStyle?,
                        by amount: CGFloat) -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        if let existing { para.setParagraphStyle(existing) }
        para.headIndent += amount
        para.firstLineHeadIndent += amount
        para.tabStops = para.tabStops.map { stop in
            NSTextTab(textAlignment: stop.alignment,
                      location: stop.location + amount)
        }
        return para
    }

    // Only a block holding a table reads the budget, so only such a
    // block's cache entry is keyed on it.

    private static func tableBudget(_ block: Block,
                                    _ budget: CGFloat) -> CGFloat {
        var result: CGFloat = 0
        switch block {
            case .table:
                result = budget
            case .quote(let inner):
                result = inner.contains { b in tableBudget(b, budget) > 0 }
                    ? budget : 0
            case .list(let items, _):
                result = items.contains { item in
                    item.blocks.contains { b in tableBudget(b, budget) > 0 }
                } ? budget : 0
            default:
                result = 0
        }
        return result
    }

    // A top-level table's cells are built once and read by the measure
    // and the render alike; a table nested in a quote or a list builds
    // its own on the way through render(_:id:images:).

    private static func render(_ block: Block, at i: Int,
                               style: MarkdownStyle,
                               images: [URL: DocumentImage],
                               seen: [URL: ObjectIdentifier],
                               cache: RenderCache?,
                               budget: CGFloat) -> NSAttributedString {
        let result: NSAttributedString
        if let cells = tableCells(of: block, at: i, style: style,
                                  images: images, seen: seen, cache: cache) {
            result = table(cells, id: String(i), style: style,
                           budget: budget)
        } else {
            result = render(block, id: String(i), style: style,
                            images: images, budget: budget)
        }
        return result
    }

    private static func tableCells(of block: Block, at i: Int,
                                   style: MarkdownStyle,
                                   images: [URL: DocumentImage],
                                   seen: [URL: ObjectIdentifier],
                                   cache: RenderCache?) -> TableCells? {
        var result: TableCells? = nil
        if case .table(let headers, let rows, let alignments) = block {
            var known = cache?.tables[i]
            let stale = known?.block != block ||
                        known?.style != style || known?.images != seen
            if stale {
                known = RenderCache.Table(
                    block: block, style: style, images: seen,
                    cells: tableCells(headers: headers, rows: rows,
                                      alignments: alignments,
                                      style: style, images: images))
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
                             cache: RenderCache? = nil,
                             style: MarkdownStyle = .current) -> CGFloat {
        var widest: CGFloat = 0
        let seen = images.mapValues { image in ObjectIdentifier(image) }
        var live: [Int: RenderCache.Minimum] = [:]
        for (i, block) in blocks.enumerated() {
            var known = cache?.minimums[i]
            let stale = known?.block != block || known?.style != style ||
                        known?.images != seen
            if stale {
                known = RenderCache.Minimum(
                    block: block, style: style, images: seen,
                    width: minimumWidth(of: block, at: i, style: style,
                                        images: images, seen: seen,
                                        cache: cache))
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
                                     style: MarkdownStyle,
                                     images: [URL: DocumentImage],
                                     seen: [URL: ObjectIdentifier],
                                     cache: RenderCache?) -> CGFloat {
        let result: CGFloat
        if let cells = tableCells(of: block, at: i, style: style,
                                  images: images, seen: seen, cache: cache) {
            result = tableMinimumWidth(cells)
        } else {
            result = minimumWidth(ofBlock: block, style: style,
                                  images: images)
        }
        return result
    }

    private static func widestMinimum(in blocks: [Block],
                                      style: MarkdownStyle,
                                      images: [URL: DocumentImage])
        -> CGFloat {
        var widest: CGFloat = 0
        for block in blocks {
            let w = minimumWidth(ofBlock: block, style: style,
                                 images: images)
            if w > widest { widest = w }
        }
        return widest
    }

    private static func minimumWidth(ofBlock block: Block,
                                     style: MarkdownStyle,
                                     images: [URL: DocumentImage])
        -> CGFloat {
        var result: CGFloat = 0
        switch block {
            case .table(let headers, let rows, let alignments):
                result = tableMinimumWidth(headers: headers, rows: rows,
                                           alignments: alignments,
                                           style: style, images: images)
            case .math(let tex):
                result = mathMinimumWidth(tex, style: style)
            case .quote(let inner):
                result = indented(widestMinimum(in: inner, style: style,
                                                images: images),
                                  by: style.quoteIndent)
            case .list(let items, _):
                for item in items {
                    let w = indented(widestMinimum(in: item.blocks,
                                                   style: style,
                                                   images: images),
                                     by: style.listIndent)
                    if w > result { result = w }
                }
            default:
                result = 0
        }
        return result
    }

    // A formula has no line breaks to give, so it scales to the line it
    // is offered, down to half its size; past that the surface widens
    // to hold it, the same bargain the tables strike.
    //
    // Wide enough for the copy button too. The paragraph is centred, so
    // the slack is split between the two margins and a gutter on the
    // right costs the same on the left; without it, a formula that
    // exactly fills the surface leaves the button sitting on top of it.

    private static func mathMinimumWidth(_ tex: String,
                                         style: MarkdownStyle) -> CGFloat {
        let size = TeX.displaySize(body: style.bodySize)
        var result: CGFloat = 0
        if let layout = TeX.layout(tex, size: size) {
            result = ceil(layout.width * mathFloor) + mathSlack
        }
        return result
    }

    private static var mathFloor: CGFloat { 0.5 }

    // The copy button's gutter on both sides of a display, plus air.
    private static var mathSlack: CGFloat { 8 + copyButtonGutter * 2 }

    // The size a display draws at on a line `available` wide: its own
    // when it fits, else scaled down to fit, never below half.

    static func mathFit(natural: CGSize, available: CGFloat) -> CGSize {
        var scale: CGFloat = 1
        if natural.width > available {
            scale = max(available / natural.width, mathFloor)
        }
        return CGSize(width: natural.width * scale,
                      height: natural.height * scale)
    }

    // The room a display has on a line: the line less the slack the
    // minimum asked for.

    static func mathRoom(in lineWidth: CGFloat) -> CGFloat {
        lineWidth - mathSlack
    }

    // An indent only widens a document that had something to widen it;
    // a quote full of prose still asks for nothing.

    private static func indented(_ inner: CGFloat,
                                 by amount: CGFloat) -> CGFloat {
        inner > 0 ? inner + amount : 0
    }

    static func tableMinimumWidth(headers: [String], rows: [[String]],
                                  alignments: [Alignment],
                                  style: MarkdownStyle,
                                  images: [URL: DocumentImage] = [:])
        -> CGFloat {
        tableMinimumWidth(tableCells(headers: headers, rows: rows,
                                     alignments: alignments,
                                     style: style, images: images))
    }

    static func table(headers: [String], rows: [[String]],
                      alignments: [Alignment], id: String,
                      style: MarkdownStyle,
                      images: [URL: DocumentImage],
                      budget: CGFloat) -> NSAttributedString {
        table(tableCells(headers: headers, rows: rows,
                         alignments: alignments, style: style,
                         images: images),
              id: id, style: style, budget: budget)
    }

    // Air on either side of a cell's text. The widths the layout hands a
    // table are content widths; the cells add this to each side.

    static func cellPadding(_ style: MarkdownStyle) -> CGFloat {
        (style.bodySize * 0.5).rounded()
    }

    // The copy button sits inside the header band at the table's right
    // edge, the way a code block's does, so the last column keeps this
    // much clear past its text and the table's budget pays for it.

    static var tableButtonRoom: CGFloat { copyButtonGutter + 4 }

    static func tableMinimumWidth(_ cells: TableCells) -> CGFloat {
        cells.minimums.reduce(0, +) +
            cellPadding(cells.style) * 2 * CGFloat(cells.cols) +
            tableButtonRoom
    }

    // The content width of each column inside `budget`: the naturals
    // when they fit, so a narrow table stays narrow; otherwise shared
    // out and wrapped; otherwise the minimums, and the surface widens.

    static func tableWidths(_ cells: TableCells,
                            budget: CGFloat) -> [CGFloat] {
        let taken = cellPadding(cells.style) * 2 * CGFloat(cells.cols) +
                    tableButtonRoom
        return TableMetrics.columnLayout(headers: cells.headers,
                                         rows: cells.rows,
                                         naturals: cells.naturals,
                                         minimums: cells.minimums,
                                         available: max(budget - taken, 0))
    }

    struct TableCell {
        let text: NSAttributedString
        let minimum: CGFloat
        let natural: CGFloat
    }

    struct TableCells {
        let headers: [String]
        let rows: [[String]]
        let alignments: [Alignment]
        let style: MarkdownStyle
        let cols: Int
        let header: [TableCell]
        let body: [[TableCell]]
        let minimums: [CGFloat]
        let naturals: [CGFloat]

        // The column's alignment, or leading where the row said nothing.

        func alignment(_ col: Int) -> Alignment {
            col < alignments.count ? alignments[col] : .none
        }
    }

    static func tableCells(headers: [String], rows: [[String]],
                           alignments: [Alignment], style: MarkdownStyle,
                           images: [URL: DocumentImage]) -> TableCells {
        let body = style.bodyFont
        let bold = boldFont(of: body)
        let cols = max(headers.count, rows.map { r in r.count }.max() ?? 0)
        let header = headers.map { cell in
            tableCell(cell, base: bold, style: style, images: images)
        }
        let built = rows.map { row in
            row.map { cell in
                tableCell(cell, base: body, style: style, images: images)
            }
        }
        var minimums = [CGFloat](repeating: 0, count: cols)
        var naturals = [CGFloat](repeating: 0, count: cols)
        for row in [header] + built {
            for (c, cell) in row.enumerated() where c < cols {
                if cell.minimum > minimums[c] { minimums[c] = cell.minimum }
                if cell.natural > naturals[c] { naturals[c] = cell.natural }
            }
        }
        return TableCells(headers: headers, rows: rows,
                          alignments: alignments, style: style, cols: cols,
                          header: header, body: built,
                          minimums: minimums.map { w in ceil(w) },
                          naturals: naturals.map { w in ceil(w) })
    }

    // The minimum is the widest token the cell will DRAW, not the markdown
    // that was typed: a link shows its label, not its href, and a cell
    // holding an image shows no words at all. Measuring the source instead
    // turns one image URL into a demand for two thousand points.

    static func tableCell(_ text: String, base: PlatformFont,
                          style: MarkdownStyle,
                          images: [URL: DocumentImage]) -> TableCell {
        let m = NSMutableAttributedString()
        if let first = Markdown.parseCell(text).first {
            switch first {
                case .image(let alt, let url, let w, let h):
                    appendImage(alt: alt, url: url, width: w, height: h,
                                base: base, images: images, into: m)
                case .paragraph(let attr):
                    translateInline(attr, base: base, style: style, into: m)
                default:
                    m.append(NSAttributedString(
                        string: text,
                        attributes: [
                            .font: base,
                            .foregroundColor: platformDefaultTextColor,
                        ]))
            }
        }
        let extent = cellExtent(m)
        return TableCell(text: m, minimum: extent.minimum,
                         natural: extent.natural)
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

    // Measured on the cell as drawn, in the faces it draws in, so a bold
    // header or an italic word claims the room it takes: the widest line
    // is the natural, the widest unbreakable run the minimum. An
    // attachment is counted at its own width on top, since CoreText
    // sees only the replacement character it stands in. The point of
    // slack is not decoration: the typographic width and TextKit's
    // wrapping decision disagree by a fraction, enough for a column
    // sized to the report to break the very run it was sized for.

    private static func cellExtent(_ m: NSAttributedString)
        -> (minimum: CGFloat, natural: CGFloat) {
        let text = m.string as NSString
        var minimum: CGFloat = 0
        var natural: CGFloat = 0
        for run in TableMetrics.unbreakableRuns(text) {
            let w = spanWidth(m, run)
            if w > minimum { minimum = w }
        }
        var start = 0
        for i in 0...text.length {
            if i == text.length || text.character(at: i) == 0x2028 {
                let w = spanWidth(m, NSRange(location: start,
                                             length: i - start))
                if w > natural { natural = w }
                start = i + 1
            }
        }
        return (minimum: ceil(minimum) + 1, natural: ceil(natural) + 1)
    }

    private static func spanWidth(_ m: NSAttributedString,
                                  _ range: NSRange) -> CGFloat {
        let span = m.attributedSubstring(from: range)
        let line = CTLineCreateWithAttributedString(span)
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        span.enumerateAttribute(.attachment,
                                in: NSRange(location: 0, length: span.length),
                                options: []) { value, _, _ in
            if let attachment = value as? NSTextAttachment {
                width += attachmentWidth(attachment)
            }
        }
        return width
    }

    private static func render(_ block: Block, id: String,
                               style: MarkdownStyle,
                               images: [URL: DocumentImage],
                               budget: CGFloat)
                               -> NSAttributedString {
        var result: NSAttributedString
        switch block {
            case .paragraph(let attr):
                result = paragraph(attr, style: style)
            case .heading(let level, let attr):
                result = heading(level: level, text: attr, style: style)
            case .code(let lang, let text):
                result = code(language: lang, text: text, id: id,
                              style: style)
            case .quote(let inner):
                result = quote(inner, id: id, style: style, images: images,
                               budget: budget)
            case .list(let items, let tight):
                result = list(items: items, tight: tight, depth: 0, id: id,
                              style: style, images: images, budget: budget)
            case .table(let headers, let rows, let alignments):
                result = table(headers: headers, rows: rows,
                               alignments: alignments, id: id,
                               style: style, images: images,
                               budget: budget)
            case .math(let tex):
                result = math(tex, id: id, style: style)
            case .rule:
                result = rule(style: style)
            case .image(let alt, let url, let w, let h):
                result = image(alt: alt, url: url, width: w, height: h,
                               id: id, style: style, images: images)
        }
        return result
    }

    // A display sits in its own centred paragraph, carrying the TeX it
    // came from on atomicCopyKey so Copy yields the formula rather than
    // the object-replacement character an attachment would otherwise
    // hand over. Same contract as a code fence or a table, so the copy
    // overlay needs nothing new.

    private static func math(_ tex: String, id: String,
                             style: MarkdownStyle) -> NSAttributedString {
        let base = style.bodyFont
        let m = NSMutableAttributedString()
        let size = TeX.displaySize(body: style.bodySize)
        if let layout = TeX.layout(tex, size: size) {
            m.append(NSAttributedString(
                attachment: mathAttachment(layout, scalesToLine: true)))
        } else {
            translateInline(TeX.render(tex, display: true), base: base,
                            style: style, into: m)
        }
        let content = NSRange(location: 0, length: m.length)
        m.addAttribute(atomicKindKey,
                       value: AtomicKind.math.rawValue, range: content)
        m.addAttribute(atomicIdKey, value: id, range: content)
        m.addAttribute(atomicCopyKey, value: tex, range: content)
        m.append(NSAttributedString(string: "\n"))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = style.blockSpacing
        para.paragraphSpacingBefore = style.blockSpacing
        m.addAttribute(.paragraphStyle, value: para,
                       range: NSRange(location: 0, length: m.length))
        return m
    }

    private static func quote(_ blocks: [Block], id: String,
                              style: MarkdownStyle,
                              images: [URL: DocumentImage],
                              budget: CGFloat)
                              -> NSAttributedString {
        let m = NSMutableAttributedString()
        for (i, inner) in blocks.enumerated() {
            m.append(render(inner, id: id + "." + String(i), style: style,
                            images: images,
                            budget: budget - style.quoteIndent))
        }
        move(m, by: style.quoteIndent)
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(.backgroundColor,
                       value: platformWhite(0.5, alpha: 0.06),
                       range: full)
        return m
    }

    private static func list(items: [ListItem], tight: Bool, depth: Int,
                             id: String, style: MarkdownStyle,
                             images: [URL: DocumentImage],
                             budget: CGFloat)
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        let indent = CGFloat(depth + 1) * style.listIndent
        for (idx, item) in items.enumerated() {
            let para = NSMutableParagraphStyle()
            para.headIndent = indent
            para.firstLineHeadIndent = indent - style.listIndent
            para.tabStops = [NSTextTab(textAlignment: .left,
                                       location: indent)]
            // Only between items: TextKit adds spacing-before to the
            // previous paragraph's spacing-after, so a first item with
            // one would sit twice as far under the block above it.
            para.paragraphSpacing = style.itemSpacing(tight: tight)
            para.paragraphSpacingBefore = idx == 0
                ? 0 : style.itemSpacing(tight: tight)
            if idx == items.count - 1, depth == 0 {
                para.paragraphSpacing = style.blockSpacing
            }
            m.append(listItem(item, para: para, tight: tight,
                              depth: depth, id: id + "." + String(idx),
                              style: style, images: images,
                              budget: budget))
        }
        return m
    }

    private static func listItem(_ item: ListItem, para: NSParagraphStyle,
                                 tight: Bool, depth: Int, id: String,
                                 style: MarkdownStyle,
                                 images: [URL: DocumentImage],
                                 budget: CGFloat)
        -> NSAttributedString {
        let marker: String
        if let c = item.checked {
            marker = c ? "\u{2611}" : "\u{2610}"
        } else {
            marker = item.marker
        }
        let prefix: [NSAttributedString.Key: Any] = [
            .font: style.bodyFont,
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
                    translateInline(attr, base: style.bodyFont,
                                    style: style, into: body)
                    let r = NSRange(location: 0, length: body.length)
                    body.addAttribute(.paragraphStyle, value: para,
                                      range: r)
                    line.append(body)
                    headHandled = true
                case .list(let inner, let innerTight):
                    line.append(list(items: inner, tight: innerTight,
                                     depth: depth + 1, id: id + ".0",
                                     style: style, images: images,
                                     budget: budget))
                    headHandled = true
                default:
                    break
            }
        }
        let contIndent = para.headIndent
        if !headHandled, let first = item.blocks.first {
            let rendered = NSMutableAttributedString(
                attributedString: render(first, id: id + ".0", style: style,
                                         images: images,
                                         budget: budget - contIndent))
            move(rendered, by: contIndent)
            line.append(rendered)
        }
        line.append(NSAttributedString(string: "\n"))
        for (k, rest) in item.blocks.enumerated().dropFirst() {
            let restId = id + "." + String(k)
            if case .list(let inner, let innerTight) = rest {
                line.append(list(items: inner, tight: innerTight,
                                 depth: depth + 1, id: restId,
                                 style: style, images: images,
                                 budget: budget))
            } else {
                let rendered = NSMutableAttributedString(
                    attributedString: render(rest, id: restId, style: style,
                                             images: images,
                                             budget: budget - contIndent))
                move(rendered, by: contIndent)
                line.append(rendered)
            }
        }
        return line
    }

    private static func image(alt: String, url: URL, width: CGFloat?,
                              height: CGFloat?, id: String,
                              style: MarkdownStyle,
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
            m.addAttribute(.paragraphStyle, value: blockParagraph(style),
                           range: full)
            m.append(NSAttributedString(string: "\n"))
            result = m
        } else {
            let label = alt.isEmpty ? url.absoluteString : alt
            let attrs: [NSAttributedString.Key: Any] = [
                .font: style.bodyFont,
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

    // The tint is painted by the bridge over the block's line fragments,
    // not carried as a glyph background, so it reaches the padding the
    // text is indented by and rounds its corners. Every code line is its
    // own paragraph, so only the first carries the space above and only
    // the last the space below; the lines between sit flush.

    private static func code(language: String?, text: String, id: String,
                             style: MarkdownStyle) -> NSAttributedString {
        let baseFont = style.codeFont
        let highlighted = Highlight.attribute(text, language: language,
                                              baseFont: baseFont)
        let m = NSMutableAttributedString(attributedString: highlighted)
        m.append(NSAttributedString(string: "\n",
                                    attributes: [.font: baseFont]))
        let ns = m.string as NSString
        var lineStart = 0
        while lineStart < ns.length {
            let line = ns.lineRange(for: NSRange(location: lineStart,
                                                 length: 0))
            let para = NSMutableParagraphStyle()
            para.firstLineHeadIndent = style.codePadding
            para.headIndent = style.codePadding
            para.tailIndent = -style.codePadding
            if lineStart == 0 {
                para.paragraphSpacingBefore = style.codePadding / 2
            }
            if NSMaxRange(line) >= ns.length {
                para.paragraphSpacing = style.codePadding / 2 +
                                        style.blockSpacing
            }
            m.addAttribute(.paragraphStyle, value: para, range: line)
            lineStart = NSMaxRange(line)
        }
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(atomicKindKey,
                       value: AtomicKind.code.rawValue, range: full)
        m.addAttribute(atomicIdKey, value: id, range: full)
        m.addAttribute(atomicCopyKey, value: text, range: full)
        // The badge shows the language alone: an info string may carry
        // more (`python title=x`) and the first word is the name.
        if let word = language?.split(separator: " ").first {
            m.addAttribute(atomicLabelKey, value: String(word), range: full)
        }
        return m
    }

    private static func paragraph(_ attr: AttributedString,
                                  style: MarkdownStyle)
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        translateInline(attr, base: style.bodyFont, style: style, into: m)
        let para = blockParagraph(style)
        para.alignment = textAlignment(attr)
        m.addAttribute(.paragraphStyle, value: para,
                       range: NSRange(location: 0, length: m.length))
        m.append(NSAttributedString(string: "\n"))
        return m
    }

    private static func heading(level: Int, text: AttributedString,
                                style: MarkdownStyle)
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        translateInline(text, base: style.headingFont(level), style: style,
                        into: m)
        let para = blockParagraph(style)
        para.paragraphSpacingBefore = style.headingSpacingBefore(level)
        para.paragraphSpacing = style.headingSpacingAfter(level)
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

    // A drawn line the width of the column, not a run of box-drawing
    // glyphs: the attachment asks TextKit for its line's width and
    // draws a hairline across it. Copy gives back the "---" it was.

    private static func rule(style: MarkdownStyle) -> NSAttributedString {
        let m = NSMutableAttributedString(
            attachment: ruleAttachment(height: style.blockSpacing * 2))
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(.font, value: style.bodyFont, range: full)
        m.addAttribute(atomicCopyKey, value: "---", range: full)
        m.addAttribute(.paragraphStyle, value: blockParagraph(style),
                       range: full)
        m.append(NSAttributedString(string: "\n"))
        return m
    }

    // A run carrying TeX becomes the typeset formula on the baseline at
    // the run's own size, when the style asks for it and the engine
    // accepts the formula; otherwise the Unicode spelling it already
    // holds. The formula takes the run's attributes, so a small, struck
    // or linked formula is small, struck or linked, and carries the
    // source on atomicCopyKey so a copy gives it back as typed.

    private static func translateInline(_ attr: AttributedString,
                                        base: PlatformFont,
                                        style: MarkdownStyle,
                                        into m: NSMutableAttributedString) {
        for run in attr.runs {
            let segment = String(attr[run.range].characters)
            let attrs = runAttributes(run, base: base)
            let source = style.typesetInlineMath
                ? run[InlineMathAttribute.self] : nil
            let size = (attrs[.font] as? PlatformFont)?.pointSize ??
                       base.pointSize
            let layout = source.flatMap { tex in
                TeX.layout(TeX.undelimited(tex), size: size, display: false)
            }
            if let source, let layout {
                let formula = NSMutableAttributedString(
                    attachment: mathAttachment(layout, inset: 1,
                                               scalesToLine: false))
                let full = NSRange(location: 0, length: formula.length)
                formula.addAttributes(attrs, range: full)
                formula.addAttribute(atomicCopyKey, value: source,
                                     range: full)
                m.append(formula)
            } else {
                m.append(NSAttributedString(string: segment,
                                            attributes: attrs))
            }
        }
    }

    private static func runAttributes(_ run: AttributedString.Runs.Run,
                                      base: PlatformFont)
        -> [NSAttributedString.Key: Any] {
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
        return attrs
    }

}
