import SwiftUI

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
