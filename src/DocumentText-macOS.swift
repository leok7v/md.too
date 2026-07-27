import Foundation
import AppKit

extension DocumentText {

    static func table(headers: [String], rows: [[String]],
                      images: [URL: DocumentImage]) -> NSAttributedString {
        let m = NSMutableAttributedString()
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        if cols > 0 {
            let atomicId = UUID().uuidString
            let textTable = NSTextTable()
            textTable.numberOfColumns = cols
            textTable.layoutAlgorithm = .fixedLayoutAlgorithm
            let shares = TableMetrics.pointWidths(headers: headers,
                                                  rows: rows,
                                                  available: 100)
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
            block.setWidth(6, type: .absoluteValueType, for: .padding)
            block.backgroundColor = tint
            let para = NSMutableParagraphStyle()
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
