import SwiftUI
import AppKit

struct ContentView: View {

    let text: String
    let fileURL: URL?

    @AppStorage("themeMode")
    private var themeRaw: String = ThemeMode.system.rawValue
    @AppStorage("singleSurface")
    private var singleSurface: Bool = true
    @State private var showSource = false
    @State private var liveText: String? = nil

    private var theme: ThemeMode { ThemeMode(raw: themeRaw) }
    private var displayText: String { liveText ?? text }

    var body: some View {
        MarkdownView(displayText: displayText, theme: theme,
                     showSource: showSource, singleSurface: singleSurface)
            .background(autosave)
            .toolbar {
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
            .watchingFile(fileURL, into: $liveText)
    }

    @ViewBuilder
    private var autosave: some View {
        if let url = fileURL {
            WindowFrameAutosave(name: "Markdown.Preview:\(url.path)")
        } else {
            Color.clear
        }
    }

}

struct WindowFrameAutosave: NSViewRepresentable {

    let name: String

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        apply(to: v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSView) {
        DispatchQueue.main.async {
            if let w = view.window, w.frameAutosaveName != name {
                _ = w.setFrameAutosaveName(name)
            }
        }
    }

}
