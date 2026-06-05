import SwiftUI
import PDFKit

struct CopyDocButton: View {

    let text: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.clipboard")
                .contentTransition(.opacity)
        }
        .help(copied ? "Copied" : "Copy")
        .overlay(alignment: .bottom) {
            if copied {
                Text("Copied")
                    .font(.caption)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: 28)
                    .transition(.opacity.combined(with: .scale))
            }
        }
    }

    private func copy() {
        let blocks = Markdown.parse(text)
        let plain = PlainExport.render(blocks)
        let html = HtmlExport.render(blocks, title: "Document")
        platformCopyMarkdown(plain: plain, html: html, sourceText: text)
        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.15)) { copied = false }
        }
    }

}

struct ShareButton: View {

    let text: String
    let fileURL: URL?
    var compact: Bool = true
    @State private var pdfURL: URL?
    @State private var pdfThumb: Image?

    var body: some View {
        Group {
            if let pdfURL {
                let label = fileURL?
                    .deletingPathExtension()
                    .lastPathComponent ?? "Document"
                ShareLink(
                      item: pdfURL,
                   preview: SharePreview( label,
                     image: pdfThumb ?? Image(systemName: "doc.richtext"))
                ) {
                    shareLabel
                }
                .help("Share as PDF")
            } else {
                Button(action: {}) {
                    shareLabel.opacity(0.4)
                }
                .disabled(true)
                .help("Generating PDF…")
            }
        }
        .task(id: text) {
            let title = fileURL?.deletingPathExtension().lastPathComponent ??
                        "Document"
            let url = await exportPDF(text: text, title: title)
            let thumb = url.flatMap { firstPageThumbnail(of: $0) }
            await MainActor.run {
                pdfURL = url
                pdfThumb = thumb
            }
        }
    }

    @ViewBuilder
    private var shareLabel: some View {
        if compact {
            Image(systemName: "square.and.arrow.up")
        } else {
            Label("Share as PDF", systemImage: "square.and.arrow.up")
        }
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
