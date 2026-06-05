import SwiftUI

struct MarkdownView: View {

    let displayText: String
    let theme: ThemeMode
    let showSource: Bool
    let singleSurface: Bool

    @State private var documentImages: [URL: DocumentText.DocumentImage] = [:]

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(systemBackground)
        .background(WindowAppearanceApplier(scheme: theme.colorScheme))
        .preferredColorScheme(theme.colorScheme)
    }

    @ViewBuilder
    private var content: some View {
        if showSource {
            SelectableText(attributed: AttributedString(displayText),
                           role: .mono)
        } else if singleSurface {
            documentTextView
        } else {
            rendered
        }
    }

    private var documentTextView: some View {
        let blocks = Markdown.parse(displayText)
        return SelectableText(
            nsAttributed: DocumentText.attributed(
                from: blocks, images: documentImages),
            role: .body)
            .task(id: displayText) {
                documentImages = await prefetchDocumentImages(in: blocks)
            }
    }

    private var rendered: some View {
        let blocks = Markdown.parse(displayText)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()),
                    id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
    }

}
