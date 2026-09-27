import Foundation

enum HtmlExport {

    static func render(_ blocks: [Block], title: String,
                       images: [URL: Data] = [:]) -> String {
        var head = "<!DOCTYPE html>\n<html>\n<head>\n"
        head += "<meta charset=\"utf-8\">\n"
        head += "<title>\(esc(title))</title>\n"
        head += "</head>\n<body>\n"
        var body = ""
        for block in blocks { body += renderBlock(block, images: images) }
        return head + body + "</body>\n</html>\n"
    }

    static func renderFragment(_ blocks: [Block],
                               images: [URL: Data] = [:]) -> String {
        var out = ""
        for block in blocks { out += renderBlock(block, images: images) }
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
                return "<h\(level)\(alignStyle(text))>" +
                       "\(renderInline(text))</h\(level)>\n"
            case .paragraph(let text):
                return "<p\(alignStyle(text))>\(renderInline(text))</p>\n"
            case .code(let lang, let text):
                return renderCode(lang: lang, text: text)
            case .quote(let inner):
                var s = "<blockquote style=\"\(quoteStyle)\">\n"
                for b in inner { s += renderBlock(b, images: images) }
                return s + "</blockquote>\n"
            case .list(let items, let tight):
                return renderList(items, tight: tight, images: images)
            case .table(let headers, let rows, let alignments):
                return renderTable(headers: headers, rows: rows,
                                   alignments: alignments, images: images)
            case .math(let tex):
                // Rendered as Unicode text, not a rasterized image, so it
                // keeps the page's theme and scale instead of a snapshot.
                return "<p style=\"\(mathStyle)\">" +
                       "\(renderInline(TeX.render(tex, display: true)))</p>\n"
            case .rule:
                return "<hr style=\"\(ruleStyle)\">\n"
            case .image(let alt, let url, let w, let h):
                return renderImage(alt: alt, url: url, w: w, h: h,
                                   images: images)
        }
    }

    private static func alignStyle(_ attr: AttributedString) -> String {
        var result = ""
        if attr.runs.first?[AlignAttribute.self] == .center {
            result = " style=\"text-align:center\""
        }
        return result
    }

    private static func renderInline(_ attr: AttributedString) -> String {
        var out = ""
        for run in attr.runs {
            let segment = esc(String(attr[run.range].characters))
                .replacingOccurrences(of: "\u{2028}", with: "<br>")
            let intent = run.inlinePresentationIntent ?? []
            var open: [String] = []
            var close: [String] = []
            if run[SmallAttribute.self] == true {
                open.append("<small>")
                close.insert("</small>", at: 0)
            }
            if let url = run.link, safeLink(url) {
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
            if run.underlineStyle != nil {
                open.append("<u>")
                close.insert("</u>", at: 0)
            }
            // The script level round-trips to <sup>/<sub>; the parser only
            // needed a baseline offset, but the medium can say it natively.
            if let level = run[ScriptAttribute.self] {
                let tag = level > 0 ? "sup" : "sub"
                open.append("<\(tag)>")
                close.insert("</\(tag)>", at: 0)
            }
            out += open.joined() + segment + close.joined()
        }
        return out
    }

    private static let linkSchemes: Set<String> = ["http", "https", "mailto"]

    static func safeLink(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == nil || linkSchemes.contains(scheme ?? "")
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
        let first = items.first.flatMap { item in
            Int(item.marker.filter { ch in ch.isNumber })
        } ?? 1
        let start = ordered && first != 1 ? " start=\"\(first)\"" : ""
        var out = "<\(tag)\(start) style=\"\(style)\">\n"
        for item in items { out += renderItem(item, images: images) }
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
                                    rows: [[String]],
                                    alignments: [Alignment],
                                    images: [URL: Data]) -> String {
        let n = TableMetrics.columnCount(headers: headers, rows: rows)
        var out = "<table style=\"\(tableStyle)\">\n"
        if !headers.isEmpty {
            out += "<thead><tr style=\"\(rowHeaderStyle)\">\n"
            for i in 0..<n {
                let cell = i < headers.count ? headers[i] : ""
                out += "<th style=\"\(thStyle)\(divider(i, of: n))" +
                       "\(textAlign(i, alignments))\">" +
                       "\(inlineFromCell(cell, images: images))</th>\n"
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
                out += "<td style=\"\(tdStyle)\(divider(i, of: n))" +
                       "\(textAlign(i, alignments))\">" +
                       "\(inlineFromCell(cell, images: images))</td>\n"
            }
            out += "</tr>\n"
        }
        return out + "</tbody>\n</table>\n"
    }

    // Inline styles cannot express :not(:last-child), so the column
    // index decides whether this cell gets a right divider.

    private static func divider(_ col: Int, of count: Int) -> String {
        col < count - 1 ? colDividerStyle : ""
    }

    // The header cell style says left already, so only a column that
    // asked for something else carries an alignment of its own.

    private static func textAlign(_ col: Int,
                                  _ alignments: [Alignment]) -> String {
        var result = ""
        if col < alignments.count {
            switch alignments[col] {
                case .center: result = "text-align:center;"
                case .right: result = "text-align:right;"
                case .left, .none: result = ""
            }
        }
        return result
    }

    private static func inlineFromCell(_ raw: String,
                                       images: [URL: Data]) -> String {
        var result = esc(raw)
        if let first = Markdown.parseCell(raw).first {
            switch first {
                case .paragraph(let a): result = renderInline(a)
                case .image(let alt, let url, let w, let h):
                    result = imageTag(alt: alt, url: url, w: w, h: h,
                                      images: images)
                default: result = esc(raw)
            }
        }
        return result
    }

    private static func renderImage(alt: String, url: URL,
                                      w: CGFloat?, h: CGFloat?,
                                 images: [URL: Data]) -> String {
        var result = ""
        if images[url] != nil {
            result = "<p>" + imageTag(alt: alt, url: url, w: w, h: h,
                                      images: images) + "</p>\n"
        } else {
            result = "<p style=\"\(imagePlaceholderStyle)\">" +
                     imageTag(alt: alt, url: url, w: w, h: h,
                              images: images) + "</p>\n"
        }
        return result
    }

    private static func imageTag(alt: String, url: URL,
                                 w: CGFloat?, h: CGFloat?,
                                 images: [URL: Data]) -> String {
        var style = "max-width:100%;"
        if let w { style += "width:\(Int(w))px;" }
        if let h { style += "height:\(Int(h))px;" }
        var result = ""
        if let data = images[url] {
            result = "<img alt=\"\(escAttr(alt))\" " +
                     "src=\"\(dataURI(data))\" style=\"\(style)\">"
        } else {
            let label = alt.isEmpty ? url.absoluteString : alt
            result = "[\(esc(label))]"
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

    private static let mathStyle =
        "text-align:center;" +
        "font-style:italic;" +
        "margin:0.8em 0;"

    private static let ruleStyle =
        "border:none;" +
        "border-top:1px solid rgba(128,128,128,0.3);" +
        "margin:1em 0;"

    private static let tableStyle =
        "border-collapse:collapse;" +
        "margin:0.5em 0;"

    private static let thStyle =
        "padding:6px 14px;" +
        "text-align:left;" +
        "border-bottom:1px solid rgba(128,128,128,0.3);"

    private static let tdStyle =
        "padding:6px 14px;" +
        "border-bottom:1px solid rgba(128,128,128,0.12);"

    // Lighter than the row rules so the grid reads as columns first;
    // border-collapse on the table merges it with border-bottom.
    private static let colDividerStyle =
        "border-right:1px solid rgba(128,128,128,0.20);"

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
