import Foundation

// Apple's inline markdown parser leaves <sub>/<sup> as literal text;
// the level (+1 up, -1 down) rides the run for each renderer to express.

enum ScriptAttribute: AttributedStringKey {
    typealias Value = Int
    static let name = "md.too.script"
}

// <small> has no markdown spelling either; the run is drawn at a
// fraction of its size wherever there is a size to scale.

enum SmallAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "md.too.small"
}

// Alignment rides every run of a centred paragraph or heading's text,
// since Block has no field for it.

enum AlignAttribute: AttributedStringKey {
    typealias Value = Alignment
    static let name = "md.too.align"
}

// A formula's source, delimiters included, rides the Unicode run it was
// spelled into, so plain export and copy recover exactly what was typed.

enum InlineMathAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "md.too.math"
}

enum Alignment: Equatable, Hashable, Sendable {
    case none, left, center, right
}

enum Block: Equatable, Sendable {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case code(language: String?, text: String)
    case quote([Block])
    case list(items: [ListItem], tight: Bool)
    case table(headers: [String], rows: [[String]], alignments: [Alignment])
    // Only a $$...$$ display gets a block of its own; inline $...$ stays
    // inside the paragraph's AttributedString.
    case math(String)
    case rule
    case image(alt: String, url: URL, width: CGFloat?, height: CGFloat?)
}

struct ListItem: Equatable, Sendable {
    let marker: String
    let checked: Bool?
    let blocks: [Block]
}

enum Markdown {

    @TaskLocal private static var currentRefs: [String: URL] = [:]
    @TaskLocal private static var nesting = 0
    static let maxNesting = 32

    static func parse(_ source: String) -> [Block] {
        let raw = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let (lines, refs) = stripLinkDefinitions(frontMatterAsCode(raw))
        return Markdown.$currentRefs.withValue(refs) {
            parseBlocks(lines)
        }
    }

    static func frontMatterAsCode(_ lines: [String]) -> [String] {
        var result = lines
        if lines.first?.trimmedOuter() == "---",
           let end = lines.dropFirst().prefix(64).firstIndex(where: { l in
               l.trimmedOuter() == "---" || l.trimmedOuter() == "..."
           }),
           lines[1..<end].allSatisfy({ l in
               l.trimmedOuter().isEmpty || l.hasPrefix(" ") ||
               l.hasPrefix("-") || l.hasPrefix("#") || l.contains(":")
           }), end > 1 {
            result = ["```yaml"] + lines[1..<end] + ["```"] +
                     lines[(end + 1)...]
        }
        return result
    }

    static func text(from data: Data) -> String? {
        var result = String(data: data, encoding: .utf8)
        if result == nil {
            var converted: NSString? = nil
            var lossy: ObjCBool = false
            let found = NSString.stringEncoding(
                for: data,
                encodingOptions: [.allowLossyKey: false],
                convertedString: &converted, usedLossyConversion: &lossy)
            if found != 0, let converted { result = converted as String }
        }
        if result == nil {
            result = String(data: data, encoding: .windowsCP1252)
        }
        return result
    }

    static func text(contentsOf url: URL) -> String? {
        (try? Data(contentsOf: url)).flatMap { data in text(from: data) }
    }

    private static let cellLock = NSLock()
    nonisolated(unsafe) private static var cells: [String: [Block]] = [:]
    private static let cellLimit = 4096

    // A cell's parse depends only on the cell string, so every renderer
    // that meets the same string can share the cached parse.

    static func parseCell(_ cell: String) -> [Block] {
        cellLock.lock()
        let hit = cells[cell]
        cellLock.unlock()
        let result: [Block]
        if let hit {
            result = hit
        } else {
            result = parse(cell)
            cellLock.lock()
            if cells.count >= cellLimit { cells.removeAll() }
            cells[cell] = result
            cellLock.unlock()
        }
        return result
    }

    private static func parseBlocks(_ lines: [String]) -> [Block] {
        let result: [Block]
        if nesting >= maxNesting {
            let raw = lines.joined(separator: "\n").trimmedOuter()
            result = raw.isEmpty ? [] : [.paragraph(AttributedString(raw))]
        } else {
            result = Markdown.$nesting.withValue(nesting + 1) {
                parseBlockLines(lines)
            }
        }
        return result
    }

    private static func parseBlockLines(_ source: [String]) -> [Block] {
        var lines = source
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isIndentedCode(line) {
                blocks.append(consumeIndentedCode(lines, &i))
            } else if isFence(line) {
                blocks.append(consumeFenced(lines, &i))
            } else if isMathFence(line) {
                blocks += consumeMath(&lines, &i)
            } else if isHeading(line) {
                blocks.append(consumeHeading(lines, &i))
            } else if isHR(line) {
                if case .rule = blocks.last { } else { blocks.append(.rule) }
                i += 1
            } else if isQuoteStart(line) {
                blocks.append(consumeQuote(lines, &i))
            } else if isTableStart(lines, i) {
                blocks.append(consumeTable(lines, &i))
            } else if isListStart(line) {
                blocks.append(consumeList(lines, &i))
            } else if line.trimmedOuter().isEmpty {
                i += 1
            } else if isCommentStart(line) {
                skipComment(&lines, &i)
            } else if let img = imageBlock(line) {
                blocks.append(img)
                i += 1
            } else if centerOpener(line) != nil {
                blocks += consumeCentered(lines, &i)
            } else if isDetailsStart(line) {
                blocks += consumeDetails(lines, &i)
            } else {
                blocks.append(consumeParagraph(lines, &i))
            }
        }
        return blocks
    }

    private static func stripLinkDefinitions(_ raw: [String])
        -> (lines: [String], refs: [String: URL]) {
        var refs: [String: URL] = [:]
        var out: [String] = []
        var fence: (mark: Character, n: Int)? = nil
        for line in raw {
            if let open = fence {
                if closesFence(line, open) { fence = nil }
                out.append(line)
            } else if let run = fenceRun(line), leadingSpaces(line) < 4 {
                fence = run
                out.append(line)
            } else if let parsed = parseLinkDefinition(line) {
                refs[parsed.label] = parsed.url
            } else {
                out.append(line)
            }
        }
        return (out, refs)
    }

    private static func parseLinkDefinition(_ line: String)
                                            -> (label: String, url: URL)? {
        var result: (String, URL)? = nil
        let t = line.trimmedLeading()
        if t.hasPrefix("["), leadingSpaces(line) < 4 {
            let rest = t.dropFirst()
            if let close = rest.firstIndex(of: "]") {
                let label = String(rest[..<close]).trimmedOuter()
                let after = rest[rest.index(after: close)...]
                if !label.isEmpty, !label.hasPrefix("^"),
                   after.hasPrefix(":") {
                    var rhs = String(after.dropFirst()).trimmedOuter()
                    var title = ""
                    if let space = rhs.firstIndex(of: " ") {
                        title = String(rhs[space...]).trimmedOuter()
                        rhs = String(rhs[..<space])
                    }
                    if rhs.hasPrefix("<"), rhs.hasSuffix(">") {
                        rhs = String(rhs.dropFirst().dropLast())
                    }
                    if !rhs.isEmpty, isLinkTitle(title),
                       let url = URL(string: rhs) {
                        result = (refKey(label), url)
                    }
                }
            }
        }
        return result
    }

    private static func isLinkTitle(_ s: String) -> Bool {
        var result = s.isEmpty
        if let open = s.first, let close = s.last, s.count >= 2 {
            result = (open == "\"" && close == "\"") ||
                     (open == "'" && close == "'") ||
                     (open == "(" && close == ")")
        }
        return result
    }

    private static func refKey(_ label: String) -> String {
        let lowered = label.lowercased()
        let collapsed = lowered.split(whereSeparator: { c in
            c == " " || c == "\t" || c == "\n"
        }).joined(separator: " ")
        return collapsed
    }

    private static let fullRefRE = try? NSRegularExpression(
        pattern: "(!?)\\[([^\\]\\n]+)\\]\\[([^\\]\\n]*)\\]")

    private static let shortRefRE = try? NSRegularExpression(
        pattern: "(!?)\\[([^\\]\\n]+)\\](?![\\[\\(:])")

    private static func substituteRefs(_ s: String) -> String {
        let refs = Markdown.currentRefs
        var result = s
        if !refs.isEmpty {
            result = applyRefPattern(result, fullRefRE,
                                     hasLabelGroup: true, refs: refs)
            result = applyRefPattern(result, shortRefRE,
                                     hasLabelGroup: false, refs: refs)
        }
        return result
    }

    private static func applyRefPattern(_ s: String,
                                        _ re: NSRegularExpression?,
                                        hasLabelGroup: Bool,
                                        refs: [String: URL]) -> String {
        var result = s
        if let re {
            let ns = s as NSString
            let matches = re.matches(in: s,
                range: NSRange(location: 0, length: ns.length))
            if !matches.isEmpty {
                let mutable = NSMutableString(string: s)
                for m in matches.reversed() {
                    let bang = ns.substring(with: m.range(at: 1))
                    let text = ns.substring(with: m.range(at: 2))
                    var labelSrc = text
                    if hasLabelGroup, m.numberOfRanges > 3,
                       m.range(at: 3).location != NSNotFound {
                        let g3 = ns.substring(with: m.range(at: 3))
                        if !g3.isEmpty { labelSrc = g3 }
                    }
                    if let url = refs[refKey(labelSrc)] {
                        let rep = "\(bang)[\(text)](\(url.absoluteString))"
                        mutable.replaceCharacters(in: m.range, with: rep)
                    }
                }
                result = mutable as String
            }
        }
        return result
    }

    // <u>, <sup>, <sub> and <small> are consumed after the inline parse,
    // not rewritten here, since each carries an attribute markdown
    // itself cannot spell.

    private static func isCommentStart(_ line: String) -> Bool {
        line.trimmedLeading().hasPrefix("<!--")
    }

    // A comment that opens a line is dropped through its close, however
    // many lines that takes; what follows the close on that line stays.

    private static func skipComment(_ lines: inout [String],
                                    _ i: inout Int) {
        var closed = false
        while i < lines.count, !closed {
            if let end = lines[i].range(of: "-->") {
                var from = end.upperBound
                var chaining = true
                while chaining {
                    let rest = lines[i][from...].drop { c in
                        c == " " || c == "\t"
                    }
                    if rest.hasPrefix("<!--"),
                       let next = rest.range(of: "-->") {
                        from = next.upperBound
                    } else {
                        chaining = false
                    }
                }
                let tail = String(lines[i][from...]).trimmedLeading()
                closed = true
                if tail.trimmedOuter().isEmpty {
                    i += 1
                } else {
                    lines[i] = tail
                }
            } else {
                i += 1
            }
        }
    }

    private static func htmlLine(_ line: String) -> String {
        var out = ""
        for segment in codeSpanSegments(line) {
            out += segment.code ? segment.text : htmlInline(segment.text)
        }
        return out
    }

    private struct TagRule {
        let re: NSRegularExpression?
        let template: String
        let closers: [String]
    }

    private static func tagRule(_ pattern: String, _ template: String,
                                closers: [String] = []) -> TagRule {
        TagRule(re: try? NSRegularExpression(pattern: pattern,
                                             options: .caseInsensitive),
                template: template, closers: closers)
    }

    private static let imgRule =
        tagRule(#"<img\b[^>]*?\bsrc\s*=\s*"([^"]*)"[^>]*>"#, "![]($1)")

    // Order matters: a comment goes first so its contents are never read
    // as tags, and <img> before <a> so a linked image keeps its picture.

    private static let tagRules: [TagRule] = [
        tagRule(#"<!--(?:(?!<!--).)*?-->"#, "", closers: ["-->"]),
        tagRule(#"<br\s*/?>"#, "\u{2028}"),
        imgRule,
        tagRule(#"<img\b[^>]*?\bsrc\s*=\s*'([^']*)'[^>]*>"#, "![]($1)"),
        tagRule(#"<a\b[^>]*?\bhref\s*=\s*"([^"]*)"[^>]*>"# +
                #"((?:(?!<a\b).)*?)</a>"#,
                "[$2]($1)", closers: ["</a>"]),
        tagRule(#"<a\b[^>]*?\bhref\s*=\s*'([^']*)'[^>]*>"# +
                #"((?:(?!<a\b).)*?)</a>"#,
                "[$2]($1)", closers: ["</a>"]),
        tagRule(#"<(b|strong)>((?:(?!<\1>).)*?)</\1>"#, "**$2**",
                closers: ["</b>", "</strong>"]),
        tagRule(#"<(i|em)>((?:(?!<\1>).)*?)</\1>"#, "*$2*",
                closers: ["</i>", "</em>"]),
        tagRule(#"<(s|del|strike)>((?:(?!<\1>).)*?)</\1>"#, "~~$2~~",
                closers: ["</s>", "</del>", "</strike>"]),
        tagRule(#"<(code|kbd)>((?:(?!<\1>).)*?)</\1>"#, "`$2`",
                closers: ["</code>", "</kbd>"]),
    ]

    private static let imgAltRE = try? NSRegularExpression(
        pattern: #"<img\b[^>]*?\balt\s*=\s*"([^"]*)""#,
        options: .caseInsensitive)

    private static let imgSizeRE = try? NSRegularExpression(
        pattern: #"\b(width|height)\s*=\s*"?(\d+)"?"#,
        options: .caseInsensitive)

    private static func htmlInline(_ text: String) -> String {
        var result = text
        if text.contains("<") {
            result = imagesWithAttributes(result)
            for rule in tagRules {
                let lower = rule.closers.isEmpty ? "" : result.lowercased()
                let closed = rule.closers.isEmpty ||
                             rule.closers.contains { c in lower.contains(c) }
                if closed, let re = rule.re {
                    let ns = result as NSString
                    result = re.stringByReplacingMatches(
                        in: result,
                        range: NSRange(location: 0, length: ns.length),
                        withTemplate: rule.template)
                }
            }
        }
        return result
    }

    // Alt text and size are read off the tag before the generic rule
    // reduces it to its bare source.

    private static func imagesWithAttributes(_ text: String) -> String {
        var result = text
        if let altRE = imgAltRE, let sizeRE = imgSizeRE {
            let ns = text as NSString
            let full = NSRange(location: 0, length: ns.length)
            let tags = imgRule.re?.matches(in: text, range: full) ?? []
            let mutable = NSMutableString(string: text)
            for m in tags.reversed() {
                let tag = ns.substring(with: m.range)
                let src = ns.substring(with: m.range(at: 1))
                let tagNS = tag as NSString
                let tagRange = NSRange(location: 0, length: tagNS.length)
                var alt = ""
                if let a = altRE.firstMatch(in: tag, range: tagRange) {
                    alt = tagNS.substring(with: a.range(at: 1))
                }
                var dims: [String] = []
                for d in sizeRE.matches(in: tag, range: tagRange) {
                    let key = tagNS.substring(with: d.range(at: 1))
                    let value = tagNS.substring(with: d.range(at: 2))
                    dims.append(key.lowercased() + "=" + value)
                }
                let suffix = dims.isEmpty
                    ? "" : "{" + dims.joined(separator: " ") + "}"
                mutable.replaceCharacters(
                    in: m.range, with: "![\(alt)](\(src))" + suffix)
            }
            result = mutable as String
        }
        return result
    }

    private static let centerOpenRE = try? NSRegularExpression(
        pattern: #"^\s*<(?:(?:div|p)\s+align\s*=\s*"?center"?|center)\s*>"#,
        options: .caseInsensitive)

    private static func centerOpener(_ line: String) -> NSRange? {
        var result: NSRange? = nil
        if line.contains("<"), let re = centerOpenRE {
            let ns = line as NSString
            result = re.firstMatch(
                in: line, range: NSRange(location: 0, length: ns.length))?
                .range
        }
        return result
    }

    private static func centerTag(_ opener: String) -> String {
        let lower = opener.lowercased()
        return lower.contains("<center") ? "center"
             : lower.contains("<div") ? "div" : "p"
    }

    private static let centerClosers: [String: NSRegularExpression] =
        ["center", "div", "p"].reduce(into: [:]) { map, tag in
            map[tag] = try? NSRegularExpression(
                pattern: "</" + tag + #"\s*>\s*$"#,
                options: .caseInsensitive)
        }

    private static func centerCloser(_ line: String,
                                     tag: String) -> NSRange? {
        var result: NSRange? = nil
        if line.contains("</"), let re = centerClosers[tag] {
            let ns = line as NSString
            result = re.firstMatch(
                in: line, range: NSRange(location: 0, length: ns.length))?
                .range
        }
        return result
    }

    // A centring wrapper is unwrapped; its paragraphs and headings carry
    // the alignment on their text. It may open and close on one line.

    private static func consumeCentered(_ lines: [String],
                                        _ i: inout Int) -> [Block] {
        var inner: [String] = []
        var closed = false
        var first = lines[i]
        var tag = "div"
        if let open = centerOpener(first) {
            tag = centerTag((first as NSString).substring(with: open))
            first = (first as NSString).replacingCharacters(in: open, with: "")
        }
        var line = first
        while i < lines.count, !closed {
            if let close = centerCloser(line, tag: tag) {
                line = (line as NSString).replacingCharacters(in: close,
                                                              with: "")
                closed = true
            }
            if !line.trimmedOuter().isEmpty || !inner.isEmpty {
                inner.append(line)
            }
            i += 1
            if i < lines.count, !closed { line = lines[i] }
        }
        return parseBlocks(inner).map { block in centered(block) }
    }

    private static func centered(_ block: Block) -> Block {
        let result: Block
        switch block {
            case .paragraph(var attr):
                attr[AlignAttribute.self] = .center
                result = .paragraph(attr)
            case .heading(let level, var attr):
                attr[AlignAttribute.self] = .center
                result = .heading(level: level, text: attr)
            default:
                result = block
        }
        return result
    }

    private static let summaryRE = try? NSRegularExpression(
        pattern: #"<summary>(.*?)</summary>"#, options: .caseInsensitive)

    private static func isDetailsStart(_ line: String) -> Bool {
        line.trimmedLeading().lowercased().hasPrefix("<details")
    }

    // A viewer has nothing to fold, so <details> is drawn open: the
    // summary as a bold line, the body as the blocks it holds.

    private static func consumeDetails(_ lines: [String],
                                       _ i: inout Int) -> [Block] {
        var inner: [String] = []
        var title = ""
        var line = lines[i]
        if let r = line.range(of: "<details", options: .caseInsensitive),
           let end = line[r.lowerBound...].firstIndex(of: ">") {
            line = String(line[line.index(after: end)...])
        }
        var depth = 1
        while depth > 0, i < lines.count {
            if depth == 1, title.isEmpty, let re = summaryRE {
                let ns = line as NSString
                let full = NSRange(location: 0, length: ns.length)
                if let m = re.firstMatch(in: line, range: full) {
                    title = ns.substring(with: m.range(at: 1))
                    line = ns.replacingCharacters(in: m.range, with: "")
                }
            }
            depth += line.lowercased().components(separatedBy: "<details")
                .count - 1
            var from = line.startIndex
            while depth > 0,
                  let r = line.range(of: "</details>",
                                     options: .caseInsensitive,
                                     range: from..<line.endIndex) {
                depth -= 1
                from = depth == 0 ? r.lowerBound : r.upperBound
            }
            if depth == 0 { line = String(line[..<from]) }
            if !line.trimmedOuter().isEmpty || !inner.isEmpty {
                inner.append(line)
            }
            i += 1
            if depth > 0, i < lines.count { line = lines[i] }
        }
        var out: [Block] = []
        if !title.trimmedOuter().isEmpty {
            out.append(.paragraph(inline("**" + title.trimmedOuter() + "**")))
        }
        out += parseBlocks(inner)
        return out
    }

    private static func isHeading(_ s: String) -> Bool {
        var result = false
        let t = s.trimmedOuter()
        let n = t.prefix { c in c == "#" }.count
        if n >= 1 && n <= 6 {
            let rest = t.dropFirst(n)
            result = rest.hasPrefix(" ") || rest.hasPrefix("\t") ||
                     rest.isEmpty
        }
        return result
    }

    private static func consumeHeading(_ lines: [String],
                                       _ i: inout Int) -> Block {
        let t = lines[i].trimmedOuter()
        let n = t.prefix { c in c == "#" }.count
        var body = String(t.dropFirst(n)).trimmedOuter()
        let closing = body.reversed().prefix { c in c == "#" }.count
        if closing == body.count {
            body = ""
        } else if closing > 0,
                  body.dropLast(closing).last?.isWhitespace == true {
            body = String(body.dropLast(closing)).trimmedOuter()
        }
        i += 1
        return .heading(level: n, text: inline(body))
    }

    private static func isHR(_ s: String) -> Bool {
        var result = false
        let t = s.trimmedOuter()
        if t.count >= 3, let c = t.first, c == "-" || c == "*" || c == "_" {
            result = t.allSatisfy { ch in ch == c || ch == " " || ch == "\t" }
        }
        return result
    }

    private static func isFence(_ s: String) -> Bool {
        fenceRun(s) != nil
    }

    private static func fenceRun(_ s: String) -> (mark: Character, n: Int)? {
        var result: (Character, Int)? = nil
        let t = s.trimmedLeading()
        if let c = t.first, c == "`" || c == "~" {
            let n = t.prefix { ch in ch == c }.count
            if n >= 3 { result = (c, n) }
        }
        return result
    }

    private static func closesFence(_ s: String,
                                    _ open: (mark: Character, n: Int))
        -> Bool {
        var result = false
        if let run = fenceRun(s), run.mark == open.mark, run.n >= open.n {
            result = s.trimmedOuter().allSatisfy { ch in ch == open.mark }
        }
        return result
    }

    private static func consumeFenced(_ lines: [String],
                                      _ i: inout Int) -> Block {
        let raw = lines[i]
        let t = raw.trimmedLeading()
        let open = fenceRun(raw) ?? ("`", 3)
        let lang = String(t.dropFirst(open.n)).trimmedOuter()
        let indent = raw.count - t.count
        let pad = String(repeating: " ", count: indent)
        i += 1
        var body: [String] = []
        var done = false
        while i < lines.count, !done {
            let line = lines[i]
            if closesFence(line, open) {
                done = true
            } else if indent > 0, line.hasPrefix(pad) {
                body.append(String(line.dropFirst(indent)))
            } else {
                body.append(line)
            }
            i += 1
        }
        let language = lang.isEmpty ? nil : String(lang)
        return .code(language: language, text: body.joined(separator: "\n"))
    }

    // Only a line that OPENS with $$ starts a display; one met partway
    // through a sentence is left to the inline splitter.

    private static func isMathFence(_ s: String) -> Bool {
        s.trimmedOuter().hasPrefix("$$")
    }

    // Accepts $$ ... $$ whole on one line, or opened alone with the
    // formula below; an unterminated display runs to the document's end.

    private static func consumeMath(_ lines: inout [String],
                                    _ i: inout Int) -> [Block] {
        let line = lines[i].trimmedOuter()
        var blocks: [Block] = []
        var from = line.startIndex
        var chaining = true
        while chaining {
            let rest = line[from...].drop { c in c == " " || c == "\t" }
            let inner = rest.dropFirst(2)
            if rest.hasPrefix("$$"), let end = inner.range(of: "$$") {
                blocks.append(.math(String(inner[..<end.lowerBound])
                    .trimmedOuter()))
                from = end.upperBound
            } else {
                chaining = false
            }
        }
        var result = blocks
        if blocks.isEmpty {
            result = [consumeOpenMath(&lines, &i)]
        } else {
            let tail = String(line[from...]).trimmedOuter()
            if tail.allSatisfy({ ch in ch == "$" }) {
                i += 1
            } else {
                lines[i] = tail
            }
        }
        return result
    }

    private static func consumeOpenMath(_ lines: inout [String],
                                        _ i: inout Int) -> Block {
        var body: [String] = []
        var line = String(lines[i].trimmedOuter().dropFirst(2))
        var closed = false
        var reading = true
        while reading {
            if let end = line.range(of: "$$") {
                let head = String(line[..<end.lowerBound])
                let tail = String(line[end.upperBound...]).trimmedLeading()
                if !head.trimmedOuter().isEmpty { body.append(head) }
                closed = true
                if tail.trimmedOuter().allSatisfy({ ch in ch == "$" }) {
                    i += 1
                } else {
                    lines[i] = tail
                }
            } else {
                if !line.trimmedOuter().isEmpty || !body.isEmpty {
                    body.append(line)
                }
                i += 1
            }
            reading = !closed && i < lines.count
            if reading { line = lines[i] }
        }
        return .math(body.joined(separator: "\n").trimmedOuter())
    }

    private static func isIndentedCode(_ s: String) -> Bool {
        var result = false
        if !s.trimmedOuter().isEmpty {
            result = s.hasPrefix("    ") || s.hasPrefix("\t")
        }
        return result
    }

    private static func consumeIndentedCode(_ lines: [String],
                                            _ i: inout Int) -> Block {
        var body: [String] = []
        var done = false
        while i < lines.count, !done {
            let line = lines[i]
            if line.trimmedOuter().isEmpty {
                body.append("")
                i += 1
            } else if line.hasPrefix("    ") {
                body.append(String(line.dropFirst(4)))
                i += 1
            } else if line.hasPrefix("\t") {
                body.append(String(line.dropFirst(1)))
                i += 1
            } else {
                done = true
            }
        }
        while let last = body.last, last.isEmpty { body.removeLast() }
        return .code(language: nil,
                     text: body.joined(separator: "\n"))
    }

    private static func isQuoteStart(_ s: String) -> Bool {
        leadingSpaces(s) <= 3 && s.trimmedLeading().hasPrefix(">")
    }

    private static func consumeQuote(_ lines: [String],
                                     _ i: inout Int) -> Block {
        var inner: [String] = []
        var collecting = true
        while i < lines.count, collecting {
            let line = lines[i]
            if isQuoteStart(line) {
                var t = line.trimmedLeading()
                t = String(t.dropFirst())
                if t.hasPrefix(" ") || t.hasPrefix("\t") {
                    t = String(t.dropFirst())
                }
                inner.append(t)
                i += 1
            } else if !line.trimmedOuter().isEmpty,
                      isLazyContinuation(line) {
                inner.append(line.trimmedLeading())
                i += 1
            } else {
                collecting = false
            }
        }
        return .quote(parseBlocks(inner))
    }

    private static func isListStart(_ s: String) -> Bool {
        listMarker(s) != nil
    }

    private static func listInterrupts(_ s: String) -> Bool {
        var result = false
        if let m = listMarker(s), !m.rest.trimmedOuter().isEmpty {
            result = m.label == "\u{2022}" || m.label == "1."
        }
        return result
    }

    private static func listMarker(_ line: String)
        -> (label: String, sig: Character, offset: Int, rest: String)? {
        var result: (String, Character, Int, String)? = nil
        let leading = line.prefix { c in c == " " }.count
        if leading <= 3 {
            let afterIndent = line.dropFirst(leading)
            if let first = afterIndent.first,
               first == "-" || first == "*" || first == "+" {
                result = afterMarker(
                    afterIndent.dropFirst(), leading: leading,
                    markerWidth: 1, label: "•", sig: first)
            } else {
                let digits = afterIndent.prefix { c in c.isNumber }
                let afterDigits = afterIndent.dropFirst(digits.count)
                if !digits.isEmpty, digits.count <= 9,
                   let delim = afterDigits.first,
                   delim == "." || delim == ")" {
                    result = afterMarker(
                        afterDigits.dropFirst(), leading: leading,
                        markerWidth: digits.count + 1,
                        label: String(digits) + ".", sig: delim)
                }
            }
        }
        return result
    }

    // A tab after the marker counts as one space; content sits at the
    // next tab stop, matching a tab-indented item's continuation lines.

    private static func afterMarker(_ tail: Substring, leading: Int,
                                    markerWidth: Int, label: String,
                                    sig: Character)
        -> (label: String, sig: Character, offset: Int, rest: String)? {
        var result: (String, Character, Int, String)? = nil
        let spaces = tail.prefix { c in c == " " }.count
        let blankRest = tail.allSatisfy { c in c == " " || c == "\t" }
        let column = leading + markerWidth
        if blankRest {
            result = (label, sig, column + 1, "")
        } else if tail.hasPrefix("\t") {
            result = (label, sig, column + 4 - column % 4,
                      String(tail.dropFirst()))
        } else if spaces >= 1 {
            let n = spaces >= 5 ? 1 : spaces
            result = (label, sig, column + n, String(tail.dropFirst(n)))
        }
        return result
    }

    private static func consumeList(_ lines: [String],
                                    _ i: inout Int) -> Block {
        var items: [ListItem] = []
        var tight = true
        var sig: Character? = nil
        var done = false
        while i < lines.count, !done {
            if let m = listMarker(lines[i]),
               sig == nil || m.sig == sig {
                sig = m.sig
                var body: [String] = []
                let (checked, rest) = stripTaskMarker(m.rest)
                body.append(rest)
                i += 1
                if collectItemBody(lines, &i, m.offset, &body) {
                    tight = false
                }
                items.append(ListItem(marker: m.label, checked: checked,
                                      blocks: parseBlocks(body)))
                let gap = interItemGap(lines, &i, sig: m.sig)
                if gap.loose { tight = false }
                if gap.ended { done = true }
            } else {
                done = true
            }
        }
        return .list(items: items, tight: tight)
    }

    private static func stripTaskMarker(_ s: String)
                                        -> (checked: Bool?, rest: String) {
        var result: (Bool?, String) = (nil, s)
        let boxes: [(String, Bool)] = [("[ ]", false), ("[x]", true),
                                       ("[X]", true)]
        for (box, checked) in boxes where result.0 == nil {
            if s == box {
                result = (checked, "")
            } else if s.hasPrefix(box + " ") || s.hasPrefix(box + "\t") {
                result = (checked, String(s.dropFirst(box.count + 1)))
            }
        }
        return result
    }

    private static func collectItemBody(_ lines: [String],
                                        _ i: inout Int,
                                        _ offset: Int,
                                        _ body: inout [String]) -> Bool {
        var loose = false
        var lastWasBlank = false
        var collecting = true
        while i < lines.count, collecting {
            let line = lines[i]
            if line.trimmedOuter().isEmpty {
                var j = i
                while j < lines.count, lines[j].trimmedOuter().isEmpty {
                    j += 1
                }
                if j < lines.count, leadingSpaces(lines[j]) >= offset {
                    var k = i
                    while k < j { body.append(""); k += 1 }
                    i = j
                    loose = true
                    lastWasBlank = true
                } else {
                    collecting = false
                }
            } else if leadingSpaces(line) >= offset {
                body.append(dropIndent(line, offset))
                i += 1
                lastWasBlank = false
            } else if !lastWasBlank, isLazyContinuation(line) {
                body.append(line.trimmedLeading())
                i += 1
                lastWasBlank = false
            } else {
                collecting = false
            }
        }
        return loose
    }

    private static func interItemGap(_ lines: [String], _ i: inout Int,
                                     sig: Character)
        -> (loose: Bool, ended: Bool) {
        var result: (loose: Bool, ended: Bool) = (false, false)
        let before = i
        while i < lines.count, lines[i].trimmedOuter().isEmpty {
            i += 1
        }
        if i > before {
            if i < lines.count, let n = listMarker(lines[i]),
               n.sig == sig {
                result = (true, false)
            } else {
                i = before
                result = (false, true)
            }
        }
        return result
    }

    private static func isLazyContinuation(_ line: String) -> Bool {
        !(isHeading(line) || isHR(line) || isFence(line) ||
          isMathFence(line) || isQuoteStart(line) || isListStart(line) ||
          setextLevel(line) > 0)
    }

    private static func leadingSpaces(_ s: String) -> Int {
        var n = 0
        var done = false
        for c in s {
            if !done {
                if c == " " {
                    n += 1
                } else if c == "\t" {
                    n += 4 - (n % 4)
                } else {
                    done = true
                }
            }
        }
        return n
    }

    private static func dropIndent(_ s: String, _ n: Int) -> String {
        var dropped = 0
        var idx = s.startIndex
        var done = false
        while idx < s.endIndex, !done {
            let c = s[idx]
            if c == " ", dropped < n {
                dropped += 1
                idx = s.index(after: idx)
            } else if c == "\t", dropped < n {
                dropped += 4 - (dropped % 4)
                idx = s.index(after: idx)
            } else {
                done = true
            }
        }
        return String(s[idx...])
    }

    private static func isTableRow(_ s: String) -> Bool {
        let t = s.trimmedOuter()
        return t.contains("|") && !t.isEmpty
    }

    private static func isAlignmentCell(_ cell: String) -> Bool {
        let t = cell.trimmingCharacters(in: .whitespaces)
        return t.contains("-") && t.allSatisfy { ch in "-: ".contains(ch) }
    }

    private static func isJunkCell(_ cell: String) -> Bool {
        cell.allSatisfy { ch in !ch.isLetter && !ch.isNumber }
    }

    // Tolerant delimiter-row test: one good cell and no cell carrying
    // content is enough; one stray character costs the whole table.

    private static func isTableSeparator(_ s: String) -> Bool {
        var result = false
        let t = s.trimmedOuter()
        if t.contains("|"), t.contains("-") {
            let cells = parseRow(t)
            result = cells.contains { cell in isAlignmentCell(cell) } &&
                     cells.allSatisfy { cell in
                         isAlignmentCell(cell) || isJunkCell(cell)
                     }
        }
        return result
    }

    private static func isTableStart(_ lines: [String], _ i: Int) -> Bool {
        var result = false
        if i + 1 < lines.count {
            result = isTableRow(lines[i]) &&
                     isTableSeparator(lines[i + 1])
        }
        return result
    }

    private static func consumeTable(_ lines: [String],
                                     _ i: inout Int) -> Block {
        var headers: [String] = []
        var rows: [[String]] = []
        var alignments: [Alignment] = []
        if i < lines.count, isTableRow(lines[i]) {
            headers = parseRow(lines[i])
            i += 1
        }
        if i < lines.count, isTableSeparator(lines[i]) {
            alignments = parseAlignments(lines[i])
            i += 1
        }
        while i < lines.count, isTableRow(lines[i]) {
            rows.append(parseRow(lines[i]))
            i += 1
        }
        return .table(headers: headers.map { c in cellWithRefs(c) },
                      rows: rows.map { r in r.map { c in cellWithRefs(c) } },
                      alignments: alignments)
    }

    private static func cellWithRefs(_ cell: String) -> String {
        var out = ""
        if Markdown.currentRefs.isEmpty {
            out = cell
        } else {
            for segment in codeSpanSegments(cell) {
                out += segment.code ? segment.text
                                    : substituteRefs(segment.text)
            }
        }
        return out
    }

    // A pipe escaped as \| is a character of its cell; one leading and
    // one trailing pipe are the row's frame and any other is a divider.

    private static func parseRow(_ s: String) -> [String] {
        let t = s.trimmedOuter()
        var cells: [String] = []
        var cell = ""
        var escaping = false
        for ch in t {
            if escaping {
                if ch != "|" { cell.append("\\") }
                cell.append(ch)
                escaping = false
            } else if ch == "\\" {
                escaping = true
            } else if ch == "|" {
                cells.append(cell)
                cell = ""
            } else {
                cell.append(ch)
            }
        }
        if escaping { cell.append("\\") }
        cells.append(cell)
        if t.hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|"), !cells.isEmpty {
            cells.removeLast()
        }
        return cells.map { p in p.trimmingCharacters(in: .whitespaces) }
    }

    private static func parseAlignments(_ s: String) -> [Alignment] {
        parseRow(s).map { cell in
            let t = cell.trimmingCharacters(in: .whitespaces)
            let left = t.hasPrefix(":")
            let right = t.hasSuffix(":")
            let a: Alignment
            if left && right {
                a = .center
            } else if right {
                a = .right
            } else if left {
                a = .left
            } else {
                a = .none
            }
            return a
        }
    }

    private static let imagePattern =
        #"^!\[([^\]]*)\]\(([^\s\)]+)(?:\s+"[^"]*")?\)"#
        + #"\s*(?:\{([^}]*)\})?\s*$"#

    private static let imageLineRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: imagePattern)

    private static func imageBlock(_ line: String) -> Block? {
        var result: Block? = nil
        if let re = imageLineRegex {
            let trimmed = htmlLine(line).trimmedOuter()
            let ns = trimmed as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = re.firstMatch(in: trimmed,
                                     options: [],
                                     range: range) {
                let alt = ns.substring(with: m.range(at: 1))
                let raw = ns.substring(with: m.range(at: 2))
                if let url = URL(string: raw) {
                    var width: CGFloat?
                    var height: CGFloat?
                    if m.numberOfRanges >= 4,
                       m.range(at: 3).location != NSNotFound {
                        let attrs = ns.substring(with: m.range(at: 3))
                        (width, height) = parseDimensions(attrs)
                    }
                    result = .image(alt: alt, url: url,
                                    width: width, height: height)
                }
            }
        }
        return result
    }

    private static let dimensionRE = try? NSRegularExpression(
        pattern: #"(width|height)\s*=\s*(\d+(?:\.\d+)?)(?:px)?"#,
        options: .caseInsensitive)

    private static func parseDimensions(_ attrs: String)
                                        -> (CGFloat?, CGFloat?) {
        var width: CGFloat?
        var height: CGFloat?
        if let re = dimensionRE {
            let ns = attrs as NSString
            let full = NSRange(location: 0, length: ns.length)
            re.enumerateMatches(in: attrs,
                                options: [],
                                range: full) { m, _, _ in
                if let m, m.numberOfRanges == 3 {
                    let key = ns.substring(with: m.range(at: 1))
                        .lowercased()
                    let val = ns.substring(with: m.range(at: 2))
                    if let n = Double(val) {
                        if key == "width" {
                            width = CGFloat(n)
                        } else if key == "height" {
                            height = CGFloat(n)
                        }
                    }
                }
            }
        }
        return (width, height)
    }

    // An indented line cannot interrupt a paragraph; it continues it, per
    // CommonMark, with its own leading whitespace dropped before joining.

    private static func consumeParagraph(_ lines: [String],
                                         _ i: inout Int) -> Block {
        var body: [String] = []
        var level = 0
        var done = false
        while i < lines.count, !done {
            let line = lines[i]
            level = body.isEmpty ? 0 : setextLevel(line)
            let blank = line.trimmedOuter().isEmpty
            let other = leadingSpaces(line) < 4 &&
                        (isHeading(line) || isHR(line) || isFence(line) ||
                         isMathFence(line) ||
                         isTableStart(lines, i) || isQuoteStart(line) ||
                         listInterrupts(line) || imageBlock(line) != nil ||
                         centerOpener(line) != nil ||
                         isDetailsStart(line) || isCommentStart(line))
            if level > 0 {
                i += 1
                done = true
            } else if blank || other {
                done = true
            } else {
                body.append(line.trimmedLeading())
                i += 1
            }
        }
        let raw = body.joined(separator: "\n")
        return level > 0
            ? .heading(level: level, text: inline(raw.trimmedOuter()))
            : bareMath(raw) ?? .paragraph(inline(raw))
    }

    private static func setextLevel(_ line: String) -> Int {
        var result = 0
        let t = line.trimmedOuter()
        if leadingSpaces(line) < 4, let c = t.first, c == "=" || c == "-",
           t.allSatisfy({ ch in ch == c }) {
            result = c == "=" ? 1 : 2
        }
        return result
    }

    // The paragraph must OPEN with a control word and parse completely,
    // with nothing left over, before it is read as a bare TeX formula.

    private static func bareMath(_ raw: String) -> Block? {
        var result: Block? = nil
        if opensWithControlWord(raw), !hasProseWord(raw), TeX.parses(raw) {
            result = .math(raw)
        }
        return result
    }

    // Three or more bare ASCII letters outside braces and outside a
    // control word is prose wearing a backslash, not adjacent variables.

    private static func hasProseWord(_ raw: String) -> Bool {
        var depth = 0
        var run = 0
        var found = false
        var inCommand = false
        for ch in raw {
            if ch == "\\" {
                inCommand = true
                run = 0
            } else if inCommand, ch.isLetter {
                continue
            } else {
                inCommand = false
                if ch == "{" {
                    depth += 1
                    run = 0
                } else if ch == "}" {
                    depth = max(depth - 1, 0)
                    run = 0
                } else if ch.isLetter, ch.isASCII, depth == 0 {
                    run += 1
                    if run >= 3 { found = true }
                } else {
                    run = 0
                }
            }
        }
        return found
    }

    private static func opensWithControlWord(_ raw: String) -> Bool {
        var result = false
        let t = raw.trimmedLeading()
        if t.hasPrefix("\\"), let after = t.dropFirst().first {
            result = after.isLetter
        }
        return result
    }

    // Each maths span becomes a sentinel so the WHOLE line can be
    // markdown-parsed once, keeping emphasis that wraps a formula intact.

    private static func inline(_ raw: String) -> AttributedString {
        var stitched = ""
        var maths: [TeX.Segment] = []
        for segment in codeSpanSegments(raw) {
            if segment.code {
                stitched += segment.text
            } else {
                let literal = escapedAngles(segment.text)
                let withRefs = substituteRefs(htmlInline(literal))
                for piece in mathsOutsideLinks(withRefs) {
                    switch piece {
                        case .text(let s): stitched += s
                        case .math:
                            let mark = sentinel(maths.count)
                            stitched.unicodeScalars.append(mark)
                            maths.append(piece)
                    }
                }
            }
        }
        var out = parseInlineMarkdown(normalizeBreaks(stitched))
        if !maths.isEmpty {
            var spliced = AttributedString()
            var from = out.startIndex
            for (index, piece) in maths.enumerated() {
                if case .math(let s, let display) = piece,
                   let r = out[from...].range(of: String(sentinel(index))) {
                    let tex = s.replacingOccurrences(of: String(angle),
                                                     with: "<")
                    var rendered = TeX.render(s, display: display)
                    let fence = display ? "$$" : "$"
                    rendered[InlineMathAttribute.self] = fence + tex + fence
                    spliced.append(out[from..<r.lowerBound])
                    spliced.append(rendered)
                    from = r.upperBound
                }
            }
            spliced.append(out[from...])
            out = spliced
        }
        let angled = raw.unicodeScalars.contains { s in
            s == "<" || s == "&" || s == angle
        }
        if angled {
            applyTag(&out, "u") { sub in sub.underlineStyle = .single }
            applyTag(&out, "sup") { sub in sub[ScriptAttribute.self] = 1 }
            applyTag(&out, "sub") { sub in sub[ScriptAttribute.self] = -1 }
            applyTag(&out, "small") { sub in
                sub[SmallAttribute.self] = true
            }
            restoreAngles(&out)
        }
        return out
    }

    private static let angle = Unicode.Scalar(0x10FFFD) ?? "<"

    private static func escapedAngles(_ s: String) -> String {
        var result = s
        if s.contains("<") || s.contains("&") {
            let mark = String(angle)
            result = s.replacingOccurrences(
                    of: #"(?<!\\)((?:\\\\)*)\\<"#, with: "$1" + mark,
                    options: .regularExpression)
                .replacingOccurrences(of: "&lt;", with: mark,
                                      options: .caseInsensitive)
        }
        return result
    }

    private static func restoreAngles(_ a: inout AttributedString) {
        let mark = String(angle)
        if a.characters.contains(Character(angle)) {
            var rebuilt = AttributedString()
            for run in a.runs {
                let text = String(a[run.range].characters)
                    .replacingOccurrences(of: mark, with: "<")
                rebuilt.append(AttributedString(text,
                                                attributes: run.attributes))
            }
            a = rebuilt
        }
    }

    private static let linkTarget = try? NSRegularExpression(
        pattern: #"\]\([^)\s]*"#)

    private static func mathsOutsideLinks(_ s: String) -> [TeX.Segment] {
        var out: [TeX.Segment] = []
        let ns = s as NSString
        var last = 0
        let full = NSRange(location: 0, length: ns.length)
        for m in linkTarget?.matches(in: s, range: full) ?? [] {
            out += TeX.split(ns.substring(with: NSRange(
                location: last, length: m.range.location - last)))
            out.append(.text(ns.substring(with: m.range)))
            last = NSMaxRange(m.range)
        }
        out += TeX.split(ns.substring(from: last))
        return out
    }

    // Plane 16 private use, not the BMP block, so an icon font's glyphs
    // at U+E000 are never mistaken for a sentinel.

    private static func sentinel(_ index: Int) -> Unicode.Scalar {
        Unicode.Scalar(0x100000 + UInt32(index % 0xFFFD)) ?? " "
    }

    private static func parseInlineMarkdown(_ s: String)
                                            -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var result = AttributedString(s)
        if let parsed = try? AttributedString(markdown: s, options: opts) {
            result = parsed
        }
        return result
    }

    // A hard break is a line separator inside the paragraph, keeping its
    // spacing; a literal newline would split it into separate paragraphs.

    private static func normalizeBreaks(_ s: String) -> String {
        let lines = s
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var out: [String] = []
        for (idx, line) in lines.enumerated() {
            let last = idx == lines.count - 1
            let slashes = line.reversed().prefix { ch in ch == "\\" }.count
            let spaced = line.hasSuffix("  ")
            let hardBreak = (spaced || slashes % 2 == 1) && !last
            let trimmed = hardBreak ? String(line.dropLast(spaced ? 2 : 1))
                                    : line
            if hardBreak {
                out.append(trimmed + "\u{2028}")
            } else if last {
                var tail = trimmed
                while tail.hasSuffix(" ") { tail.removeLast() }
                out.append(tail)
            } else {
                out.append(trimmed + " ")
            }
        }
        return out.joined()
    }

    // A run of N backticks opens a span that the next run of exactly N
    // closes; an opener with no matching closer is plain text.

    static func codeSpanSegments(_ line: String)
        -> [(text: String, code: Bool)] {
        var out: [(text: String, code: Bool)] = []
        let chars = Array(line)
        var text = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "`" {
                var n = 0
                while i + n < chars.count, chars[i + n] == "`" { n += 1 }
                let close = closingRun(chars, from: i + n, length: n)
                if let close {
                    if !text.isEmpty { out.append((text, false)) }
                    text = ""
                    out.append((String(chars[i..<(close + n)]), true))
                    i = close + n
                } else {
                    text += String(chars[i..<(i + n)])
                    i += n
                }
            } else {
                text.append(chars[i])
                i += 1
            }
        }
        if !text.isEmpty { out.append((text, false)) }
        return out
    }

    private static func closingRun(_ chars: [Character], from start: Int,
                                   length: Int) -> Int? {
        var result: Int? = nil
        var i = start
        while i < chars.count, result == nil {
            if chars[i] == "`" {
                var n = 0
                while i + n < chars.count, chars[i + n] == "`" { n += 1 }
                if n == length { result = i }
                i += n
            } else {
                i += 1
            }
        }
        return result
    }

    // AttributedString indices go stale after a mutation, so the search
    // restarts from the top after each replace or removal.

    private static func applyTag(_ a: inout AttributedString,
                                 _ tag: String,
                                 style: (inout AttributedSubstring) -> Void) {
        var pairing = true
        while pairing {
            pairing = tagPass(&a, tag, style: style)
        }
    }

    private static func tagPass(_ a: inout AttributedString, _ tag: String,
                                style: (inout AttributedSubstring) -> Void)
        -> Bool {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var out = AttributedString()
        var from = a.startIndex
        var paired = false
        var closerAhead = true
        while let o = a[from...].range(of: open, options: .caseInsensitive) {
            let intent = a.runs[o.lowerBound].inlinePresentationIntent
            let c = closerAhead && intent?.contains(.code) != true
                ? a[o.upperBound...].range(of: close,
                                           options: .caseInsensitive)
                : nil
            if intent?.contains(.code) == true {
                out.append(a[from..<o.upperBound])
                from = o.upperBound
            } else if let c {
                out.append(a[from..<o.lowerBound])
                var sub = a[o.upperBound..<c.lowerBound]
                style(&sub)
                out.append(sub)
                from = c.upperBound
                paired = true
            } else {
                out.append(a[from..<o.lowerBound])
                from = o.upperBound
                closerAhead = false
            }
        }
        out.append(a[from...])
        a = out
        return paired
    }

}

private extension String {

    func trimmedOuter() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func trimmedLeading() -> String {
        var i = startIndex
        while i < endIndex, self[i] == " " || self[i] == "\t" {
            i = index(after: i)
        }
        return String(self[i...])
    }

}
