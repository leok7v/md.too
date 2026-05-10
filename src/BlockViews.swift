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
            case .quote(let text):
                HStack(alignment: .top, spacing: 8) {
                    Rectangle().fill(Color.secondary.opacity(0.5))
                        .frame(width: 3)
                    SelectableText(attributed: text,
                                   role: .body, secondary: true)
                }
            case .list(let items): ListBlock(items: items)
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
        while attempt < 2, !done {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    marker(item)
                        .frame(minWidth: 22, alignment: .trailing)
                    SelectableText(attributed: item.content, role: .body)
                }
            }
        }
    }

    @ViewBuilder
    private func marker(_ item: ListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? Color.accentColor : Color.secondary)
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

private struct TableBlock: View {

    let headers: [String]
    let rows: [[String]]

    var body: some View {
        let widest = rows.map { row in row.count }.max() ?? 0
        let columnCount = max(headers.count, widest)
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 12,
                 verticalSpacing: 6) {
                if !headers.isEmpty {
                    GridRow {
                        ForEach(Array(headers.enumerated()),
                                id: \.offset) { _, cell in
                            cellView(cell, bold: true)
                        }
                    }
                    Divider().gridCellColumns(columnCount)
                }
                ForEach(Array(rows.enumerated()),
                        id: \.offset) { idx, r in
                    GridRow {
                        ForEach(Array(r.enumerated()),
                                id: \.offset) { _, cell in
                            cellView(cell, bold: false)
                        }
                    }
                    if idx < rows.count - 1 {
                        Divider()
                            .opacity(0.4)
                            .gridCellColumns(columnCount)
                    }
                }
            }
            .padding(8)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay(alignment: .topTrailing) {
            CopyButton(string: serialize())
                .padding(6)
        }
    }

    @ViewBuilder
    private func cellView(_ cell: String, bold: Bool) -> some View {
        let parsed = Markdown.parse(cell)
        if let first = parsed.first,
           case .image(let alt, let url, let w, let h) = first {
            ImageBlockView(alt: alt, url: url, width: w, height: h)
        } else {
            SelectableText(attributed: cellAttributed(cell,
                               parsed: parsed),
                                 role: .body,
                               nowrap: true,
                                 bold: bold)
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

    private func serialize() -> String {
        var out = ""
        if !headers.isEmpty {
            out += "| " + headers.joined(separator: " | ") + " |\n"
            let dashes = Array(repeating: "---", count: headers.count)
                .joined(separator: "|")
            out += "|" + dashes + "|\n"
        }
        for r in rows {
            out += "| " + r.joined(separator: " | ") + " |\n"
        }
        return out
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
