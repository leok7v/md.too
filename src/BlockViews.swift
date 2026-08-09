import SwiftUI

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
        while attempt < 2, !done, !Task.isCancelled {
            do {
                let (data, response) =
                    try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse,
                   !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let decoded = platformDecodeImage(data)
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
        let h = headers.map { s in TableMetrics.normalize(s) }
        let r = rows.map { row in
            row.map { s in TableMetrics.normalize(s) }
        }
        let n = TableMetrics.columnCount(headers: h, rows: r)
        let layout = columnLayout(n, headers: h, rows: r)
        let fitWidth: CGFloat? = layout.constrained
            ? max(0, available - 16) : nil
        ScrollView(.horizontal, showsIndicators: !layout.constrained) {
            VStack(alignment: .leading, spacing: 0) {
                if !h.isEmpty {
                    rowView(h, bold: true,
                            shade: Color.primary.opacity(0.07),
                            n: n, widths: layout.widths, wrap: layout.wrap,
                            constrained: layout.constrained)
                    Divider()
                }
                ForEach(Array(r.enumerated()), id: \.offset) { idx, row in
                    rowView(row, bold: false,
                            shade: idx % 2 == 1
                                ? Color.primary.opacity(0.04)
                                : Color.clear,
                            n: n, widths: layout.widths, wrap: layout.wrap,
                            constrained: layout.constrained)
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
                TableMetrics.serializeMonospaced(headers: h, rows: r))
                .padding(6)
        }
    }

    // Three outcomes, not two. A column narrower than its longest word
    // cannot wrap down to fit, so the text spills over its neighbour --
    // SwiftUI clips nothing by default and the row reads as a pile of
    // overlapping glyphs. Past that floor the table stops being asked to
    // fit at all: it takes its minimum and the surrounding horizontal
    // ScrollView, which is already here for the natural-width case,
    // carries what does not show.

    private func columnLayout(_ n: Int,
                              headers h: [String],
                              rows r: [[String]])
        -> (widths: [CGFloat]?, wrap: Bool, constrained: Bool) {
        var result: ([CGFloat]?, Bool, Bool) = (nil, false, false)
        let usable = available - CGFloat(max(n - 1, 0)) * 12 - 16
        if available > 0, n > 0 {
            let natural = naturalColumnWidths(n, headers: h, rows: r)
            let mins = minimumColumnWidths(n, headers: h, rows: r)
            if natural.reduce(0, +) <= usable {
                result = (natural, false, false)
            } else if mins.reduce(0, +) > usable {
                result = (mins, true, false)
            } else {
                let widths = TableMetrics.pointWidths(headers: h,
                                                      rows: r,
                                                      available: usable,
                                                      minimums: mins)
                if !widths.isEmpty {
                    result = (widths, true, true)
                }
            }
        }
        return result
    }

    private func minimumColumnWidths(_ n: Int,
                                     headers h: [String],
                                     rows r: [[String]]) -> [CGFloat] {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: FontRole.body.platformFont
        ]
        var widths = [CGFloat](repeating: 0, count: n)
        for c in 0..<n {
            let word = TableMetrics.longestWord(headers: h,
                                                rows: r, col: c)
            let w = (word as NSString).size(withAttributes: attrs).width
            widths[c] = ceil(w) + 4
        }
        return widths
    }

    private func naturalColumnWidths(_ n: Int,
                                     headers h: [String],
                                     rows r: [[String]]) -> [CGFloat] {
        let body = FontRole.body.platformFont
        let bold = boldFont(of: body)
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: body]
        let boldAttrs: [NSAttributedString.Key: Any] = [.font: bold]
        var widths = [CGFloat](repeating: 0, count: n)
        for c in 0..<n {
            var maxW: CGFloat = 0
            if c < h.count {
                let s = (TeX.scriptsToUnicode(h[c]) as NSString)
                    .size(withAttributes: boldAttrs).width
                if s > maxW { maxW = s }
            }
            for row in r where c < row.count {
                let s = (TeX.scriptsToUnicode(row[c]) as NSString)
                    .size(withAttributes: bodyAttrs).width
                if s > maxW { maxW = s }
            }
            widths[c] = ceil(maxW) + 4
        }
        return widths
    }

    private func rowView(_ cells: [String], bold: Bool, shade: Color,
                         n: Int, widths: [CGFloat]?,
                         wrap: Bool, constrained: Bool) -> some View {
        let fill: CGFloat? = constrained ? .infinity : nil
        return HStack(alignment: .top, spacing: 12) {
            ForEach(Array(0..<n), id: \.self) { i in
                let text = i < cells.count ? cells[i] : ""
                cell(text, bold: bold, width: widths?[i], wrap: wrap)
            }
        }
        .frame(maxWidth: fill, alignment: .leading)
        .padding(.vertical, 4)
        .background(shade)
    }

    // clipped(), because a cell is only ever given a width the column
    // agreed to: anything that still does not fit is the caller's
    // arithmetic being wrong, and a truncated tail is recoverable where
    // text drawn across the next column is not.

    @ViewBuilder
    private func cell(_ text: String, bold: Bool,
                      width: CGFloat?, wrap: Bool) -> some View {
        let parsed = Markdown.parse(text)
        if let first = parsed.first,
           case .image(let alt, let url, let w, let h) = first {
            ImageBlockView(alt: alt, url: url, width: w, height: h)
                .frame(width: width, alignment: .leading)
                .clipped()
        } else if let width {
            SelectableText(attributed: cellAttributed(text, parsed: parsed),
                           role: .body, nowrap: !wrap, bold: bold)
                .frame(width: width, alignment: .leading)
                .clipped()
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
        platformSetClipboardString(string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

}
