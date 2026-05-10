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

    deinit {
        if let t = themeObserver {
            NotificationCenter.default.removeObserver(t)
        }
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        // QL extensions tear down their host once preparePreviewOfFile
        // returns, so SwiftUI's `.task` modifiers may never run. Prefetch
        // every image URL the document references here, on the await side
        // of preparePreview, and pass the resulting [URL: Image] map to
        // MarkdownView via Environment so ImageBlockView can render
        // synchronously.
        let blocks = Markdown.parse(text)
        let prefetched = await Self.prefetchImages(in: blocks)

        await MainActor.run {
            if let t = themeObserver {
                NotificationCenter.default.removeObserver(t)
                themeObserver = nil
            }
            for sub in view.subviews { sub.removeFromSuperview() }
            let root = AnyView(
                MarkdownView(text: text)
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
            ) { [weak self] _ in self?.applyAppearance() }
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
        async -> [URL: Image] {
        var urls: Set<URL> = []
        for b in blocks {
            switch b {
                case .image(_, let u, _, _):
                    urls.insert(u)
                case .table(_, let rows):
                    for row in rows {
                        for cell in row {
                            let parsed = Markdown.parse(cell)
                            if let first = parsed.first,
                               case .image(_, let u, _, _) = first {
                                urls.insert(u)
                            }
                        }
                    }
                default:
                    break
            }
        }
        let agent = "Markdown.Preview/1.0" +
                    " (https://github.com/leok7v/md.too)"
        let datas: [(URL, Data?)] =
            await withTaskGroup(of: (URL, Data?).self) { group in
                for u in urls {
                    group.addTask {
                        var req = URLRequest(url: u)
                        req.setValue(agent,
                                     forHTTPHeaderField: "User-Agent")
                        let data = try? await URLSession.shared
                            .data(for: req).0
                        return (u, data)
                    }
                }
                var result: [(URL, Data?)] = []
                for await pair in group { result.append(pair) }
                return result
            }
        var out: [URL: Image] = [:]
        for (u, data) in datas {
            if let data, let nsImg = NSImage(data: data) {
                out[u] = Image(nsImage: nsImg)
            }
        }
        return out
    }
}
