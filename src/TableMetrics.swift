import Foundation

enum TableMetrics {

    static func columnCount(headers: [String], rows: [[String]]) -> Int {
        var n = headers.count
        for row in rows where row.count > n { n = row.count }
        return n
    }

    // Counted on the cell a reader will SEE, not the one that was typed:
    // "m<sup>2</sup>" is two characters wide, and weighting a column by
    // thirteen hands it a share the text never fills.

    static func charWidths(headers: [String], rows: [[String]]) -> [Int] {
        let n = columnCount(headers: headers, rows: rows)
        var widths = [Int](repeating: 3, count: n)
        var all = rows
        all.insert(headers, at: 0)
        for cells in all {
            for (i, cell) in cells.enumerated() where i < n {
                let count = TeX.scriptsToUnicode(cell).count
                if count > widths[i] { widths[i] = count }
            }
        }
        return widths
    }

    static func pointWidths(headers: [String], rows: [[String]],
                            available: CGFloat,
                            minimums: [CGFloat]? = nil) -> [CGFloat] {
        let n = columnCount(headers: headers, rows: rows)
        var result = [CGFloat](repeating: 0, count: n)
        let chars = charWidths(headers: headers, rows: rows)
        let weights = chars.map { c in sqrt(CGFloat(c)) }
        let sum = weights.reduce(0, +)
        if available > 0, n > 0 {
            if let mins = minimums, mins.count == n {
                let minSum = mins.reduce(0, +)
                if minSum >= available, minSum > 0 {
                    result = fairWidths(minimums: mins, weights: weights,
                                        available: available)
                } else if sum > 0 {
                    let remainder = available - minSum
                    result = (0..<n).map { i in
                        mins[i] + remainder * weights[i] / sum
                    }
                } else {
                    result = mins
                }
            } else if sum > 0 {
                result = weights.map { wt in available * wt / sum }
            }
        }
        return result
    }

    // Shared shortfall, not shared percentage. When the minimums do not
    // fit, every column that CAN be satisfied is -- smallest demand
    // first -- and what is left over goes to the columns that cannot be,
    // split by weight. Scaling all of them by one factor instead takes
    // the same third from a column holding "52.3", which then breaks a
    // number across three lines, as from one holding a heading that had
    // a word boundary to give away for free.

    private static func fairWidths(minimums: [CGFloat],
                                   weights: [CGFloat],
                                   available: CGFloat) -> [CGFloat] {
        let n = minimums.count
        var result = [CGFloat](repeating: 0, count: n)
        var settled = [Bool](repeating: false, count: n)
        var remaining = available
        var settling = true
        while settling {
            var pending: CGFloat = 0
            for c in 0..<n where !settled[c] { pending += weights[c] }
            var grants: [Int] = []
            for c in 0..<n where !settled[c] && pending > 0 {
                if minimums[c] <= remaining * weights[c] / pending {
                    grants.append(c)
                }
            }
            for c in grants {
                result[c] = minimums[c]
                settled[c] = true
                remaining -= minimums[c]
            }
            settling = !grants.isEmpty
        }
        var short: CGFloat = 0
        for c in 0..<n where !settled[c] { short += weights[c] }
        for c in 0..<n where !settled[c] {
            result[c] = short > 0 ? remaining * weights[c] / short
                                  : remaining / CGFloat(n)
        }
        return result
    }

    // The widths a table draws its columns at: every column its natural
    // width when the row of naturals fits, otherwise the weighted shares
    // floored at the minimums and capped at the naturals, with the slack
    // a column did not want handed to the ones still short of theirs.
    // The minimums alone when even they do not fit: a column narrower
    // than its longest run cannot wrap down to it, and the caller lets
    // the table overflow rather than the cells overlap.

    static func columnLayout(headers: [String], rows: [[String]],
                             naturals: [CGFloat], minimums: [CGFloat],
                             available: CGFloat) -> [CGFloat] {
        var result = naturals
        if minimums.reduce(0, +) > available {
            result = minimums
        } else if naturals.reduce(0, +) > available {
            let shared = pointWidths(headers: headers, rows: rows,
                                     available: available,
                                     minimums: minimums)
            result = capped(shared, naturals)
        }
        return result
    }

    private static func capped(_ widths: [CGFloat],
                               _ naturals: [CGFloat]) -> [CGFloat] {
        var out = widths
        let want = (0..<out.count).map { c in max(naturals[c] - out[c], 0) }
        let short = want.reduce(0, +)
        var slack: CGFloat = 0
        for c in 0..<out.count where out[c] > naturals[c] {
            slack += out[c] - naturals[c]
            out[c] = naturals[c]
        }
        let give = min(slack, short)
        if short > 0 {
            for c in 0..<out.count { out[c] += give * want[c] / short }
        }
        return out
    }

    // Where a cell's text can break: at a space, a hard break, and after
    // a hyphen, slash or dash that sits between words. "-0.614" stays
    // one run, so a column sized as though the number could split never
    // renders it as "-0.61" over "4".

    static func unbreakableRuns(_ text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = 0
        for i in 0..<text.length {
            let c = text.character(at: i)
            let next = i + 1 < text.length ? text.character(at: i + 1) : 0
            let space = c == 0x20 || c == 0x09 || c == 0x0A || c == 0x2028
            let soft = [0x2D, 0x2F, 0x2013, 0x2014].contains(c) &&
                       !(0x30...0x39).contains(next)
            if space || soft {
                let end = space ? i : i + 1
                if end > start {
                    out.append(NSRange(location: start, length: end - start))
                }
                start = i + 1
            }
        }
        if text.length > start {
            out.append(NSRange(location: start, length: text.length - start))
        }
        return out
    }

    // The widest line of a cell, and its widest unbreakable run, both in
    // the face the cell draws in.

    static func naturalWidth(_ text: String, font: PlatformFont) -> CGFloat {
        var widest: CGFloat = 0
        for line in text.split(separator: "\u{2028}",
                               omittingEmptySubsequences: false) {
            let w = (String(line) as NSString)
                .size(withAttributes: [.font: font]).width
            if w > widest { widest = w }
        }
        return widest
    }

    static func minimumWidth(_ text: String, font: PlatformFont) -> CGFloat {
        let ns = text as NSString
        var widest: CGFloat = 0
        for run in unbreakableRuns(ns) {
            let w = ns.substring(with: run)
                .size(withAttributes: [.font: font]).width
            if w > widest { widest = w }
        }
        return widest
    }

    static func normalize(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        var out = ""
        var inSpace = false
        for ch in trimmed {
            if ch.isWhitespace {
                if !inSpace { out.append(" ") }
                inSpace = true
            } else {
                out.append(ch)
                inSpace = false
            }
        }
        return out
    }

    static func longestWord(headers: [String], rows: [[String]],
                                col: Int) -> String {
        var best = ""
        var column: [String] = []
        if col < headers.count { column.append(headers[col]) }
        for row in rows where col < row.count {
            column.append(row[col])
        }
        for cell in column {
            let visible = TeX.scriptsToUnicode(cell)
            for word in visible.split(separator: " ",
                                      omittingEmptySubsequences: true) {
                if word.count > best.count { best = String(word) }
            }
        }
        return best
    }

    static func serializeMonospaced(headers: [String],
                                    rows: [[String]],
                                    alignments: [Alignment] = []) -> String {
        let n = columnCount(headers: headers, rows: rows)
        // Converted once, up front: the padding is computed from the same
        // strings that get printed, so the columns still line up. A pipe
        // inside a cell goes back out escaped, or it reads as a divider.
        let h = headers.map { c in pipesEscaped(TeX.scriptsToUnicode(c)) }
        let r = rows.map { row in
            row.map { c in pipesEscaped(TeX.scriptsToUnicode(c)) }
        }
        let widths = charWidths(headers: h, rows: r)
        var lines: [String] = []
        if !h.isEmpty {
            lines.append(monoRow(h, n: n, widths: widths))
            let dashes = (0..<n).map { i in
                delimiter(width: widths[i],
                          alignment: i < alignments.count
                              ? alignments[i] : .none)
            }
            lines.append("| " + dashes.joined(separator: " | ") + " |")
        }
        for row in r {
            lines.append(monoRow(row, n: n, widths: widths))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // The delimiter cell spells the column's alignment with its colons,
    // so the serialisation parses back to the same table.

    private static func delimiter(width: Int,
                                  alignment: Alignment) -> String {
        let inner = String(repeating: "-", count: max(width - 2, 1))
        let result: String
        switch alignment {
            case .none: result = String(repeating: "-", count: max(width, 3))
            case .left: result = ":" + inner + "-"
            case .right: result = "-" + inner + ":"
            case .center: result = ":" + inner + ":"
        }
        return result
    }

    // A pipe inside a cell goes back out escaped and a hard break as the
    // tag it came from, so the copy parses to the cell it was.
    private static func pipesEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "|", with: "\\|")
         .replacingOccurrences(of: "\u{2028}", with: "<br>")
    }

    private static func monoRow(_ cells: [String], n: Int,
                                widths: [Int]) -> String {
        var parts: [String] = []
        for i in 0..<n {
            let cell = i < cells.count ? cells[i] : ""
            let fill = max(0, widths[i] - cell.count)
            parts.append(cell + String(repeating: " ", count: fill))
        }
        return "| " + parts.joined(separator: " | ") + " |"
    }

}
