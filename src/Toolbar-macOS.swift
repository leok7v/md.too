import SwiftUI
import AppKit

// The system save glyph with a tiny "pdf" / "html" badge bottom-right,
// so the two save buttons are visually distinguishable at toolbar size.
private struct SaveGlyph: View {

    let badge: String

    var body: some View {
        Image(systemName: "square.and.arrow.down")
            .overlay(alignment: .bottomTrailing) {
                Text(badge)
                    .font(.system(size: 7, weight: .bold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 2)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .cornerRadius(2)
                    .offset(x: 6, y: 3)
            }
    }

}

struct SaveButton: View {

    let text: String
    let fileURL: URL?

    var body: some View {
        Button(action: save) {
            SaveGlyph(badge: "pdf")
        }
        .help("Save as PDF...")
    }

    private func save() {
        let title = fileURL?.deletingPathExtension().lastPathComponent ??
                    "Document"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(title).pdf"
        panel.canCreateDirectories = true
        panel.title = "Save PDF"
        let captured = text
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                Task {
                    let pdf = await exportPDF(text: captured,
                                              title: title)
                    if let pdf {
                        try? FileManager.default.removeItem(at: dest)
                        try? FileManager.default.copyItem(at: pdf,
                                                          to: dest)
                    }
                }
            }
        }
    }

}

struct SaveHtmlButton: View {

    let text: String
    let fileURL: URL?

    var body: some View {
        Button(action: save) {
            SaveGlyph(badge: "html")
        }
        .help("Save as HTML...")
    }

    private func save() {
        let title = fileURL?.deletingPathExtension().lastPathComponent ??
                    "Document"
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(title).html"
        panel.canCreateDirectories = true
        panel.title = "Save HTML"
        let captured = text
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                Task {
                    let blocks = Markdown.parse(captured)
                    let images = await HtmlExport.prefetchImages(
                        in: blocks)
                    let html = HtmlExport.render(
                        blocks, title: title, images: images)
                    if let data = html.data(using: .utf8) {
                        try? FileManager.default.removeItem(at: dest)
                        try? data.write(to: dest)
                    }
                }
            }
        }
    }

}
