import SwiftUI
#if os(macOS)
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Quit when the last document window closes — but only after the
    // user has actually opened a document. Otherwise launching from
    // Finder (which auto-presents the Open panel) and cancelling would
    // terminate the process before the user could pick a file.
    // NSPanel (the Open panel) is filtered out so it doesn't count as
    // a "document window".
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
#endif

@main
struct MarkdownPreviewApp: App {

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        TempPDFs.cleanOnLaunch()
        primeOpenPanelDefault()
    }

    private func primeOpenPanelDefault() {
        // The Open panel runs in a separate XPC service
        // (com.apple.appkit.xpc.openAndSavePanelService) and writes
        // its navigation history to its own preferences domain, not
        // ours. So our sandboxed app never sees the panel's "last
        // directory" updates — if we seed once on first launch, the
        // seed sticks forever. Re-seed every launch from
        // NSDocumentController's recent-documents list so the panel
        // opens where the user is actually working.
        //
        // Defer to the next runloop turn: NSDocumentController is
        // lazily initialized off NSApplication, and touching .shared
        // from inside App.init() (which runs before NSApplication has
        // finished setting up) crashes inside libswiftCore on the
        // first read of its internal Swift collections. By the time
        // the dispatched block runs, NSApp is fully up and the open
        // panel hasn't been shown yet (we only need the seed before
        // the user picks File > Open).
        #if os(macOS)
        DispatchQueue.main.async {
            Self.seedOpenPanelDirectory()
        }
        #endif
    }

    #if os(macOS)
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
        // Most-recent open's parent dir is "where the user is working
        // now". Skip stale entries (file moved/deleted). Fall back to
        // ~/Documents on first launch (no recents yet) so the panel
        // doesn't default to /Applications where the .app sits.
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
    #endif

    var body: some Scene {
        let scene = DocumentGroup(viewing: MarkdownDocument.self) { file in
            MarkdownView(text: file.document.text, fileURL: file.fileURL)
                #if os(macOS)
                .frame(minWidth: 640, minHeight: 480)
                #else
                .frame(minWidth: 360, minHeight: 360)
                #endif
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #if os(macOS)
        return scene.defaultSize(width: 800, height: 900)
        #else
        return scene
        #endif
    }

}
