import Foundation

enum TableMetrics {

    static func columnCount(headers: [String], rows: [[String]]) -> Int {
        var n = headers.count
        for row in rows where row.count > n { n = row.count }
        return n
    }

    static func charWidths(headers: [String], rows: [[String]]) -> [Int] {
        let n = columnCount(headers: headers, rows: rows)
        var widths = [Int](repeating: 1, count: n)
        var all = rows
        all.insert(headers, at: 0)
        for cells in all {
            for (i, cell) in cells.enumerated() where i < n {
                if cell.count > widths[i] { widths[i] = cell.count }
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
                    let scale = available / minSum
                    result = mins.map { v in v * scale }
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
            for word in cell.split(separator: " ",
                                   omittingEmptySubsequences: true) {
                if word.count > best.count { best = String(word) }
            }
        }
        return best
    }

    static func serializeMonospaced(headers: [String],
                                       rows: [[String]]) -> String {
        let n = columnCount(headers: headers, rows: rows)
        let widths = charWidths(headers: headers, rows: rows)
        var lines: [String] = []
        if !headers.isEmpty {
            lines.append(monoRow(headers, n: n, widths: widths))
            let dashes = (0..<n).map { i in
                String(repeating: "-", count: widths[i])
            }
            lines.append("| " + dashes.joined(separator: " | ") + " |")
        }
        for row in rows {
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
