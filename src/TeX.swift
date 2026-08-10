import Foundation
import CoreGraphics

enum TeX {

    // The two engines meet here. KaTeX typesets a display wherever
    // there is a graphics context to draw into; nil means it refused --
    // a macro it does not know, a construct outside its grammar -- and
    // the caller falls back to render(_:display:), which spells the
    // formula out in Unicode rather than showing nothing. Every surface
    // without a context (HTML, plain text, the clipboard) skips this
    // and takes the Unicode form directly.

    static func layout(_ tex: String, size: CGFloat) -> MathLayout? {
        var settings = MathSettings()
        settings.displayMode = true
        settings.fontSize = size
        return try? KaTeX.layout(tex, settings: settings)
    }

    // Display maths is set larger than the prose around it, the way a
    // TeX document does: the ratio is the one the md2png CLI defaults
    // to, 20pt of maths against 15pt of text.
    static func displaySize(body: CGFloat) -> CGFloat { body * 4 / 3 }

    // Whether the WHOLE string is TeX the parser recognises: every
    // token known, nothing left over. Parse only, no layout and no
    // font, because this is asked speculatively about paragraphs that
    // merely look like they might be formulas.

    static func parses(_ tex: String) -> Bool {
        (try? Parser.parse(tex)) != nil
    }

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

    // The plain-text answer to <sub>/<sup>, for the surfaces that have no
    // baseline to offset: a monospaced table serialization, a character
    // count, a clipboard paste. Every character or none -- a half-mapped
    // run reads as a typo, so one unrepresentable letter sends the whole
    // of it to parentheses, the same shape mapScript uses for TeX.

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

    // A body with no '<' in it is an INNERMOST pair, which is what makes
    // one pass safe: "m<sub>DO<sub>2</sub></sub>" is real notation, and a
    // pattern that let the body span a tag would pair the outer opener
    // with the inner closer and strand the rest.
    private static let scriptTagRE: NSRegularExpression? =
        try? NSRegularExpression(pattern: #"<(sub|sup)>([^<]*)</\1>"#,
                                 options: .caseInsensitive)

    // Rewrites the tags in a RAW cell, for the table measurers and the
    // monospaced serializer -- they see the markdown source, never the
    // parsed runs, and would otherwise size a column to "m<sup>2</sup>".
    // Repeated until it stops changing, so nesting unwinds inside out.

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

    private static func replaceTokens(_ s: String) -> String {
        var out = s
        let pairs = tokenMap.sorted { a, b in a.key.count > b.key.count }
        for (k, v) in pairs {
            out = replaceToken(out, k, v)
        }
        return out
    }

    // A control word ends where a non-letter begins. Without that,
    // "\newcommand" becomes "(not equal)wcommand" the moment \ne is
    // substituted inside it -- which is exactly what a reader sees when
    // KaTeX refuses a formula and this is all that is left. Keys that do
    // not end in a letter (\, \; \\) have no boundary to respect.

    private static func replaceToken(_ s: String, _ key: String,
                                     _ value: String) -> String {
        var result = s
        if let last = key.last, last.isLetter {
            let pattern = NSRegularExpression.escapedPattern(for: key)
                        + "(?![A-Za-z])"
            if let re = try? NSRegularExpression(pattern: pattern) {
                let ns = s as NSString
                let full = NSRange(location: 0, length: ns.length)
                result = re.stringByReplacingMatches(
                    in: s, range: full,
                    withTemplate:
                        NSRegularExpression.escapedTemplate(for: value))
            }
        } else {
            result = s.replacingOccurrences(of: key, with: value)
        }
        return result
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
        // U+2212 alongside the hyphen: a document that spells its
        // exponents with a real minus is the same document that spells
        // them with <sup>, and one unmapped character sends the whole
        // run to parentheses.
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

