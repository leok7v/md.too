import SwiftUI
import UniformTypeIdentifiers

struct MarkdownDocument: FileDocument {
    static let readableContentTypes: [UTType] = {
        var t: [UTType] = []
        if let x = UTType(filenameExtension: "md") { t.append(x) }
        if let x = UTType(filenameExtension: "markdown") { t.append(x) }
        if let x = UTType(filenameExtension: "mdown") { t.append(x) }
        if let x = UTType(filenameExtension: "mkd") { t.append(x) }
        if let x = UTType("net.daringfireball.markdown") { t.append(x) }
        if let x = UTType("public.markdown") { t.append(x) }
        if t.isEmpty { t = [.plainText] }
        return t
    }()
    static let writableContentTypes: [UTType] = []

    var text: String = ""

    init() {}

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let str = String(data: data, encoding: .utf8) {
            text = str
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

enum Block {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case code(language: String?, text: String)
    case quote(AttributedString)
    case list([ListItem])
    case table(headers: [String], rows: [[String]])
    case rule
    case image(alt: String, url: URL, width: CGFloat?, height: CGFloat?)
}

struct ListItem {
    let marker: String
    let checked: Bool?
    let content: AttributedString
}

enum Markdown {

    // Active link-reference table for the parse currently underway.
    // @TaskLocal so concurrent parses (main-thread render + background
    // PDF export, etc.) each see their own document's refs.
    @TaskLocal private static var currentRefs: [String: URL] = [:]

    static func parse(_ source: String) -> [Block] {
        let raw = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let (lines, refs) = stripLinkDefinitions(raw)
        return Markdown.$currentRefs.withValue(refs) {
            parseBlocks(lines)
        }
    }

    private static func parseBlocks(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isFence(line) {
                blocks.append(consumeFenced(lines, &i))
            } else if isHeading(line) {
                blocks.append(consumeHeading(lines, &i))
            } else if isHR(line) {
                if case .rule = blocks.last { } else { blocks.append(.rule) }
                i += 1
            } else if isTableStart(lines, i) {
                blocks.append(consumeTable(lines, &i))
            } else if isQuoteStart(line) {
                blocks.append(consumeQuote(lines, &i))
            } else if isListStart(line) {
                blocks.append(consumeList(lines, &i))
            } else if isIndentedCode(line) {
                blocks.append(consumeIndentedCode(lines, &i))
            } else if line.trimmedOuter().isEmpty {
                i += 1
            } else if let img = imageBlock(line) {
                blocks.append(img)
                i += 1
            } else {
                blocks.append(consumeParagraph(lines, &i))
            }
        }
        return blocks
    }

    // Walk lines once. Pull single-line link-definition lines
    // (`[label]: url` optionally followed by a "title") out of the
    // stream and into a label -> URL table. Definitions inside a
    // fenced code block stay put. Multi-line definitions (where the
    // URL or title wraps onto the next line) are not supported in
    // this pass; the rare authors who write that can switch to inline
    // links.
    private static func stripLinkDefinitions(_ raw: [String])
        -> (lines: [String], refs: [String: URL]) {
        var refs: [String: URL] = [:]
        var out: [String] = []
        var inFence = false
        var fenceMarker = ""
        for line in raw {
            let trimmed = line.trimmedLeading()
            if inFence {
                if trimmed.hasPrefix(fenceMarker) { inFence = false }
                out.append(line)
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence = true
                fenceMarker = String(trimmed.prefix(3))
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
        if t.hasPrefix("[") {
            let rest = t.dropFirst()
            if let close = rest.firstIndex(of: "]") {
                let label = String(rest[..<close]).trimmedOuter()
                let after = rest[rest.index(after: close)...]
                if !label.isEmpty, after.hasPrefix(":") {
                    var rhs = String(after.dropFirst()).trimmedOuter()
                    // Optional title in "...", '...', or (...)
                    // — drop everything after the URL.
                    if let space = rhs.firstIndex(of: " ") {
                        rhs = String(rhs[..<space])
                    }
                    if rhs.hasPrefix("<"), rhs.hasSuffix(">") {
                        rhs = String(rhs.dropFirst().dropLast())
                    }
                    if let url = URL(string: rhs) {
                        result = (refKey(label), url)
                    }
                }
            }
        }
        return result
    }

    private static func refKey(_ label: String) -> String {
        // CommonMark: case-insensitive, internal whitespace collapsed.
        let lowered = label.lowercased()
        let collapsed = lowered.split(whereSeparator: { c in
            c == " " || c == "\t" || c == "\n"
        }).joined(separator: " ")
        return collapsed
    }

    // Rewrite `[text][label]`, `[text][]`, and bare `[text]` (when a
    // matching definition exists) into `[text](url)` so Apple's
    // built-in inline-Markdown parser can render them as hyperlinks.
    // Image variants `![alt][label]` and `![alt]` get the same
    // treatment. References inside backtick code spans are technically
    // mis-handled (they get rewritten), but Apple's parser keeps the
    // result inside the code span anyway, so the visible damage is
    // "[foo](bar)" appearing literal in a code span — rare in real
    // documents.
    private static func substituteRefs(_ s: String) -> String {
        let refs = Markdown.currentRefs
        var result = s
        if !refs.isEmpty {
            result = applyRefPattern(
                result, pattern: "(!?)\\[([^\\]\\n]+)\\]\\[([^\\]\\n]*)\\]",
                hasLabelGroup: true, refs: refs)
            result = applyRefPattern(
                result, pattern: "(!?)\\[([^\\]\\n]+)\\](?![\\[\\(:])",
                hasLabelGroup: false, refs: refs)
        }
        return result
    }

    private static func applyRefPattern(_ s: String,
                                        pattern: String,
                                        hasLabelGroup: Bool,
                                        refs: [String: URL]) -> String {
        var result = s
        if let re = try? NSRegularExpression(pattern: pattern) {
            let ns = s as NSString
            let matches = re.matches(
                in: s,
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

    private static func isHeading(_ s: String) -> Bool {
        var result = false
        let t = s.trimmedOuter()
        let n = t.prefix { c in c == "#" }.count
        if n >= 1 && n <= 6 {
            let rest = t.dropFirst(n)
            result = rest.hasPrefix(" ") || rest.isEmpty
        }
        return result
    }

    private static func consumeHeading(_ lines: [String],
                                       _ i: inout Int) -> Block {
        let t = lines[i].trimmedOuter()
        let n = t.prefix { c in c == "#" }.count
        let body = String(t.dropFirst(n)).trimmedOuter()
        i += 1
        return .heading(level: n, text: inline(body))
    }

    private static func isHR(_ s: String) -> Bool {
        var result = false
        let t = s.trimmedOuter()
        if t.count >= 3, let c = t.first,
           c == "-" || c == "*" || c == "_" {
            result = t.allSatisfy { ch in
                ch == c || ch == " " || ch == "\t"
            }
        }
        return result
    }

    private static func isFence(_ s: String) -> Bool {
        let t = s.trimmedLeading()
        return t.hasPrefix("```") || t.hasPrefix("~~~")
    }

    private static func consumeFenced(_ lines: [String],
                                      _ i: inout Int) -> Block {
        let raw = lines[i]
        let t = raw.trimmedLeading()
        let fence = String(t.prefix(3))
        let lang = String(t.dropFirst(3)).trimmedOuter()
        let indent = raw.count - t.count
        let pad = String(repeating: " ", count: indent)
        i += 1
        var body: [String] = []
        var done = false
        while i < lines.count, !done {
            let line = lines[i]
            let trimmed = line.trimmedLeading()
            if trimmed.hasPrefix(fence) {
                done = true
            } else if indent > 0, line.hasPrefix(pad) {
                body.append(String(line.dropFirst(indent)))
            } else {
                body.append(line)
            }
            i += 1
        }
        let language = lang.isEmpty ? nil : String(lang)
        return .code(language: language,
                     text: body.joined(separator: "\n"))
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
        s.trimmedOuter().hasPrefix(">")
    }

    private static func consumeQuote(_ lines: [String],
                                     _ i: inout Int) -> Block {
        var body: [String] = []
        while i < lines.count, isQuoteStart(lines[i]) {
            var t = lines[i].trimmedOuter()
            if t.hasPrefix(">") { t.removeFirst() }
            if t.hasPrefix(" ") { t.removeFirst() }
            body.append(String(t))
            i += 1
        }
        return .quote(inline(body.joined(separator: "\n")))
    }

    private static func isListStart(_ s: String) -> Bool {
        var result = false
        let t = s.trimmedOuter()
        if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
            result = true
        } else {
            let n = t.prefix { c in c.isNumber }
            result = !n.isEmpty && t.dropFirst(n.count).hasPrefix(". ")
        }
        return result
    }

    private static func consumeList(_ lines: [String],
                                    _ i: inout Int) -> Block {
        var items: [ListItem] = []
        while i < lines.count, isListStart(lines[i]) {
            let t = lines[i].trimmedOuter()
            var marker = "•"
            var body = t
            if t.hasPrefix("- ") ||
               t.hasPrefix("* ") ||
               t.hasPrefix("+ ") {
                body = String(t.dropFirst(2))
            } else {
                let n = t.prefix { c in c.isNumber }
                let rest = t.dropFirst(n.count)
                if rest.hasPrefix(". ") {
                    marker = String(n) + "."
                    body = String(rest.dropFirst(2))
                }
            }
            var checked: Bool? = nil
            if body.hasPrefix("[ ] ") {
                checked = false
                body = String(body.dropFirst(4))
            } else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") {
                checked = true
                body = String(body.dropFirst(4))
            }
            items.append(ListItem(marker: marker,
                                  checked: checked,
                                  content: inline(body)))
            i += 1
        }
        return .list(items)
    }

    private static func isTableRow(_ s: String) -> Bool {
        let t = s.trimmedOuter()
        return t.contains("|") && !t.isEmpty
    }

    private static func isTableSeparator(_ s: String) -> Bool {
        var result = false
        let t = s.trimmedOuter()
        if t.contains("|"), t.contains("-") {
            result = t.allSatisfy { ch in "-:| \t".contains(ch) }
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
        if i < lines.count, isTableRow(lines[i]) {
            headers = parseRow(lines[i])
            i += 1
        }
        if i < lines.count, isTableSeparator(lines[i]) {
            i += 1
        }
        while i < lines.count, isTableRow(lines[i]) {
            rows.append(parseRow(lines[i]))
            i += 1
        }
        return .table(headers: headers, rows: rows)
    }

    private static func parseRow(_ s: String) -> [String] {
        let pipes = CharacterSet(charactersIn: "|")
        let t = s.trimmedOuter().trimmingCharacters(in: pipes)
        return t.split(separator: "|", omittingEmptySubsequences: false)
            .map { p in p.trimmingCharacters(in: .whitespaces) }
    }

    private static let imagePattern =
        #"^!\[([^\]]*)\]\(([^\s\)]+)(?:\s+"[^"]*")?\)"#
        + #"\s*(?:\{([^}]*)\})?\s*$"#

    private static let imageLineRegex: NSRegularExpression? =
        try? NSRegularExpression(pattern: imagePattern)

    private static func imageBlock(_ line: String) -> Block? {
        var result: Block? = nil
        if let re = imageLineRegex {
            let trimmed = line.trimmedOuter()
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

    private static func parseDimensions(_ attrs: String)
        -> (CGFloat?, CGFloat?) {
        var width: CGFloat?
        var height: CGFloat?
        let pat = #"(width|height)\s*=\s*(\d+(?:\.\d+)?)(?:px)?"#
        if let re = try? NSRegularExpression(pattern: pat,
                                             options: .caseInsensitive) {
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

    private static func consumeParagraph(_ lines: [String],
                                         _ i: inout Int) -> Block {
        var body: [String] = []
        var done = false
        while i < lines.count, !done {
            let line = lines[i]
            let blank = line.trimmedOuter().isEmpty
            let other = isHeading(line) || isHR(line) || isFence(line) ||
                        isTableStart(lines, i) || isQuoteStart(line) ||
                        isListStart(line) || isIndentedCode(line) ||
                        imageBlock(line) != nil
            if blank || other {
                done = true
            } else {
                body.append(line)
                i += 1
            }
        }
        return .paragraph(inline(body.joined(separator: "\n")))
    }

    private static func inline(_ raw: String) -> AttributedString {
        let withRefs = substituteRefs(raw)
        let normalized = normalizeBreaks(withRefs)
        let segments = TeX.split(normalized)
        var out = AttributedString()
        for seg in segments {
            switch seg {
                case .text(let s): out.append(parseInlineMarkdown(s))
                case .math(let s, let display):
                    out.append(TeX.render(s, display: display))
            }
        }
        applyUnderlineTags(&out)
        return out
    }

    private static func parseInlineMarkdown(_ s: String)
        -> AttributedString {
        let opts = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var result = AttributedString(s)
        if let parsed = try? AttributedString(markdown: s,
                                              options: opts) {
            result = parsed
        }
        return result
    }

    private static func normalizeBreaks(_ s: String) -> String {
        let lines = s
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var out: [String] = []
        for (idx, line) in lines.enumerated() {
            let last = idx == lines.count - 1
            let hardBreak = line.hasSuffix("  ")
            let trimmed = hardBreak ? String(line.dropLast(2)) : line
            if hardBreak {
                out.append(trimmed + "\n")
            } else if last {
                out.append(trimmed)
            } else {
                out.append(trimmed + " ")
            }
        }
        return out.joined()
    }

    private static func applyUnderlineTags(_ a: inout AttributedString) {
        while let open = a.range(of: "<u>", options: .caseInsensitive) {
            if let close = a[open.upperBound...].range(
                of: "</u>", options: .caseInsensitive) {
                var sub = a[open.upperBound..<close.lowerBound]
                sub.underlineStyle = .single
                a.replaceSubrange(open.lowerBound..<close.upperBound, with: sub)
            } else {
                a.removeSubrange(open)
            }
        }
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

enum TeX {

    enum Segment {
        case text(String)
        case math(String, display: Bool)
    }

    static func split(_ s: String) -> [Segment] {
        var out: [Segment] = []
        var buf = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            var consumed = false
            if c == "\\",
               let next = s.index(i, offsetBy: 1,
                                  limitedBy: s.endIndex),
               next < s.endIndex,
               s[next] == "$" {
                buf.append("$")
                i = s.index(after: next)
                consumed = true
            }
            if !consumed, c == "$" {
                var isDisplay = false
                if let nx = s.index(i, offsetBy: 1,
                                    limitedBy: s.endIndex) {
                    isDisplay = nx < s.endIndex && s[nx] == "$"
                }
                let endMarker = isDisplay ? "$$" : "$"
                let off = isDisplay ? 2 : 1
                let searchStart = s.index(i, offsetBy: off)
                if searchStart <= s.endIndex,
                   let endRange = s.range(
                    of: endMarker,
                    range: searchStart..<s.endIndex) {
                    if !buf.isEmpty {
                        out.append(.text(buf))
                        buf.removeAll()
                    }
                    let body = String(s[searchStart..<endRange.lowerBound])
                    out.append(.math(body, display: isDisplay))
                    i = endRange.upperBound
                    consumed = true
                }
            }
            if !consumed {
                buf.append(c)
                i = s.index(after: i)
            }
        }
        if !buf.isEmpty { out.append(.text(buf)) }
        return out
    }

    static func render(_ src: String, display: Bool) -> AttributedString {
        let rendered = renderToString(src)
        var a = AttributedString(rendered)
        a.font = display ? .system(.title3).italic() : .system(.body).italic()
        return a
    }

    private static func renderToString(_ src: String) -> String {
        var s = expandText(src)
        s = expandFractions(s)
        s = expandScript(s, prefix: "^", map: superscriptMap)
        s = expandScript(s, prefix: "_", map: subscriptMap)
        s = replaceTokens(s)
        s = s.replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func expandText(_ s: String) -> String {
        // Replace \text{X} with {X} so subscripts/superscripts pick up the
        // whole body as a unit (e.g. M_\text{electron} -> M_{electron}).
        // Standalone \text{X} loses its braces at the end of the pipeline
        // when stray { and } are stripped, so the body still surfaces clean.
        var out = s
        let pattern = #"\\text\s*\{([^{}]*)\}"#
        while let r = out.range(of: pattern, options: .regularExpression) {
            let replaced = out[r].replacingOccurrences(
                of: #"^\\text\s*\{([^{}]*)\}$"#,
                with: "{$1}",
                options: .regularExpression)
            out.replaceSubrange(r, with: replaced)
        }
        return out
    }

    private static func expandFractions(_ s: String) -> String {
        // Manual brace matching so \frac{a}{b} works even when a or b
        // contain other brace groups (e.g. \frac{M_{electron}}{M_{this}}).
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            var consumed = false
            if let next = s.index(i, offsetBy: 5, limitedBy: s.endIndex),
               s[i..<next] == "\\frac" {
                var j = next
                while j < s.endIndex, s[j].isWhitespace {
                    j = s.index(after: j)
                }
                if j < s.endIndex, s[j] == "{",
                   let endA = matchBrace(s, from: j) {
                    var k = s.index(after: endA)
                    while k < s.endIndex, s[k].isWhitespace {
                        k = s.index(after: k)
                    }
                    if k < s.endIndex, s[k] == "{",
                       let endB = matchBrace(s, from: k) {
                        out.append(String(s[s.index(after: j)..<endA]))
                        out.append("⁄")
                        out.append(String(s[s.index(after: k)..<endB]))
                        i = s.index(after: endB)
                        consumed = true
                    }
                }
            }
            if !consumed {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func matchBrace(_ s: String,
                                   from: String.Index) -> String.Index? {
        var result: String.Index? = nil
        if from < s.endIndex, s[from] == "{" {
            var depth = 1
            var i = s.index(after: from)
            while i < s.endIndex, result == nil {
                if s[i] == "{" {
                    depth += 1
                } else if s[i] == "}" {
                    depth -= 1
                    if depth == 0 { result = i }
                }
                i = s.index(after: i)
            }
        }
        return result
    }

    private static func expandScript(_ s: String,
                                  prefix: Character,
                                     map: [Character: Character]) -> String {
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            var consumed = false
            if c == prefix,
               let next = s.index(i, offsetBy: 1,
                                  limitedBy: s.endIndex),
               next < s.endIndex {
                let after = s[next]
                if after == "{" {
                    let tail = s[s.index(after: next)...]
                    if let close = tail.firstIndex(of: "}") {
                        let start = s.index(after: next)
                        let body = String(s[start..<close])
                        out.append(mapScript(body, map: map))
                        i = s.index(after: close)
                        consumed = true
                    }
                } else {
                    out.append(mapScript(String(after), map: map))
                    i = s.index(after: next)
                    consumed = true
                }
            }
            if !consumed {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func mapScript(_ s: String,
                                  map: [Character: Character]) -> String {
        // Single-char bodies use the Unicode subscript/superscript glyph
        // when available (digits and a common letter set). Multi-char
        // bodies fall back to parens because Unicode subscript letters in
        // U+2090..U+209C have uneven font support and render inconsistently
        // (some letters subscript, some plain). Parens keep the visual
        // grouping consistent across fonts.
        var result = "(" + s + ")"
        if s.isEmpty {
            result = ""
        } else if s.count == 1, let first = s.first, let m = map[first] {
            result = String(m)
        }
        return result
    }

    private static func replaceTokens(_ s: String) -> String {
        var out = s
        let pairs = tokenMap.sorted { a, b in a.key.count > b.key.count }
        for (k, v) in pairs {
            out = out.replacingOccurrences(of: k, with: v)
        }
        return out
    }

    private static let tokenMap: [String: String] = [
        "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ",
        "\\epsilon": "ε", "\\varepsilon": "ε", "\\zeta": "ζ", "\\eta": "η",
        "\\theta": "θ", "\\vartheta": "ϑ", "\\iota": "ι", "\\kappa": "κ",
        "\\lambda": "λ", "\\mu": "μ", "\\nu": "ν", "\\xi": "ξ",
        "\\pi": "π", "\\varpi": "ϖ", "\\rho": "ρ", "\\varrho": "ϱ",
        "\\sigma": "σ", "\\varsigma": "ς", "\\tau": "τ", "\\upsilon": "υ",
        "\\phi": "φ", "\\varphi": "ϕ", "\\chi": "χ",
        "\\psi": "ψ", "\\omega": "ω",
        "\\Gamma": "Γ", "\\Delta": "Δ", "\\Theta": "Θ", "\\Lambda": "Λ",
        "\\Xi": "Ξ", "\\Pi": "Π", "\\Sigma": "Σ", "\\Upsilon": "Υ",
        "\\Phi": "Φ", "\\Psi": "Ψ", "\\Omega": "Ω",
        "\\times": "×", "\\cdot": "·", "\\div": "÷",
        "\\pm": "±", "\\mp": "∓",
        "\\le": "≤", "\\leq": "≤", "\\ge": "≥", "\\geq": "≥",
        "\\neq": "≠", "\\ne": "≠", "\\approx": "≈", "\\equiv": "≡",
        "\\sim": "∼", "\\propto": "∝",
        "\\to": "→", "\\rightarrow": "→",
        "\\leftarrow": "←", "\\Rightarrow": "⇒",
        "\\Leftarrow": "⇐", "\\leftrightarrow": "↔",
        "\\Leftrightarrow": "⇔",
        "\\sum": "∑", "\\prod": "∏", "\\int": "∫", "\\oint": "∮",
        "\\infty": "∞", "\\partial": "∂", "\\nabla": "∇",
        "\\forall": "∀", "\\exists": "∃", "\\nexists": "∄",
        "\\in": "∈", "\\notin": "∉", "\\subset": "⊂", "\\supset": "⊃",
        "\\subseteq": "⊆", "\\supseteq": "⊇",
        "\\cup": "∪", "\\cap": "∩",
        "\\emptyset": "∅", "\\varnothing": "∅",
        "\\sqrt": "√", "\\angle": "∠", "\\perp": "⊥", "\\parallel": "∥",
        "\\land": "∧", "\\lor": "∨", "\\lnot": "¬", "\\neg": "¬",
        "\\dots": "…", "\\ldots": "…", "\\cdots": "⋯", "\\vdots": "⋮",
        "\\hbar": "ℏ", "\\ell": "ℓ", "\\Re": "ℜ", "\\Im": "ℑ",
        "\\mathbb{R}": "ℝ", "\\mathbb{N}": "ℕ", "\\mathbb{Z}": "ℤ",
        "\\mathbb{Q}": "ℚ", "\\mathbb{C}": "ℂ",
        "\\left": "", "\\right": "", "\\,": " ", "\\;": " ", "\\ ": " ",
        "\\\\": "\n",
    ]

    private static let superscriptMap: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ",
        "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ",
        "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ",
        "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
    ]

    private static let subscriptMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
        "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]
}

