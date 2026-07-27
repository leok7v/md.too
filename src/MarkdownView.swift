import SwiftUI

struct MarkdownView: View {

    let displayText: String
    let theme: ThemeMode
    let showSource: Bool
    let singleSurface: Bool
    var find: MarkdownFindController? = nil

    @State private var documentImages: [URL: DocumentText.DocumentImage] = [:]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("md.doc")
            }
            .background(systemBackground)
            .background(WindowAppearanceApplier(scheme: theme.colorScheme))
            .preferredColorScheme(theme.colorScheme)
            .onAppear {
                // Aligning the match's fraction of the document to the
                // same fraction of the viewport puts the match on
                // screen for any document height.
                find?.scrollTo = { fraction in
                    proxy.scrollTo("md.doc",
                                   anchor: UnitPoint(x: 0, y: fraction))
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if showSource {
            SelectableText(attributed: AttributedString(displayText),
                           role: .mono, find: find)
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
            role: .body, find: find)
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
