import Foundation
import CoreGraphics

enum TeX {

    private struct LayoutKey: Hashable {
        let tex: String
        let size: CGFloat
        let display: Bool
    }

    private static let layoutLock = NSLock()
    private static let layoutCapacity = 256
    nonisolated(unsafe) private static var layouts: [LayoutKey: MathLayout?]
        = [:]

    // Test-only: lets a test start the layout cache empty.

    static func forgetLayouts() {
        layoutLock.lock()
        defer { layoutLock.unlock() }
        layouts.removeAll()
    }

    static var cachedLayoutCount: Int {
        layoutLock.lock()
        defer { layoutLock.unlock() }
        return layouts.count
    }

    static func layout(_ tex: String, size: CGFloat,
                       display: Bool = true) -> MathLayout? {
        let key = LayoutKey(tex: tex, size: size, display: display)
        layoutLock.lock()
        defer { layoutLock.unlock() }
        let result: MathLayout?
        if let known = layouts[key] {
            result = known
        } else {
            var settings = MathSettings()
            settings.displayMode = display
            settings.fontSize = size
            result = try? KaTeX.layout(tex, settings: settings)
            if layouts.count >= layoutCapacity { layouts.removeAll() }
            layouts.updateValue(result, forKey: key)
        }
        return result
    }

    static func undelimited(_ source: String) -> String {
        source.trimmingCharacters(in: CharacterSet(charactersIn: "$"))
    }

    // 4/3 matches md2png's 20pt-math to 15pt-body ratio.
    static func displaySize(body: CGFloat) -> CGFloat { body * 4 / 3 }

    // Parse only; no layout or font cost for what may be plain text.

    static func parses(_ tex: String) -> Bool {
        (try? Parser.parse(tex)) != nil
    }

    enum Segment {
        case text(String)
        case math(String, display: Bool)
    }

    static func split(_ s: String) -> [Segment] {
        let closers = s.contains("$") ? inlineClosers(s) : []
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
                let off = isDisplay ? 2 : 1
                let searchStart = s.index(i, offsetBy: off)
                let endRange = isDisplay
                    ? s.range(of: "$$", range: searchStart..<s.endIndex)
                    : inlineClose(s, from: searchStart, closers)
                if let endRange {
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

    private static func inlineClosers(_ s: String) -> [String.Index] {
        var out: [String.Index] = []
        var i = s.startIndex
        var before: Character = " "
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            let digit = next < s.endIndex && s[next].isNumber
            if c == "$", !before.isWhitespace, before != "\\", !digit {
                out.append(i)
            }
            before = c
            i = next
        }
        return out
    }

    private static func inlineClose(_ s: String, from start: String.Index,
                                    _ closers: [String.Index])
        -> Range<String.Index>? {
        var result: Range<String.Index>? = nil
        if start < s.endIndex, !s[start].isWhitespace, s[start] != "$" {
            var lo = 0
            var hi = closers.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if closers[mid] > start { hi = mid } else { lo = mid + 1 }
            }
            if lo < closers.count {
                result = closers[lo]..<s.index(after: closers[lo])
            }
        }
        return result
    }

    static func render(_ src: String, display: Bool) -> AttributedString {
        let rendered = renderToString(src)
        var a = AttributedString(rendered)
        a.font = display ? .system(.title3).italic() : .system(.body).italic()
        return a
    }

    private static func renderToString(_ src: String) -> String {
        var s = expandText(src)
        for (pattern, template) in spelledOut {
            s = s.replacingOccurrences(of: pattern, with: template,
                                       options: .regularExpression)
        }
        s = expandFractions(s)
        s = expandScript(s, prefix: "^", map: superscriptMap)
        s = expandScript(s, prefix: "_", map: subscriptMap)
        s = replaceTokens(s)
        s = s.replacingOccurrences(of: #"\\[A-Za-z]+\s*"#, with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\([^A-Za-z\n])"#, with: "$1",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: "{", with: "")
             .replacingOccurrences(of: "}", with: "")
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let textCommand = try? NSRegularExpression(
        pattern: #"\\(?:text(?!color)[a-z]*|mbox)\s*\{([^{}]*)\}"#)

    private static let spelledOut: [(String, String)] = [
        (#"\\(?:begin|end)\s*\{[^{}]*\}"#, ""),
        (#"\\[dt]frac(?![A-Za-z])"#, "\\\\frac"),
        (#"\\q?quad(?![A-Za-z])"#, "  "),
        (#"\\over(?![A-Za-z])"#, "\u{2044}"),
        (#"(?<!\\)&"#, " "),
        (#"\\operatorname\*?\s*\{([^{}]*)\}"#, "$1"),
        (#"\\xrightarrow\s*(?:\[[^\]]*\])?"#, "\u{2192}"),
        (#"\\xleftarrow\s*(?:\[[^\]]*\])?"#, "\u{2190}"),
        (#"\\(?:text)?color\s*\{[^{}]*\}"#, ""),
        (#"\\not\s*="#, "\u{2260}"),
        (#"\\("# + Symbols.namedOps.keys
            .map { name in String(name.dropFirst()) }
            .sorted { a, b in a.count > b.count }
            .joined(separator: "|") + #")(?![A-Za-z])"#, "$1"),
    ]

    private static func expandText(_ s: String) -> String {
        var out = s
        if let re = textCommand {
            let full = NSRange(location: 0, length: (s as NSString).length)
            out = re.stringByReplacingMatches(in: s, range: full,
                                              withTemplate: "{$1}")
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

    private static func expandScript(_ s: String, prefix: Character,
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
                } else if after == "\\" {
                    let word = controlWord(s, from: next)
                    out.append(mapScript(String(s[next..<word]), map: map))
                    i = word
                    consumed = true
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

    private static func controlWord(_ s: String,
                                    from start: String.Index) -> String.Index {
        var end = s.index(after: start)
        if end < s.endIndex, s[end].isLetter {
            while end < s.endIndex, s[end].isLetter {
                end = s.index(after: end)
            }
        } else if end < s.endIndex {
            end = s.index(after: end)
        }
        return end
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

    // Every character maps or none does; a half-mapped run reads as a
    // typo, so one unrepresentable letter sends the whole run to parens.

    static func unicodeScript(_ s: String, superscript sup: Bool) -> String {
        let map = sup ? superscriptMap : subscriptMap
        let mapped = s.compactMap { c in map[c] }
        var result = "(" + s + ")"
        if s.isEmpty {
            result = ""
        } else if mapped.count == s.count {
            result = String(mapped)
        }
        return result
    }

    // A body with no '<' is an innermost pair; the pattern never spans
    // a tag, so it cannot pair an outer opener with an inner closer.
    private static let scriptTagRE: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"<(sub|sup)>([^<]*)</\1>"#,
                                 options: .caseInsensitive)

    static func scriptsToUnicode(_ s: String) -> String {
        var result = s
        var unwinding = s.contains("<")
        while unwinding {
            let next = innermostScripts(result)
            unwinding = next != result
            result = next
        }
        return result
    }

    private static func innermostScripts(_ s: String) -> String {
        var result = s
        if let re = scriptTagRE {
            let ns = s as NSString
            let full = NSRange(location: 0, length: ns.length)
            let m = NSMutableString(string: s)
            for match in re.matches(in: s, range: full).reversed() {
                let tag = ns.substring(with: match.range(at: 1))
                let body = ns.substring(with: match.range(at: 2))
                let sup = tag.lowercased() == "sup"
                let plain = unicodeScript(body, superscript: sup)
                m.replaceCharacters(in: match.range, with: plain)
            }
            result = m as String
        }
        return result
    }

    static func replaceTokens(_ s: String) -> String {
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        while i < scalars.count {
            let taken = scalars[i] == "\\" ? expansion(scalars, at: i) : nil
            if let taken {
                out.append(contentsOf: taken.value.unicodeScalars)
                i = taken.end
            } else {
                out.append(scalars[i])
                i += 1
            }
        }
        return String(out)
    }

    private static func isAsciiLetter(_ c: Unicode.Scalar) -> Bool {
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    }

    // A control word ends at the first non-letter, so "\ne" cannot
    // match inside "\newcommand" and substitute the wrong span.

    private static func controlWordEnd(_ s: [Unicode.Scalar],
                                       at i: Int) -> Int {
        var end = i + 1
        if end < s.count, isAsciiLetter(s[end]) {
            while end < s.count, isAsciiLetter(s[end]) { end += 1 }
        } else if end < s.count {
            end += 1
        }
        return end
    }

    private static func expansion(_ s: [Unicode.Scalar], at i: Int)
        -> (value: String, end: Int)? {
        let end = controlWordEnd(s, at: i)
        var word = ""
        word.unicodeScalars.append(contentsOf: s[i..<end])
        var result: (value: String, end: Int)? = nil
        if end + 2 < s.count, s[end] == "{", s[end + 2] == "}",
           let braced = tokenMap[word + "{" + String(s[end + 1]) + "}"] {
            result = (braced, end + 3)
        } else if let plain = tokenMap[word] {
            result = (plain, end)
        }
        return result
    }

    static let tokenMap: [String: String] = [
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
        "\\iff": "⟺", "\\implies": "⟹", "\\Longrightarrow": "⟹",
        "\\gets": "←", "\\leqslant": "⩽", "\\geqslant": "⩾",
        "\\colon": ":", "\\bmod": "mod", "\\pmod": "mod ",
        "\\left": "", "\\right": "", "\\,": " ", "\\;": " ", "\\ ": " ",
        "\\\\": "\n",
    ]

    private static let superscriptMap: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
        "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        // U+2212 is mapped alongside the hyphen, or an exponent typed
        // with a real minus sign falls whole to parentheses.
        "+": "⁺", "-": "⁻", "\u{2212}": "⁻", "=": "⁼",
        "(": "⁽", ")": "⁾",
        "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ",
        "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ", "k": "ᵏ", "l": "ˡ",
        "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ",
        "t": "ᵗ", "u": "ᵘ", "v": "ᵛ",
        "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ",
    ]

    private static let subscriptMap: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
        "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "\u{2212}": "₋", "=": "₌",
        "(": "₍", ")": "₎",
        "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
        "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
        "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
    ]

}

