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
    case quote([Block])
    case list(items: [ListItem], tight: Bool)
    case table(headers: [String], rows: [[String]])
    case rule
    case image(alt: String, url: URL, width: CGFloat?, height: CGFloat?)
}

struct ListItem {
    let marker: String
    let checked: Bool?
    let blocks: [Block]
}

enum Markdown {

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
        let lowered = label.lowercased()
        let collapsed = lowered.split(whereSeparator: { c in
            c == " " || c == "\t" || c == "\n"
        }).joined(separator: " ")
        return collapsed
    }

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
                if t.hasPrefix(" ") { t = String(t.dropFirst()) }
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

    private static func afterMarker(_ tail: Substring, leading: Int,
                                    markerWidth: Int, label: String,
                                    sig: Character)
        -> (label: String, sig: Character, offset: Int, rest: String)? {
        var result: (String, Character, Int, String)? = nil
        let spaces = tail.prefix { c in c == " " }.count
        let blankRest = tail.allSatisfy { c in c == " " }
        if blankRest {
            result = (label, sig, leading + markerWidth + 1, "")
        } else if spaces >= 1 {
            let n = spaces >= 5 ? 1 : spaces
            result = (label, sig, leading + markerWidth + n,
                      String(tail.dropFirst(n)))
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
        if s.hasPrefix("[ ] ") {
            result = (false, String(s.dropFirst(4)))
        } else if s.hasPrefix("[x] ") || s.hasPrefix("[X] ") {
            result = (true, String(s.dropFirst(4)))
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
          isQuoteStart(line) || isListStart(line))
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
        var out = ""
        var i = s.startIndex
        while i < s.endIndex {
            var consumed = false
            if let frac = parseFracAt(s, from: i) {
                out.append(frac.a)
                out.append("⁄")
                out.append(frac.b)
                i = frac.end
                consumed = true
            }
            if !consumed {
                out.append(s[i])
                i = s.index(after: i)
            }
        }
        return out
    }

    private static func parseFracAt(_ s: String, from: String.Index)
        -> (a: String, b: String, end: String.Index)? {
        var result: (String, String, String.Index)? = nil
        if let afterCmd = s.index(from, offsetBy: 5,
                                  limitedBy: s.endIndex),
           s[from..<afterCmd] == "\\frac" {
            var j = afterCmd
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
                    let a = String(s[s.index(after: j)..<endA])
                    let b = String(s[s.index(after: k)..<endB])
                    result = (a, b, s.index(after: endB))
                }
            }
        }
        return result
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

