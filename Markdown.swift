import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#elseif os(iOS)
import UIKit
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#endif

#if !QUICKLOOK_EXTENSION
@main
struct MarkdownPreviewApp: App {
    init() {
        TempPDFs.cleanOnLaunch()
        primeOpenPanelDefault()
    }

    private func primeOpenPanelDefault() {
        // First-run open panel defaults to /Applications because that's
        // where the .app lives. Point it at ~/Documents instead by
        // seeding the keys NSOpenPanel reads on launch (only when the
        // user hasn't picked anything yet).
        #if os(macOS) && !QUICKLOOK_EXTENSION
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first
        guard let docs else { return }
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "NSNavLastRootDirectory") == nil {
            defaults.set(docs.path, forKey: "NSNavLastRootDirectory")
        }
        if defaults.data(forKey: "NSOSPLastRootDirectory") == nil,
           let bookmark = try? docs.bookmarkData() {
            defaults.set(bookmark, forKey: "NSOSPLastRootDirectory")
        }
        #endif
    }

    var body: some Scene {
        let scene = DocumentGroup(viewing: MarkdownDocument.self) { file in
            MarkdownView(text: file.document.text, fileURL: file.fileURL)
                .frame(minWidth: 360, minHeight: 360)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #if os(macOS)
        return scene.defaultSize(width: 800, height: 900)
        #else
        return scene
        #endif
    }
}
#endif

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

    static func parse(_ source: String) -> [Block] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
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
        let normalized = normalizeBreaks(raw)
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

enum FontRole {

    case body
    case heading(Int)
    case mono

    var platformFont: PlatformFont {
        switch self {
            case .body:
                return PlatformFont.preferredFont(forTextStyle: .body)
            case .heading(let n):
                let style: PlatformFont.TextStyle
                switch n {
                    case 1: style = .largeTitle
                    case 2: style = .title1
                    case 3: style = .title2
                    case 4: style = .title3
                    case 5: style = .headline
                    default: style = .subheadline
                }
                let base = PlatformFont.preferredFont(forTextStyle: style)
                return bold(base)
            case .mono:
                #if os(macOS)
                return NSFont.monospacedSystemFont(
                    ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                    weight: .regular)
                #else
                return UIFont.monospacedSystemFont(
                    ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize,
                    weight: .regular)
                #endif
        }
    }

    private func bold(_ f: PlatformFont) -> PlatformFont {
        var result = f
        #if os(macOS)
        var traits = f.fontDescriptor.symbolicTraits
        traits.insert(.bold)
        let d = f.fontDescriptor.withSymbolicTraits(traits)
        result = NSFont(descriptor: d, size: f.pointSize) ?? f
        #else
        var traits = f.fontDescriptor.symbolicTraits
        traits.insert(.traitBold)
        if let d = f.fontDescriptor.withSymbolicTraits(traits) {
            result = UIFont(descriptor: d, size: f.pointSize)
        }
        #endif
        return result
    }
}

struct PrefetchedImagesKey: EnvironmentKey {
    static let defaultValue: [URL: Image] = [:]
}

extension EnvironmentValues {
    var prefetchedImages: [URL: Image] {
        get { self[PrefetchedImagesKey.self] }
        set { self[PrefetchedImagesKey.self] = newValue }
    }
}

enum ThemeMode: String, CaseIterable {

    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
        }
    }

    var symbol: String {
        switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max.fill"
            case .dark: return "moon.fill"
        }
    }

    var help: String {
        switch self {
            case .system: return "Theme: System (click for Light)"
            case .light: return "Theme: Light (click for Dark)"
            case .dark: return "Theme: Dark (click for System)"
        }
    }

    var next: ThemeMode {
        switch self {
            case .system: return .light
            case .light: return .dark
            case .dark: return .system
        }
    }
}

#if os(macOS) && !QUICKLOOK_EXTENSION

private struct WindowFrameAutosave: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        apply(to: v)
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }
    private func apply(to view: NSView) {
        DispatchQueue.main.async {
            if let w = view.window, w.frameAutosaveName != name {
                _ = w.setFrameAutosaveName(name)
            }
        }
    }
}

private struct WindowAppearanceApplier: NSViewRepresentable {
    let scheme: ColorScheme?

    final class Coordinator {
        var scheme: ColorScheme?
        var observers: [NSObjectProtocol] = []
        weak var view: NSView?
        deinit {
            for o in observers {
                NotificationCenter.default.removeObserver(o)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        let coord = context.coordinator
        coord.scheme = scheme
        coord.view = v
        let names: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeKeyNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ]
        coord.observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak coord] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let coord, let view = coord.view {
                        view.window?.appearance =
                            Self.appearanceFor(coord.scheme)
                    }
                }
            }
        }
        DispatchQueue.main.async {
            v.window?.appearance = Self.appearanceFor(scheme)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.scheme = scheme
        DispatchQueue.main.async {
            nsView.window?.appearance = Self.appearanceFor(scheme)
        }
    }

    static func dismantleNSView(_ nsView: NSView,
                                coordinator: Coordinator) {
        for o in coordinator.observers {
            NotificationCenter.default.removeObserver(o)
        }
    }

    private static func appearanceFor(_ scheme: ColorScheme?)
        -> NSAppearance? {
        var result: NSAppearance? = nil
        switch scheme {
            case .none: result = nil
            case .light: result = NSAppearance(named: .aqua)
            case .dark: result = NSAppearance(named: .darkAqua)
            @unknown default: result = nil
        }
        return result
    }
}

#elseif os(iOS)

private struct WindowAppearanceApplier: UIViewRepresentable {
    let scheme: ColorScheme?
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        apply(to: v)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        apply(to: uiView)
    }
    private func apply(to view: UIView) {
        var style: UIUserInterfaceStyle = .unspecified
        switch scheme {
            case .none: style = .unspecified
            case .light: style = .light
            case .dark: style = .dark
            @unknown default: style = .unspecified
        }
        DispatchQueue.main.async {
            view.window?.overrideUserInterfaceStyle = style
        }
    }
}

#endif

struct MarkdownView: View {
    let text: String
    let fileURL: URL?

    @AppStorage("themeMode")
    private var themeRaw: String = ThemeMode.system.rawValue

    private var theme: ThemeMode {
        ThemeMode(rawValue: themeRaw) ?? .system
    }

    init(text: String, fileURL: URL? = nil) {
        self.text = text
        self.fileURL = fileURL
    }

    @ViewBuilder
    var body: some View {
        #if QUICKLOOK_EXTENSION
        let body = scrollContent
            .background(systemBackground)
            .preferredColorScheme(theme.colorScheme)
        #else
        let body = scrollContent
            .background(systemBackground)
            .background(WindowAppearanceApplier(scheme: theme.colorScheme))
            .preferredColorScheme(theme.colorScheme)
        #endif
        #if QUICKLOOK_EXTENSION
        body.overlay(alignment: .topTrailing) {
            ThemeButton(theme: theme) {
                themeRaw = theme.next.rawValue
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        #else
        let withAutosave: AnyView = {
            var v = AnyView(body)
            #if os(macOS)
            if let url = fileURL {
                let autosave = WindowFrameAutosave(
                    name: "Markdown.Preview:\(url.path)")
                v = AnyView(body.background(autosave))
            }
            #endif
            return v
        }()
        withAutosave.toolbar {
            ToolbarItem(placement: .primaryAction) {
                ThemeButton(theme: theme) {
                    themeRaw = theme.next.rawValue
                }
            }
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                SaveButton(text: text, fileURL: fileURL)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                ShareButton(text: text, fileURL: fileURL)
            }
        }
        #endif
    }

    private var scrollContent: some View {
        let blocks = Markdown.parse(text)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()),
                        id: \.offset) { _, block in
                    BlockView(block: block)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var systemBackground: Color {
        #if os(macOS)
        return Color(nsColor: .textBackgroundColor)
        #else
        return Color(.systemBackground)
        #endif
    }
}

private struct BlockView: View {
    let block: Block

    var body: some View {
        switch block {
            case .heading(let level, let text):
                SelectableText(attributed: text, role: .heading(level))
                    .padding(.top, level <= 2 ? 8 : 4)
            case .paragraph(let text):
                SelectableText(attributed: text, role: .body)
            case .code(let language, let text):
                CodeBlock(text: text, language: language)
            case .quote(let text):
                HStack(alignment: .top, spacing: 8) {
                    Rectangle().fill(Color.secondary.opacity(0.5))
                        .frame(width: 3)
                    SelectableText(attributed: text,
                                   role: .body, secondary: true)
                }
            case .list(let items): ListBlock(items: items)
            case .table(let headers, let rows):
                TableBlock(headers: headers, rows: rows)
            case .rule:
                Rectangle().fill(Color.secondary.opacity(0.4))
                    .frame(height: 1)
                    .padding(.vertical, 4)
            case .image(let alt, let url, let width, let height):
                ImageBlockView(alt: alt, url: url,
                               width: width, height: height)
        }
    }
}

private struct ImageBlockView: View {

    let alt: String
    let url: URL
    let width: CGFloat?
    let height: CGFloat?
    @Environment(\.prefetchedImages) private var prefetched
    @State private var image: Image?
    @State private var failed = false

    var body: some View {
        let resolved = image ?? prefetched[url]
        Group {
            if let resolved {
                sized(resolved)
            } else if failed {
                placeholder(alt.isEmpty ? "image unavailable" : alt)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                placeholder("loading…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityLabel(alt)
        .task(id: url) { await load() }
    }

    @ViewBuilder
    private func sized(_ image: Image) -> some View {
        let scaled = image.resizable().scaledToFit()
        if let w = width, let h = height {
            scaled.frame(width: w, height: h, alignment: .leading)
        } else if let w = width {
            scaled.frame(maxWidth: w, alignment: .leading)
        } else if let h = height {
            scaled.frame(maxHeight: h, alignment: .leading)
        } else {
            scaled.frame(maxWidth: 320, alignment: .leading)
        }
    }

    private func load() async {
        image = nil
        failed = false
        var req = URLRequest(url: url)
        let agent = "Markdown.Preview/1.0" +
                    " (https://github.com/leok7v/md.too)"
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        var done = false
        var attempt = 0
        while attempt < 2, !done {
            do {
                let (data, response) =
                    try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                var decoded: Image? = nil
                #if os(macOS)
                if let nsImage = NSImage(data: data) {
                    decoded = Image(nsImage: nsImage)
                }
                #else
                if let uiImage = UIImage(data: data) {
                    decoded = Image(uiImage: uiImage)
                }
                #endif
                if let decoded {
                    image = decoded
                    done = true
                } else {
                    throw URLError(.cannotDecodeContentData)
                }
            } catch {
                if attempt < 1 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                } else {
                    failed = true
                }
            }
            attempt += 1
        }
    }

    private func placeholder(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
            Text(text)
                .foregroundStyle(.secondary)
                .italic()
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

}

private struct ListBlock: View {

    let items: [ListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    marker(item)
                        .frame(minWidth: 22, alignment: .trailing)
                    SelectableText(attributed: item.content, role: .body)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: ListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
        } else {
            Text(item.marker).foregroundStyle(.secondary)
        }
    }
}

private struct CodeBlock: View {

    let text: String
    let language: String?

    var body: some View {
        let baseFont = FontRole.mono.platformFont
        let highlighted = Highlight.attribute(text,
                                              language: language,
                                              baseFont: baseFont)
        ScrollView(.horizontal, showsIndicators: false) {
            SelectableText(nsAttributed: highlighted,
                           role: .mono,
                           nowrap: true)
                .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.1))
        )
        .overlay(alignment: .topTrailing) {
            CopyButton(string: text)
                .padding(6)
        }
    }
}

private struct TableBlock: View {

    let headers: [String]
    let rows: [[String]]

    var body: some View {
        let widest = rows.map { row in row.count }.max() ?? 0
        let columnCount = max(headers.count, widest)
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 12,
                 verticalSpacing: 6) {
                if !headers.isEmpty {
                    GridRow {
                        ForEach(Array(headers.enumerated()),
                                id: \.offset) { _, cell in
                            cellView(cell, bold: true)
                        }
                    }
                    Divider().gridCellColumns(columnCount)
                }
                ForEach(Array(rows.enumerated()),
                        id: \.offset) { idx, r in
                    GridRow {
                        ForEach(Array(r.enumerated()),
                                id: \.offset) { _, cell in
                            cellView(cell, bold: false)
                        }
                    }
                    if idx < rows.count - 1 {
                        Divider()
                            .opacity(0.4)
                            .gridCellColumns(columnCount)
                    }
                }
            }
            .padding(8)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(alignment: .topTrailing) {
            CopyButton(string: serialize())
                .padding(6)
        }
    }

    @ViewBuilder
    private func cellView(_ cell: String, bold: Bool) -> some View {
        let parsed = Markdown.parse(cell)
        if let first = parsed.first,
           case .image(let alt, let url, let w, let h) = first {
            ImageBlockView(alt: alt, url: url, width: w, height: h)
        } else {
            SelectableText(attributed: cellAttributed(cell,
                               parsed: parsed),
                                 role: .body,
                               nowrap: true,
                                 bold: bold)
        }
    }

    private func cellAttributed(_ cell: String,
                                parsed: [Block]) -> AttributedString {
        var result = AttributedString(cell)
        if let first = parsed.first,
           case .paragraph(let a) = first {
            result = a
        }
        return result
    }

    private func serialize() -> String {
        var out = ""
        if !headers.isEmpty {
            out += "| " + headers.joined(separator: " | ") + " |\n"
            let dashes = Array(repeating: "---", count: headers.count)
                .joined(separator: "|")
            out += "|" + dashes + "|\n"
        }
        for r in rows {
            out += "| " + r.joined(separator: " | ") + " |\n"
        }
        return out
    }
}

private struct CopyButton: View {

    let string: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(4)
                .background(Circle().fill(Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
        .help("Copy")
    }

    private func copy() {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

struct SelectableText: View {

    let attributed: AttributedString?
    let nsAttributed: NSAttributedString?
    let role: FontRole
    let nowrap: Bool
    let bold: Bool
    let secondary: Bool

    init(attributed: AttributedString, role: FontRole = .body,
         nowrap: Bool = false, bold: Bool = false, secondary: Bool = false) {
        self.attributed = attributed
        self.nsAttributed = nil
        self.role = role
        self.nowrap = nowrap
        self.bold = bold
        self.secondary = secondary
    }

    init(nsAttributed: NSAttributedString, role: FontRole = .body,
         nowrap: Bool = false, bold: Bool = false, secondary: Bool = false) {
        self.attributed = nil
        self.nsAttributed = nsAttributed
        self.role = role
        self.nowrap = nowrap
        self.bold = bold
        self.secondary = secondary
    }

    var body: some View {
        NativeText(attributed: attributed,
                   nsAttributed: nsAttributed,
                   role: role,
                   nowrap: nowrap,
                   bold: bold,
                   secondary: secondary)
            .fixedSize(horizontal: nowrap, vertical: true)
    }
}

private struct NativeText {

    let attributed: AttributedString?
    let nsAttributed: NSAttributedString?
    let role: FontRole
    let nowrap: Bool
    let bold: Bool
    let secondary: Bool

    func resolved() -> NSAttributedString {
        let ns: NSMutableAttributedString
        if let nsAttributed {
            ns = NSMutableAttributedString(
                attributedString: nsAttributed)
        } else if let attributed {
            ns = NSMutableAttributedString(
                attributedString: NSAttributedString(attributed))
        } else {
            ns = NSMutableAttributedString(string: "")
        }
        let full = NSRange(location: 0, length: ns.length)
        let baseFont = role.platformFont
        ns.enumerateAttribute(.font,
                              in: full,
                              options: []) { value, range, _ in
            if let f = value as? PlatformFont {
                let merged = mergeTraits(of: f, into: baseFont,
                                         bold: bold)
                ns.addAttribute(.font, value: merged, range: range)
            } else {
                let final = bold ? boldFont(baseFont) : baseFont
                ns.addAttribute(.font, value: final, range: range)
            }
        }
        let defaultColor = secondary ? secondaryColor : primaryColor
        ns.enumerateAttribute(.foregroundColor,
                              in: full,
                              options: []) { value, range, _ in
            if value == nil {
                ns.addAttribute(.foregroundColor,
                                value: defaultColor,
                                range: range)
            }
        }
        return ns
    }

    private var primaryColor: PlatformColor {
        #if os(macOS)
        return NSColor.textColor
        #else
        return UIColor.label
        #endif
    }

    private var secondaryColor: PlatformColor {
        #if os(macOS)
        return NSColor.secondaryLabelColor
        #else
        return UIColor.secondaryLabel
        #endif
    }

    private func mergeTraits(of source: PlatformFont,
                             into base: PlatformFont,
                             bold: Bool) -> PlatformFont {
        var result = base
        #if os(macOS)
        var traits = source.fontDescriptor.symbolicTraits
        traits.formUnion(base.fontDescriptor.symbolicTraits)
        if bold { traits.insert(.bold) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        result = NSFont(descriptor: descriptor,
                        size: base.pointSize) ?? base
        #else
        var traits = source.fontDescriptor.symbolicTraits
        traits.formUnion(base.fontDescriptor.symbolicTraits)
        if bold { traits.insert(.traitBold) }
        if let descriptor = base.fontDescriptor
            .withSymbolicTraits(traits) {
            result = UIFont(descriptor: descriptor,
                            size: base.pointSize)
        }
        #endif
        return result
    }

    private func boldFont(_ f: PlatformFont) -> PlatformFont {
        var result = f
        #if os(macOS)
        var traits = f.fontDescriptor.symbolicTraits
        traits.insert(.bold)
        let d = f.fontDescriptor.withSymbolicTraits(traits)
        result = NSFont(descriptor: d, size: f.pointSize) ?? f
        #else
        var traits = f.fontDescriptor.symbolicTraits
        traits.insert(.traitBold)
        if let d = f.fontDescriptor.withSymbolicTraits(traits) {
            result = UIFont(descriptor: d, size: f.pointSize)
        }
        #endif
        return result
    }
}

#if os(macOS)
extension NativeText: NSViewRepresentable {

    final class Coordinator: NSObject, NSTextViewDelegate {
        func textView(_ tv: NSTextView, clickedOnLink link: Any,
                        at: Int) -> Bool {
            var url: URL? = nil
            switch link {
                case let u as URL: url = u
                case let s as String: url = URL(string: s)
                default: url = nil
            }
            var handled = false
            if let url {
                NSWorkspace.shared.open(url)
                handled = true
            }
            return handled
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ResizingTextView {
        let v = ResizingTextView()
        v.delegate = context.coordinator
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = !nowrap
        if nowrap {
            v.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
        }
        v.isVerticallyResizable = true
        v.isHorizontallyResizable = nowrap
        v.setContentCompressionResistancePriority(.defaultLow,
                                                  for: .horizontal)
        v.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        return v
    }

    func updateNSView(_ v: ResizingTextView, context: Context) {
        v.nowrap = nowrap
        let next = resolved()
        if v.textStorage?.isEqual(to: next) != true {
            v.textStorage?.setAttributedString(next)
            v.invalidateIntrinsicContentSize()
        }
    }

    final class ResizingTextView: NSTextView {

        var nowrap: Bool = false
        private var lastBounds: NSSize = .zero

        override var intrinsicContentSize: NSSize {
            var result = super.intrinsicContentSize
            if let lm = layoutManager, let tc = textContainer {
                lm.ensureLayout(for: tc)
                let r = lm.usedRect(for: tc)
                let inset = textContainerInset
                let w: CGFloat
                if nowrap {
                    w = r.width + inset.width * 2
                } else {
                    w = NSView.noIntrinsicMetric
                }
                let h = r.height + inset.height * 2
                result = NSSize(width: w, height: h)
            }
            return result
        }

        override func layout() {
            super.layout()
            if bounds.size != lastBounds {
                lastBounds = bounds.size
                invalidateIntrinsicContentSize()
            }
        }
    }
}

#elseif os(iOS)

extension NativeText: UIViewRepresentable {

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.isSelectable = true
        v.isScrollEnabled = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer.lineFragmentPadding = 0
        v.adjustsFontForContentSizeCategory = true
        v.linkTextAttributes = [
            .foregroundColor: UIColor.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        v.setContentCompressionResistancePriority(.defaultLow,
                                                  for: .horizontal)
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        let next = resolved()
        if v.attributedText?.isEqual(to: next) != true {
            v.attributedText = next
            v.invalidateIntrinsicContentSize()
        }
    }
}
#endif

struct ThemeButton: View {
    let theme: ThemeMode
    let onCycle: () -> Void

    var body: some View {
        Button(action: onCycle) {
            Image(systemName: theme.symbol)
        }
        .help(theme.help)
    }
}

#if os(macOS) && !QUICKLOOK_EXTENSION

struct SaveButton: View {

    let text: String
    let fileURL: URL?

    var body: some View {
        Button(action: save) {
            Image(systemName: "square.and.arrow.down")
        }
        .help("Save as PDF…")
    }

    private func save() {
        let title = fileURL?.deletingPathExtension().lastPathComponent ??
                    "Document"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(title).pdf"
        panel.canCreateDirectories = true
        panel.title = "Save PDF"
        let captured = text
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                Task {
                    let pdf = await exportPDF(text: captured,
                                              title: title)
                    if let pdf {
                        try? FileManager.default.removeItem(at: dest)
                        try? FileManager.default.copyItem(at: pdf,
                                                          to: dest)
                    }
                }
            }
        }
    }
}

#endif

#if !QUICKLOOK_EXTENSION

struct ShareButton: View {

    let text: String
    let fileURL: URL?
    @State private var pdfURL: URL?

    var body: some View {
        Group {
            if let pdfURL {
                let label = fileURL?
                    .deletingPathExtension()
                    .lastPathComponent ?? "Document"
                ShareLink(
                    item: pdfURL,
                    preview: SharePreview(
                        label, image: Image(systemName: "doc.richtext"))
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share as PDF")
            } else {
                Button(action: {}) {
                    Image(systemName: "square.and.arrow.up").opacity(0.4)
                }
                .disabled(true)
                .help("Generating PDF…")
            }
        }
        .task(id: text) {
            let title = fileURL?.deletingPathExtension().lastPathComponent ??
                        "Document"
            let url = await exportPDF(text: text, title: title)
            await MainActor.run { pdfURL = url }
        }
    }
}

#endif
