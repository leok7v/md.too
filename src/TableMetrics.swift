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
        var widths = [Int](repeating: 1, count: n)
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
                                       rows: [[String]]) -> String {
        let n = columnCount(headers: headers, rows: rows)
        // Converted once, up front: the padding is computed from the same
        // strings that get printed, so the columns still line up.
        let h = headers.map { c in TeX.scriptsToUnicode(c) }
        let r = rows.map { row in row.map { c in TeX.scriptsToUnicode(c) } }
        let widths = charWidths(headers: h, rows: r)
        var lines: [String] = []
        if !h.isEmpty {
            lines.append(monoRow(h, n: n, widths: widths))
            let dashes = (0..<n).map { i in
                String(repeating: "-", count: widths[i])
            }
            lines.append("| " + dashes.joined(separator: " | ") + " |")
        }
        for row in r {
            lines.append(monoRow(row, n: n, widths: widths))
        }
        return lines.joined(separator: "\n") + "\n"
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
