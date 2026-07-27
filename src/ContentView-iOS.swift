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
    @State private var expanded = false
    @State private var interaction = 0

    private var theme: ThemeMode { ThemeMode(raw: themeRaw) }
    private var displayText: String { liveText ?? text }

    var body: some View {
        MarkdownView(displayText: displayText, theme: theme,
                     showSource: showSource, singleSurface: singleSurface)
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .task(id: interaction) { await collapseAfterIdle() }
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
            if !expanded {
                Text(fileURL?.lastPathComponent ?? "Document")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if expanded {
                Button(action: { expanded = false }) {
                    Image(systemName: "chevron.right.2")
                }
                .accessibilityLabel("Hide actions")
                SourceButton(showingSource: showSource) {
                    showSource.toggle()
                }
                CopyDocButton(text: displayText)
                ShareButton(text: displayText, fileURL: fileURL)
                ThemeButton(theme: theme) { themeRaw = theme.next.rawValue }
            } else {
                Button(action: { expanded = true; interaction += 1 }) {
                    Image(systemName: "chevron.left.2")
                }
                .accessibilityLabel("More actions")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .simultaneousGesture(TapGesture().onEnded { interaction += 1 })
        .animation(.easeInOut(duration: 0.2), value: expanded)
    }

    private func collapseAfterIdle() async {
        if expanded {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { expanded = false }
        }
    }

}
