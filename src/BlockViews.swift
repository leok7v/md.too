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
            case .table(let headers, let rows, let alignments):
                TableBlock(headers: headers, rows: rows,
                           alignments: alignments)
            case .math(let tex):
                MathBlock(tex: tex)
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
    @State private var image: SizedImage?
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
        .task(id: url) {
            if prefetched[url] == nil { await load() }
        }
    }

    @ViewBuilder
    private func sized(_ sized: SizedImage) -> some View {
        let scaled = sized.image.resizable().scaledToFit()
        if let w = width, let h = height {
            scaled.frame(width: w, height: h, alignment: .leading)
        } else if let w = width {
            scaled.frame(maxWidth: w, alignment: .leading)
        } else if let h = height {
            scaled.frame(maxHeight: h, alignment: .leading)
        } else {
            scaled.frame(maxWidth: min(320, sized.size.width),
                         alignment: .leading)
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
                } else if !Task.isCancelled {
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
    @Environment(\.textZoom) private var zoom

    var body: some View {
        let style = MarkdownStyle.at(zoom: zoom)
        let highlighted = Highlight.attribute(text,
                                              language: language,
                                              baseFont: style.codeFont)
        ScrollView(.horizontal, showsIndicators: false) {
            SelectableText(nsAttributed: highlighted,
                           role: .mono,
                           nowrap: true)
                .padding(style.codePadding)
        }
        .background(
            RoundedRectangle(cornerRadius: style.cornerRadius)
                .fill(Color.secondary.opacity(0.1))
        )
        .overlay(alignment: .topTrailing) {
            CopyButton(string: text, label: language)
                .padding(6)
        }
    }

}

private struct MathBlock: View {

    let tex: String
    @Environment(\.textZoom) private var zoom
    @Environment(\.colorScheme) private var scheme
    @State private var available: CGFloat = 0

    var body: some View {
        let size = TeX.displaySize(
            body: FontRole.body.platformFont(scale: zoom).pointSize)
        if let layout = TeX.layout(tex, size: size) {
            typeset(layout)
        } else {
            // KaTeX refused it. The substituter always has an answer,
            // so the reader gets the formula spelled out rather than a
            // gap where a formula should be.
            SelectableText(attributed: TeX.render(tex, display: true))
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func typeset(_ layout: MathLayout) -> some View {
        let content = layout.width + copyButtonGutter * 2
        ScrollView(.horizontal, showsIndicators: content > available) {
            Canvas { ctx, _ in
                ctx.withCGContext { cg in
                    layout.draw(in: cg, at: .zero, color: ink, flipped: true)
                }
            }
            .frame(width: layout.width, height: layout.height)
            .padding(.horizontal, copyButtonGutter)
            .frame(maxWidth: available > 0 ? available : nil)
            .accessibilityLabel(tex)
        }
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
            CopyButton(string: tex).padding(2)
        }
        .padding(.vertical, 4)
    }

    // Resolved from the scheme: a raw CGContext carries no appearance
    // for a dynamic system colour to resolve against.
    private var ink: CGColor {
        scheme == .dark ? CGColor(gray: 0.92, alpha: 1)
                        : CGColor(gray: 0.10, alpha: 1)
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
    let alignments: [Alignment]
    @State private var available: CGFloat = 0
    @State private var measure = TableMeasure()

    var body: some View {
        let t = measure.measured(headers: headers, rows: rows,
                                 alignments: alignments)
        let layout = columnLayout(t)
        let fitWidth: CGFloat? = layout.constrained
            ? max(0, available - 16) : nil
        ScrollView(.horizontal, showsIndicators: !layout.constrained) {
            VStack(alignment: .leading, spacing: 0) {
                if !t.headers.isEmpty {
                    rowView(t.headers, bold: true,
                            shade: Color.primary.opacity(0.07),
                            n: t.cols, widths: layout.widths,
                            wrap: layout.wrap,
                            constrained: layout.constrained)
                    Divider()
                }
                ForEach(Array(t.rows.enumerated()),
                        id: \.offset) { idx, row in
                    rowView(row, bold: false,
                            shade: idx % 2 == 1
                                ? Color.primary.opacity(0.04)
                                : Color.clear,
                            n: t.cols, widths: layout.widths,
                            wrap: layout.wrap,
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
            CopyButton(string: t.monospaced)
                .padding(6)
        }
    }

    private func columnLayout(_ t: TableMeasure.Measured)
        -> (widths: [CGFloat]?, wrap: Bool, constrained: Bool) {
        var result: ([CGFloat]?, Bool, Bool) = (nil, false, false)
        let usable = available - CGFloat(max(t.cols - 1, 0)) * 12 - 16
        if available > 0, t.cols > 0 {
            if t.naturals.reduce(0, +) <= usable {
                result = (t.naturals, false, false)
            } else if t.minimums.reduce(0, +) > usable {
                result = (t.minimums, true, false)
            } else {
                let widths = TableMetrics.pointWidths(headers: t.headers,
                                                      rows: t.rows,
                                                      available: usable,
                                                      minimums: t.minimums)
                if !widths.isEmpty {
                    result = (widths, true, true)
                }
            }
        }
        return result
    }

    private func rowView(_ cells: [String], bold: Bool, shade: Color,
                         n: Int, widths: [CGFloat]?,
                         wrap: Bool, constrained: Bool) -> some View {
        let fill: CGFloat? = constrained ? .infinity : nil
        return HStack(alignment: .top, spacing: 12) {
            ForEach(Array(0..<n), id: \.self) { i in
                let text = i < cells.count ? cells[i] : ""
                cell(text, bold: bold, width: widths?[i], wrap: wrap,
                     alignment: frameAlignment(i))
            }
        }
        .frame(maxWidth: fill, alignment: .leading)
        .padding(.vertical, 4)
        .background(shade)
    }

    // A cell is only ever given a width the column agreed to; anything
    // that overflows it is the caller's arithmetic, not a real overflow.

    private func frameAlignment(_ col: Int) -> SwiftUI.Alignment {
        let a = col < alignments.count ? alignments[col] : .none
        let result: SwiftUI.Alignment
        switch a {
            case .center: result = .center
            case .right: result = .trailing
            case .left, .none: result = .leading
        }
        return result
    }

    @ViewBuilder
    private func cell(_ text: String, bold: Bool,
                      width: CGFloat?, wrap: Bool,
                      alignment: SwiftUI.Alignment) -> some View {
        let parsed = Markdown.parseCell(text)
        if let first = parsed.first,
           case .image(let alt, let url, let w, let h) = first {
            ImageBlockView(alt: alt, url: url, width: w, height: h)
                .frame(width: width, alignment: alignment)
                .clipped()
        } else if let width {
            SelectableText(attributed: cellAttributed(text, parsed: parsed),
                           role: .body, nowrap: !wrap, bold: bold)
                .frame(width: width, alignment: alignment)
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

final class TableMeasure {

    static func shown(_ cell: String) -> String {
        var result = TeX.scriptsToUnicode(cell)
        if let first = Markdown.parseCell(cell).first {
            switch first {
                case .paragraph(let attr): result = String(attr.characters)
                case .image: result = ""
                default: result = TeX.scriptsToUnicode(cell)
            }
        }
        return result
    }

    struct Measured {
        let headers: [String]
        let rows: [[String]]
        let cols: Int
        let naturals: [CGFloat]
        let minimums: [CGFloat]
        let monospaced: String
    }

    private var headers: [String] = []
    private var rows: [[String]] = []
    private var alignments: [Alignment] = []
    private var bodySize: CGFloat = 0
    private var value = Measured(headers: [], rows: [], cols: 0,
                                 naturals: [], minimums: [], monospaced: "")

    func measured(headers: [String], rows: [[String]],
                  alignments: [Alignment]) -> Measured {
        let bodySize = FontRole.body.platformFont.pointSize
        let stale = self.headers != headers || self.rows != rows ||
                    self.alignments != alignments ||
                    self.bodySize != bodySize
        if stale {
            value = TableMeasure.measure(headers: headers, rows: rows,
                                         alignments: alignments)
            self.headers = headers
            self.rows = rows
            self.alignments = alignments
            self.bodySize = bodySize
        }
        return value
    }

    static func measure(headers: [String], rows: [[String]],
                        alignments: [Alignment]) -> Measured {
        let h = headers.map { s in TableMetrics.normalize(s) }
        let r = rows.map { row in row.map { s in TableMetrics.normalize(s) } }
        let n = TableMetrics.columnCount(headers: h, rows: r)
        let body = FontRole.body.platformFont
        let bold = boldFont(of: body)
        var naturals = [CGFloat](repeating: 0, count: n)
        var minimums = [CGFloat](repeating: 0, count: n)
        for c in 0..<n {
            var natural: CGFloat = 0
            var minimum: CGFloat = 0
            if c < h.count {
                let visible = shown(h[c])
                natural = TableMetrics.naturalWidth(visible, font: bold)
                minimum = TableMetrics.minimumWidth(visible, font: bold)
            }
            for row in r where c < row.count {
                let visible = shown(row[c])
                let s = TableMetrics.naturalWidth(visible, font: body)
                let w = TableMetrics.minimumWidth(visible, font: body)
                if s > natural { natural = s }
                if w > minimum { minimum = w }
            }
            naturals[c] = ceil(natural) + 4
            minimums[c] = ceil(minimum) + 4
        }
        return Measured(headers: h, rows: r, cols: n, naturals: naturals,
                        minimums: minimums,
                        monospaced: TableMetrics.serializeMonospaced(
                            headers: h, rows: r, alignments: alignments))
    }

}

private struct CopyButton: View {

    let string: String
    var label: String? = nil
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 4) {
                if let label {
                    Text(label.uppercased())
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, label == nil ? 4 : 7)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
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
