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
            ThemeButton(theme: theme) {
                themeRaw = theme.next.rawValue
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
                ThemeButton(theme: theme) {
                    themeRaw = theme.next.rawValue
                }
            }
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                SaveButton(text: displayText, fileURL: fileURL)
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                ShareButton(text: displayText, fileURL: fileURL)
            }
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
        let blocks = Markdown.parse(displayText)
        return ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()),
                        id: \.offset) { _, block in
                    BlockView(block: block)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
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
