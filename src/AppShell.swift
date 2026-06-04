import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if os(macOS)

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

struct WindowAppearanceApplier: NSViewRepresentable {

    let scheme: ColorScheme?

    final class Coordinator {
        var scheme: ColorScheme?
        var observers: [NSObjectProtocol] = []
        weak var view: NSView?
        deinit {
            for o in observers {
                NotificationCenter.default.removeObserver(o)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView(frame: .zero)
        let coord = context.coordinator
        coord.scheme = scheme
        coord.view = v
        let names: [Notification.Name] = [
            NSWindow.didResignKeyNotification,
            NSWindow.didBecomeKeyNotification,
            NSApplication.didBecomeActiveNotification,
            NSApplication.didResignActiveNotification,
        ]
        coord.observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak coord] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    if let coord, let view = coord.view {
                        view.window?.appearance =
                            Self.appearanceFor(coord.scheme)
                    }
                }
            }
        }
        DispatchQueue.main.async {
            v.window?.appearance = Self.appearanceFor(scheme)
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.scheme = scheme
        DispatchQueue.main.async {
            nsView.window?.appearance = Self.appearanceFor(scheme)
        }
    }

    static func dismantleNSView(_ nsView: NSView,
                                coordinator: Coordinator) {
        for o in coordinator.observers {
            NotificationCenter.default.removeObserver(o)
        }
    }

    private static func appearanceFor(_ scheme: ColorScheme?)
        -> NSAppearance? {
        var result: NSAppearance? = nil
        switch scheme {
            case .none: result = nil
            case .light: result = NSAppearance(named: .aqua)
            case .dark: result = NSAppearance(named: .darkAqua)
            @unknown default: result = nil
        }
        return result
    }
}

#elseif os(iOS)

struct WindowAppearanceApplier: UIViewRepresentable {

    let scheme: ColorScheme?
    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        apply(to: v)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {
        apply(to: uiView)
    }
    private func apply(to view: UIView) {
        var style: UIUserInterfaceStyle = .unspecified
        switch scheme {
            case .none: style = .unspecified
            case .light: style = .light
            case .dark: style = .dark
            @unknown default: style = .unspecified
        }
        DispatchQueue.main.async {
            view.window?.overrideUserInterfaceStyle = style
        }
    }

}
#endif

final class MarkdownFileWatcher: NSObject, NSFilePresenter {

    let url: URL
    let presentedItemOperationQueue = OperationQueue.main
    var presentedItemURL: URL? { url }

    private let onChange: (String) -> Void
    private var debounce: DispatchWorkItem?

    init(url: URL, onChange: @escaping (String) -> Void) {
        self.url = url
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        // Initial coordinated read - handles iCloud-stubbed files
        // (Files-app sharing). The FileDocument framework's
        // `configuration.file.regularFileContents` returns whatever
        // bytes are currently materialized; an iCloud file that is
        // not fully downloaded reports a smaller "EOF" than its
        // actual size, so `String(contentsOf:URL)` (which does loop
        // internally until that EOF) only sees a truncated head.
        // NSFileCoordinator.coordinate(readingItemAt:) triggers full
        // materialization before the read and emits the complete
        // content via onChange, replacing the partial FileDocument
        // initial text in the view's @State.
        reload()
    }

    deinit {
        debounce?.cancel()
        NSFileCoordinator.removeFilePresenter(self)
    }

    func presentedItemDidChange() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        debounce = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + 0.1, execute: work)
    }

    func presentedItemDidMove(to newURL: URL) {
        // Atomic-write editors rename a temp over the real file.
        // Treat that as a content change and re-read the same URL.
        presentedItemDidChange()
    }

    private func reload() {
        // NSFileCoordinator.coordinate(readingItemAt:...) is synchronous
        // and can block until the file is available - if another process
        // (an atomic-write editor saving over our open file) holds it,
        // the block lasts as long as their write. Apple's docs say not
        // to call this on the main thread for that reason. Dispatch the
        // coordinator + read to a background queue and bounce the
        // resulting text back to main for the @State write in the view.
        let targetURL = url
        let changeHandler = onChange
        DispatchQueue.global(qos: .userInitiated).async {
            let coord = NSFileCoordinator(filePresenter: self)
            var coordError: NSError?
            coord.coordinate(
                readingItemAt: targetURL,
                options: .withoutChanges,
                error: &coordError) { actualURL in
                    let read = try? String(
                        contentsOf: actualURL, encoding: .utf8)
                    if let read {
                        DispatchQueue.main.async {
                            changeHandler(read)
                        }
                    }
                }
        }
    }
    
}
