import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct BlockView: View {

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
            case .quote(let blocks):
                HStack(alignment: .top, spacing: 8) {
                    Rectangle().fill(Color.secondary.opacity(0.5))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(blocks.enumerated()),
                                id: \.offset) { _, b in
                            BlockView(block: b)
                        }
                    }
                    .environment(\.secondaryText, true)
                }
            case .list(let items, let tight):
                ListBlock(items: items, tight: tight)
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
        // !Task.isCancelled in the guard: when SwiftUI cancels the
        // .task(id:) on view destruction or URL change, the in-flight
        // URLSession + Task.sleep both throw CancellationError; the
        // try? swallows it but without this check the loop would still
        // run one more wasted iteration before attempt < 2 falsifies.
        while attempt < 2, !done, !Task.isCancelled {
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
    let tight: Bool

    var body: some View {
        let gap: CGFloat = tight ? 3 : 9
        VStack(alignment: .leading, spacing: gap) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    marker(item)
                        .frame(width: gutterWidth, alignment: .trailing)
                    VStack(alignment: .leading, spacing: gap) {
                        ForEach(Array(item.blocks.enumerated()),
                                id: \.offset) { _, b in
                            BlockView(block: b)
                        }
                    }
                }
            }
        }
    }

    // Every row shares one gutter width (the widest marker in this
    // list) so the content column never shifts row-to-row. Each nested
    // list adds its own gutter, so depth indents consistently.
    private var gutterWidth: CGFloat {
        let widest = items.map { item in
            item.checked == nil ? item.marker.count : 1
        }.max() ?? 1
        return CGFloat(widest) * 10 + 8
    }

    @ViewBuilder
    private func marker(_ item: ListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor
                                         : Color.secondary)
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

enum TableMetrics {

    static func columnCount(headers: [String], rows: [[String]]) -> Int {
        var n = headers.count
        for row in rows where row.count > n { n = row.count }
        return n
    }

    // Max content width per column in characters (raw max, >= 1). This is
    // the true width for monospaced / ASCII export and the shared basis
    // for on-screen and PDF point widths, so the renderers agree.
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

    // Per-column point widths for a given available width. Weights are
    // sqrt(charWidth) so wide columns don't starve narrow ones; the
    // result sums to `available`. Shared by on-screen and PDF so the
    // two renderers proportion columns the same way.
    static func pointWidths(headers: [String], rows: [[String]],
                            available: CGFloat) -> [CGFloat] {
        let n = columnCount(headers: headers, rows: rows)
        var result = [CGFloat](repeating: 0, count: n)
        let chars = charWidths(headers: headers, rows: rows)
        let weights = chars.map { c in sqrt(CGFloat(c)) }
        let sum = weights.reduce(0, +)
        if sum > 0, available > 0 {
            result = weights.map { wt in available * wt / sum }
        }
        return result
    }

    // Width-aligned ASCII table for the copy payload and text export.
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

private struct TableWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct TableBlock: View {

    let headers: [String]
    let rows: [[String]]
    @State private var available: CGFloat = 0

    var body: some View {
        let n = TableMetrics.columnCount(headers: headers, rows: rows)
        let widths = pointWidths(n)
        let fitWidth: CGFloat? = widths == nil ? nil : max(0, available - 16)
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if !headers.isEmpty {
                    // Header gets a slightly stronger band than the
                    // zebra so it reads as a header in both themes,
                    // not just the same shade as the first data row.
                    rowView(headers, bold: true,
                            shade: Color.primary.opacity(0.07),
                            n: n, widths: widths)
                    Divider()
                }
                ForEach(Array(rows.enumerated()),
                        id: \.offset) { idx, r in
                    rowView(r, bold: false,
                            shade: idx % 2 == 1
                                ? Color.primary.opacity(0.04)
                                : Color.clear,
                            n: n, widths: widths)
                }
            }
            .padding(8)
            .frame(width: fitWidth, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: TableWidthKey.self,
                                       value: proxy.size.width)
            }
        )
        .onPreferenceChange(TableWidthKey.self) { w in
            if w > 0, w != available { available = w }
        }
        .overlay(alignment: .topTrailing) {
            CopyButton(string:
                TableMetrics.serializeMonospaced(headers: headers,
                                                 rows: rows))
                .padding(6)
        }
    }

    // Distribute the measured viewport across columns, sqrt-dampened by
    // content length so wide columns don't starve narrow ones. nil means
    // the table can't fit the viewport, so cells render at natural width
    // inside the horizontal scroll instead.
    private func pointWidths(_ n: Int) -> [CGFloat]? {
        var result: [CGFloat]? = nil
        let usable = available - CGFloat(max(n - 1, 0)) * 12 - 16
        let minWidth = 48 * CGFloat(n)
        if available > 0, usable >= minWidth {
            let widths = TableMetrics.pointWidths(headers: headers,
                                                  rows: rows,
                                                  available: usable)
            if !widths.isEmpty { result = widths }
        }
        return result
    }

    private func rowView(_ cells: [String], bold: Bool, shade: Color,
                         n: Int, widths: [CGFloat]?) -> some View {
        let fill: CGFloat? = widths == nil ? nil : .infinity
        return HStack(alignment: .top, spacing: 12) {
            ForEach(Array(0..<n), id: \.self) { i in
                let text = i < cells.count ? cells[i] : ""
                cell(text, bold: bold, width: widths?[i])
            }
        }
        .frame(maxWidth: fill, alignment: .leading)
        .padding(.vertical, 4)
        .background(shade)
    }

    @ViewBuilder
    private func cell(_ text: String, bold: Bool,
                      width: CGFloat?) -> some View {
        let parsed = Markdown.parse(text)
        if let first = parsed.first,
           case .image(let alt, let url, let w, let h) = first {
            ImageBlockView(alt: alt, url: url, width: w, height: h)
                .frame(width: width, alignment: .leading)
        } else if let width {
            SelectableText(attributed: cellAttributed(text, parsed: parsed),
                                 role: .body, bold: bold)
                .frame(width: width, alignment: .leading)
        } else {
            SelectableText(attributed: cellAttributed(text, parsed: parsed),
                                 role: .body, nowrap: true, bold: bold)
                .fixedSize(horizontal: true, vertical: false)
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
