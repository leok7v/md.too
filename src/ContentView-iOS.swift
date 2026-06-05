import SwiftUI
import UIKit

struct ContentView: View {

    let text: String
    let fileURL: URL?
    var onClose: (() -> Void)? = nil

    @AppStorage("themeMode")
    private var themeRaw: String = ThemeMode.system.rawValue
    @AppStorage("singleSurface")
    private var singleSurface: Bool = false
    @State private var showSource = false
    @State private var liveText: String? = nil

    private var theme: ThemeMode { ThemeMode(raw: themeRaw) }
    private var displayText: String { liveText ?? text }

    var body: some View {
        MarkdownView(displayText: displayText, theme: theme,
                     showSource: showSource, singleSurface: singleSurface)
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .watchingFile(fileURL, into: $liveText)
    }

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 12) {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "chevron.backward").font(.headline)
                }
                .accessibilityLabel("Back to Files")
            }
            Text(fileURL?.lastPathComponent ?? "Document")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            SourceButton(showingSource: showSource) { showSource.toggle() }
            CopyDocButton(text: displayText)
            ShareButton(text: displayText, fileURL: fileURL)
            ThemeButton(theme: theme) { themeRaw = theme.next.rawValue }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

}
