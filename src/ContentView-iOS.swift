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
    @AppStorage(ReadingColumn.key)
    private var readingColumn: Bool = false
    @AppStorage(Zoom.key) private var zoom: Int = 0
    @State private var showSource = false
    @State private var liveText: String? = nil
    @State private var expanded = false
    @State private var pinned = false
    @State private var interaction = 0
    @State private var pinchFrom: Int? = nil
    @State private var pinchLabel: String? = nil
    @State private var settled = 0

    private var theme: ThemeMode { ThemeMode(raw: themeRaw) }
    private var displayText: String { liveText ?? text }

    var body: some View {
        MarkdownView(displayText: displayText, theme: theme,
                     showSource: showSource, singleSurface: singleSurface,
                     readingColumn: readingColumn, zoom: zoom)
            .safeAreaInset(edge: .top, spacing: 0) { topBar }
            .simultaneousGesture(pinchZoom)
            .overlay { zoomReadout }
            .task(id: interaction) { await collapseAfterIdle() }
            .task(id: settled) { await hideReadout() }
            .watchingFile(fileURL, into: $liveText)
    }

    private var pinchZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let from = pinchFrom ?? zoom
                if pinchFrom == nil { pinchFrom = from }
                let want = Zoom.scale(from) * value.magnification
                pinchLabel = Zoom.percent(Zoom.notch(nearest: want))
            }
            .onEnded { value in
                let from = pinchFrom ?? zoom
                let want = Zoom.scale(from) * value.magnification
                let landed = Zoom.notch(nearest: want)
                zoom = landed
                pinchFrom = nil
                pinchLabel = Zoom.percent(landed)
                settled += 1
            }
    }

    private func hideReadout() async {
        if pinchLabel != nil, pinchFrom == nil {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if !Task.isCancelled { pinchLabel = nil }
        }
    }

    @ViewBuilder
    private var zoomReadout: some View {
        if let pinchLabel {
            Text(pinchLabel)
                .font(.headline)
                .monospacedDigit()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .allowsHitTesting(false)
                .transition(.opacity)
        }
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
                Group {
                    Button(action: { expanded = false }) {
                        Image(systemName: "chevron.right.2")
                    }
                    .accessibilityLabel("Hide actions")
                    SourceButton(showingSource: showSource) {
                        showSource.toggle()
                    }
                    CopyDocButton(text: displayText)
                    ShareButton(text: displayText, fileURL: fileURL)
                    ThemeButton(theme: theme) {
                        themeRaw = theme.next.rawValue
                    }
                }
                .simultaneousGesture(TapGesture().onEnded { pinned = true })
            } else {
                Button(action: {
                    expanded = true
                    pinned = false
                    interaction += 1
                }) {
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
        if expanded, !pinned {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled, !pinned { expanded = false }
        }
    }

}
