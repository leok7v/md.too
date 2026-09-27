import SwiftUI

private struct ViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct MarkdownView: View, Equatable {

    let displayText: String
    let theme: ThemeMode
    let showSource: Bool
    let singleSurface: Bool
    var readingColumn: Bool = true
    var find: MarkdownFindController? = nil
    // Read by FontRole from UserDefaults, not from here. It is a stored
    // property so a changed notch makes SwiftUI re-run body, which is
    // what re-measures the document at the new size.
    var zoom: Int = 0

    @State private var documentImages: [URL: DocumentText.DocumentImage] = [:]
    @State private var viewport: CGFloat = 0
    @State private var cache = DocumentText.RenderCache()

    // Equatable so a host re-render that changed none of these (a find
    // keystroke, a toolbar toggle) does not re-parse the document.
    static func == (a: MarkdownView, b: MarkdownView) -> Bool {
        a.displayText == b.displayText && a.theme == b.theme &&
        a.showSource == b.showSource &&
        a.singleSurface == b.singleSurface &&
        a.readingColumn == b.readingColumn &&
        a.find === b.find && a.zoom == b.zoom
    }

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

    // One text view holds the document. Its width is the reading column
    // when the window is wider, or the window when it is not, or the
    // width the widest block needs when that is more; the view is
    // centred in the viewport and scrolls sideways past it. When a block
    // pushes the surface past the column, the prose keeps the column:
    // centred inside the surface while the surface fits the window, at
    // the leading edge once it scrolls, so it is on screen at rest. A
    // window narrower than the column has no column, so the only number
    // the string ever takes from the window is whether it fits, and a
    // resize moves the view without rebuilding the string.

    // The style is built from the zoom this view holds, so the cache
    // key and the dependency SwiftUI re-renders on are one value.

    private var documentTextView: some View {
        let blocks = Markdown.parse(displayText)
        let style = MarkdownStyle.at(zoom: Zoom.scale(zoom))
        let fits = max(viewport - 40, 0)
        let need = DocumentText.minimumWidth(of: blocks,
                                             images: documentImages,
                                             cache: cache, style: style)
        let columned = readingColumn && fits >= style.columnWidth
        let measure = columned ? style.columnWidth : fits
        let width = max(measure, need)
        let column: DocumentText.Column? = columned && width > measure
            ? DocumentText.Column(
                inset: width > fits ? 0 : ((width - measure) / 2).rounded(),
                width: measure)
            : nil
        let urls = ImagePrefetch.collectURLs(in: blocks)
        return ScrollView(.horizontal, showsIndicators: width > fits) {
            SelectableText(
                nsAttributed: DocumentText.attributed(
                    from: blocks, images: documentImages, cache: cache,
                    style: style, column: column),
                role: .body, find: find)
                .frame(width: viewport > 0 ? width : nil,
                       alignment: .leading)
                .frame(width: viewport > 0 ? max(fits, width) : nil,
                       alignment: .center)
        }
        // Keyed on the image URLs, not the text: a reload that touched
        // no image fetches nothing.
        .task(id: urls) {
            let missing = urls.subtracting(documentImages.keys)
            if !missing.isEmpty {
                let fetched = await ImagePrefetch.fetchAndDecode(
                    missing, decode: platformDocumentImage)
                documentImages.merge(fetched) { _, fresh in fresh }
            }
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
