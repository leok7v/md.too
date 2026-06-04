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
        let urls = ImagePrefetch.collectURLs(in: blocks)
        let datas = await ImagePrefetch.fetch(urls)
        return datas.compactMapValues { d in
            NSImage(data: d).map { ns in Image(nsImage: ns) }
        }
    }

}
