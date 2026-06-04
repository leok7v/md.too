import SwiftUI
import PDFKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

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
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(plain, forType: .string)
        item.setString(html, forType: .html)
        if let rtf = htmlToRtf(html) {
            item.setData(rtf, forType: .rtf)
        }
        CopyPdfProvider.shared.set(text: text)
        item.setDataProvider(CopyPdfProvider.shared, forTypes: [.pdf])
        pb.writeObjects([item])
        #else
        UIPasteboard.general.setItems([[
            "public.utf8-plain-text": plain,
            "public.html": html,
        ]])
        #endif
        withAnimation(.easeInOut(duration: 0.15)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeInOut(duration: 0.15)) { copied = false }
        }
    }

    #if os(macOS)
    private func htmlToRtf(_ html: String) -> Data? {
        var result: Data? = nil
        if let data = html.data(using: .utf8),
           let attr = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil) {
            result = try? attr.data(
                from: NSRange(location: 0, length: attr.length),
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.rtf,
                ])
        }
        return result
    }
    #endif

}

#if os(macOS)

private final class CopyPdfProvider: NSObject, NSPasteboardItemDataProvider {

    static let shared = CopyPdfProvider()

    private var text: String = ""

    func set(text: String) {
        self.text = text
    }

    func pasteboard(_ pasteboard: NSPasteboard?,
                    item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .pdf,
           let data = exportPDFDataSync(text: text, title: "Document") {
            item.setData(data, forType: .pdf)
        }
    }

}

#endif

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
                    preview: SharePreview(
                        label,
                        image: pdfThumb
                            ?? Image(systemName: "doc.richtext"))
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
        guard let doc = PDFDocument(url: url),
              let page = doc.page(at: 0) else { return nil }
        let size = CGSize(width: 512, height: 512)
        #if os(macOS)
        return Image(nsImage: page.thumbnail(of: size, for: .cropBox))
        #else
        return Image(uiImage: page.thumbnail(of: size, for: .cropBox))
        #endif
    }

}
