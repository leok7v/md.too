import SwiftUI

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
            recountLater()
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

    // Recounts against the view's own re-derived matches, without
    // re-running the search, after a live reload.
    func viewDidReapply() { recountLater() }

    private func recountLater() {
        DispatchQueue.main.async { [weak self] in self?.recount() }
    }

    private func recount() {
        matchCount = target?.liveFindCount ?? 0
        if matchCount == 0 {
            cursor = -1
            currentMatch = 0
        } else if cursor >= matchCount {
            cursor = matchCount - 1
            currentMatch = cursor + 1
        }
    }

    private func step(forward: Bool) {
        recount()
        if matchCount > 0, let view = target {
            cursor = ((cursor + (forward ? 1 : -1)) % matchCount
                      + matchCount) % matchCount
            view.setActive(cursor)
            if !view.activeMatchOnScreen() { view.revealActiveMatch() }
            if !view.activeMatchOnScreen(),
               let fraction = view.activeMatchFraction() {
                scrollTo?(fraction)
            }
            currentMatch = cursor + 1
        }
    }

}

// activeMatchFraction is the vertical position as a fraction of the
// laid-out text height; activeMatchOnScreen is true only when that
// match is wholly inside the visible part of the view.

@MainActor
protocol FindableTextView: AnyObject {
    func findAll(_ query: String, caseSensitive: Bool) -> Int
    func setActive(_ index: Int?)
    func clearFind()
    var liveFindCount: Int { get }
    func activeMatchFraction() -> CGFloat?
    func activeMatchOnScreen() -> Bool
    func revealActiveMatch()
}

// Guards a non-advancing match so an empty query terminates.

func markdownFindRanges(in text: String, query: String,
                        caseSensitive: Bool) -> [NSRange] {
    var result: [NSRange] = []
    if !query.isEmpty {
        let ns = text as NSString
        let opts: NSString.CompareOptions = caseSensitive
            ? .diacriticInsensitive
            : [.caseInsensitive, .diacriticInsensitive]
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
