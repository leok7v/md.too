import SwiftUI

private struct ViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MarkdownView: View {

    let displayText: String
    let theme: ThemeMode
    let showSource: Bool
    let singleSurface: Bool
    var find: MarkdownFindController? = nil
    // Read by FontRole from UserDefaults, not from here. It is a stored
    // property so a changed notch makes SwiftUI re-run body, which is
    // what re-measures the document at the new size.
    var zoom: Int = 0

    @State private var documentImages: [URL: DocumentText.DocumentImage] = [:]
    @State private var viewport: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id("md.doc")
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: ViewportWidthKey.self,
                                           value: proxy.size.width)
                }
            )
            .onPreferenceChange(ViewportWidthKey.self) { w in
                if w > 0, w != viewport { viewport = w }
            }
            .background(systemBackground)
            .background(WindowAppearanceApplier(scheme: theme.colorScheme))
            .preferredColorScheme(theme.colorScheme)
            .environment(\.textZoom, Zoom.scale(zoom))
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

    // One text view holds the document, so a table too wide for the
    // window cannot scroll on its own the way a block-rendered one does.
    // The whole surface is given the width the widest table needs and
    // scrolls sideways to reach it -- paragraphs travel with it, which
    // is the price of a single selectable surface. A document whose
    // tables fit asks for nothing and stays aligned to the window.

    private var documentTextView: some View {
        let blocks = Markdown.parse(displayText)
        let fits = max(viewport - 40, 0)
        let need = DocumentText.minimumWidth(of: blocks)
        let width = max(fits, need)
        return ScrollView(.horizontal, showsIndicators: need > fits) {
            SelectableText(
                nsAttributed: DocumentText.attributed(
                    from: blocks, images: documentImages),
                role: .body, find: find)
                .frame(width: viewport > 0 ? width : nil,
                       alignment: .leading)
        }
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
