import Foundation

enum DocumentText {

    static func blockParagraph(_ style: MarkdownStyle)
        -> NSMutableParagraphStyle {
        let para = NSMutableParagraphStyle()
        para.paragraphSpacing = style.blockSpacing
        return para
    }

    typealias DocumentImage = PlatformImage

    struct Column: Equatable {
        let inset: CGFloat
        let width: CGFloat
        let surface: CGFloat

        init(inset: CGFloat, width: CGFloat,
             surface: CGFloat = .infinity) {
            self.inset = inset
            self.width = width
            self.surface = surface
        }
    }

    // Keyed by block position, so an unchanged block keeps the text
    // object it was built into and the splice stays O(delta).
    final class RenderCache {
        struct Entry {
            let block: Block
            let style: MarkdownStyle
            let column: Column?
            let images: [URL: ObjectIdentifier]
            // The width a table in the block was laid out for; zero for
            // a block holding none, so a budget change leaves it alone.
            let budget: CGFloat
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
        // Handed back as the same instance while no entry moved, so a
        // host re-render that changed nothing costs no assembly.
        var surface: NSAttributedString? = nil

        // Cached by text equality, so a re-render that leaves the text
        // unchanged costs a string compare, not a parse.
        private var parsedText = ""
        private var parsed: [Block] = []

        func blocks(for text: String) -> [Block] {
            if text != parsedText {
                parsed = Markdown.parse(text)
                parsedText = text
            }
            return parsed
        }
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
            let named = imagesNamed(by: block, in: seen)
            let stale = entry?.block != block ||
                        entry?.style != style || entry?.images != named ||
                        entry?.budget != owed
            if stale || entry?.column != column {
                let plain = stale
                    ? completed(render(block, at: i, style: style,
                                       images: images, seen: named,
                                       cache: cache, budget: measure),
                                style: style)
                    : entry?.plain ?? NSAttributedString()
                let need = column == nil ? 0
                    : minimumWidth(of: block, at: i, style: style,
                                   images: images, seen: named,
                                   cache: cache)
                entry = RenderCache.Entry(
                    block: block, style: style, column: column,
                    images: named, budget: owed, plain: plain,
                    text: column.map { c in
                        placed(plain, need: need, in: c)
                    } ?? plain)
            }
            if let entry {
                live[i] = entry
                m.append(entry.text)
            }
        }
        // An entry that was kept holds the very text object the cache
        // had; one that was rebuilt holds a fresh one.
        let unchanged = live.count == cache?.entries.count &&
            live.allSatisfy { pair in
                pair.value.text === cache?.entries[pair.key]?.text
            }
        let result = unchanged ? cache?.surface ?? m : m
        if let cache {
            cache.entries = live
            cache.tables = cache.tables.filter { pair in
                live[pair.key] != nil
            }
            cache.surface = result
        }
        return result
    }

    // Fills any run the builders left without a font or colour, so the
    // text view never falls back to TextKit's defaults.

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

    private static func placed(_ plain: NSAttributedString, need: CGFloat,
                               in column: Column) -> NSAttributedString {
        var result = plain
        if need <= column.width {
            result = columned(plain, column: column)
        } else {
            let shift = max(min(column.inset, column.surface - need), 0)
            if shift > 0 {
                let m = NSMutableAttributedString(attributedString: plain)
                move(m, by: shift)
                result = m
            }
        }
        return result
    }

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

    // The original is held too, so the identity it's keyed on cannot be
    // freed and reused while the moved table is still in flight.

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

    private static func imagesNamed(by block: Block,
                                    in seen: [URL: ObjectIdentifier])
        -> [URL: ObjectIdentifier] {
        var result: [URL: ObjectIdentifier] = [:]
        for url in ImagePrefetch.collectURLs(in: [block]) {
            if let id = seen[url] { result[url] = id }
        }
        return result
    }

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

    // A top-level table's cells are cached and shared by the measure
    // and the render; a nested table rebuilds its own each time.

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

    // The narrowest the whole document can draw before a table or
    // formula is squeezed below its content; zero when nothing needs one.

    static func minimumWidth(of blocks: [Block],
                             images: [URL: DocumentImage] = [:],
                             cache: RenderCache? = nil,
                             style: MarkdownStyle = .current) -> CGFloat {
        var widest: CGFloat = 0
        let seen = images.mapValues { image in ObjectIdentifier(image) }
        var live: [Int: RenderCache.Minimum] = [:]
        for (i, block) in blocks.enumerated() {
            var known = cache?.minimums[i]
            let named = imagesNamed(by: block, in: seen)
            let stale = known?.block != block || known?.style != style ||
                        known?.images != named
            if stale {
                known = RenderCache.Minimum(
                    block: block, style: style, images: named,
                    width: minimumWidth(of: block, at: i, style: style,
                                        images: images, seen: named,
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

    // Doubled because the centred paragraph splits slack across both
    // margins; a button on the right costs room on the left too.

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

    static func mathFit(natural: CGSize, available: CGFloat) -> CGSize {
        var scale: CGFloat = 1
        if natural.width > available {
            scale = max(available / natural.width, mathFloor)
        }
        return CGSize(width: natural.width * scale,
                      height: natural.height * scale)
    }

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

    static var tableButtonRoom: CGFloat { copyButtonGutter + 4 }

    static func tableMinimumWidth(_ cells: TableCells) -> CGFloat {
        cells.minimums.reduce(0, +) +
            cellPadding(cells.style) * 2 * CGFloat(cells.cols) +
            tableButtonRoom
    }

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

    // Minimum is the widest DRAWN token, not the markdown source: a
    // link's href or an image URL would inflate it absurdly.

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

    // An attachment adds its own width on top: CoreText only sees the
    // replacement character it stands in for.

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
            // TextKit adds the paragraph above's spacing to this one's
            // before, so only non-first items carry it.
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

    private static func code(language: String?, text: String, id: String,
                             style: MarkdownStyle) -> NSAttributedString {
        let baseFont = style.codeFont
        let highlighted = Highlight.attribute(text, language: language,
                                              baseFont: baseFont)
        let m = NSMutableAttributedString(attributedString: highlighted)
        m.append(NSAttributedString(string: "\n",
                                    attributes: [.font: baseFont]))
        let ns = m.string as NSString
        let word = language?.split(separator: " ").first.map(String.init)
        // The first line's tailIndent leaves room for the copy badge;
        // the bridge restores the box's full width past that gap.
        let room = codeBadgeRoom(label: word)
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
                para.tailIndent = -(style.codePadding + room)
                m.addAttribute(codeBadgeRoomKey, value: room, range: line)
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
        if let word {
            m.addAttribute(atomicLabelKey, value: word, range: full)
        }
        return m
    }

    // Estimates the SwiftUI badge's width from the label's length,
    // since the badge itself lays out later.

    static func codeBadgeRoom(label: String?) -> CGFloat {
        copyButtonGutter + 12 +
            (label.map { l in CGFloat(l.count) * 7.5 + 14 } ?? 0)
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
