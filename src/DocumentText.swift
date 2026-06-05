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
        let full = NSRange(location: 0, length: m.length)
        m.addAttribute(.backgroundColor,
                       value: platformWhite(0.5, alpha: 0.10), range: full)
        m.addAttribute(atomicKindKey,
                       value: AtomicKind.code.rawValue, range: full)
        m.addAttribute(atomicIdKey, value: UUID().uuidString, range: full)
        m.append(NSAttributedString(string: "\n\n"))
        return m
    }

    private static func monospaceFont() -> PlatformFont {
        let bodySize = PlatformFont.preferredFont(forTextStyle: .body)
            .pointSize
        return monoFont(at: bodySize - 1)
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
            let runFont = styledRunFont(intent: intent, base: base)
            var attrs: [NSAttributedString.Key: Any] = [
                .font: runFont,
                .foregroundColor: platformDefaultTextColor,
            ]
            if intent.contains(.strikethrough) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let url = run.link { attrs[.link] = url }
            m.append(NSAttributedString(string: segment, attributes: attrs))
        }
    }

}
