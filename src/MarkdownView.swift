import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct MarkdownView: View {

    let text: String
    let fileURL: URL?

    @AppStorage("themeMode")
    private var themeRaw: String = ThemeMode.system.rawValue

    // PLAN-TABLES Step 2 feature flag. Default per-platform:
    //   macOS: ON  - DocumentText into one NSTextView via NSTextTable;
    //               AppKit's text system handles long-doc layout
    //               reliably and the arbiter gives atomic-block snap
    //               on cross-block drag selections.
    //   iOS:   OFF - UITextView truncates tall attributed strings
    //               at an internal layout limit even with TextKit 1
    //               (Dockerfile / math / image content past a certain
    //               offset just stops rendering). The per-block
    //               BlockView path renders fine on iOS because each
    //               block is its own short UITextView and the outer
    //               SwiftUI ScrollView handles vertical scrolling.
    //               Same model im.ai uses on iOS, same model that
    //               worked here before commit 88d12c9 flipped the
    //               default on.
    // Opt out / opt in via:
    //   defaults write <bundle-id> singleSurface -bool {YES,NO}
    #if os(macOS)
    @AppStorage("singleSurface")
    private var singleSurface: Bool = true
    #else
    @AppStorage("singleSurface")
    private var singleSurface: Bool = false
    #endif

    @State private var showSource = false

    #if !QUICKLOOK_EXTENSION
    @State private var liveText: String? = nil
    @State private var watcher: MarkdownFileWatcher? = nil
    #endif

    private var theme: ThemeMode {
        ThemeMode(rawValue: themeRaw) ?? .system
    }

    private var displayText: String {
        #if QUICKLOOK_EXTENSION
        return text
        #else
        return liveText ?? text
        #endif
    }

    init(text: String, fileURL: URL? = nil) {
        self.text = text
        self.fileURL = fileURL
    }

    @ViewBuilder
    var body: some View {
        #if QUICKLOOK_EXTENSION
        let body = scrollContent
            .background(systemBackground)
            .preferredColorScheme(theme.colorScheme)
        #else
        let body = scrollContent
            .background(systemBackground)
            .background(WindowAppearanceApplier(scheme: theme.colorScheme))
            .preferredColorScheme(theme.colorScheme)
        #endif
        #if QUICKLOOK_EXTENSION
        body.overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                SourceButton(showingSource: showSource) {
                    showSource.toggle()
                }
                ThemeButton(theme: theme) {
                    themeRaw = theme.next.rawValue
                }
            }
            .buttonStyle(.plain)
            .padding(8)
        }
        #else
        let withAutosave: AnyView = {
            var v = AnyView(body)
            #if os(macOS)
            if let url = fileURL {
                let autosave = WindowFrameAutosave(
                    name: "Markdown.Preview:\(url.path)")
                v = AnyView(body.background(autosave))
            }
            #endif
            return v
        }()
        withAutosave.toolbar {
            ToolbarItem(placement: .primaryAction) {
                SourceButton(showingSource: showSource) {
                    showSource.toggle()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                CopyDocButton(text: displayText)
            }
            #if os(macOS)
            // macOS has room for the full toolbar - keep PDF / HTML /
            // Share / Theme as visible buttons. The nav bar fits all
            // six.
            ToolbarItem(placement: .primaryAction) {
                SaveButton(text: displayText, fileURL: fileURL)
            }
            ToolbarItem(placement: .primaryAction) {
                SaveHtmlButton(text: displayText, fileURL: fileURL)
            }
            ToolbarItem(placement: .primaryAction) {
                ShareButton(text: displayText, fileURL: fileURL)
            }
            ToolbarItem(placement: .primaryAction) {
                ThemeButton(theme: theme) {
                    themeRaw = theme.next.rawValue
                }
            }
            #else
            // iOS: the nav bar can host roughly two primary buttons
            // alongside DocumentGroup's own back / title / file menu
            // chrome. Anything beyond that gets silently dropped by
            // SwiftUI - `.primaryAction` does not auto-overflow on iOS
            // (the `...` shown by DocumentGroup is its OWN menu, not
            // ours). Surface the secondary actions via an explicit
            // `Menu` so they're always reachable.
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ShareButton(text: displayText, fileURL: fileURL)
                    Button {
                        themeRaw = theme.next.rawValue
                    } label: {
                        Label(theme.help, systemImage: theme.symbol)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            #endif
        }
        .onAppear {
            startWatchingIfNeeded()
        }
        .onDisappear {
            watcher = nil
        }
        #endif
    }

    #if !QUICKLOOK_EXTENSION
    private func startWatchingIfNeeded() {
        if watcher != nil { return }
        let url = fileURL
        if let url {
            watcher = MarkdownFileWatcher(url: url) { newText in
                DispatchQueue.main.async {
                    liveText = newText
                }
            }
        }
    }
    #endif

    private var scrollContent: some View {
        ScrollView(.vertical) {
            Group {
                if showSource {
                    SelectableText(attributed: AttributedString(displayText),
                                   role: .mono)
                } else if singleSurface {
                    documentTextView
                } else {
                    rendered
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // DocumentText lives in PDFRenderer.swift (apps-only target
    // membership); the QL extension cannot see it. QL also has no
    // toolbar to flip the flag, so falling back to the block-tree
    // path there is the right behavior anyway.
    #if !QUICKLOOK_EXTENSION
    @State private var documentImages: [URL: DocumentText.DocumentImage] = [:]
    #endif

    @ViewBuilder
    private var documentTextView: some View {
        #if !QUICKLOOK_EXTENSION
        let blocks = Markdown.parse(displayText)
        SelectableText(nsAttributed: DocumentText.attributed(
                           from: blocks, images: documentImages),
                       role: .body)
            .task(id: displayText) {
                documentImages = await prefetchDocumentImages(in: blocks)
            }
        #else
        rendered
        #endif
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

    private var systemBackground: Color {
        #if os(macOS)
        return Color(nsColor: .textBackgroundColor)
        #else
        return Color(.systemBackground)
        #endif
    }

}
