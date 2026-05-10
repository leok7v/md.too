import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct MarkdownPreviewApp: App {
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
        let recents = NSDocumentController.shared.recentDocumentURLs
        for url in recents {
            let parent = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.path) {
                return parent
            }
        }
        return FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask).first
    }
    #endif

    var body: some Scene {
        let scene = DocumentGroup(viewing: MarkdownDocument.self) { file in
            MarkdownView(text: file.document.text, fileURL: file.fileURL)
                .frame(minWidth: 360, minHeight: 360)
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
