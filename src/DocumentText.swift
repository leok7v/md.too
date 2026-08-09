import Foundation

enum DocumentText {

    typealias DocumentImage = PlatformImage

    static func attributed(from blocks: [Block],
                           images: [URL: DocumentImage] = [:])
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        for block in blocks {
            m.append(render(block, images: images))
        }
        return m
    }

    // The narrowest this document can be drawn before a table is asked
    // for less room than its content can occupy. One text view holds the
    // whole document, so there is no per-table escape here the way the
    // block renderer has: the answer is a single width for everything,
    // and the caller scrolls horizontally when the viewport is smaller.
    // Zero for a document with no tables, which is the common case and
    // leaves the text width-aligned to the window.

    static func minimumWidth(of blocks: [Block]) -> CGFloat {
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
            case .table(let headers, let rows):
                result = tableMinimumWidth(headers: headers, rows: rows)
            case .quote(let inner):
                result = indented(minimumWidth(of: inner), by: 18)
            case .list(let items, _):
                for item in items {
                    let w = indented(minimumWidth(of: item.blocks), by: 20)
                    if w > result { result = w }
                }
            default:
                result = 0
        }
        return result
    }

    // An indent only widens a document that had something to widen it;
    // a quote full of prose still asks for nothing.

    private static func indented(_ inner: CGFloat,
                                 by amount: CGFloat) -> CGFloat {
        inner > 0 ? inner + amount : 0
    }

    // Widest token a column must be able to hold, measured on the text
    // that will be DRAWN rather than the markdown that was typed: a link
    // shows its label, not its href, and a cell holding an image shows
    // no words at all. Measuring the source instead turns one image URL
    // into a demand for two thousand points.
    //
    // Measured against the WIDEST face the cell could end up in, not the
    // one it probably will. A run marked as code becomes monospaced and
    // one marked strong becomes bold, either of which outgrows the plain
    // body face -- and a token that outgrows its column is exactly the
    // thing this number exists to prevent.

    static func longestWordWidth(_ cell: String,
                                 font: PlatformFont) -> CGFloat {
        var widest: CGFloat = 0
        let faces = widestFaces(of: font)
        for word in renderedText(of: cell).split(separator: " ") {
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

    private static func renderedText(of cell: String) -> String {
        var result = TeX.scriptsToUnicode(cell)
        if let first = Markdown.parse(cell).first {
            switch first {
                case .paragraph(let a): result = String(a.characters)
                case .image: result = ""
                default: break
            }
        }
        return result
    }

    static func columnMinimums(headers: [String], rows: [[String]],
                               cols: Int) -> [CGFloat] {
        let body = FontRole.body.platformFont
        let bold = boldFont(of: body)
        var out = [CGFloat](repeating: 0, count: cols)
        for c in 0..<cols {
            var widest: CGFloat = 0
            if c < headers.count {
                let w = longestWordWidth(headers[c], font: bold)
                if w > widest { widest = w }
            }
            for row in rows where c < row.count {
                let w = longestWordWidth(row[c], font: body)
                if w > widest { widest = w }
            }
            out[c] = ceil(widest)
        }
        return out
    }

    private static func render(_ block: Block, images: [URL: DocumentImage])
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
                result = table(headers: headers, rows: rows, images: images)
            case .math(let tex):
                result = math(tex)
            case .rule:
                result = rule()
            case .image(let alt, let url, let w, let h):
                result = image(alt: alt, url: url, width: w, height: h,
                               images: images)
        }
        return result
    }

    static func tableCell(_ text: String,
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
                                .foregroundColor: platformSecondaryColor,
                            ]))
                    }
                case .paragraph(let attr):
                    translateInline(attr, base: base, into: m)
                default:
                    m.append(NSAttributedString(
                        string: text,
                        attributes: [
                            .font: base,
                            .foregroundColor: platformDefaultTextColor,
                        ]))
            }
        }
        return m
    }

    // A display sits in its own centred paragraph, carrying the TeX it
    // came from on atomicCopyKey so Copy yields the formula rather than
    // the object-replacement character an attachment would otherwise
    // hand over. Same contract as a code fence or a table, so the copy
    // overlay needs nothing new.

    private static func math(_ tex: String) -> NSAttributedString {
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
        m.addAttribute(atomicIdKey, value: UUID().uuidString, range: content)
        m.addAttribute(atomicCopyKey, value: tex, range: content)
        m.append(NSAttributedString(string: "\n\n"))
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.paragraphSpacing = 6
        para.paragraphSpacingBefore = 6
        m.addAttribute(.paragraphStyle, value: para,
                       range: NSRange(location: 0, length: m.length))
        return m
    }

    private static func quote(_ blocks: [Block], images: [URL: DocumentImage])
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
        m.addAttribute(.backgroundColor,
                       value: platformWhite(0.5, alpha: 0.06),
                       range: full)
        return m
    }

    private static func list(items: [ListItem], tight: Bool, depth: Int,
                            images: [URL: DocumentImage])
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        let indent = CGFloat(depth + 1) * 20
        let para = NSMutableParagraphStyle()
        para.headIndent = indent
        para.firstLineHeadIndent = indent - 20
        para.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        para.paragraphSpacing = tight ? 2 : 8
        para.paragraphSpacingBefore = tight ? 2 : 4
        for item in items {
            m.append(listItem(item, para: para, tight: tight,
                              depth: depth, images: images))
        }
        // Blocks separate with a blank line and each item already ends
        // with one newline, so a top-level list owes one more to match
        // the paragraph / heading convention. A nested list sits inside
        // an item and must not open a gap mid-list.
        if depth == 0 { m.append(NSAttributedString(string: "\n")) }
        return m
    }

    private static func listItem(_ item: ListItem, para: NSParagraphStyle,
                                 tight: Bool, depth: Int,
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
        let contIndent = para.headIndent
        for rest in item.blocks.dropFirst() {
            if case .list(let inner, let innerTight) = rest {
                line.append(list(items: inner, tight: innerTight,
                                 depth: depth + 1, images: images))
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

    private static func image(alt: String, url: URL, width: CGFloat?,
                           height: CGFloat?, images: [URL: DocumentImage])
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
            m.addAttribute(atomicIdKey, value: UUID().uuidString, range: full)
            m.append(NSAttributedString(string: "\n\n"))
            result = m
        } else {
            let label = alt.isEmpty ? url.absoluteString : alt
            let attrs: [NSAttributedString.Key: Any] = [
                .font: FontRole.body.platformFont,
                .foregroundColor: platformSecondaryColor,
                atomicKindKey: AtomicKind.image.rawValue,
                atomicIdKey: UUID().uuidString,
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

    private static func code(language: String?, text: String)
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
        m.addAttribute(atomicIdKey, value: UUID().uuidString, range: full)
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
        m.append(NSAttributedString(string: "\n\n"))
        return m
    }

    private static func heading(level: Int,
                                text: AttributedString)
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        translateInline(text, base: FontRole.heading(level).platformFont,
                              into: m)
        m.append(NSAttributedString(string: "\n\n"))
        return m
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
            if let level = run[ScriptAttribute.self] {
                let script = scriptRunFont(level, base: runFont)
                runFont = script.font
                attrs[.baselineOffset] = script.offset
            }
            attrs[.font] = runFont
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link { attrs[.link] = url }
            m.append(NSAttributedString(string: segment, attributes: attrs))
        }
    }

}
