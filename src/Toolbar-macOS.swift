import SwiftUI
import PDFKit
import AppKit
import UniformTypeIdentifiers

struct SaveMenu: View {

    let text: String
    let fileURL: URL?

    var body: some View {
        Menu {
            Button("Save as PDF...") {
                save(.pdf, ext: "pdf", produce: Self.pdfData)
            }
            Button("Save as HTML...") {
                save(.html, ext: "html", produce: Self.htmlData)
            }
        } label: {
            Image(systemName: "square.and.arrow.down")
        }
        .help("Save as PDF or HTML")
    }

    private func save(_ type: UTType, ext: String,
                      produce: @escaping (String, String) async -> Data?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "\(documentTitle(of: fileURL)).\(ext)"
        panel.canCreateDirectories = true
        panel.title = "Save \(ext.uppercased())"
        let captured = text
        let name = documentTitle(of: fileURL)
        panel.begin { response in
            if response == .OK, let dest = panel.url {
                Task {
                    let data = await produce(captured, name)
                    if let data {
                        try? FileManager.default.removeItem(at: dest)
                        try? data.write(to: dest)
                    }
                }
            }
        }
    }

    private static func pdfData(_ text: String, _ title: String) async
        -> Data? {
        let pdf = await exportPDF(text: text, title: title)
        return pdf.flatMap { url in try? Data(contentsOf: url) }
    }

    private static func htmlData(_ text: String, _ title: String) async
        -> Data? {
        let blocks = Markdown.parse(text)
        let images = await HtmlExport.prefetchImages(in: blocks)
        let html = HtmlExport.render(blocks, title: title, images: images)
        return html.data(using: .utf8)
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
            let mine = TempPDFs.nextTag()
            let pdf = await exportPDF(text: text, title: title, tag: mine)
            if !Task.isCancelled {
                replace(&pdfURL, with: pdf)
                pdfThumb = pdf.flatMap { url in firstPageThumbnail(of: url) }
                let html = await exportHTML(text: text, title: title,
                                            tag: mine)
                if !Task.isCancelled { replace(&htmlURL, with: html) }
            }
        }
    }

    private var title: String { documentTitle(of: fileURL) }

    private func replace(_ published: inout URL?, with fresh: URL?) {
        if let old = published, old != fresh {
            try? FileManager.default.removeItem(at: old)
        }
        published = fresh
    }

}
