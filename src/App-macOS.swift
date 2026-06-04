import SwiftUI
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var didOpenDocumentWindow = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func windowDidBecomeKey(_ note: Notification) {
        if let w = note.object as? NSWindow, !(w is NSPanel) {
            didOpenDocumentWindow = true
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        didOpenDocumentWindow
    }
}

@main struct App: SwiftUI.App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        TempPDFs.cleanOnLaunch()
        DispatchQueue.main.async { Self.seedOpenPanelDirectory() }
    }

    private static func seedOpenPanelDirectory() {
        let dir = lastWorkingDirectory()
        if let dir {
            let defaults = UserDefaults.standard
            defaults.set(dir.path, forKey: "NSNavLastRootDirectory")
            if let bookmark = try? dir.bookmarkData() {
                defaults.set(bookmark, forKey: "NSOSPLastRootDirectory")
            }
        }
    }

    private static func lastWorkingDirectory() -> URL? {
        var result = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first
        let recents = NSDocumentController.shared.recentDocumentURLs
        if let live = recents.first(where: { u in
            FileManager.default.fileExists(
                atPath: u.deletingLastPathComponent().path)
        }) {
            result = live.deletingLastPathComponent()
        }
        return result
    }

    var body: some Scene {
        DocumentGroup(viewing: MarkdownDocument.self) { file in
            MarkdownView(text: file.document.text, fileURL: file.fileURL)
                .frame(minWidth: 640, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        .defaultSize(width: 800, height: 600)
    }

}
