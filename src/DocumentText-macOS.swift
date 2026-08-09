import Foundation
import AppKit

extension DocumentText {

    // Horizontal cell padding, as a percentage of the table width so it
    // can be subtracted from the column-share budget in the same unit.
    private static var cellPad: CGFloat { 0.6 }

    // Solved against the SHARES the table will actually be built with,
    // not against the bare sum of the minimums. A column's share is a
    // fixed fraction of the table width, so the width at which column c
    // finally holds its widest token is min[c] / share[c], and the table
    // needs the largest of those. Summing the minimums instead answers a
    // question nobody asked -- the shares are weighted by character
    // count, so the sum can be reached with a column still starved.

    static func tableMinimumWidth(headers: [String],
                                  rows: [[String]]) -> CGFloat {
        var result: CGFloat = 0
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        if cols > 0 {
            let mins = columnMinimums(headers: headers, rows: rows,
                                      cols: cols)
            let fractions = TableMetrics.pointWidths(
                headers: headers, rows: rows,
                available: contentBudget(cols: cols) / 100)
            for c in 0..<cols where c < fractions.count
                                    && fractions[c] > 0 {
                let need = mins[c] / fractions[c]
                if need > result { result = need }
            }
            result = ceil(result)
        }
        return result
    }

    private static func contentBudget(cols: Int) -> CGFloat {
        max(100 - CGFloat(cols) * cellPad * 2, 50)
    }

    static func table(headers: [String], rows: [[String]],
                      images: [URL: DocumentImage]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        if cols > 0 {
            let atomicId = UUID().uuidString
            let textTable = NSTextTable()
            textTable.numberOfColumns = cols
            // Automatic, not fixed: fixed layout is CSS table-layout:
            // fixed, where a cell whose content outgrows its declared
            // width spills OVER the next column instead of widening --
            // headers printed on top of each other. The column shares
            // below are weighted by character count and cannot know the
            // rendered size, so any font the widths were not computed
            // for (a zoom step, a narrow window) overflowed them.
            textTable.layoutAlgorithm = .automaticLayoutAlgorithm
            // The shares have to leave room for the padding, or the
            // table demands 100% plus cellPad * 2 * cols and the last
            // columns are squeezed off the edge. Percentage padding
            // keeps that arithmetic in one unit.
            let budget = contentBudget(cols: cols)
            let shares = TableMetrics.pointWidths(headers: headers,
                                                  rows: rows,
                                                  available: budget)
            var rowIdx = 0
            if !headers.isEmpty {
                m.append(tableRow(cells: headers, table: textTable,
                                  rowIdx: rowIdx, cols: cols,
                                  shares: shares,
                                  bold: true,
                                  tint: platformWhite(0.5, alpha: 0.14),
                                  atomicId: atomicId,
                                  images: images))
                rowIdx += 1
            }
            for (idx, row) in rows.enumerated() {
                let tint: PlatformColor = idx % 2 == 1
                    ? platformWhite(0.5, alpha: 0.07) : platformClearColor
                m.append(tableRow(cells: row, table: textTable,
                                  rowIdx: rowIdx, cols: cols,
                                  shares: shares,
                                  bold: false, tint: tint,
                                  atomicId: atomicId,
                                  images: images))
                rowIdx += 1
            }
            // One contiguous atomic kind / id / copy over the whole table
            // (cells plus the separators, which carry none per-cell) so
            // selection-snap sees one unit and the copy overlay yields ONE
            // button. Stamped before the trailing newline so a drag past
            // the table stops at the table edge.
            let content = NSRange(location: 0, length: m.length)
            m.addAttribute(atomicKindKey,
                           value: AtomicKind.table.rawValue, range: content)
            m.addAttribute(atomicIdKey, value: atomicId, range: content)
            m.addAttribute(atomicCopyKey,
                           value: TableMetrics.serializeMonospaced(
                               headers: headers, rows: rows),
                           range: content)
            m.append(NSAttributedString(string: "\n"))
        }
        return m
    }

    private static func tableRow(cells: [String],
                                 table: NSTextTable,
                                 rowIdx: Int, cols: Int,
                                 shares: [CGFloat],
                                 bold: Bool,
                                 tint: PlatformColor,
                                 atomicId: String,
                                 images: [URL: DocumentImage])
        -> NSAttributedString {
        let m = NSMutableAttributedString()
        let base = bold ? boldFont(of: FontRole.body.platformFont) : FontRole.body.platformFont
        for col in 0..<cols {
            let cellText = col < cells.count ? cells[col] : ""
            let block = NSTextTableBlock(table: table,
                                         startingRow: rowIdx, rowSpan: 1,
                                         startingColumn: col,
                                         columnSpan: 1)
            if col < shares.count {
                block.setValue(shares[col],
                               type: .percentageValueType,
                               for: .width)
            }
            block.setWidth(cellPad, type: .percentageValueType,
                           for: .padding, edge: .minX)
            block.setWidth(cellPad, type: .percentageValueType,
                           for: .padding, edge: .maxX)
            block.setWidth(3, type: .absoluteValueType,
                           for: .padding, edge: .minY)
            block.setWidth(3, type: .absoluteValueType,
                           for: .padding, edge: .maxY)
            block.backgroundColor = tint
            let para = NSMutableParagraphStyle()
            // Word wrapping is safe here only because the view refuses
            // to be narrower than tableMinimumWidth: NSTextTable cannot
            // lay out a row holding a token wider than its column -- it
            // widens that column, gives up on the rest, and stacks every
            // remaining cell at the widened column's origin, so the row
            // reads as overlapping glyphs. No column-width spelling
            // avoids it (percentage, absolute, none at all, fixed
            // algorithm, minimumWidth -- all collapse alike); only never
            // posing the question does.
            para.lineBreakMode = .byWordWrapping
            para.textBlocks = [block]
            let cellAttr = NSMutableAttributedString(
                attributedString: tableCell(cellText, base: base,
                                            images: images))
            if cellAttr.length == 0 {
                cellAttr.append(NSAttributedString(
                    string: "\u{00A0}",
                    attributes: [.font: base,
                                 .foregroundColor: platformDefaultTextColor]))
            }
            let full = NSRange(location: 0, length: cellAttr.length)
            cellAttr.addAttribute(.paragraphStyle, value: para,
                                  range: full)
            cellAttr.addAttribute(atomicKindKey,
                                  value: AtomicKind.table.rawValue,
                                  range: full)
            cellAttr.addAttribute(atomicIdKey, value: atomicId,
                                  range: full)
            m.append(cellAttr)
            m.append(NSAttributedString(string: "\n"))
        }
        return m
    }

}
