//
//  KaTeX.swift - a self-contained TeX math renderer.
//
//  One file, one font. No WebView, no JavaScript, no generated metric
//  tables: the font metrics, big-operator sizes, stretchy delimiter
//  recipes and the ~50 TeX layout constants all come from the OpenType
//  MATH table of STIXTwoMath.otf, which macOS ships in
//  /System/Library/Fonts/Supplemental and which md.too bundles on iOS.
//
//  Public surface used by md.too:
//      KaTeX.layout(_:settings:)   -> MathLayout   (measure)
//      MathLayout.draw(in:at:color:flipped:)       (draw)
//      MathLayout.cgImage(...)                     (rasterize)
//
//  Nothing here is safe to change by eye: the output is geometry, and a
//  glyph moved by a point compiles clean and reads as no diff at all.
//  MD/tests/KaTeXGoldenTests.swift fingerprints 36 formulas by their
//  layout metrics and by a hash of their rasterized pixels -- run it
//  after touching anything in this file.
//

import Foundation
import CoreGraphics
import CoreText


public enum MathError: Error, CustomStringConvertible {
    case syntax(String, at: Int)
    case fontUnavailable(String)

    public var description: String {
        switch self {
        case .syntax(let m, let p): return "TeX syntax error at \(p): \(m)"
        case .fontUnavailable(let m): return "math font unavailable: \(m)"
        }
    }
}


public struct MathSettings {
    public enum TagSide { case left, right }

    /// Display style (`$$`) vs inline/text style (`$`).
    public var displayMode: Bool = true
    /// Base font size in points.
    public var fontSize: CGFloat = 20
    public var color: CGColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    /// Where `\tag{...}` is placed. `.left` reproduces LaTeX's `leqno`.
    public var tagSide: TagSide = .right
    /// Minimum gap between the body and a `\tag`.
    public var tagGap: CGFloat = 32
    /// If set, `\tag`s are pushed out to this total width.
    public var tagColumnWidth: CGFloat? = nil

    public init() {}
}


/// Minimal OpenType reader: table directory, cmap, and the MATH table.
public final class MathFontFile {
    typealias Variant = (glyph: CGGlyph, adv: CGFloat)
    typealias Metrics = (adv: CGFloat, h: CGFloat, d: CGFloat)

    let bytes: [UInt8]
    let cgFont: CGFont
    let upem: CGFloat

    private var tables: [String: (off: Int, len: Int)] = [:]
    private var cmapSub = 0
    private var cmapFmt = 0

    private var glyphCache: [UInt32: CGGlyph] = [:]
    private var ctCache: [CGFloat: CTFont] = [:]

    // MATH
    private var mathConstants = 0
    private var italicCorr: [CGGlyph: CGFloat] = [:]
    private var topAccent: [CGGlyph: CGFloat] = [:]
    private(set) var minConnectorOverlap: CGFloat = 0
    /// Minimum height of a big operator in display style, in em.
    private(set) var displayOperatorMinHeight: CGFloat = 1.4
    private var vertVariants: [CGGlyph: [Variant]] = [:]
    private var horizVariants: [CGGlyph: [Variant]] = [:]
    private var vertAssembly: [CGGlyph: [AssemblyPart]] = [:]
    private(set) var scriptPercent: CGFloat = 0.7
    private(set) var scriptScriptPercent: CGFloat = 0.5

    struct AssemblyPart {
        let glyph: CGGlyph
        let startConnector: CGFloat
        let endConnector: CGFloat
        let fullAdvance: CGFloat
        let isExtender: Bool
    }


    public init(data: Data) throws {
        self.bytes = [UInt8](data)
        let font: CGFont
        if let provider = CGDataProvider(data: data as CFData),
           let parsed = CGFont(provider) {
            font = parsed
        } else {
            throw MathError.fontUnavailable("not a usable font file")
        }
        self.cgFont = font
        self.upem = CGFloat(font.unitsPerEm)
        try readTableDirectory()
        try readCmap()
        readMath()
    }

    public convenience init(url: URL) throws {
        try self.init(data: try Data(contentsOf: url))
    }


    @inline(__always) func u8(_ o: Int) -> Int {
        o < bytes.count ? Int(bytes[o]) : 0
    }
    @inline(__always) func u16(_ o: Int) -> Int { (u8(o) << 8) | u8(o + 1) }
    @inline(__always) func i16(_ o: Int) -> Int {
        let v = u16(o)
        return v >= 0x8000 ? v - 0x10000 : v
    }
    @inline(__always) func u32(_ o: Int) -> Int { (u16(o) << 16) | u16(o + 2) }

    private func readTableDirectory() throws {
        var failure: MathError? = nil
        if bytes.count > 12 {
            let n = u16(4)
            if n > 0, 12 + 16 * n <= bytes.count {
                for i in 0..<n {
                    let e = 12 + 16 * i
                    let tag = String(bytes: bytes[e..<(e + 4)],
                                     encoding: .isoLatin1) ?? ""
                    tables[tag] = (u32(e + 8), u32(e + 12))
                }
            } else {
                failure = .fontUnavailable("bad table count")
            }
        } else {
            failure = .fontUnavailable("truncated")
        }
        if let failure { throw failure }
    }


    private func readCmap() throws {
        var failure: MathError? = nil
        if let t = tables["cmap"] {
            let n = u16(t.off + 2)
            var best = 0, bestScore = -1
            for i in 0..<n {
                let p = t.off + 4 + 8 * i
                let plat = u16(p), enc = u16(p + 2), off = u32(p + 4)
                let score: Int
                switch (plat, enc) {
                case (3, 10): score = 4
                case (0, 4), (0, 6): score = 3
                case (3, 1): score = 2
                case (0, _): score = 1
                default: score = 0
                }
                if score > bestScore { bestScore = score; best = t.off + off }
            }
            if bestScore >= 0 {
                cmapSub = best
                cmapFmt = u16(best)
            } else {
                failure = .fontUnavailable("no usable cmap subtable")
            }
        } else {
            failure = .fontUnavailable("no cmap")
        }
        if let failure { throw failure }
    }

    /// Glyph id for a Unicode scalar, 0 when the font has no such glyph.
    public func glyph(_ cp: UInt32) -> CGGlyph {
        var result: CGGlyph = 0
        if let cached = glyphCache[cp] {
            result = cached
        } else {
            switch cmapFmt {
            case 12: result = segmentedCoverage(cp)
            case 4: result = segmentMapping(cp)
            case 6: result = trimmedMapping(cp)
            default: break
            }
            glyphCache[cp] = result
        }
        return result
    }

    private func segmentedCoverage(_ cp: UInt32) -> CGGlyph {
        var found: CGGlyph? = nil
        var lo = 0
        var hi = u32(cmapSub + 12) - 1
        while lo <= hi && found == nil {
            let mid = (lo + hi) / 2
            let p = cmapSub + 16 + 12 * mid
            let s = UInt32(u32(p)), e = UInt32(u32(p + 4))
            if cp < s {
                hi = mid - 1
            } else if cp > e {
                lo = mid + 1
            } else {
                found = CGGlyph(UInt32(u32(p + 8)) &+ (cp - s))
            }
        }
        return found ?? 0
    }

    private func segmentMapping(_ cp: UInt32) -> CGGlyph {
        var result: CGGlyph = 0
        if cp <= 0xFFFF {
            let segX2 = u16(cmapSub + 6)
            let ends = cmapSub + 14
            let starts = ends + segX2 + 2
            let deltas = starts + segX2
            let ranges = deltas + segX2
            var seg: Int? = nil
            var i = 0
            while i < segX2 && seg == nil {
                if UInt32(u16(ends + i)) >= cp { seg = i }
                i += 2
            }
            if let seg, UInt32(u16(starts + seg)) <= cp {
                let ro = u16(ranges + seg)
                if ro == 0 {
                    result = CGGlyph((Int(cp) + i16(deltas + seg)) & 0xFFFF)
                } else {
                    let idx = Int(cp) - u16(starts + seg)
                    let g = u16(ranges + seg + ro + 2 * idx)
                    if g != 0 {
                        result = CGGlyph((g + i16(deltas + seg)) & 0xFFFF)
                    }
                }
            }
        }
        return result
    }

    private func trimmedMapping(_ cp: UInt32) -> CGGlyph {
        var result: CGGlyph = 0
        let first = u16(cmapSub + 6), count = u16(cmapSub + 8)
        if cp >= UInt32(first) && cp < UInt32(first + count) {
            result = CGGlyph(u16(cmapSub + 10 + 2 * (Int(cp) - first)))
        }
        return result
    }

    public func glyph(_ ch: Character) -> CGGlyph {
        glyph(ch.unicodeScalars.first?.value ?? 0)
    }


    private func coverage(_ off: Int) -> [CGGlyph: Int] {
        var map: [CGGlyph: Int] = [:]
        switch u16(off) {
        case 1:
            let n = u16(off + 2)
            for i in 0..<n { map[CGGlyph(u16(off + 4 + 2 * i))] = i }
        case 2:
            let n = u16(off + 2)
            for i in 0..<n {
                let p = off + 4 + 6 * i
                let s = u16(p), e = u16(p + 2), si = u16(p + 4)
                if e >= s { for g in s...e { map[CGGlyph(g)] = si + (g - s) } }
            }
        default: break
        }
        return map
    }

    private func readMath() {
        if let t = tables["MATH"] { readMath(at: t.off) }
    }

    private func readMath(at base: Int) {
        mathConstants = base + u16(base + 4)
        let glyphInfo = base + u16(base + 6)
        let variants = base + u16(base + 8)

        let doh = u16(mathConstants + 6)
        if doh > 0 { displayOperatorMinHeight = CGFloat(doh) / upem }

        let sp = i16(mathConstants)
        let ssp = i16(mathConstants + 2)
        if sp > 0 { scriptPercent = CGFloat(sp) / 100 }
        if ssp > 0 { scriptScriptPercent = CGFloat(ssp) / 100 }

        // MathGlyphInfo: italics correction, top accent attachment
        let icOff = u16(glyphInfo)
        if icOff != 0 {
            let ic = glyphInfo + icOff
            let cov = coverage(ic + u16(ic))
            let n = u16(ic + 2)
            for (g, i) in cov where i < n {
                italicCorr[g] = CGFloat(i16(ic + 4 + 4 * i)) / upem
            }
        }
        let taOff = u16(glyphInfo + 2)
        if taOff != 0 {
            let ta = glyphInfo + taOff
            let cov = coverage(ta + u16(ta))
            let n = u16(ta + 2)
            for (g, i) in cov where i < n {
                topAccent[g] = CGFloat(i16(ta + 4 + 4 * i)) / upem
            }
        }

        // MathVariants
        minConnectorOverlap = CGFloat(u16(variants)) / upem
        let vertOff = u16(variants + 2)
        let horizOff = u16(variants + 4)
        let vertCov = vertOff != 0 ? coverage(variants + vertOff) : [:]
        let horizCov = horizOff != 0 ? coverage(variants + horizOff) : [:]
        let vertCount = u16(variants + 6)
        let horizCount = u16(variants + 8)

        func readConstruction(_ off: Int) -> ([Variant], [AssemblyPart]) {
            var vars: [Variant] = []
            let n = u16(off + 2)
            for i in 0..<n {
                let p = off + 4 + 4 * i
                vars.append((CGGlyph(u16(p)), CGFloat(u16(p + 2)) / upem))
            }
            var parts: [AssemblyPart] = []
            let asmOff = u16(off)
            if asmOff != 0 {
                let a = off + asmOff
                let pn = u16(a + 4)
                for i in 0..<pn {
                    let p = a + 6 + 10 * i
                    parts.append(AssemblyPart(
                        glyph: CGGlyph(u16(p)),
                        startConnector: CGFloat(u16(p + 2)) / upem,
                        endConnector: CGFloat(u16(p + 4)) / upem,
                        fullAdvance: CGFloat(u16(p + 6)) / upem,
                        isExtender: (u16(p + 8) & 1) != 0))
                }
            }
            return (vars, parts)
        }

        for (g, i) in vertCov where i < vertCount {
            let off = variants + u16(variants + 10 + 2 * i)
            let (v, a) = readConstruction(off)
            if !v.isEmpty { vertVariants[g] = v }
            if !a.isEmpty { vertAssembly[g] = a }
        }
        for (g, i) in horizCov where i < horizCount {
            let off = variants + u16(variants + 10 + 2 * vertCount + 2 * i)
            let (v, _) = readConstruction(off)
            if !v.isEmpty { horizVariants[g] = v }
        }
    }

    /// MATH table constants, in em.
    public enum Constant: Int, Sendable {
        case mathLeading = 0, axisHeight, accentBaseHeight,
             flattenedAccentBaseHeight, subscriptShiftDown, subscriptTopMax,
             subscriptBaselineDropMin, superscriptShiftUp,
             superscriptShiftUpCramped, superscriptBottomMin,
             superscriptBaselineDropMax, subSuperscriptGapMin,
             superscriptBottomMaxWithSubscript, spaceAfterScript,
             upperLimitGapMin, upperLimitBaselineRiseMin, lowerLimitGapMin,
             lowerLimitBaselineDropMin, stackTopShiftUp,
             stackTopDisplayStyleShiftUp, stackBottomShiftDown,
             stackBottomDisplayStyleShiftDown, stackGapMin,
             stackDisplayStyleGapMin, stretchStackTopShiftUp,
             stretchStackBottomShiftDown, stretchStackGapAboveMin,
             stretchStackGapBelowMin, fractionNumeratorShiftUp,
             fractionNumeratorDisplayStyleShiftUp,
             fractionDenominatorShiftDown,
             fractionDenominatorDisplayStyleShiftDown, fractionNumeratorGapMin,
             fractionNumDisplayStyleGapMin, fractionRuleThickness,
             fractionDenominatorGapMin, fractionDenomDisplayStyleGapMin,
             skewedFractionHorizontalGap, skewedFractionVerticalGap,
             overbarVerticalGap, overbarRuleThickness, overbarExtraAscender,
             underbarVerticalGap, underbarRuleThickness,
             underbarExtraDescender, radicalVerticalGap,
             radicalDisplayStyleVerticalGap, radicalRuleThickness,
             radicalExtraAscender, radicalKernBeforeDegree,
             radicalKernAfterDegree
    }

    private static let fallback: [Constant: CGFloat] = [
        .axisHeight: 0.25, .accentBaseHeight: 0.45,
        .subscriptShiftDown: 0.25, .subscriptTopMax: 0.4,
        .subscriptBaselineDropMin: 0.05,
        .superscriptShiftUp: 0.41, .superscriptShiftUpCramped: 0.29,
        .superscriptBottomMin: 0.13, .superscriptBaselineDropMax: 0.38,
        .subSuperscriptGapMin: 0.2, .superscriptBottomMaxWithSubscript: 0.4,
        .spaceAfterScript: 0.04, .upperLimitGapMin: 0.135,
        .upperLimitBaselineRiseMin: 0.3,
        .lowerLimitGapMin: 0.135, .lowerLimitBaselineDropMin: 0.6,
        .fractionNumeratorShiftUp: 0.4,
        .fractionNumeratorDisplayStyleShiftUp: 0.68,
        .fractionDenominatorShiftDown: 0.35,
        .fractionDenominatorDisplayStyleShiftDown: 0.68,
        .fractionNumeratorGapMin: 0.05, .fractionNumDisplayStyleGapMin: 0.15,
        .fractionRuleThickness: 0.05, .fractionDenominatorGapMin: 0.05,
        .fractionDenomDisplayStyleGapMin: 0.15,
        .overbarVerticalGap: 0.15, .overbarRuleThickness: 0.05,
        .overbarExtraAscender: 0.05,
        .radicalVerticalGap: 0.06, .radicalDisplayStyleVerticalGap: 0.17,
        .radicalRuleThickness: 0.05, .radicalExtraAscender: 0.05,
        .radicalKernBeforeDegree: 0.28, .radicalKernAfterDegree: -0.36,
    ]

    /// Constant in em units.
    public func constant(_ c: Constant) -> CGFloat {
        let result: CGFloat
        if mathConstants > 0 {
            result = CGFloat(i16(mathConstants + 8 + 4 * c.rawValue)) / upem
        } else {
            result = MathFontFile.fallback[c] ?? 0
        }
        return result
    }


    func ctFont(_ size: CGFloat) -> CTFont {
        let result: CTFont
        if let cached = ctCache[size] {
            result = cached
        } else {
            result = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
            ctCache[size] = result
        }
        return result
    }

    private struct MetricKey: Hashable { let g: CGGlyph; let s: CGFloat }
    private var metricCache: [MetricKey: Metrics] = [:]

    func rect(_ g: CGGlyph, _ size: CGFloat) -> CGRect {
        var glyphs = [g]
        var rects = [CGRect.zero]
        CTFontGetBoundingRectsForGlyphs(ctFont(size), .horizontal,
                                        &glyphs, &rects, 1)
        return rects[0].isNull ? .zero : rects[0]
    }

    func metrics(_ g: CGGlyph, _ size: CGFloat) -> Metrics {
        let key = MetricKey(g: g, s: size)
        let result: Metrics
        if let cached = metricCache[key] {
            result = cached
        } else {
            var glyphs = [g]
            var advances = [CGSize.zero]
            var rects = [CGRect.zero]
            let font = ctFont(size)
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs,
                                       &advances, 1)
            CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs,
                                            &rects, 1)
            let r = rects[0]
            result = (advances[0].width,
                      r.isNull || r.isEmpty ? 0 : r.maxY,
                      r.isNull || r.isEmpty ? 0 : -r.minY)
            metricCache[key] = result
        }
        return result
    }

    func italicCorrection(_ g: CGGlyph, _ size: CGFloat) -> CGFloat {
        (italicCorr[g] ?? 0) * size
    }
    func topAccentAttachment(_ g: CGGlyph, _ size: CGFloat) -> CGFloat? {
        topAccent[g].map { v in v * size }
    }
    func verticalVariants(_ g: CGGlyph) -> [Variant] { vertVariants[g] ?? [] }
    func horizontalVariants(_ g: CGGlyph) -> [Variant] {
        horizVariants[g] ?? []
    }
    func verticalAssembly(_ g: CGGlyph) -> [AssemblyPart] {
        vertAssembly[g] ?? []
    }

    // One parsed font serves every formula, and its glyph and CTFont
    // caches fill lazily as they are used, so the instance is mutable
    // for its whole life. `KaTeX.layout` holds this lock across a whole
    // layout, which is what makes sharing it safe; nothing else may
    // touch a MathFontFile.
    static let lock = NSLock()
    nonisolated(unsafe) private static var cached: MathFontFile?

    /// Override to point at a different MATH-table font. The md2png CLI
    /// sets it from --font; the app never does.
    public static var overrideURL: URL?

    // Two places, in this order: the app bundle, which is where the iOS
    // build carries its copy, then the system font macOS ships. No
    // environment variable and no working-directory search -- a
    // sandboxed app reaches neither, and a resource an app cannot
    // account for is a resource it should not look for.

    public static func shared() throws -> MathFontFile {
        var candidates: [URL] = []
        if let o = overrideURL { candidates.append(o) }
        if let u = Bundle.main.url(forResource: "STIXTwoMath",
                                   withExtension: "otf") {
            candidates.append(u)
        }
        candidates.append(URL(fileURLWithPath:
            "/System/Library/Fonts/Supplemental/STIXTwoMath.otf"))
        var found = cached
        for u in candidates where found == nil {
            if FileManager.default.fileExists(atPath: u.path),
               let f = try? MathFontFile(url: u) {
                cached = f
                found = f
            }
        }
        let result: MathFontFile
        if let found {
            result = found
        } else {
            throw MathError.fontUnavailable("no MATH-table font found")
        }
        return result
    }
}


struct Tok {
    let text: String
    let pos: Int
    var isCommand: Bool { text.hasPrefix("\\") }
}

struct Lexer {
    static func tokens(_ input: String) -> [Tok] {
        var out: [Tok] = []
        let s = Array(input)
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "%" {
                while i < s.count && s[i] != "\n" { i += 1 }
            } else if c == " " || c == "\t" || c == "\n" || c == "\r" {
                i += 1
            } else if c == "\\" {
                let start = i
                i += 1
                if i < s.count && s[i].isLetter {
                    var name = "\\"
                    while i < s.count && s[i].isLetter {
                        name.append(s[i])
                        i += 1
                    }
                    out.append(Tok(text: name, pos: start))
                } else if i < s.count {
                    out.append(Tok(text: "\\" + String(s[i]), pos: start))
                    i += 1
                } else {
                    out.append(Tok(text: "\\", pos: start))
                }
            } else {
                out.append(Tok(text: String(c), pos: i))
                i += 1
            }
        }
        return out
    }
}


public enum Atom: Sendable {
    case ord, op, bin, rel, open, close, punct, inner
}

/// A math "font" in the TeX sense: selects a Unicode math
/// alphanumeric block.
public enum MathVariant: Sendable {
    case italic, upright, bold, boldItalic, script, boldScript, fraktur
    case doubleStruck, sansSerif, sansBold, sansItalic, mono, text
}

enum Alphanumerics {
    private static let scriptUpper: [Character: UInt32] = [
        "B": 0x212C, "E": 0x2130, "F": 0x2131, "H": 0x210B,
        "I": 0x2110, "L": 0x2112, "M": 0x2133, "R": 0x211B,
    ]
    private static let scriptLower: [Character: UInt32] = [
        "e": 0x212F, "g": 0x210A, "o": 0x2134,
    ]
    private static let frakturUpper: [Character: UInt32] = [
        "C": 0x212D, "H": 0x210C, "I": 0x2111, "R": 0x211C, "Z": 0x2128,
    ]
    private static let bbUpper: [Character: UInt32] = [
        "C": 0x2102, "H": 0x210D, "N": 0x2115, "P": 0x2119,
        "Q": 0x211A, "R": 0x211D, "Z": 0x2124,
    ]

    // Each variant is one contiguous run of 26 capitals, one of 26
    // lowercase and (sometimes) one of 10 digits, plus the handful of
    // letters Unicode had already assigned elsewhere before the maths
    // blocks existed. Written as a table rather than a switch: the
    // switch spelled the same three additions out thirteen times, and
    // the only thing distinguishing the cases was the numbers.
    //
    // A base of zero means the variant has no run of that kind, and the
    // character is left as it was: script has no digits, italic has no
    // digits, upright is not in the table at all.

    private struct Alphabet: Sendable {
        let upper: UInt32
        let lower: UInt32
        let digit: UInt32
        var exceptions: [Character: UInt32] = [:]

        func map(_ ch: Character, scalar: UInt32) -> UInt32 {
            var result = scalar
            if let assigned = exceptions[ch] {
                result = assigned
            } else if ch.isLetter, ch.isUppercase, upper > 0 {
                result = upper + scalar - 65
            } else if ch.isLetter, ch.isLowercase, lower > 0 {
                result = lower + scalar - 97
            } else if ch.isNumber, digit > 0 {
                result = digit + scalar - 48
            }
            return result
        }
    }

    private static let alphabets: [MathVariant: Alphabet] = [
        .italic: Alphabet(upper: 0x1D434, lower: 0x1D44E, digit: 0,
                          exceptions: ["h": 0x210E]),
        .sansItalic: Alphabet(upper: 0x1D434, lower: 0x1D44E, digit: 0,
                              exceptions: ["h": 0x210E]),
        .bold: Alphabet(upper: 0x1D400, lower: 0x1D41A, digit: 0x1D7CE),
        .boldItalic: Alphabet(upper: 0x1D468, lower: 0x1D482,
                              digit: 0x1D7CE),
        .script: Alphabet(upper: 0x1D49C, lower: 0x1D4B6, digit: 0,
                          exceptions: scriptUpper.merging(scriptLower) {
                              a, _ in a
                          }),
        .boldScript: Alphabet(upper: 0x1D4D0, lower: 0x1D4EA, digit: 0),
        .fraktur: Alphabet(upper: 0x1D504, lower: 0x1D51E, digit: 0,
                           exceptions: frakturUpper),
        .doubleStruck: Alphabet(upper: 0x1D538, lower: 0x1D552,
                                digit: 0x1D7D8, exceptions: bbUpper),
        .sansSerif: Alphabet(upper: 0x1D5A0, lower: 0x1D5BA,
                             digit: 0x1D7E2),
        .sansBold: Alphabet(upper: 0x1D5D4, lower: 0x1D5EE,
                            digit: 0x1D7EC),
        .mono: Alphabet(upper: 0x1D670, lower: 0x1D68A, digit: 0x1D7F6),
    ]

    /// Map an ASCII letter/digit into the requested math alphanumeric
    /// block. Anything else, and any variant with no block of its own,
    /// comes back unchanged.
    static func map(_ ch: Character, _ v: MathVariant) -> UInt32 {
        let scalar = ch.unicodeScalars.first?.value ?? 0
        var result = scalar
        if scalar < 128, let alphabet = alphabets[v] {
            result = alphabet.map(ch, scalar: scalar)
        }
        return result
    }
}


struct SymbolDef: Sendable {
    let scalar: UInt32
    let atom: Atom
    /// If true the codepoint is already final and must not be
    /// re-mapped by \mathXX.
    let literal: Bool
    init(_ s: UInt32, _ a: Atom, literal: Bool = true) {
        scalar = s
        atom = a
        self.literal = literal
    }
}

enum Symbols {
    /// Greek lowercase are the *italic* math alphanumerics, as in LaTeX;
    /// uppercase Greek stay upright.
    static let table: [String: SymbolDef] = {
        var t: [String: SymbolDef] = [:]
        let lower: [(String, UInt32)] = [
            ("alpha", 0x1D6FC), ("beta", 0x1D6FD), ("gamma", 0x1D6FE),
            ("delta", 0x1D6FF), ("varepsilon", 0x1D700), ("zeta", 0x1D701),
            ("eta", 0x1D702), ("theta", 0x1D703), ("iota", 0x1D704),
            ("kappa", 0x1D705), ("lambda", 0x1D706), ("mu", 0x1D707),
            ("nu", 0x1D708), ("xi", 0x1D709), ("omicron", 0x1D70A),
            ("pi", 0x1D70B), ("rho", 0x1D70C), ("varsigma", 0x1D70D),
            ("sigma", 0x1D70E), ("tau", 0x1D70F), ("upsilon", 0x1D710),
            ("varphi", 0x1D711), ("chi", 0x1D712), ("psi", 0x1D713),
            ("omega", 0x1D714), ("epsilon", 0x1D716), ("vartheta", 0x1D717),
            ("varkappa", 0x1D718), ("phi", 0x1D719), ("varrho", 0x1D71A),
            ("varpi", 0x1D71B),
        ]
        for (n, c) in lower { t["\\" + n] = SymbolDef(c, .ord) }
        let upper: [(String, UInt32)] = [
            ("Gamma", 0x393), ("Delta", 0x394), ("Theta", 0x398),
            ("Lambda", 0x39B), ("Xi", 0x39E), ("Pi", 0x3A0), ("Sigma", 0x3A3),
            ("Upsilon", 0x3A5), ("Phi", 0x3A6), ("Psi", 0x3A8),
            ("Omega", 0x3A9),
        ]
        for (n, c) in upper { t["\\" + n] = SymbolDef(c, .ord) }

        let rels: [(String, UInt32)] = [
            ("leq", 0x2264), ("le", 0x2264), ("geq", 0x2265), ("ge", 0x2265),
            ("neq", 0x2260), ("ne", 0x2260), ("approx", 0x2248),
            ("equiv", 0x2261), ("sim", 0x223C), ("simeq", 0x2243),
            ("cong", 0x2245), ("propto", 0x221D), ("in", 0x2208),
            ("notin", 0x2209), ("ni", 0x220B), ("subset", 0x2282),
            ("supset", 0x2283), ("subseteq", 0x2286), ("supseteq", 0x2287),
            ("ll", 0x226A), ("gg", 0x226B), ("prec", 0x227A), ("succ", 0x227B),
            ("mid", 0x2223), ("parallel", 0x2225), ("perp", 0x22A5),
            ("to", 0x2192), ("rightarrow", 0x2192), ("leftarrow", 0x2190),
            ("Rightarrow", 0x21D2), ("Leftarrow", 0x21D0),
            ("leftrightarrow", 0x2194), ("Leftrightarrow", 0x21D4),
            ("mapsto", 0x21A6), ("hookrightarrow", 0x21AA),
            ("longrightarrow", 0x27F6), ("longleftarrow", 0x27F5),
            ("implies", 0x27F9), ("lesssim", 0x2272), ("gtrsim", 0x2273),
            ("asymp", 0x224D),
        ]
        for (n, c) in rels { t["\\" + n] = SymbolDef(c, .rel) }

        let bins: [(String, UInt32)] = [
            ("pm", 0x00B1), ("mp", 0x2213), ("times", 0x00D7), ("div", 0x00F7),
            ("cdot", 0x22C5), ("ast", 0x2217), ("star", 0x22C6),
            ("circ", 0x2218), ("bullet", 0x2219), ("cap", 0x2229),
            ("cup", 0x222A), ("uplus", 0x228E), ("sqcap", 0x2293),
            ("sqcup", 0x2294), ("vee", 0x2228), ("wedge", 0x2227),
            ("setminus", 0x2216), ("wr", 0x2240), ("oplus", 0x2295),
            ("ominus", 0x2296), ("otimes", 0x2297), ("oslash", 0x2298),
            ("odot", 0x2299),
        ]
        for (n, c) in bins { t["\\" + n] = SymbolDef(c, .bin) }

        let ords: [(String, UInt32)] = [
            ("infty", 0x221E), ("partial", 0x2202), ("nabla", 0x2207),
            ("forall", 0x2200), ("exists", 0x2203), ("nexists", 0x2204),
            ("emptyset", 0x2205), ("varnothing", 0x2205), ("neg", 0x00AC),
            ("lnot", 0x00AC), ("top", 0x22A4), ("bot", 0x22A5),
            ("angle", 0x2220), ("triangle", 0x25B3), ("square", 0x25A1),
            ("Box", 0x25A1), ("hbar", 0x210F), ("ell", 0x2113), ("Re", 0x211C),
            ("Im", 0x2111), ("aleph", 0x2135), ("wp", 0x2118),
            ("prime", 0x2032), ("degree", 0x00B0), ("dagger", 0x2020),
            ("ddagger", 0x2021), ("flat", 0x266D), ("sharp", 0x266F),
            ("checkmark", 0x2713), ("surd", 0x221A),
        ]
        for (n, c) in ords { t["\\" + n] = SymbolDef(c, .ord) }

        let inners: [(String, UInt32)] = [
            ("ldots", 0x2026), ("dots", 0x2026), ("cdots", 0x22EF),
            ("vdots", 0x22EE), ("ddots", 0x22F1),
        ]
        for (n, c) in inners { t["\\" + n] = SymbolDef(c, .inner) }

        let opens: [(String, UInt32)] = [
            ("langle", 0x27E8), ("lbrace", 0x007B), ("lbrack", 0x005B),
            ("lceil", 0x2308), ("lfloor", 0x230A), ("lvert", 0x007C),
            ("lVert", 0x2016),
        ]
        for (n, c) in opens { t["\\" + n] = SymbolDef(c, .open) }
        let closes: [(String, UInt32)] = [
            ("rangle", 0x27E9), ("rbrace", 0x007D), ("rbrack", 0x005D),
            ("rceil", 0x2309), ("rfloor", 0x230B), ("rvert", 0x007C),
            ("rVert", 0x2016),
        ]
        for (n, c) in closes { t["\\" + n] = SymbolDef(c, .close) }

        t["\\{"] = SymbolDef(0x007B, .open)
        t["\\}"] = SymbolDef(0x007D, .close)
        t["\\|"] = SymbolDef(0x2016, .ord)
        t["\\backslash"] = SymbolDef(0x005C, .ord)
        t["\\%"] = SymbolDef(0x0025, .ord)
        t["\\#"] = SymbolDef(0x0023, .ord)
        t["\\&"] = SymbolDef(0x0026, .ord)
        t["\\_"] = SymbolDef(0x005F, .ord)
        t["\\$"] = SymbolDef(0x0024, .ord)
        return t
    }()

    /// Big operators: name -> (codepoint, default \limits behaviour
    /// in display)
    static let bigOps: [String: (UInt32, Bool)] = [
        "\\sum": (0x2211, true), "\\prod": (0x220F, true),
        "\\coprod": (0x2210, true), "\\int": (0x222B, false),
        "\\iint": (0x222C, false), "\\iiint": (0x222D, false),
        "\\oint": (0x222E, false), "\\bigcup": (0x22C3, true),
        "\\bigcap": (0x22C2, true), "\\bigvee": (0x22C1, true),
        "\\bigwedge": (0x22C0, true), "\\bigoplus": (0x2A01, true),
        "\\bigotimes": (0x2A02, true), "\\bigodot": (0x2A00, true),
        "\\bigsqcup": (0x2A06, true), "\\biguplus": (0x2A04, true),
    ]

    /// Upright multi-letter operators (\lim, \sin, ...).
    /// Bool = limits above/below.
    static let namedOps: [String: Bool] = [
        "\\lim": true, "\\limsup": true, "\\liminf": true, "\\max": true,
        "\\min": true, "\\sup": true, "\\inf": true, "\\det": true,
        "\\gcd": true, "\\Pr": true, "\\sin": false, "\\cos": false,
        "\\tan": false, "\\cot": false, "\\sec": false, "\\csc": false,
        "\\arcsin": false, "\\arccos": false, "\\arctan": false,
        "\\sinh": false, "\\cosh": false, "\\tanh": false, "\\log": false,
        "\\ln": false, "\\exp": false, "\\deg": false, "\\dim": false,
        "\\ker": false, "\\hom": false, "\\arg": false, "\\Bbb": false,
    ]

    static let accents: [String: UInt32] = [
        "\\hat": 0x0302, "\\widehat": 0x0302, "\\bar": 0x0304,
        "\\overline": 0x0304, "\\tilde": 0x0303, "\\widetilde": 0x0303,
        "\\vec": 0x20D7, "\\dot": 0x0307, "\\ddot": 0x0308, "\\breve": 0x0306,
        "\\check": 0x030C, "\\acute": 0x0301, "\\grave": 0x0300,
        "\\mathring": 0x030A,
    ]

    static let fontCommands: [String: MathVariant] = [
        "\\mathrm": .upright, "\\mathit": .italic, "\\mathbf": .bold,
        "\\mathbb": .doubleStruck, "\\Bbb": .doubleStruck,
        "\\mathcal": .script, "\\mathscr": .script, "\\mathfrak": .fraktur,
        "\\mathsf": .sansSerif, "\\mathtt": .mono, "\\boldsymbol": .boldItalic,
        "\\bm": .boldItalic, "\\operatorname": .upright,
    ]

    /// Spacing commands, in mu (1/18 em).
    static let spaces: [String: CGFloat] = [
        "\\,": 3, "\\thinspace": 3, "\\:": 4, "\\>": 4, "\\medspace": 4,
        "\\;": 5, "\\thickspace": 5, "\\!": -3, "\\negthinspace": -3,
        "\\quad": 18, "\\qquad": 36, "\\ ": 6, "\\enspace": 9, "~": 6,
    ]

    static let delimiters: [String: UInt32] = [
        "(": 0x28, ")": 0x29, "[": 0x5B, "]": 0x5D, "|": 0x7C, "/": 0x2F,
        "\\{": 0x7B, "\\}": 0x7D, "\\lbrace": 0x7B, "\\rbrace": 0x7D,
        "\\langle": 0x27E8, "\\rangle": 0x27E9, "\\lceil": 0x2308,
        "\\rceil": 0x2309, "\\lfloor": 0x230A, "\\rfloor": 0x230B,
        "\\vert": 0x7C, "\\|": 0x2016, "\\Vert": 0x2016, "\\lvert": 0x7C,
        "\\rvert": 0x7C, "\\lVert": 0x2016, "\\rVert": 0x2016,
        "\\backslash": 0x5C, "\\uparrow": 0x2191, "\\downarrow": 0x2193,
        ".": 0,
    ]

    /// Atom class for a bare ASCII character.
    static func atom(for ch: Character) -> Atom {
        switch ch {
        case "+", "-", "*", "/": return .bin
        case "=", "<", ">": return .rel
        case "(", "[": return .open
        case ")", "]": return .close
        case ",", ";": return .punct
        case ":": return .rel
        default: return .ord
        }
    }

    /// ASCII characters that must be swapped for a proper math glyph.
    static func substitute(_ ch: Character) -> UInt32? {
        switch ch {
        case "-": return 0x2212       // minus sign
        case "*": return 0x2217
        case "'": return 0x2032
        default: return nil
        }
    }
}


indirect enum Node {
    case symbol(UInt32, Atom, literal: Bool)
    case group([Node])
    case styled(MathVariant, [Node])
    case supsub(base: Node?, sup: [Node]?, sub: [Node]?)
    case frac(num: [Node], den: [Node], rule: Bool,
              left: UInt32?, right: UInt32?)
    case sqrt(body: [Node], index: [Node]?)
    case accent(UInt32, [Node], stretchy: Bool)
    case bigOp(UInt32, limits: Bool?)
    case namedOp(String, limits: Bool)
    case leftRight(left: UInt32, right: UInt32, body: [Node])
    case sizedDelim(UInt32, Int)
    case text(String)
    case space(mu: CGFloat)
    case kern(CGFloat)
    case array(rows: [[[Node]]], gaps: [CGFloat], style: ArrayStyle)
    case tag([Node])
    case styleSwitch(TeXStyle, [Node])

    enum ArrayStyle {
        case aligned, substack, gathered
        case matrix(left: UInt32?, right: UInt32?)

        var isAligned: Bool {
            var result = false
            if case .aligned = self { result = true }
            return result
        }
        var isSubstack: Bool {
            var result = false
            if case .substack = self { result = true }
            return result
        }
        // Everything but `aligned` centres its columns. `aligned` is the
        // amsmath template, where odd columns hug the relation between
        // them.
        var centresColumns: Bool { !isAligned }
    }
}

public enum TeXStyle: Int {
    case display = 0, text = 1, script = 2, scriptScript = 3

    var isCramped: Bool { false }
    func sup() -> TeXStyle {
        self == .display || self == .text ? .script : .scriptScript
    }
    func sub() -> TeXStyle { sup() }
    func fracNum() -> TeXStyle {
        switch self {
        case .display: return .text
        case .text: return .script
        default: return .scriptScript
        }
    }
    func fracDen() -> TeXStyle { fracNum() }
    var isTight: Bool { self == .script || self == .scriptScript }
}


final class Parser {
    private let toks: [Tok]
    private var i = 0

    init(_ input: String) { toks = Lexer.tokens(input) }

    private var peek: Tok? { i < toks.count ? toks[i] : nil }
    private func next() -> Tok? {
        let t = peek
        if t != nil { i += 1 }
        return t
    }
    private func eat(_ s: String) -> Bool {
        if peek?.text == s { i += 1; return true }
        return false
    }
    private var pos: Int { peek?.pos ?? 0 }

    static func parse(_ input: String) throws -> [Node] {
        let p = Parser(input)
        var nodes = try p.expression(stop: [])
        if let t = p.peek, t.text == "\\\\" || t.text == "&" {
            nodes = [try p.implicitRows(first: nodes)]
        }
        if let t = p.peek {
            throw MathError.syntax("unexpected '\(t.text)'", at: t.pos)
        }
        return nodes
    }

    // A display can hold several lines, and columns inside them, without
    // ever naming an environment. `$$a \\ b$$` is a two-line display in
    // LaTeX and in KaTeX; `&` outside one is an error in both, but a
    // converter lifting equations out of a PDF drops the \begin{aligned}
    // and leaves exactly that behind, and a stack of rows is unambiguous
    // enough to draw rather than refuse. An `&` anywhere means the rows
    // align on it; otherwise they are simply gathered.

    private func implicitRows(first: [Node]) throws -> Node {
        var rows: [[[Node]]] = []
        var gaps: [CGFloat] = []
        var row: [[Node]] = [first]
        var aligned = false
        var reading = true
        while reading {
            if eat("&") {
                aligned = true
                row.append(try expression(stop: []))
            } else if eat("\\\\") {
                gaps.append(optionalDimension() ?? 0)
                rows.append(row)
                row = [try expression(stop: [])]
            } else {
                reading = false
            }
        }
        if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
        return .array(rows: rows, gaps: gaps,
                      style: aligned ? .aligned : .gathered)
    }

    private static let stoppers: Set<String> = [
        "}", "&", "\\\\", "\\right", "\\end", "]",
    ]

    private func atStop(_ stop: Set<String>) -> Bool {
        var result = true
        if let t = peek {
            result = stop.contains(t.text) ||
                     ["}", "&", "\\\\", "\\right", "\\end"].contains(t.text)
        }
        return result
    }

    func expression(stop: Set<String>) throws -> [Node] {
        var out: [Node] = []
        while !atStop(stop) {
            out.append(try atom())
        }
        return out
    }

    /// A nucleus plus any primes / ^ / _ attached to it.
    private func atom() throws -> Node {
        let base: Node? = try nucleus()

        // primes collapse into the superscript
        var primes = 0
        while peek?.text == "'" { primes += 1; i += 1 }

        var sup: [Node]? = nil
        var sub: [Node]? = nil
        if primes > 0 {
            sup = (0..<primes).map { _ in
                Node.symbol(0x2032, .ord, literal: true)
            }
        }

        var failure: MathError? = nil
        while failure == nil, let t = peek, t.text == "^" || t.text == "_" {
            i += 1
            let arg = try argument()
            if t.text == "^" {
                if sup == nil { sup = arg } else { sup! += arg }
            } else if sub != nil {
                failure = .syntax("double subscript", at: t.pos)
            } else {
                sub = arg
            }
        }
        if let failure { throw failure }
        // \limits / \nolimits already consumed in nucleus()
        let result: Node
        if sup == nil && sub == nil {
            result = base ?? .group([])
        } else {
            result = .supsub(base: base, sup: sup, sub: sub)
        }
        return result
    }

    /// One argument: a braced group, or a single atom.
    private func argument() throws -> [Node] {
        var result: [Node] = []
        var failure: MathError? = nil
        if let t = peek {
            if t.text == "{" {
                i += 1
                result = try expression(stop: ["}"])
                if !eat("}") { failure = .syntax("missing '}'", at: pos) }
            } else {
                result = [try nucleus()]
            }
        } else {
            failure = .syntax("missing argument", at: pos)
        }
        if let failure { throw failure }
        return result
    }

    /// Optional `[...]` argument.
    private func optionalArgument() throws -> [Node]? {
        var result: [Node]? = nil
        var failure: MathError? = nil
        if peek?.text == "[" {
            i += 1
            var depth = 0
            var out: [Node] = []
            while let t = peek, !(t.text == "]" && depth == 0) {
                if t.text == "{" { depth += 1 }
                if t.text == "}" { depth -= 1 }
                out.append(try atom())
            }
            if eat("]") {
                result = out
            } else {
                failure = .syntax("missing ']'", at: pos)
            }
        }
        if let failure { throw failure }
        return result
    }

    /// Raw `[4pt]`-style dimension after `\\`.
    private func optionalDimension() -> CGFloat? {
        var result: CGFloat? = nil
        if peek?.text == "[" {
            let save = i
            i += 1
            var s = ""
            while let t = peek, t.text != "]" { s += t.text; i += 1 }
            if eat("]") {
                result = Parser.dimension(s)
            } else {
                i = save
            }
        }
        return result
    }

    static func dimension(_ s: String) -> CGFloat? {
        var num = ""
        var unit = ""
        for ch in s {
            if ch.isNumber || ch == "." || ch == "-" || ch == "+" {
                num.append(ch)
            } else if !ch.isWhitespace {
                unit.append(ch)
            }
        }
        var result: CGFloat? = nil
        if let v = Double(num) {
            let f: CGFloat
            switch unit.lowercased() {
            case "pt": f = 1
            case "bp": f = 1.00375
            case "mm": f = 2.845
            case "cm": f = 28.45
            case "in": f = 72.27
            case "pc": f = 12
            case "ex": f = 4.3
            case "em": f = 10        // callers scale by size / 10
            case "mu": f = 10.0 / 18
            default: f = 1
            }
            result = CGFloat(v) * f
        }
        return result
    }


    // Four kinds of nucleus, tried in order: a braced group, a bare
    // character, a command that is nothing but a table entry, and a
    // command with a grammar of its own.

    private func nucleus() throws -> Node {
        let result: Node
        if let t = next() {
            let s = t.text
            if s == "{" {
                result = try groupNode()
            } else if !t.isCommand {
                result = characterNode(s)
            } else if let node = try tableNode(s) {
                result = node
            } else {
                result = try commandNode(s, t)
            }
        } else {
            throw MathError.syntax("unexpected end of input", at: pos)
        }
        return result
    }

    private func groupNode() throws -> Node {
        let body = try expression(stop: ["}"])
        if !eat("}") {
            throw MathError.syntax("missing '}'", at: pos)
        }
        return .group(body)
    }

    private func characterNode(_ s: String) -> Node {
        let result: Node
        if s == "~" {
            result = .space(mu: 6)
        } else {
            let ch = Character(s)
            if let sub = Symbols.substitute(ch) {
                result = .symbol(sub, Symbols.atom(for: ch), literal: true)
            } else {
                let scalar = ch.unicodeScalars.first?.value ?? 0
                let isAlnum = (ch.isLetter || ch.isNumber) && scalar < 128
                result = .symbol(scalar, Symbols.atom(for: ch),
                                 literal: !isAlnum)
            }
        }
        return result
    }

    // The commands that are pure lookups. nil means the name belongs to
    // the switch in commandNode instead.

    private func tableNode(_ s: String) throws -> Node? {
        var result: Node? = nil
        if let sp = Symbols.spaces[s] {
            result = .space(mu: sp)
        } else if let d = Symbols.table[s] {
            result = .symbol(d.scalar, d.atom, literal: d.literal)
        } else if let v = Symbols.fontCommands[s] {
            result = .styled(v, try argument())
        } else if let acc = Symbols.accents[s] {
            let stretchy = s.hasPrefix("\\wide") || s == "\\overline"
            result = .accent(acc, try argument(), stretchy: stretchy)
        } else if let (cp, limits) = Symbols.bigOps[s] {
            result = .bigOp(cp, limits: limitsOverride() ?? limits)
        } else if let limits = Symbols.namedOps[s] {
            result = .namedOp(String(s.dropFirst()),
                              limits: limitsOverride() ?? limits)
        }
        return result
    }

    // \limits and \nolimits following an operator override where its
    // sub- and superscripts go. The last one wins, and both big
    // operators and named ones accept them, which is why this is not
    // written out twice.

    private func limitsOverride() -> Bool? {
        var result: Bool? = nil
        while let n = peek, n.text == "\\limits" || n.text == "\\nolimits" {
            result = n.text == "\\limits"
            i += 1
        }
        return result
    }

    private func commandNode(_ s: String, _ t: Tok) throws -> Node {
        switch s {
        case "\\frac", "\\dfrac", "\\tfrac", "\\cfrac":
            return try fracNode(s)
        case "\\binom":
            let n = try argument(), d = try argument()
            return .frac(num: n, den: d, rule: false, left: 0x28, right: 0x29)
        case "\\sqrt":
            let idx = try optionalArgument()
            return .sqrt(body: try argument(), index: idx)
        case "\\text", "\\textrm", "\\textup", "\\mbox", "\\textnormal":
            return .text(try textArgument())
        case "\\textbf":
            return .styled(.bold, [.text(try textArgument())])
        case "\\textit", "\\emph":
            return .styled(.italic, [.text(try textArgument())])
        case "\\left":
            return try leftRightNode()
        case "\\substack":
            return try substackNode()
        case "\\tag":
            return .tag(try argument())
        case "\\begin":
            return try environment()
        case "\\displaystyle":
            return .styleSwitch(.display, try expression(stop: []))
        case "\\textstyle":
            return .styleSwitch(.text, try expression(stop: []))
        case "\\scriptstyle":
            return .styleSwitch(.script, try expression(stop: []))
        case "\\scriptscriptstyle":
            return .styleSwitch(.scriptScript, try expression(stop: []))
        case "\\big", "\\bigl", "\\bigr", "\\Big", "\\Bigl", "\\Bigr",
             "\\bigg", "\\biggl", "\\biggr", "\\Bigg", "\\Biggl", "\\Biggr":
            return try sizedDelimNode(s)
        case "\\limits", "\\nolimits", "\\!", "\\nonumber", "\\notag":
            return .group([])
        case "\\hspace", "\\kern", "\\mskip", "\\hskip":
            return kernNode()
        default:
            throw MathError.syntax("unknown command '\(s)'", at: t.pos)
        }
    }

    // \dfrac and \tfrac are \frac inside a style switch; \cfrac is
    // treated as plain \frac, which is what it degrades to without
    // continued-fraction alignment.

    private func fracNode(_ s: String) throws -> Node {
        let n = try argument(), d = try argument()
        let node = Node.frac(num: n, den: d, rule: true,
                             left: nil, right: nil)
        let result: Node
        if s == "\\dfrac" {
            result = .styleSwitch(.display, [node])
        } else if s == "\\tfrac" {
            result = .styleSwitch(.text, [node])
        } else {
            result = node
        }
        return result
    }

    private func leftRightNode() throws -> Node {
        var left: UInt32 = 0
        var right: UInt32 = 0
        var body: [Node] = []
        var failure: MathError? = nil
        if let d = next() {
            left = Symbols.delimiters[d.text] ?? 0
            body = try expression(stop: ["\\right"])
            if eat("\\right"), let r = next() {
                right = Symbols.delimiters[r.text] ?? 0
            } else {
                failure = .syntax("missing \\right", at: pos)
            }
        } else {
            failure = .syntax("missing delimiter", at: pos)
        }
        if let failure { throw failure }
        return .leftRight(left: left, right: right, body: body)
    }

    private func substackNode() throws -> Node {
        var rows: [[[Node]]] = []
        var failure: MathError? = nil
        if eat("{") {
            rows = try rowsAndCells(stop: "}", cells: false).0
            if !eat("}") { failure = .syntax("missing '}'", at: pos) }
        } else {
            failure = .syntax("\\substack needs {", at: pos)
        }
        if let failure { throw failure }
        return .array(rows: rows, gaps: [], style: .substack)
    }

    // \big through \Biggl: the count of g's picks the size, and a
    // capital B moves it up one more.

    private func sizedDelimNode(_ s: String) throws -> Node {
        var cp: UInt32 = 0
        var failure: MathError? = nil
        if let d = next() {
            cp = Symbols.delimiters[d.text] ?? 0
        } else {
            failure = .syntax("missing delimiter", at: pos)
        }
        if let failure { throw failure }
        var n = s.dropFirst().hasPrefix("B") ? 2 : 1
        if s.contains("bigg") || s.contains("Bigg") { n = 3 }
        return .sizedDelim(cp, n)
    }

    // A bare \kern with no braced dimension is a no-op rather than an
    // error: it is the shape AI-written markdown reaches for most.

    private func kernNode() -> Node {
        var result = Node.group([])
        if peek?.text == "{" {
            i += 1
            var raw = ""
            while let t = peek, t.text != "}" {
                raw += t.text
                i += 1
            }
            _ = eat("}")
            result = .kern(Parser.dimension(raw) ?? 0)
        }
        return result
    }

    /// `\text{...}`: reassemble the raw characters. The lexer has
    /// dropped spaces, so re-read them from the source token positions.
    private func textArgument() throws -> String {
        let open = peek
        var out = ""
        var failure: MathError? = nil
        if eat("{") {
            var depth = 0
            // Gaps are measured from the brace, not from the first token,
            // so a leading space survives: `\text{ is even}` is written
            // with that space for a reason and reads as "isxeven" without
            // it. The closing brace is a gap like any other, or
            // `\text{if }` loses the space it ends with.
            var lastEnd = open.map { t in t.pos + t.text.count } ?? -1
            while let t = peek, !(t.text == "}" && depth == 0) {
                if lastEnd >= 0 && t.pos > lastEnd { out += " " }
                if t.text == "{" { depth += 1 }
                if t.text == "}" { depth -= 1 }
                if t.isCommand {
                    switch t.text {
                    case "\\ ": out += " "
                    case "\\&": out += "&"
                    case "\\%": out += "%"
                    case "\\_": out += "_"
                    case "\\#": out += "#"
                    default: out += String(t.text.dropFirst())
                    }
                } else if t.text != "{" && t.text != "}" {
                    out += t.text
                }
                lastEnd = t.pos + t.text.count
                i += 1
            }
            if let t = peek, lastEnd >= 0, t.pos > lastEnd { out += " " }
            if !eat("}") { failure = .syntax("missing '}'", at: pos) }
        } else {
            failure = .syntax("expected '{'", at: pos)
        }
        if let failure { throw failure }
        return out
    }


    private func environmentName() throws -> String {
        var name = ""
        var failure: MathError? = nil
        if eat("{") {
            while let t = peek, t.text != "}" { name += t.text; i += 1 }
            if !eat("}") { failure = .syntax("missing '}'", at: pos) }
        } else {
            failure = .syntax("expected '{'", at: pos)
        }
        if let failure { throw failure }
        return name
    }

    private static func arrayStyle(_ name: String) -> Node.ArrayStyle? {
        let result: Node.ArrayStyle?
        switch name {
        case "aligned", "align", "align*", "alignedat", "split", "eqnarray":
            result = .aligned
        case "gathered", "gather", "gather*":
            result = .gathered
        case "matrix", "array":
            result = .matrix(left: nil, right: nil)
        case "pmatrix":
            result = .matrix(left: 0x28, right: 0x29)
        case "bmatrix":
            result = .matrix(left: 0x5B, right: 0x5D)
        case "vmatrix":
            result = .matrix(left: 0x7C, right: 0x7C)
        case "Bmatrix":
            result = .matrix(left: 0x7B, right: 0x7D)
        case "cases":
            result = .matrix(left: 0x7B, right: 0)
        case "substack":
            result = .substack
        default:
            result = nil
        }
        return result
    }

    private func environment() throws -> Node {
        let name = try environmentName()
        let (rows, gaps) = try rowsAndCells(stop: "\\end", cells: true)
        var style = Node.ArrayStyle.gathered
        var failure: MathError? = nil
        if eat("\\end") {
            let close = try environmentName()
            if close != name {
                failure = .syntax(
                    "\\begin{\(name)} closed by \\end{\(close)}", at: pos)
            } else if let known = Parser.arrayStyle(name) {
                style = known
            } else {
                failure = .syntax("unknown environment '\(name)'", at: pos)
            }
        } else {
            failure = .syntax("missing \\end", at: pos)
        }
        if let failure { throw failure }
        return .array(rows: rows, gaps: gaps, style: style)
    }

    /// Parse `a & b \\[gap] c & d` until `stop`.
    private func rowsAndCells(stop: String,
                              cells: Bool) throws -> ([[[Node]]], [CGFloat]) {
        var rows: [[[Node]]] = []
        var gaps: [CGFloat] = []
        var row: [[Node]] = []
        var reading = true
        while reading {
            let cell = try expression(stop: [stop])
            row.append(cell)
            if !(cells && eat("&")) {
                if eat("\\\\") {
                    gaps.append(optionalDimension() ?? 0)
                    rows.append(row)
                    row = []
                    reading = peek != nil && peek?.text != stop
                } else {
                    reading = false
                }
            }
        }
        if !(row.count == 1 && row[0].isEmpty) || rows.isEmpty {
            rows.append(row)
        }
        return (rows, gaps)
    }
}


final class Box {
    enum Kind {
        case glyph(CGGlyph, CGFloat)   // glyph id, font size
        case rule
        case list
    }
    var kind: Kind = .list
    var width: CGFloat = 0
    var height: CGFloat = 0     // ink above the baseline
    var depth: CGFloat = 0      // ink below the baseline
    var italic: CGFloat = 0
    /// True for a bare glyph (TeXbook rule 18a starts its script
    /// shifts at zero).
    var isCharLike = false
    var children: [(box: Box, dx: CGFloat, dy: CGFloat)] = []

    init(kind: Kind = .list) { self.kind = kind }

    static func kern(_ w: CGFloat) -> Box {
        let b = Box(); b.width = w; return b
    }

    static func rule(width: CGFloat, height: CGFloat,
                     depth: CGFloat = 0) -> Box {
        let b = Box(kind: .rule)
        b.width = width; b.height = height; b.depth = depth
        return b
    }

    /// Horizontal list: boxes placed left to right on a shared baseline.
    static func hbox(_ boxes: [Box]) -> Box {
        let b = Box()
        var x: CGFloat = 0
        for c in boxes {
            b.children.append((c, x, 0))
            x += c.width
            b.height = max(b.height, c.height)
            b.depth = max(b.depth, c.depth)
        }
        b.width = x
        b.italic = boxes.last?.italic ?? 0
        return b
    }

    /// Explicitly placed children; `dy` is positive upwards from the baseline.
    static func place(_ items: [(box: Box, dx: CGFloat, dy: CGFloat)]) -> Box {
        let b = Box()
        b.children = items
        for (c, dx, dy) in items {
            b.width = max(b.width, dx + c.width)
            b.height = max(b.height, c.height + dy)
            b.depth = max(b.depth, c.depth - dy)
        }
        return b
    }

    func shifted(dy: CGFloat) -> Box {
        Box.place([(self, 0, dy)])
    }

    /// Re-measure a box's extents from its children (after manual edits).
    func remeasure() {
        height = 0; depth = 0
        for (c, _, dy) in children {
            height = max(height, c.height + dy)
            depth = max(depth, c.depth - dy)
        }
    }

    func render(in ctx: CGContext, x: CGFloat, y: CGFloat,
                font: MathFontFile) {
        switch kind {
        case .glyph(let g, let size):
            var glyphs = [g]
            var points = [CGPoint(x: x, y: y)]
            CTFontDrawGlyphs(font.ctFont(size), &glyphs, &points, 1, ctx)
        case .rule:
            ctx.fill(CGRect(x: x, y: y - depth, width: width,
                            height: height + depth))
        case .list:
            break
        }
        for (child, dx, dy) in children {
            child.render(in: ctx, x: x + dx, y: y + dy, font: font)
        }
    }
}


struct Opts {
    let font: MathFontFile
    var style: TeXStyle
    var cramped: Bool
    var variant: MathVariant
    var base: CGFloat

    var size: CGFloat {
        switch style {
        case .display, .text: return base
        case .script: return base * font.scriptPercent
        case .scriptScript: return base * font.scriptScriptPercent
        }
    }
    /// A MATH constant scaled to the current style's font size.
    func k(_ c: MathFontFile.Constant) -> CGFloat { font.constant(c) * size }
    var axis: CGFloat { k(.axisHeight) }
    var mu: CGFloat { size / 18 }

    func with(style: TeXStyle? = nil, cramped: Bool? = nil,
              variant: MathVariant? = nil) -> Opts {
        var o = self
        if let s = style { o.style = s }
        if let c = cramped { o.cramped = c }
        if let v = variant { o.variant = v }
        return o
    }
}


enum Spacing {
    /// Negative values are suppressed in script and scriptscript styles.
    static let table: [[Int]] = [
        //        ord  op  bin  rel open close punct inner
        /*ord*/  [  0,  1,  -2,  -3,  0,   0,    0,   -1],
        /*op*/   [  1,  1,   0,  -3,  0,   0,    0,   -1],
        /*bin*/  [ -2, -2,   0,   0, -2,   0,    0,   -2],
        /*rel*/  [ -3, -3,   0,   0, -3,   0,    0,   -3],
        /*open*/ [  0,  0,   0,   0,  0,   0,    0,    0],
        /*close*/[  0,  1,  -2,  -3,  0,   0,    0,   -1],
        /*punct*/[ -1, -1,   0,  -1, -1,  -1,   -1,   -1],
        /*inner*/[ -1,  1,  -2,  -3, -1,   0,   -1,   -1],
    ]

    static func index(_ a: Atom) -> Int {
        switch a {
        case .ord: return 0
        case .op: return 1
        case .bin: return 2
        case .rel: return 3
        case .open: return 4
        case .close: return 5
        case .punct: return 6
        case .inner: return 7
        }
    }

    static func amount(_ l: Atom, _ r: Atom, tight: Bool) -> Int {
        let v = table[index(l)][index(r)]
        let result: Int
        if v < 0 {
            result = tight ? 0 : -v
        } else {
            result = v
        }
        return result
    }
}


final class Layouter {
    let font: MathFontFile
    var tagBox: Box?

    init(font: MathFontFile) { self.font = font }


    func glyphBox(_ scalar: UInt32, _ size: CGFloat) -> Box {
        var g = font.glyph(scalar)
        if g == 0, scalar > 0x1D000 {
            // math alphanumeric missing: fall back to the plain ASCII letter
            if let ascii = Layouter.demote(scalar) { g = font.glyph(ascii) }
        }
        if g == 0 { g = font.glyph(scalar) }
        let m = font.metrics(g, size)
        let b = Box(kind: .glyph(g, size))
        b.width = m.adv
        b.height = m.h
        b.depth = m.d
        b.italic = font.italicCorrection(g, size)
        b.isCharLike = true
        return b
    }

    /// Map a math alphanumeric codepoint back to its ASCII base.
    static func demote(_ cp: UInt32) -> UInt32? {
        let ranges: [(UInt32, UInt32, UInt32)] = [
            (0x1D400, 0x1D419, 65), (0x1D41A, 0x1D433, 97),
            (0x1D434, 0x1D44D, 65), (0x1D44E, 0x1D467, 97),
            (0x1D468, 0x1D481, 65), (0x1D482, 0x1D49B, 97),
            (0x1D49C, 0x1D4B5, 65), (0x1D4B6, 0x1D4CF, 97),
            (0x1D4D0, 0x1D4E9, 65), (0x1D4EA, 0x1D503, 97),
            (0x1D504, 0x1D51D, 65), (0x1D51E, 0x1D537, 97),
            (0x1D538, 0x1D551, 65), (0x1D552, 0x1D56B, 97),
            (0x1D5A0, 0x1D5B9, 65), (0x1D5BA, 0x1D5D3, 97),
            (0x1D5D4, 0x1D5ED, 65), (0x1D5EE, 0x1D607, 97),
            (0x1D670, 0x1D689, 65), (0x1D68A, 0x1D6A3, 97),
            (0x1D7CE, 0x1D7D7, 48), (0x1D7D8, 0x1D7E1, 48),
            (0x1D7E2, 0x1D7EB, 48), (0x1D7EC, 0x1D7F5, 48),
            (0x1D7F6, 0x1D7FF, 48),
        ]
        var result: UInt32? = nil
        for (lo, hi, base) in ranges where cp >= lo && cp <= hi {
            if result == nil { result = base + (cp - lo) }
        }
        if result == nil, cp >= 0x1D6FC, cp <= 0x1D71B {
            result = 0x3B1 + (cp - 0x1D6FC)
        }
        if result == nil, cp >= 0x1D6E2, cp <= 0x1D6FA {
            result = 0x391 + (cp - 0x1D6E2)
        }
        return result
    }


    private func variantBox(_ g: CGGlyph, _ size: CGFloat) -> Box {
        let m = font.metrics(g, size)
        let b = Box(kind: .glyph(g, size))
        b.width = m.adv; b.height = m.h; b.depth = m.d
        b.italic = font.italicCorrection(g, size)
        b.isCharLike = true
        return b
    }

    func stretchVertical(_ scalar: UInt32, target: CGFloat, _ o: Opts) -> Box {
        let size = o.size
        let base = font.glyph(scalar)
        let result: Box
        if base == 0 {
            result = Box.kern(0)
        } else {
            let m = font.metrics(base, size)
            let variants = font.verticalVariants(base)
            let fitting = variants.first(where: { v in
                v.adv * size >= target - 0.01
            })
            let parts = font.verticalAssembly(base)
            if m.h + m.d >= target - 0.01 {
                result = glyphBox(scalar, size)
            } else if let fitting {
                result = variantBox(fitting.glyph, size)
            } else if !parts.isEmpty {
                result = assemble(parts, target: target, size: size)
            } else if let last = variants.last {
                // No recipe: the largest variant available.
                result = variantBox(last.glyph, size)
            } else {
                result = glyphBox(scalar, size)
            }
        }
        return result
    }

    private func assemble(_ parts: [MathFontFile.AssemblyPart],
                          target: CGFloat, size: CGFloat) -> Box {
        let overlap = font.minConnectorOverlap * size
        let ext = parts.filter { p in p.isExtender }
        let fixed = parts.filter { p in !p.isExtender }
        let fixedLen = fixed.reduce(CGFloat(0)) { sum, p in
            sum + p.fullAdvance * size
        }
        let extLen = ext.reduce(CGFloat(0)) { sum, p in
            sum + p.fullAdvance * size
        }

        var reps = 1
        func total(_ r: Int) -> CGFloat {
            let count = fixed.count + ext.count * r
            var result: CGFloat = 0
            if count > 0 {
                let span = fixedLen + extLen * CGFloat(r)
                result = span - overlap * CGFloat(count - 1)
            }
            return result
        }
        while total(reps) < target && reps < 200 { reps += 1 }

        var sequence: [MathFontFile.AssemblyPart] = []
        for p in parts {
            if p.isExtender {
                for _ in 0..<reps { sequence.append(p) }
            } else {
                sequence.append(p)
            }
        }

        // Parts run bottom to top in the font's order.
        var items: [(box: Box, dx: CGFloat, dy: CGFloat)] = []
        var y: CGFloat = 0
        var maxWidth: CGFloat = 0
        for (idx, p) in sequence.enumerated() {
            let m = font.metrics(p.glyph, size)
            let b = Box(kind: .glyph(p.glyph, size))
            b.width = m.adv; b.height = m.h; b.depth = m.d
            maxWidth = max(maxWidth, m.adv)
            if idx > 0 { y -= overlap }
            items.append((b, 0, y + m.d))
            y += p.fullAdvance * size
        }
        let box = Box.place(items)
        // Centre the assembly vertically on its own middle.
        let mid = (box.height - box.depth) / 2
        let shifted = Box.place(items.map { i in (i.box, i.dx, i.dy - mid) })
        shifted.width = maxWidth
        shifted.isCharLike = true
        return shifted
    }

    /// Delimiter sized to enclose `height`/`depth` around the maths axis.
    func delimiter(_ scalar: UInt32, height: CGFloat, depth: CGFloat,
                   _ o: Opts) -> Box {
        let result: Box
        if scalar == 0 {
            result = Box.kern(0)
        } else {
            let axis = o.axis
            let delta = max(height - axis, depth + axis)
            let target = max(2 * delta * 1.0, o.size * 1.0)
            let b = stretchVertical(scalar, target: target, o)
            let mid = (b.height - b.depth) / 2
            result = b.shifted(dy: axis - mid)
        }
        return result
    }

    func sizedDelimiter(_ scalar: UInt32, _ n: Int, _ o: Opts) -> Box {
        let factors: [CGFloat] = [1.2, 1.8, 2.4, 3.0]
        let target = o.size * factors[min(max(n, 1), 4) - 1]
        let b = stretchVertical(scalar, target: target, o)
        let mid = (b.height - b.depth) / 2
        return b.shifted(dy: o.axis - mid)
    }

    /// Build a list of nodes into a single box, applying inter-atom spacing.
    func build(_ nodes: [Node], _ o: Opts) -> Box {
        var items = nodes.map { n in node(n, o) }

        // TeX rule: a binary operator with nothing suitable on its left, or
        // followed by a relation/close/punct, degrades to an ordinary atom.
        for idx in items.indices where items[idx].atom == .bin {
            let leftOK: Bool
            if idx == 0 { leftOK = false } else {
                switch items[idx - 1].atom {
                case .bin, .op, .rel, .open, .punct: leftOK = false
                default: leftOK = true
                }
            }
            var rightOK = idx + 1 < items.count
            if idx + 1 < items.count {
                switch items[idx + 1].atom {
                case .rel, .close, .punct: rightOK = false
                default: break
                }
            }
            if !leftOK || !rightOK { items[idx].atom = .ord }
        }

        var boxes: [Box] = []
        for (idx, it) in items.enumerated() {
            if idx > 0 {
                let mu = Spacing.amount(items[idx - 1].atom, it.atom,
                                        tight: o.style.isTight)
                if mu != 0 { boxes.append(Box.kern(CGFloat(mu) * o.mu)) }
            }
            boxes.append(it.box)
        }
        return Box.hbox(boxes)
    }

    func node(_ n: Node, _ o: Opts) -> (box: Box, atom: Atom) {
        switch n {
        case .symbol(let cp, let atom, let literal):
            let scalar: UInt32
            if literal {
                scalar = cp
            } else if let ch = Unicode.Scalar(cp).map({ u in Character(u) }) {
                scalar = Alphanumerics.map(ch, o.variant)
            } else {
                scalar = cp
            }
            return (glyphBox(scalar, o.size), atom)

        case .group(let body):
            return (build(body, o), .ord)

        case .styled(let v, let body):
            return (build(body, o.with(variant: v)), .ord)

        case .styleSwitch(let st, let body):
            return (build(body, o.with(style: st)), .ord)

        case .space(let mu):
            return (Box.kern(mu * o.mu), .ord)

        case .kern(let pt):
            return (Box.kern(pt * o.size / 10), .ord)

        case .text(let s):
            return (textBox(s, o), .ord)

        case .tag(let body):
            var d = o
            d.style = .display
            tagBox = build(body, d)
            return (Box.kern(0), .ord)

        case .sizedDelim(let cp, let size):
            return (sizedDelimiter(cp, size, o), .ord)

        case .bigOp(let cp, let limits):
            _ = limits
            return (bigOpBox(cp, o), .op)

        case .namedOp(let name, _):
            return (textBox(name, o.with(variant: .upright)), .op)

        case .accent(let cp, let body, let stretchy):
            return (accentBox(cp, body, stretchy: stretchy, o), .ord)

        case .sqrt(let body, let index):
            return (sqrtBox(body, index, o), .ord)

        case .frac(let num, let den, let rule, let left, let right):
            return (fracBox(num, den, rule: rule, left: left,
                            right: right, o), .ord)

        case .leftRight(let l, let r, let body):
            return (leftRightBox(l, r, body, o), .inner)

        case .array(let rows, let gaps, let style):
            return (arrayBox(rows, gaps, style, o), .ord)

        case .supsub(let base, let sup, let sub):
            return supsubBox(base, sup, sub, o)
        }
    }


    func textBox(_ s: String, _ o: Opts) -> Box {
        var boxes: [Box] = []
        let spaceWidth = font.metrics(font.glyph(UInt32(32)), o.size).adv
        for ch in s {
            if ch == " " {
                boxes.append(Box.kern(spaceWidth))
            } else {
                let cp = ch.unicodeScalars.first!.value
                let mapped = (o.variant == .bold || o.variant == .italic)
                    ? Alphanumerics.map(ch, o.variant) : cp
                boxes.append(glyphBox(mapped, o.size))
            }
        }
        return Box.hbox(boxes)
    }


    func bigOpBox(_ cp: UInt32, _ o: Opts) -> Box {
        let b: Box
        if o.style == .display {
            let target = max(font.displayOperatorMinHeight * o.size,
                             o.size * 1.0)
            b = stretchVertical(cp, target: target, o)
        } else {
            b = glyphBox(cp, o.size)
        }
        // TeX centres operators on the maths axis.
        let mid = (b.height - b.depth) / 2
        // tex.web make_op turns the operator into a shifted box, which is why
        // rule 18a stops applying and \int_a^b hangs off the glyph's extents.
        let out = b.shifted(dy: o.axis - mid)
        out.italic = b.italic
        out.width = b.width
        return out
    }


    func supsubBox(_ base: Node?, _ sup: [Node]?, _ sub: [Node]?,
                   _ o: Opts) -> (Box, Atom) {
        let result: (Box, Atom)
        if let stacked = limitsForm(base, sup, sub, o) {
            result = (stacked, .op)
        } else {
            result = scriptsBox(base, sup, sub, o)
        }
        return result
    }

    /// Limits above/below rather than beside, when the base asks for it.

    private func limitsForm(_ base: Node?, _ sup: [Node]?, _ sub: [Node]?,
                            _ o: Opts) -> Box? {
        var result: Box? = nil
        if let b = base, o.style == .display {
            switch b {
            case .bigOp(let cp, let limits) where limits ?? true:
                result = limitsBox(bigOpBox(cp, o), sup, sub, o)
            case .namedOp(let name, let limits) where limits:
                let opBox = textBox(name, o.with(variant: .upright))
                result = limitsBox(opBox, sup, sub, o)
            default: break
            }
        }
        return result
    }

    private func scriptsBox(_ base: Node?, _ sup: [Node]?, _ sub: [Node]?,
                            _ o: Opts) -> (Box, Atom) {
        let baseResult = base.map { n in node(n, o) }
        let baseBox = baseResult?.box ?? Box.kern(0)
        let atom = baseResult?.atom ?? .ord

        let scriptOpts = o.with(style: o.style.sup(), cramped: o.cramped)
        let supBox = sup.map { n in build(n, scriptOpts) }
        let subBox = sub.map { n in
            build(n, o.with(style: o.style.sub(), cramped: true))
        }

        // Rule 18a: a lone glyph nucleus starts its script shifts at zero.
        let isChar = baseBox.isCharLike

        let supDrop = o.k(.superscriptBaselineDropMax)
        let subDrop = o.k(.subscriptBaselineDropMin)
        let shiftUp = o.cramped ? o.k(.superscriptShiftUpCramped)
                                : o.k(.superscriptShiftUp)
        var u: CGFloat = isChar ? 0 : baseBox.height - supDrop
        var v: CGFloat = isChar ? 0 : baseBox.depth + subDrop

        let italic = baseBox.italic

        var result: Box
        if let sp = supBox, subBox == nil {
            u = max(u, shiftUp)
            u = max(u, sp.depth + o.k(.superscriptBottomMin))
            result = Box.place([(baseBox, 0, 0),
                                (sp, baseBox.width + italic, u)])
        } else if let sb = subBox, supBox == nil {
            v = max(v, o.k(.subscriptShiftDown))
            v = max(v, sb.height - o.k(.subscriptTopMax))
            result = Box.place([(baseBox, 0, 0), (sb, baseBox.width, -v)])
        } else if let sp = supBox, let sb = subBox {
            u = max(u, shiftUp)
            u = max(u, sp.depth + o.k(.superscriptBottomMin))
            v = max(v, o.k(.subscriptShiftDown))
            v = max(v, sb.height - o.k(.subscriptTopMax))

            let gapMin = o.k(.subSuperscriptGapMin)
            let gap = (u - sp.depth) - (sb.height - v)
            if gap < gapMin {
                v += gapMin - gap
                let bottomMax = o.k(.superscriptBottomMaxWithSubscript)
                let psi = bottomMax - (u - sp.depth)
                if psi > 0 { u += psi; v -= psi }
            }
            result = Box.place([
                (baseBox, 0, 0),
                (sp, baseBox.width + italic, u),
                (sb, baseBox.width, -v),
            ])
        } else {
            result = baseBox
        }

        if supBox != nil || subBox != nil {
            result = Box.hbox([result, Box.kern(o.k(.spaceAfterScript))])
        }
        return (result, atom)
    }

    /// Limits set above and below an operator.
    func limitsBox(_ opBox: Box, _ sup: [Node]?, _ sub: [Node]?,
                   _ o: Opts) -> Box {
        let upper = sup.map { n in build(n, o.with(style: o.style.sup())) }
        let lower = sub.map { n in
            build(n, o.with(style: o.style.sub(), cramped: true))
        }
        let width = max(opBox.width, max(upper?.width ?? 0, lower?.width ?? 0))

        var items: [(box: Box, dx: CGFloat, dy: CGFloat)] = []
        items.append((opBox, (width - opBox.width) / 2, 0))

        if let up = upper {
            let gap = max(o.k(.upperLimitGapMin),
                          o.k(.upperLimitBaselineRiseMin) - up.depth)
            let dy = opBox.height + gap + up.depth
            items.append((up, (width - up.width) / 2, dy))
        }
        if let lo = lower {
            let gap = max(o.k(.lowerLimitGapMin),
                          o.k(.lowerLimitBaselineDropMin) - lo.height)
            let dy = -(opBox.depth + gap + lo.height)
            items.append((lo, (width - lo.width) / 2, dy))
        }
        let b = Box.place(items)
        b.width = width
        return b
    }


    func accentBox(_ cp: UInt32, _ body: [Node], stretchy: Bool,
                   _ o: Opts) -> Box {
        let base = build(body, o.with(cramped: true))
        let glyph = font.glyph(cp)
        let result: Box
        if glyph == 0 {
            result = base
        } else {
            let chosen = stretchy
                ? stretchedAccent(glyph, over: base.width, o) : glyph
            result = placeAccent(chosen, over: base, o)
        }
        return result
    }

    // The narrowest variant wide enough for the base, else the widest
    // one the font offers.

    private func stretchedAccent(_ g: CGGlyph, over width: CGFloat,
                                 _ o: Opts) -> CGGlyph {
        var result = g
        let fitting = font.horizontalVariants(g).first(where: { v in
            v.adv * o.size >= width
        })
        if let fitting { result = fitting.glyph }
        let variants = font.horizontalVariants(result)
        if !variants.isEmpty,
           font.metrics(result, o.size).adv < width,
           let last = variants.last {
            result = last.glyph
        }
        return result
    }

    private func placeAccent(_ g: CGGlyph, over base: Box,
                             _ o: Opts) -> Box {
        let m = font.metrics(g, o.size)
        let accRect = font.rect(g, o.size)
        let acc = Box(kind: .glyph(g, o.size))
        acc.width = m.adv; acc.height = m.h; acc.depth = m.d

        // Horizontal: line the accent's centre up with the base's
        // attachment point.
        var attach = base.width / 2 + base.italic / 2
        if case .glyph(let bg, let sz) = base.kind,
           let a = font.topAccentAttachment(bg, sz) {
            attach = a
        }
        let accCentre = accRect.isEmpty ? m.adv / 2 : accRect.midX
        let dx = attach - accCentre

        // Vertical: raise by however far the base rises above
        // accentBaseHeight.
        let clearance = max(0, base.height - o.k(.accentBaseHeight))
        let box = Box.place([(base, 0, 0), (acc, dx, clearance)])
        box.width = base.width
        box.italic = base.italic
        return box
    }


    func sqrtBox(_ body: [Node], _ index: [Node]?, _ o: Opts) -> Box {
        let inner = build(body, o.with(cramped: true))
        let rule = max(o.k(.radicalRuleThickness), o.size * 0.04)
        let gap = o.style == .display
            ? o.k(.radicalDisplayStyleVerticalGap)
            : o.k(.radicalVerticalGap)
        let target = inner.height + inner.depth + gap + rule
        let radical = stretchVertical(0x221A, target: target, o)

        // Sit the radical so its top edge is the rule's top edge.
        let radDy = (inner.height + gap + rule) - radical.height
        let bar = Box.rule(width: inner.width + o.size * 0.08, height: rule)

        var items: [(box: Box, dx: CGFloat, dy: CGFloat)] = [
            (radical, 0, radDy),
            (bar, radical.width, inner.height + gap),
            (inner, radical.width + o.size * 0.04, 0),
        ]
        var xShift: CGFloat = 0
        if let idx = index {
            let iBox = build(idx, o.with(style: .scriptScript))
            let kernBefore = o.k(.radicalKernBeforeDegree)
            let kernAfter = o.k(.radicalKernAfterDegree)
            xShift = max(0, kernBefore + iBox.width + kernAfter)
            let raise = 0.6 * (radical.height + radical.depth) - radical.depth
            items = items.map { i in (i.box, i.dx + xShift, i.dy) }
            items.append((iBox, kernBefore, raise + radDy))
        }
        let box = Box.place(items)
        let ascender = o.k(.radicalExtraAscender)
        box.height = max(box.height, inner.height + gap + rule + ascender)
        box.width = xShift + radical.width + bar.width
        return box
    }


    func fracBox(_ num: [Node], _ den: [Node], rule: Bool,
                 left: UInt32?, right: UInt32?, _ o: Opts) -> Box {
        let display = o.style == .display
        let numBox = build(num, o.with(style: o.style.fracNum()))
        let denBox = build(den, o.with(style: o.style.fracDen(),
                                       cramped: true))
        let ruleMin = max(o.k(.fractionRuleThickness), o.size * 0.04)
        let thickness = rule ? ruleMin : 0
        let axis = o.axis

        var up = display ? o.k(.fractionNumeratorDisplayStyleShiftUp)
                         : o.k(.fractionNumeratorShiftUp)
        var down = display ? o.k(.fractionDenominatorDisplayStyleShiftDown)
                           : o.k(.fractionDenominatorShiftDown)

        if rule {
            let gapNum = display ? o.k(.fractionNumDisplayStyleGapMin)
                                 : o.k(.fractionNumeratorGapMin)
            let gapDen = display ? o.k(.fractionDenomDisplayStyleGapMin)
                                 : o.k(.fractionDenominatorGapMin)
            up = max(up, axis + thickness / 2 + gapNum + numBox.depth)
            down = max(down, -axis + thickness / 2 + gapDen + denBox.height)
        } else {
            let gap = display ? o.k(.stackDisplayStyleGapMin)
                              : o.k(.stackGapMin)
            let clearance = (up - numBox.depth) - (denBox.height - down)
            if clearance < gap {
                let extra = (gap - clearance) / 2
                up += extra; down += extra
            }
        }

        let width = max(numBox.width, denBox.width)
        var items: [(box: Box, dx: CGFloat, dy: CGFloat)] = [
            (numBox, (width - numBox.width) / 2, up),
            (denBox, (width - denBox.width) / 2, -down),
        ]
        if rule {
            let bar = Box.rule(width: width, height: thickness / 2,
                               depth: thickness / 2)
            items.append((bar, 0, axis))
        }
        var body = Box.place(items)
        body.width = width

        if left != nil || right != nil {
            let l = delimiter(left ?? 0, height: body.height,
                              depth: body.depth, o)
            let r = delimiter(right ?? 0, height: body.height,
                              depth: body.depth, o)
            body = Box.hbox([l, body, r])
        } else {
            body = Box.hbox([Box.kern(o.mu * 3), body, Box.kern(o.mu * 3)])
        }
        return body
    }


    func leftRightBox(_ l: UInt32, _ r: UInt32, _ body: [Node],
                      _ o: Opts) -> Box {
        let inner = build(body, o)
        let lb = delimiter(l, height: inner.height, depth: inner.depth, o)
        let rb = delimiter(r, height: inner.height, depth: inner.depth, o)
        return Box.hbox([lb, inner, rb])
    }


    // Four steps, each of which used to be a paragraph of this one
    // function: typeset the cells, measure the columns, pack each row to
    // those widths, stack the rows on the maths axis. Fences last.

    func arrayBox(_ rows: [[[Node]]], _ gaps: [CGFloat],
                  _ style: Node.ArrayStyle, _ o: Opts) -> Box {
        let cells = arrayCells(rows, style, o)
        let widths = columnWidths(cells)
        let gap = columnGap(style, o)
        let rowBoxes = cells.map { row in
            arrayRow(row, widths: widths, style: style, gap: gap)
        }
        return fenced(stackRows(rowBoxes, gaps, style, o), style, o)
    }

    private func arrayCells(_ rows: [[[Node]]], _ style: Node.ArrayStyle,
                            _ o: Opts) -> [[Box]] {
        rows.map { row in
            row.enumerated().map { (c, cell) -> Box in
                let box = build(cell, o)
                // amsmath's `&=` template: a column that opens with a
                // relation keeps the thick space it would have had
                // mid-list.
                var result = box
                if style.isAligned, c % 2 == 1,
                   case .symbol(_, .rel, _)? = cell.first {
                    result = Box.hbox([Box.kern(5 * o.mu), box])
                }
                return result
            }
        }
    }

    private func columnWidths(_ cells: [[Box]]) -> [CGFloat] {
        let count = cells.map(\.count).max() ?? 0
        var widths = [CGFloat](repeating: 0, count: max(count, 1))
        for row in cells {
            for (c, b) in row.enumerated() {
                widths[c] = max(widths[c], b.width)
            }
        }
        return widths
    }

    private func columnGap(_ style: Node.ArrayStyle,
                           _ o: Opts) -> CGFloat {
        var result: CGFloat = 0
        switch style {
            case .substack, .gathered: result = 0
            case .aligned: result = o.size
            case .matrix: result = o.size * 0.8
        }
        return result
    }

    // In an `aligned` the even columns are pushed right so the relation
    // that opens the odd column lines up down the block, and the pair
    // itself is not separated. Everywhere else a column is centred.

    private func arrayRow(_ row: [Box], widths: [CGFloat],
                          style: Node.ArrayStyle, gap: CGFloat) -> Box {
        var parts: [Box] = []
        for (c, b) in row.enumerated() {
            let slack = widths[c] - b.width
            if style.centresColumns {
                parts.append(Box.kern(slack / 2))
                parts.append(b)
                parts.append(Box.kern(slack / 2))
            } else if c % 2 == 0 {
                parts.append(Box.kern(slack))
                parts.append(b)
            } else {
                parts.append(b)
                parts.append(Box.kern(slack))
            }
            if c + 1 < row.count {
                let interior = style.isAligned && c % 2 == 0
                parts.append(Box.kern(interior ? 0 : gap))
            }
        }
        return Box.hbox(parts)
    }

    private func stackRows(_ rowBoxes: [Box], _ gaps: [CGFloat],
                           _ style: Node.ArrayStyle, _ o: Opts) -> Box {
        let lineSkip = o.size * (style.isSubstack ? 0.18 : 0.35)
        let minSkip = o.size * (style.isSubstack ? 1.0 : 1.2)
        var items: [(box: Box, dx: CGFloat, dy: CGFloat)] = []
        var y: CGFloat = 0
        var totalWidth: CGFloat = 0
        for (idx, rb) in rowBoxes.enumerated() {
            if idx > 0 {
                let extra = idx - 1 < gaps.count ? gaps[idx - 1] : 0
                let need = rowBoxes[idx - 1].depth + rb.height
                         + lineSkip + extra
                y -= max(minSkip + extra, need)
            }
            items.append((rb, 0, y))
            totalWidth = max(totalWidth, rb.width)
        }
        let stack = Box.place(items)
        // Centre the whole stack on the maths axis.
        let mid = (stack.height - stack.depth) / 2
        let centred = Box.place(items.map { i in
            (i.box, i.dx, i.dy + o.axis - mid)
        })
        centred.width = totalWidth
        return centred
    }

    private func fenced(_ box: Box, _ style: Node.ArrayStyle,
                        _ o: Opts) -> Box {
        var result = box
        if case .matrix(let l, let r) = style, l != nil || r != nil {
            let lb = delimiter(l ?? 0, height: box.height,
                               depth: box.depth, o)
            let rb = delimiter(r ?? 0, height: box.height,
                               depth: box.depth, o)
            result = Box.hbox([lb, Box.kern(o.size * 0.15), box,
                               Box.kern(o.size * 0.15), rb])
        }
        return result
    }
}

public struct MathLayout {
    public let width: CGFloat
    public let ascent: CGFloat
    public let descent: CGFloat
    public var height: CGFloat { ascent + descent }
    public var size: CGSize { CGSize(width: width, height: height) }
    /// Horizontal offset of the formula body (non-zero when a `\tag`
    /// sits on the left).
    public let bodyOrigin: CGFloat

    let box: Box
    let font: MathFontFile
    let color: CGColor

    /// Draw with `at` as the top-left corner of the layout's bounding box.
    /// Set `flipped` for contexts whose y axis points down (UIKit,
    /// SwiftUI `Canvas`). `color` overrides the one the layout was built
    /// with, so a theme switch redraws rather than re-lays out: the
    /// boxes do not depend on the ink.
    public func draw(in ctx: CGContext, at point: CGPoint,
                     color ink: CGColor? = nil, flipped: Bool = false) {
        ctx.saveGState()
        let savedText = ctx.textMatrix
        ctx.setFillColor(ink ?? color)
        if flipped {
            // The scale below already turns the context y-up, so the
            // text matrix must stay identity: flipping it as well
            // mirrors every glyph about its own baseline. Same matrix
            // as the branch beneath, which is the one the PDF proves.
            ctx.translateBy(x: point.x, y: point.y + ascent)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = .identity
        } else {
            ctx.translateBy(x: point.x, y: point.y - ascent)
            ctx.textMatrix = .identity
        }
        box.render(in: ctx, x: 0, y: 0, font: font)
        ctx.textMatrix = savedText
        ctx.restoreGState()
    }

    /// Draw with `origin` on the baseline, at the left edge.
    public func draw(in ctx: CGContext, baseline origin: CGPoint,
                     color ink: CGColor? = nil, flipped: Bool = false) {
        let y = flipped ? origin.y - ascent : origin.y + ascent
        draw(in: ctx, at: CGPoint(x: origin.x, y: y),
             color: ink, flipped: flipped)
    }

    public func cgImage(scale: CGFloat = 2, padding: CGFloat = 8,
                        background: CGColor? = nil,
                        color ink: CGColor? = nil) -> CGImage? {
        var result: CGImage? = nil
        let w = Int(((width + padding * 2) * scale).rounded(.up))
        let h = Int(((height + padding * 2) * scale).rounded(.up))
        if w > 0, h > 0,
           let ctx = CGContext(
               data: nil, width: w, height: h, bitsPerComponent: 8,
               bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            if let bg = background {
                ctx.setFillColor(bg)
                ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w),
                                height: CGFloat(h)))
            }
            ctx.scaleBy(x: scale, y: scale)
            draw(in: ctx, at: CGPoint(x: padding, y: height + padding),
                 color: ink)
            result = ctx.makeImage()
        }
        return result
    }
}


public enum KaTeX {

    /// Parse and lay out a TeX fragment.
    public static func layout(
        _ tex: String, settings: MathSettings = MathSettings()
    ) throws -> MathLayout {
        MathFontFile.lock.lock()
        defer { MathFontFile.lock.unlock() }
        let font = try MathFontFile.shared()
        let nodes = try Parser.parse(tex)
        let layouter = Layouter(font: font)
        let opts = Opts(font: font,
                        style: settings.displayMode ? .display : .text,
                        cramped: false,
                        variant: .italic,
                        base: settings.fontSize)
        let body = layouter.build(nodes, opts)

        var final = body
        var bodyOrigin: CGFloat = 0
        if let tag = layouter.tagBox {
            let gap = settings.tagGap
            switch settings.tagSide {
            case .right:
                let natural = body.width + gap + tag.width
                let total = settings.tagColumnWidth ?? natural
                let pad = max(gap, total - body.width - tag.width)
                final = Box.hbox([body, Box.kern(pad), tag])
            case .left:
                bodyOrigin = tag.width + gap
                final = Box.hbox([tag, Box.kern(gap), body])
            }
        }

        return MathLayout(width: final.width,
                          ascent: final.height,
                          descent: final.depth,
                          bodyOrigin: bodyOrigin,
                          box: final,
                          font: font,
                          color: settings.color)
    }

    /// Convenience: lay out and rasterize in one call.
    public static func cgImage(
        _ tex: String, settings: MathSettings = MathSettings(),
        scale: CGFloat = 2, padding: CGFloat = 8,
        background: CGColor? = nil
    ) throws -> CGImage? {
        try layout(tex, settings: settings).cgImage(scale: scale,
                                                    padding: padding,
                                                    background: background)
    }

    /// Measure only.
    public static func measure(
        _ tex: String, settings: MathSettings = MathSettings()
    ) throws -> CGSize {
        try layout(tex, settings: settings).size
    }
}
