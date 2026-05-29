import SwiftUI
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
    // HTML -> NSAttributedString -> RTF via Foundation. Lossier than a
    // direct [Block] -> NSAttributedString walker (rgba backgrounds,
    // table shading, and link styles come through inconsistently), but
    // ten lines and zero parallel maintenance. See the
    // pasteboard-rtf-roundtrip memory for the upgrade path.
    //
    // The .pdf flavor is registered lazily via CopyPdfProvider so the
    // PDF renders only when a target (Pages, Keynote, Preview) actually
    // asks for it - Copy stays instant for the common text/HTML/RTF
    // paste targets and avoids the full CGContext draw on every click.
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
// NSPasteboardItem does not strongly retain its data provider, so the
// provider must outlive the item; a process-wide singleton is the
// lightest way to guarantee that. set(text:) updates the singleton at
// each Copy so the .pdf callback renders the right document.
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
    @State private var pdfURL: URL?

    var body: some View {
        Group {
            if let pdfURL {
                let label = fileURL?
                    .deletingPathExtension()
                    .lastPathComponent ?? "Document"
                ShareLink(
                    item: pdfURL,
                    preview: SharePreview(
                        label, image: Image(systemName: "doc.richtext"))
                ) {
                    Image(systemName: "square.and.arrow.up")
                }
                .help("Share as PDF")
            } else {
                Button(action: {}) {
                    Image(systemName: "square.and.arrow.up").opacity(0.4)
                }
                .disabled(true)
                .help("Generating PDF…")
            }
        }
        .task(id: text) {
            let title = fileURL?.deletingPathExtension().lastPathComponent ??
                        "Document"
            let url = await exportPDF(text: text, title: title)
            await MainActor.run { pdfURL = url }
        }
    }

}
