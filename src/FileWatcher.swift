import Foundation
import SwiftUI

@MainActor
final class FileWatcher: NSObject, NSFilePresenter {

    nonisolated let presentedItemOperationQueue = OperationQueue.main

    private nonisolated let urlLock = NSLock()
    private nonisolated(unsafe) var current: URL

    nonisolated var url: URL {
        urlLock.withLock { current }
    }

    nonisolated var presentedItemURL: URL? { url }

    private let onChange: @MainActor (String) -> Void
    private var pending: Task<Void, Never>?
    private var generation = 0

    init(url: URL, onChange: @escaping @MainActor (String) -> Void) {
        self.current = url
        self.onChange = onChange
        super.init()
        NSFileCoordinator.addFilePresenter(self)
        reload()
    }

    func stop() {
        pending?.cancel()
        NSFileCoordinator.removeFilePresenter(self)
    }

    isolated deinit {
        pending?.cancel()
    }

    nonisolated func presentedItemDidChange() {
        MainActor.assumeIsolated { scheduleReload() }
    }

    nonisolated func presentedItemDidMove(to newURL: URL) {
        urlLock.withLock { current = newURL }
        presentedItemDidChange()
    }

    private func scheduleReload() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            if !Task.isCancelled { self?.reload() }
        }
    }

    private func reload() {
        generation += 1
        let mine = generation
        let target = url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let coord = NSFileCoordinator(filePresenter: self)
            var coordError: NSError?
            var read: String? = nil
            coord.coordinate(readingItemAt: target, options: .withoutChanges,
                             error: &coordError) { actualURL in
                read = Markdown.text(contentsOf: actualURL)
            }
            if let text = read {
                Task { @MainActor [weak self] in self?.apply(text, mine) }
            }
        }
    }

    private func apply(_ text: String, _ mine: Int) {
        if mine == generation { onChange(text) }
    }

}

struct WatchingFile: ViewModifier {

    let fileURL: URL?
    @Binding var liveText: String?
    @State private var watcher: FileWatcher? = nil

    func body(content: Content) -> some View {
        content
            .onAppear { startWatching() }
            .onDisappear {
                watcher?.stop()
                watcher = nil
            }
    }

    private func startWatching() {
        if watcher == nil, let url = fileURL {
            watcher = FileWatcher(url: url) { newText in
                liveText = newText
            }
        }
    }

}

extension View {

    func watchingFile(_ url: URL?, into liveText: Binding<String?>)
                      -> some View {
        modifier(WatchingFile(fileURL: url, liveText: liveText))
    }

}
