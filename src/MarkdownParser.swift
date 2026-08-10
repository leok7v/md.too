import Foundation

// <sub> and <sup> survive Apple's inline markdown parser as literal
// text, and there is no markdown spelling for either, so the tags are
// consumed here and the level left on the run for each renderer to set
// however its medium expresses a script: a baseline offset on screen and
// in the PDF, a real tag in the HTML, a Unicode digit in plain text.
// The value is the direction, +1 up and -1 down.
//
// A plain AttributedStringKey on purpose: it is read off attr.runs by
// every renderer and never has to survive NSAttributedString(_:), which
// drops custom keys outside a declared scope. applyScriptRuns bridges
// the two paths that do need it on the NS side.

enum ScriptAttribute: AttributedStringKey {
    typealias Value = Int
    static let name = "md.too.script"
}

enum Block {
    case heading(level: Int, text: AttributedString)
    case paragraph(AttributedString)
    case code(language: String?, text: String)
    case quote([Block])
    case list(items: [ListItem], tight: Bool)
    case table(headers: [String], rows: [[String]])
    // A $$...$$ display, carried as its TeX source. Inline $...$ stays
    // inside the paragraph's AttributedString: only a display gets a
    // block of its own, because only a display is typeset rather than
    // spelled out in Unicode.
    case math(String)
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
            } else if isMathFence(line) {
                blocks.append(consumeMath(lines, &i))
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

    private static func applyRefPattern(_ s: String, pattern: String,
                                        hasLabelGroup: Bool,
                                        refs: [String: URL]) -> String {
        var result = s
        if let re = try? NSRegularExpression(pattern: pattern) {
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
        if t.count >= 3, let c = t.first, c == "-" || c == "*" || c == "_" {
            result = t.allSatisfy { ch in ch == c || ch == " " || ch == "\t" }
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
        return .code(language: language, text: body.joined(separator: "\n"))
    }

    // Only a line that OPENS with $$ starts a display. A $$ met partway
    // through a sentence belongs to that sentence and is left to the
    // inline splitter, which is also what happens to every $...$.

    private static func isMathFence(_ s: String) -> Bool {
        s.trimmedOuter().hasPrefix("$$")
    }

    // Accepts both spellings authors use: the whole thing on one line,
    // and an opening $$ with the formula on the lines below. An
    // unterminated display runs to the end of the document rather than
    // swallowing the rest as prose.

    private static func consumeMath(_ lines: [String],
                                    _ i: inout Int) -> Block {
        var body: [String] = []
        var rest = String(lines[i].trimmedOuter().dropFirst(2))
        var closed = false
        if let end = rest.range(of: "$$", options: .backwards) {
            rest = String(rest[..<end.lowerBound])
            closed = true
        }
        if !rest.trimmedOuter().isEmpty { body.append(rest) }
        i += 1
        while i < lines.count, !closed {
            let t = lines[i].trimmedOuter()
            if let end = t.range(of: "$$") {
                let head = String(t[..<end.lowerBound])
                if !head.trimmedOuter().isEmpty { body.append(head) }
                closed = true
            } else {
                body.append(lines[i])
            }
            i += 1
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
          isMathFence(line) || isQuoteStart(line) || isListStart(line))
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
                        isMathFence(line) ||
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
        let raw = body.joined(separator: "\n")
        return bareMath(raw) ?? .paragraph(inline(raw))
    }

    // A converter lifting an equation out of a PDF writes the TeX with
    // nothing around it, and the paragraph then reads as a wall of
    // backslashes. Markdown has no opinion about this, so the test has
    // to be strict enough that prose can never pass it: the paragraph
    // must OPEN with a control word, and the whole of it must parse --
    // every token recognised, no unknown command, nothing left over.
    // A sentence that merely mentions \frac fails on its first ordinary
    // word, and a Windows path fails because \\ is not a control word.

    private static func bareMath(_ raw: String) -> Block? {
        var result: Block? = nil
        if opensWithControlWord(raw), !hasProseWord(raw), TeX.parses(raw) {
            result = .math(raw)
        }
        return result
    }

    // Parsing cleanly is not enough on its own. In maths, neighbouring
    // letters are separate variables multiplied together, so "\alpha is
    // the first letter" parses perfectly -- as alpha times i times s and
    // so on -- and would be typeset as a formula. A run of three or more
    // letters is prose wearing a backslash.
    //
    // Letters inside braces are exempt: that is where \text{} keeps its
    // words, and where the converters put them. Letters belonging to a
    // control word are exempt for the obvious reason.

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
        applyScriptTags(&out, tag: "sup", level: 1)
        applyScriptTags(&out, tag: "sub", level: -1)
        return out
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

    // Same shape as applyUnderlineTags: an unclosed opener is dropped
    // rather than left on screen, since a stray "<sup>" is markup the
    // reader never wrote and never wants to see.

    private static func applyScriptTags(_ a: inout AttributedString,
                                        tag: String, level: Int) {
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        while let o = a.range(of: open, options: .caseInsensitive) {
            if let c = a[o.upperBound...].range(of: close,
                                                options: .caseInsensitive) {
                var sub = a[o.upperBound..<c.lowerBound]
                sub[ScriptAttribute.self] = level
                a.replaceSubrange(o.lowerBound..<c.upperBound, with: sub)
            } else {
                a.removeSubrange(o)
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
