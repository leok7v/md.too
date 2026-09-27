import SwiftUI

private struct ViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// Not Equatable, on purpose: SwiftUI takes an Equatable view's == as
// the whole truth about whether it changed, and the images fetched into
// its state are invisible to ==. A host re-render that changed nothing
// is cheap instead: the parse and every block's render are cached.
struct MarkdownView: View {

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
    // width the widest block needs when that is more. The column sits
    // centred in the viewport and the surface starts where the column
    // starts, so a block wider than the column begins at the prose's
    // left edge and runs right, past the viewport if it must, and the
    // prose is on screen at rest whatever the block did. A window
    // narrower than the column has no column, so the only number the
    // string ever takes from the window is whether it fits, and a
    // resize moves the view without rebuilding the string.

    // The style is built from the zoom this view holds, so the cache
    // key and the dependency SwiftUI re-renders on are one value.

    private var documentTextView: some View {
        let blocks = traced("parse") { cache.blocks(for: displayText) }
        let style = MarkdownStyle.at(zoom: Zoom.scale(zoom))
        let fits = max(viewport - 40, 0)
        let need = traced("minimum") {
            DocumentText.minimumWidth(of: blocks, images: documentImages,
                                      cache: cache, style: style)
        }
        let columned = readingColumn && fits >= style.columnWidth
        let measure = columned ? style.columnWidth : fits
        let width = max(measure, need)
        let lead = columned ? ((fits - measure) / 2).rounded() : 0
        let column: DocumentText.Column? = columned && width > measure
            ? DocumentText.Column(inset: 0, width: measure, surface: width)
            : nil
        let urls = ImagePrefetch.collectURLs(in: blocks)
        let surface = traced("surface") {
            DocumentText.attributed(from: blocks, images: documentImages,
                                    cache: cache, style: style,
                                    budget: measure, column: column)
        }
        return ScrollView(.horizontal,
                          showsIndicators: lead + width > fits) {
            SelectableText(nsAttributed: surface, role: .body, find: find)
                .frame(width: viewport > 0 ? width : nil,
                       alignment: .leading)
                .padding(.leading, lead)
                .frame(width: viewport > 0 ? max(fits, lead + width) : nil,
                       alignment: .leading)
        }
        // Keyed on the image URLs, not the text: a reload that touched
        // no image fetches nothing.
        .task(id: urls) {
            let missing = urls.subtracting(documentImages.keys)
            if !missing.isEmpty {
                let fetched = await ImagePrefetch.fetchAndDecode(
                    missing, decode: platformDocumentImage)
                if MarkdownView.tracing {
                    let line = "md.too images: \(fetched.count) of " +
                               "\(missing.count)\n"
                    FileHandle.standardError.write(Data(line.utf8))
                }
                documentImages.merge(fetched) { _, fresh in fresh }
            }
        }
    }

    // Wall time of one stage of a rebuild on stderr, in a debug build
    // run with MDTOO_TRACE set; a release build pays nothing.

    private func traced<T>(_ stage: String, _ work: () -> T) -> T {
        let start = ContinuousClock.now
        let result = work()
        if MarkdownView.tracing {
            let took = ContinuousClock.now - start
            FileHandle.standardError.write(
                Data("md.too \(stage): \(took)\n".utf8))
        }
        return result
    }

    private static var tracing: Bool {
        var on = false
        #if DEBUG
        on = ProcessInfo.processInfo.environment["MDTOO_TRACE"] != nil
        #endif
        return on
    }

    private var rendered: some View {
        let blocks = cache.blocks(for: displayText)
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()),
                    id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
    }

}
