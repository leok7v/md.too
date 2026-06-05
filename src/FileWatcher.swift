import Foundation
import SwiftUI

final class FileWatcher: NSObject, NSFilePresenter {

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
        presentedItemDidChange()
    }

    private func reload() {
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

struct WatchingFile: ViewModifier {

    let fileURL: URL?
    @Binding var liveText: String?
    @State private var watcher: FileWatcher? = nil

    func body(content: Content) -> some View {
        content
            .onAppear { startWatching() }
            .onDisappear { watcher = nil }
    }

    private func startWatching() {
        if watcher == nil, let url = fileURL {
            watcher = FileWatcher(url: url) { newText in
                DispatchQueue.main.async { liveText = newText }
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
