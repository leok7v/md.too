import Foundation
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum Highlight {

    static func attribute(_ code: String,
                        language: String?,
                        baseFont: PlatformFont) -> NSAttributedString {
        let ns = NSMutableAttributedString(string: code)
        let full = NSRange(location: 0, length: (code as NSString).length)
        ns.addAttribute(.font, value: baseFont, range: full)
        ns.addAttribute(.foregroundColor, value: defaultFg, range: full)
        if let language {
            let lower = language.lowercased()
            let key = data.aliases[lower] ?? lower
            if let spec = data.languages[key] {
                var mask = [Bool](repeating: false, count: full.length)
                apply(spec.blockComment, code: code, full: full,
                      color: data.comment, into: ns, mask: &mask)
                apply(spec.lineComment, code: code, full: full,
                      color: data.comment, into: ns, mask: &mask)
                apply(spec.string, code: code, full: full,
                      color: data.string, into: ns, mask: &mask)
                apply(spec.meta, code: code, full: full,
                      color: data.builtin, into: ns, mask: &mask)
                apply(spec.tag, code: code, full: full,
                      color: data.variable, into: ns, mask: &mask)
                apply(spec.attr, code: code, full: full,
                      color: data.attr, into: ns, mask: &mask)
                apply(spec.type, code: code, full: full,
                      color: data.type, into: ns, mask: &mask)
                apply(spec.builtin, code: code, full: full,
                      color: data.builtin, into: ns, mask: &mask)
                apply(spec.number, code: code, full: full,
                      color: data.number, into: ns, mask: &mask)
                applyKeywords(spec.keywords, code: code, full: full,
                              color: data.keyword, into: ns, mask: mask)
            }
        }
        return ns
    }

    private static func apply(_ pattern: String?,
                                   code: String,
                                   full: NSRange,
                                  color: PlatformColor,
                                into ns: NSMutableAttributedString,
                                   mask: inout [Bool]) {
        let opts: NSRegularExpression.Options =
            [.dotMatchesLineSeparators, .anchorsMatchLines]
        if let pattern,
           let re = try? NSRegularExpression(pattern: pattern,
                                             options: opts) {
            re.enumerateMatches(in: code, options: [],
                             range: full) { m, _, _ in
                if let m {
                    let r = m.range
                    let lo = r.location
                    let hi = lo + r.length
                    let inside = lo >= 0 && hi <= mask.count
                    let collide = inside && (lo..<hi).contains { i in mask[i] }
                    if inside && !collide {
                        for i in lo..<hi { mask[i] = true }
                        ns.addAttribute(.foregroundColor, value: color,
                                                          range: r)
                    }
                }
            }
        }
    }

    private static func applyKeywords(_ words: [String],
                                         code: String,
                                         full: NSRange,
                                        color: PlatformColor,
                                      into ns: NSMutableAttributedString,
                                         mask: [Bool]) {
        if !words.isEmpty {
            let escaped = words
                .map { w in NSRegularExpression.escapedPattern(for: w) }
                .joined(separator: "|")
            let pattern = "(?<![\\w@])(" + escaped + ")(?![\\w])"
            if let re = try? NSRegularExpression(pattern: pattern) {
                re.enumerateMatches(in: code, options: [],
                                 range: full) { m, _, _ in
                    if let m {
                        let r = m.range
                        let lo = r.location
                        let hi = lo + r.length
                        let inside = lo >= 0 && hi <= mask.count
                        let collide = inside && (lo..<hi).contains { i in
                            mask[i]
                        }
                        if inside && !collide {
                            ns.addAttribute(.foregroundColor,
                                            value: color, range: r)
                        }
                    }
                }
            }
        }
    }

    #if os(macOS)
    private static let defaultFg = NSColor.textColor
    #else
    private static let defaultFg = UIColor.label
    #endif

    private struct Spec {
        let keywords: [String]
        let lineComment: String?
        let blockComment: String?
        let string: String?
        let number: String?
        let tag: String?
        let attr: String?
        let meta: String?
        let type: String?
        let builtin: String?
    }

    private struct Loaded {
        let languages: [String: Spec]
        let aliases: [String: String]
        let keyword: PlatformColor
        let string: PlatformColor
        let number: PlatformColor
        let comment: PlatformColor
        let type: PlatformColor
        let builtin: PlatformColor
        let variable: PlatformColor
        let attr: PlatformColor

        static let empty = Loaded(
            languages: [:], aliases: [:],
            keyword: .gray, string: .gray, number: .gray, comment: .gray,
            type: .gray, builtin: .gray, variable: .gray, attr: .gray)
    }

    private static let data: Loaded = load()

    private static func load() -> Loaded {
        var result: Loaded = .empty
        let url = Bundle.main.url(forResource: "highlights",
                                  withExtension: "ini")
        if let url,
           let source = try? String(contentsOf: url, encoding: .utf8) {
            result = build(from: parseINI(source))
        }
        return result
    }

    private static func parseINI(_ source: String) -> [String: String] {
        var result: [String: String] = [:]
        var pending = ""
        let lines = source.split(separator: "\n",
                                 omittingEmptySubsequences: false)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("\\") {
                pending += line.dropLast()
            } else {
                let merged = pending + line
                pending = ""
                let isComment = merged.hasPrefix("#") || merged.hasPrefix(";")
                if !merged.isEmpty && !isComment,
                   let eq = merged.firstIndex(of: "=") {
                    let after = merged.index(after: eq)
                    let key = merged[..<eq]
                        .trimmingCharacters(in: .whitespaces)
                    let value = merged[after...]
                        .trimmingCharacters(in: .whitespaces)
                    result[String(key)] = String(value)
                }
            }
        }
        return result
    }

    private static func build(from dict: [String: String]) -> Loaded {
        var families: [String: [String: String]] = [:]
        var langs: [String: [String: String]] = [:]
        var themes: [String: [String: String]] = [:]
        for (k, v) in dict {
            let parts = k.split(separator: ".", maxSplits: 2,
                                omittingEmptySubsequences: false)
            if parts.count == 3 {
                let domain = String(parts[0])
                let id = String(parts[1])
                let prop = String(parts[2])
                if domain == "family" {
                    families[id, default: [:]][prop] = v
                } else if domain == "lang" {
                    langs[id, default: [:]][prop] = v
                } else if domain == "theme" {
                    themes[id, default: [:]][prop] = v
                }
            }
        }
        var languages: [String: Spec] = [:]
        var aliases: [String: String] = [:]
        for (id, fields) in langs {
            let family = families[fields["family"] ?? ""] ?? [:]
            let keywords = (fields["keywords"] ?? "")
                .split(separator: ",")
                .map { s in s.trimmingCharacters(in: .whitespaces) }
                .filter { s in !s.isEmpty }
            languages[id] = Spec(
                keywords: keywords,
                lineComment:
                         fields["lineComment"] ?? family["lineComment"],
                blockComment:
                         fields["blockComment"] ?? family["blockComment"],
                string:  fields["string"] ?? family["string"],
                number:  fields["number"] ?? family["number"],
                tag:     fields["tag"] ?? family["tag"],
                attr:    fields["attr"] ?? family["attr"],
                meta:    fields["meta"] ?? family["meta"],
                type:    fields["type"] ?? family["type"],
                builtin: fields["builtin"] ?? family["builtin"])
            aliases[id] = id
            for a in (fields["aliases"] ?? "").split(separator: ",") {
                let key = a
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if !key.isEmpty { aliases[key] = id }
            }
        }
        let dark = themes["dark"] ?? [:]
        let light = themes["light"] ?? [:]
        func color(_ key: String) -> PlatformColor {
            adaptive(light: hex(light[key]), dark: hex(dark[key]))
        }
        return Loaded(
            languages: languages, aliases: aliases,
            keyword:  color("keyword"),
            string:   color("string"),
            number:   color("number"),
            comment:  color("comment"),
            type:     color("type"),
            builtin:  color("builtin"),
            variable: color("variable"),
            attr:     color("attr"))
    }

    private static func hex(_ s: String?) -> PlatformColor {
        var result: PlatformColor = .gray
        if var v = s, !v.isEmpty {
            if v.hasPrefix("#") { v.removeFirst() }
            if v.count == 6, let n = UInt32(v, radix: 16) {
                let r = CGFloat((n >> 16) & 0xff) / 255.0
                let g = CGFloat((n >> 8) & 0xff) / 255.0
                let b = CGFloat(n & 0xff) / 255.0
                result = PlatformColor(red: r, green: g, blue: b, alpha: 1.0)
            }
        }
        return result
    }

    private static func adaptive(light: PlatformColor,
                                  dark: PlatformColor) -> PlatformColor {
        #if os(macOS)
        return NSColor(name: nil) { appearance in
            let darkMatches: [NSAppearance.Name] = [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark,
            ]
            let isDark = appearance.bestMatch(from: darkMatches) != nil
            return isDark ? dark : light
        }
        #else
        return UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        }
        #endif
    }
}
