import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct MarkdownView: View {

    let text: String
    let fileURL: URL?
    var onClose: (() -> Void)? = nil

    @AppStorage("themeMode")
    private var themeRaw: String = ThemeMode.system.rawValue

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

    init(text: String, fileURL: URL? = nil,
         onClose: (() -> Void)? = nil) {
        self.text = text
        self.fileURL = fileURL
        self.onClose = onClose
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
        #if os(macOS)
        withAutosave.toolbar {
            ToolbarItem(placement: .primaryAction) {
                SourceButton(showingSource: showSource) {
                    showSource.toggle()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                CopyDocButton(text: displayText)
            }
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
        }
        .onAppear {
            startWatchingIfNeeded()
        }
        .onDisappear {
            watcher = nil
        }
        #else
        withAutosave
            .safeAreaInset(edge: .top, spacing: 0) {
                iOSToolbarOverlay
            }
            .onAppear {
                startWatchingIfNeeded()
            }
            .onDisappear {
                watcher = nil
            }
        #endif
        #endif
    }

    #if os(iOS) && !QUICKLOOK_EXTENSION
    @ViewBuilder
    private var iOSToolbarOverlay: some View {
        HStack(spacing: 12) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "chevron.backward")
                        .font(.headline)
                }
                .accessibilityLabel("Back to Files")
            }
            Text(fileURL?.lastPathComponent ?? "Document")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            SourceButton(showingSource: showSource) {
                showSource.toggle()
            }
            CopyDocButton(text: displayText)
            ShareButton(text: displayText, fileURL: fileURL)
            ThemeButton(theme: theme) {
                themeRaw = theme.next.rawValue
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
    #endif

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
