import SwiftUI
import AppKit

struct ContentView: View {

    let text: String
    let fileURL: URL?

    @AppStorage("themeMode")
    private var themeRaw: String = ThemeMode.system.rawValue
    @AppStorage("singleSurface")
    private var singleSurface: Bool = true
    @AppStorage(Zoom.key) private var zoom: Int = 0
    @State private var showSource = false
    @State private var liveText: String? = nil
    @State private var expanded = false
    @State private var hovering = false
    @StateObject private var find = MarkdownFindController()
    @State private var findVisible = false
    @State private var findQuery = ""
    @FocusState private var findFocused: Bool

    private var theme: ThemeMode { ThemeMode(raw: themeRaw) }
    private var displayText: String { liveText ?? text }
    private var idle: Bool { expanded && !hovering }

    var body: some View {
        MarkdownView(displayText: displayText, theme: theme,
                     showSource: showSource, singleSurface: singleSurface,
                     find: find, zoom: zoom)
            .background(autosave)
            .background(findShortcut)
            .safeAreaInset(edge: .top, spacing: 0) { findBarIfVisible }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { actions }
            }
            .task(id: idle) { await collapseAfterIdle() }
            .watchingFile(fileURL, into: $liveText)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if expanded {
                Button(action: { expanded = false }) {
                    Image(systemName: "chevron.right.2")
                }
                .help("Hide actions")
                SourceButton(showingSource: showSource) {
                    showSource.toggle()
                }
                CopyDocButton(text: displayText)
                Button(action: openFind) {
                    Image(systemName: "magnifyingglass")
                }
                .help("Find (Cmd-F)")
                SaveMenu(text: displayText, fileURL: fileURL)
                ShareMenu(text: displayText, fileURL: fileURL)
                ThemeButton(theme: theme) {
                    themeRaw = theme.next.rawValue
                }
            } else {
                Button(action: { expanded = true }) {
                    Image(systemName: "chevron.left.2")
                }
                .help("More actions")
            }
        }
        .onHover { inside in hovering = inside }
        .animation(.easeInOut(duration: 0.2), value: expanded)
    }

    private func collapseAfterIdle() async {
        if idle {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { expanded = false }
        }
    }

    private var findShortcut: some View {
        Button(action: openFind) { EmptyView() }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
    }

    @ViewBuilder
    private var findBarIfVisible: some View {
        if findVisible { findBar }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $findQuery)
                .textFieldStyle(.plain)
                .focused($findFocused)
                .frame(maxWidth: 360)
                .onSubmit { find.findNext() }
                .onExitCommand { closeFind() }
            Text(findCountLabel)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(action: { find.findPrevious() }) {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(find.matchCount == 0)
            Button(action: { find.findNext() }) {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(find.matchCount == 0)
            Spacer(minLength: 0)
            Button(action: closeFind) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onChange(of: findQuery) { q in find.find(q) }
    }

    private var findCountLabel: String {
        var result = ""
        if !findQuery.isEmpty {
            result = find.matchCount == 0 ? "0"
                : "\(find.currentMatch)/\(find.matchCount)"
        }
        return result
    }

    private func openFind() {
        findVisible = true
        findFocused = true
        if !findQuery.isEmpty { find.find(findQuery) }
    }

    private func closeFind() {
        find.clear()
        findVisible = false
    }

    private var autosave: some View {
        WindowFrameAutosave(name: "md.too.document")
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
