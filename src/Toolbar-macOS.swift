import SwiftUI
import AppKit

struct SaveButton: View {

    let text: String
    let fileURL: URL?

    var body: some View {
        Button(action: save) {
            Image(systemName: "square.and.arrow.down")
        }
        .help("Save as PDF…")
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
