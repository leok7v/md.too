import SwiftUI
import PDFKit
import AppKit

struct SaveMenu: View {

    let text: String
    let fileURL: URL?

    var body: some View {
        Menu {
            Button("Save as PDF...") { savePDF() }
            Button("Save as HTML...") { saveHTML() }
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .help("Save as PDF or HTML")
    }

    private var title: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
    }

    private func savePDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "\(title).pdf"
        panel.canCreateDirectories = true
        panel.title = "Save PDF"
        let captured = text
        let name = title
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                Task {
                    let pdf = await exportPDF(text: captured, title: name)
                    if let pdf {
                        try? FileManager.default.removeItem(at: dest)
                        try? FileManager.default.copyItem(at: pdf, to: dest)
                    }
                }
            }
        }
    }

    private func saveHTML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = "\(title).html"
        panel.canCreateDirectories = true
        panel.title = "Save HTML"
        let captured = text
        let name = title
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                Task {
                    let blocks = Markdown.parse(captured)
                    let images = await HtmlExport.prefetchImages(in: blocks)
                    let html = HtmlExport.render(blocks, title: name,
                                                 images: images)
                    if let data = html.data(using: .utf8) {
                        try? FileManager.default.removeItem(at: dest)
                        try? data.write(to: dest)
                    }
                }
            }
        }
    }

}

struct ShareMenu: View {

    let text: String
    let fileURL: URL?
    @State private var pdfURL: URL?
    @State private var htmlURL: URL?
    @State private var pdfThumb: Image?

    var body: some View {
        Menu {
            if let pdfURL {
                ShareLink(item: pdfURL,
                          preview: SharePreview(title,
                              image: pdfThumb ??
                                  Image(systemName: "doc.richtext"))) {
                    Label("Share as PDF", systemImage: "doc.richtext")
                }
            }
            if let htmlURL {
                ShareLink(item: htmlURL,
                          preview: SharePreview(title,
                              image: Image(systemName: "globe"))) {
                    Label("Share as HTML", systemImage: "globe")
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .disabled(pdfURL == nil && htmlURL == nil)
        .help("Share as PDF or HTML")
        .task(id: text) {
            pdfURL = await exportPDF(text: text, title: title)
            pdfThumb = pdfURL.flatMap { url in firstPageThumbnail(of: url) }
            htmlURL = await exportHTML(text: text, title: title)
        }
    }

    private var title: String {
        fileURL?.deletingPathExtension().lastPathComponent ?? "Document"
    }

    private func firstPageThumbnail(of url: URL) -> Image? {
        var result: Image? = nil
        if let doc = PDFDocument(url: url),
           let page = doc.page(at: 0) {
            let size = CGSize(width: 512, height: 512)
            result = platformPDFPageThumbnail(page, size: size)
        }
        return result
    }

}
