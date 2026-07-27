import SwiftUI

// Find / Find Next over the single-surface document view. The view
// registers itself (Bridges-macOS); the controller highlights every
// match, steps a cursor through them, and asks the host (MarkdownView)
// to scroll via a fraction of the document height. Aligning the
// match's own fraction of the view to the same fraction of the
// viewport guarantees the match lands on screen without the text view
// owning a scroll view. Pattern adapted from the GaDeoN.devs MD
// package, reduced to the one-view case.

@MainActor
final class MarkdownFindController: ObservableObject {

    @Published private(set) var matchCount = 0
    @Published private(set) var currentMatch = 0

    var scrollTo: ((CGFloat) -> Void)?

    private weak var target: (any FindableTextView)?
    private var cursor = -1
    private var query = ""

    func register(_ view: any FindableTextView) {
        target = view
        if !query.isEmpty {
            _ = view.findAll(query, caseSensitive: false)
            recount()
        }
    }

    func unregister(_ view: any FindableTextView) {
        if target === view { target = nil }
    }

    func find(_ q: String) {
        query = q
        matchCount = target?.findAll(q, caseSensitive: false) ?? 0
        cursor = -1
        currentMatch = 0
        if matchCount > 0 { step(forward: true) }
    }

    func findNext() { step(forward: true) }

    func findPrevious() { step(forward: false) }

    func clear() {
        target?.clearFind()
        query = ""
        cursor = -1
        matchCount = 0
        currentMatch = 0
    }

    // The registered view calls this after a live reload re-derived
    // its matches, so the displayed total stays honest without
    // re-running the search.
    func viewDidReapply() { recount() }

    private func recount() {
        matchCount = target?.liveFindCount ?? 0
        if matchCount == 0 {
            cursor = -1
            currentMatch = 0
        } else if cursor >= matchCount {
            cursor = matchCount - 1
        }
    }

    private func step(forward: Bool) {
        recount()
        if matchCount > 0, let view = target {
            cursor = ((cursor + (forward ? 1 : -1)) % matchCount
                      + matchCount) % matchCount
            view.setActive(cursor)
            if let fraction = view.activeMatchFraction() {
                scrollTo?(fraction)
            }
            currentMatch = cursor + 1
        }
    }

}

// Implemented by the platform text views. findAll highlights every
// match without selecting; setActive selects one (or clears with
// nil); activeMatchFraction is the active match's vertical position
// as a fraction of the laid-out text height.

@MainActor
protocol FindableTextView: AnyObject {
    func findAll(_ query: String, caseSensitive: Bool) -> Int
    func setActive(_ index: Int?)
    func clearFind()
    var liveFindCount: Int { get }
    func activeMatchFraction() -> CGFloat?
}

// All non-overlapping ranges of query in text. Non-advancing matches
// are guarded so a degenerate query terminates.

func markdownFindRanges(in text: String, query: String,
                        caseSensitive: Bool) -> [NSRange] {
    var result: [NSRange] = []
    if !query.isEmpty {
        let ns = text as NSString
        let opts: NSString.CompareOptions =
            caseSensitive ? [] : .caseInsensitive
        var start = 0
        var searching = true
        while searching {
            let scope = NSRange(location: start,
                                length: ns.length - start)
            let r = ns.range(of: query, options: opts, range: scope)
            if r.location == NSNotFound {
                searching = false
            } else {
                result.append(r)
                start = r.location + max(r.length, 1)
                if start >= ns.length { searching = false }
            }
        }
    }
    return result
}
