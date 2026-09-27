import SwiftUI
import AppKit
import Quartz

final class QuickLookViewController: NSViewController, QLPreviewingController {

    private var hostingController: NSHostingController<AnyView>?
    private var themeObserver: NSObjectProtocol?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 800))
        view.autoresizingMask = [.width, .height]
    }

    isolated deinit {
        if let t = themeObserver {
            NotificationCenter.default.removeObserver(t)
        }
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let decoded = Markdown.text(from: try Data(contentsOf: url))
        if decoded == nil { throw CocoaError(.fileReadCorruptFile) }
        let text = decoded ?? ""
        let blocks = Markdown.parse(text)
        let prefetched = await Self.prefetchImages(in: blocks)
        await MainActor.run {
            if let t = themeObserver {
                NotificationCenter.default.removeObserver(t)
                themeObserver = nil
            }
            for sub in view.subviews { sub.removeFromSuperview() }
            let root = AnyView(
                QLContent(text: text, blocks: blocks)
                    .environment(\.prefetchedImages, prefetched)
            )
            let host = NSHostingController(rootView: root)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.width, .height]
            view.addSubview(host.view)
            hostingController = host
            applyAppearance()
            themeObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyAppearance() }
            }
        }
    }

    private func applyAppearance() {
        let raw = UserDefaults.standard.string(forKey: "themeMode") ??
                  ThemeMode.system.rawValue
        let mode = ThemeMode(rawValue: raw) ?? .system
        let appearance: NSAppearance? = {
            switch mode {
                case .system: return nil
                case .light: return NSAppearance(named: .aqua)
                case .dark: return NSAppearance(named: .darkAqua)
            }
        }()
        view.appearance = appearance
        hostingController?.view.appearance = appearance
    }

    private static func prefetchImages(in blocks: [Block])
        async -> [URL: SizedImage] {
        await ImagePrefetch.fetchAndDecode(in: blocks,
                                           decode: platformDecodeImage)
    }

}

struct QLContent: View {

    let text: String
    let blocks: [Block]

    @AppStorage("themeMode")
    private var themeRaw: String = ThemeMode.system.rawValue
    @State private var showSource = false

    private var theme: ThemeMode { ThemeMode(raw: themeRaw) }

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(systemBackground)
        .preferredColorScheme(theme.colorScheme)
        .overlay(alignment: .topTrailing) {
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
    }

    @ViewBuilder
    private var content: some View {
        if showSource {
            SelectableText(attributed: AttributedString(text),
                           role: .mono)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(blocks.enumerated()),
                        id: \.offset) { _, block in
                    BlockView(block: block)
                }
            }
        }
    }

}
