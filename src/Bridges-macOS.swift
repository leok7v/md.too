import SwiftUI
import AppKit

extension NativeText: NSViewRepresentable {

    final class Coordinator: NSObject, NSTextViewDelegate {

        private var anchor: Int = 0
        private var anchorScope: NSRange? = nil

        func textView(_ tv: NSTextView, clickedOnLink link: Any,
                        at: Int) -> Bool {
            var url: URL? = nil
            switch link {
                case let u as URL: url = u
                case let s as String: url = URL(string: s)
                default: url = nil
            }
            var handled = false
            if let url {
                NSWorkspace.shared.open(url)
                handled = true
            }
            return handled
        }

        func textView(_ textView: NSTextView,
                      willChangeSelectionFromCharacterRange
                                  oldRange: NSRange,
                      toCharacterRange newRange: NSRange) -> NSRange {
            var result = newRange
            if let storage = textView.textStorage {
                if newRange.length == 0 {
                    anchor = newRange.location
                    anchorScope = atomicScope(at: anchor, in: storage)
                } else if let scope = anchorScope {
                    let endLo = newRange.location
                    let endHi = newRange.location + newRange.length
                    let scopeLo = scope.location
                    let scopeHi = scope.location + scope.length
                    let endInScope = endLo >= scopeLo && endHi <= scopeHi
                    if !endInScope {
                        let lo = min(endLo, scopeLo)
                        let hi = max(endHi, scopeHi)
                        result = NSRange(location: lo,
                                         length: hi - lo)
                        result = expandToAtomicBoundaries(
                            result, in: storage)
                    }
                } else {
                    result = expandToAtomicBoundaries(result,
                                                     in: storage)
                }
            }
            return result
        }

        // longestEffectiveRange, not effectiveRange: a cell's paragraph
        // style fragments the plain range at one cell, not the table.
        private func atomicRun(at pos: Int,
                               in storage: NSTextStorage) -> NSRange? {
            var result: NSRange? = nil
            if pos >= 0, pos < storage.length {
                var effective = NSRange(location: 0, length: 0)
                let full = NSRange(location: 0, length: storage.length)
                let value = storage.attribute(
                    atomicIdKey, at: pos,
                    longestEffectiveRange: &effective, in: full)
                if value != nil { result = effective }
            }
            return result
        }

        private func atomicScope(at pos: Int,
                                 in storage: NSTextStorage) -> NSRange? {
            atomicRun(at: pos, in: storage)
        }

        private func expandToAtomicBoundaries(_ range: NSRange,
                         in storage: NSTextStorage) -> NSRange {
            var lo = range.location
            var hi = range.location + range.length
            storage.enumerateAttribute(atomicIdKey,
                                       in: range,
                                       options: []) { value, r, _ in
                if value != nil,
                   let run = atomicRun(at: r.location, in: storage) {
                    if run.location < lo { lo = run.location }
                    let end = run.location + run.length
                    if end > hi { hi = end }
                }
            }
            return NSRange(location: lo, length: hi - lo)
        }

    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ResizingTextView {
        let v = ResizingTextView()
        v.delegate = context.coordinator
        v.isEditable = false
        v.isSelectable = true
        v.drawsBackground = false
        v.backgroundColor = .clear
        v.textContainerInset = .zero
        v.textContainer?.lineFragmentPadding = 0
        v.textContainer?.widthTracksTextView = !nowrap
        if nowrap {
            v.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude)
        }
        v.isVerticallyResizable = true
        v.isHorizontallyResizable = nowrap
        v.setContentCompressionResistancePriority(.defaultLow,
                                                  for: .horizontal)
        v.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        v.findController = find
        if let find { find.register(v) }
        v.onCopySpots = onCopySpots
        return v
    }

    static func dismantleNSView(_ v: ResizingTextView,
                                coordinator: Coordinator) {
        v.findController?.unregister(v)
    }

    func updateNSView(_ v: ResizingTextView, context: Context) {
        v.nowrap = nowrap
        v.onCopySpots = onCopySpots
        v.applyResolved(resolved())
    }

    final class ResizingTextView: NSTextView, FindableTextView {

        var nowrap: Bool = false
        weak var findController: MarkdownFindController?
        var onCopySpots: (([CopyBlockSpot]) -> Void)?
        private var lastBounds: NSSize = .zero
        private var contentGeneration = 0
        private var overlayGeneration = -1
        private var lastSpots: [CopyBlockSpot] = []
        private var findMatches: [NSRange] = []
        private var activeIndex: Int? = nil
        private var findQuery = ""
        private var findCaseSensitive = false

        var liveFindCount: Int { findMatches.count }

        private var lastApplied: NSAttributedString? = nil

        // The render cache returns the same instance when unchanged,
        // so reference equality alone is enough to skip the splice.
        func applyResolved(_ next: NSAttributedString) {
            if next !== lastApplied, let ts = textStorage {
                lastApplied = next
                if applyIncremental(ts, next) {
                    contentGeneration += 1
                    invalidateIntrinsicContentSize()
                    needsLayout = true
                    reapplyFind()
                }
            }
        }

        // Concrete sRGB: a dynamic system color resolves to nil off a
        // trait environment and would abort the attribute set.
        private var findTint: NSColor {
            NSColor(srgbRed: 1.0, green: 0.84, blue: 0.2, alpha: 0.35)
        }
        private var activeTint: NSColor {
            NSColor(srgbRed: 1.0, green: 0.6, blue: 0.0, alpha: 0.6)
        }

        func findAll(_ query: String, caseSensitive: Bool) -> Int {
            findQuery = query
            findCaseSensitive = caseSensitive
            findMatches = markdownFindRanges(in: string, query: query,
                                             caseSensitive: caseSensitive)
            activeIndex = nil
            highlightAll()
            return findMatches.count
        }

        // The zero-length call anchors the arbiter at the match first;
        // skipping it lets a stale anchor stretch the selection.
        func setActive(_ index: Int?) {
            activeIndex = index
            highlightAll()
            let len = textStorage?.length ?? 0
            if let i = index, i >= 0, i < findMatches.count,
               NSMaxRange(findMatches[i]) <= len {
                setSelectedRange(NSRange(location: findMatches[i].location,
                                         length: 0))
                setSelectedRange(findMatches[i])
            } else {
                setSelectedRange(NSRange(location: 0, length: 0))
            }
        }

        func clearFind() {
            findQuery = ""
            findMatches = []
            activeIndex = nil
            if let lm = layoutManager, let ts = textStorage {
                lm.removeTemporaryAttribute(
                    .backgroundColor,
                    forCharacterRange: NSRange(location: 0,
                                               length: ts.length))
            }
        }

        func reapplyFind() {
            if !findQuery.isEmpty {
                findMatches = markdownFindRanges(
                    in: string, query: findQuery,
                    caseSensitive: findCaseSensitive)
                if let a = activeIndex, a >= findMatches.count {
                    activeIndex = nil
                }
                highlightAll()
                findController?.viewDidReapply()
            }
        }

        func activeMatchFraction() -> CGFloat? {
            var result: CGFloat? = nil
            if let rect = activeMatchRect(), let lm = layoutManager,
               let tc = textContainer {
                let used = lm.usedRect(for: tc)
                if used.height > 0 { result = rect.midY / used.height }
            }
            return result
        }

        func activeMatchOnScreen() -> Bool {
            var result = false
            if let rect = activeMatchRect() {
                let origin = textContainerOrigin
                result = visibleRect.contains(
                    rect.offsetBy(dx: origin.x, dy: origin.y))
            }
            return result
        }

        // A match recorded before a reload may end past the storage
        // now, and the layout manager raises on such a range.
        private func activeMatchRect() -> NSRect? {
            var result: NSRect? = nil
            let len = textStorage?.length ?? 0
            if let i = activeIndex, i >= 0, i < findMatches.count,
               NSMaxRange(findMatches[i]) <= len,
               let lm = layoutManager, let tc = textContainer {
                let gr = lm.glyphRange(forCharacterRange: findMatches[i],
                                       actualCharacterRange: nil)
                result = lm.boundingRect(forGlyphRange: gr, in: tc)
            }
            return result
        }

        // Temporary, not real, attributes: they overlay the text
        // without touching storage, so the splice diff stays clean.
        private func highlightAll() {
            if let lm = layoutManager, let ts = textStorage {
                let full = NSRange(location: 0, length: ts.length)
                lm.removeTemporaryAttribute(.backgroundColor,
                                            forCharacterRange: full)
                for (i, r) in findMatches.enumerated()
                where NSMaxRange(r) <= ts.length {
                    lm.setTemporaryAttributes(
                        [.backgroundColor: i == activeIndex
                            ? activeTint : findTint],
                        forCharacterRange: r)
                }
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            if let lm = layoutManager, let tc = textContainer,
               let ts = textStorage {
                let style = MarkdownStyle.current
                let origin = textContainerOrigin
                let shown = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
                let glyphs = lm.glyphRange(forBoundingRect: shown, in: tc)
                let chars = lm.characterRange(forGlyphRange: glyphs,
                                              actualGlyphRange: nil)
                codeBlockTint.setFill()
                for box in codeBlockRects(in: ts, layoutManager: lm,
                                          container: tc, within: chars,
                                          padding: style.codePadding,
                                          trailing: style.blockSpacing) {
                    NSBezierPath(roundedRect: box.offsetBy(dx: origin.x,
                                                           dy: origin.y),
                                 xRadius: style.cornerRadius,
                                 yRadius: style.cornerRadius).fill()
                }
            }
            super.draw(dirtyRect)
        }

        override var intrinsicContentSize: NSSize {
            var result = super.intrinsicContentSize
            if let lm = layoutManager, let tc = textContainer {
                lm.ensureLayout(for: tc)
                let r = lm.usedRect(for: tc)
                let inset = textContainerInset
                let w: CGFloat
                if nowrap {
                    w = r.width + inset.width * 2
                } else {
                    w = NSView.noIntrinsicMetric
                }
                let h = r.height + inset.height * 2
                result = NSSize(width: w, height: h)
            }
            return result
        }

        // NSTextView routes Cmd-C through copy(_:); plain RTF cannot
        // hold an image attachment (RTFD can), hence the split below.

        override func copy(_ sender: Any?) {
            let picked = selectedRange()
            let store = picked.length > 0 ? textStorage : nil
            if let store {
                let slice = store.attributedSubstring(from: picked)
                let board = NSPasteboard.general
                board.clearContents()
                let lone = Self.lonePDF(slice, dark: self.isDark)
                var types: [NSPasteboard.PasteboardType] =
                    [.rtfd, .rtf, .html, .string]
                if lone != nil { types.insert(.pdf, at: 1) }
                board.declareTypes(types, owner: nil)
                if let lone { board.setData(lone, forType: .pdf) }
                let rich = Self.illustrated(slice, dark: self.isDark)
                if let data = rich.rtfd(
                    from: NSRange(location: 0, length: rich.length),
                    documentAttributes: [:]) {
                    board.setData(data, forType: .rtfd)
                }
                let spelled = Self.spelled(slice)
                let whole = NSRange(location: 0, length: spelled.length)
                board.setString(spelled.string, forType: .string)
                if let data = spelled.rtf(from: whole,
                                          documentAttributes: [:]) {
                    board.setData(data, forType: .rtf)
                }
                if let data = try? spelled.data(
                    from: whole,
                    documentAttributes: [
                        .documentType: NSAttributedString.DocumentType.html,
                        .characterEncoding: String.Encoding.utf8.rawValue,
                    ]) {
                    board.setData(data, forType: .html)
                }
            } else {
                super.copy(sender)
            }
        }

        // The VIEW's appearance, never the process: a theme forced in the
        // app is invisible to NSAppearance.currentDrawing().
        private var isDark: Bool {
            effectiveAppearance
                .bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }

        // Returns NSAttributedString, not String: the RTF flavour is
        // written from this and needs the run's bold and italic too.
        private static func spelled(
            _ slice: NSAttributedString
        ) -> NSAttributedString {
            let m = NSMutableAttributedString(attributedString: slice)
            let full = NSRange(location: 0, length: m.length)
            for range in Self.attachments(in: m, full).reversed() {
                let tex = m.attribute(atomicCopyKey, at: range.location,
                                      effectiveRange: nil) as? String
                var attrs = m.attributes(at: range.location,
                                         effectiveRange: nil)
                attrs.removeValue(forKey: .attachment)
                m.replaceCharacters(
                    in: range,
                    with: NSAttributedString(string: tex ?? "",
                                             attributes: attrs))
            }
            return m
        }

        private static func illustrated(_ slice: NSAttributedString,
                                        dark: Bool) -> NSAttributedString {
            let m = NSMutableAttributedString(attributedString: slice)
            let full = NSRange(location: 0, length: m.length)
            for range in Self.attachments(in: m, full).reversed() {
                let cell = (m.attribute(.attachment, at: range.location,
                                        effectiveRange: nil)
                            as? NSTextAttachment)?.attachmentCell
                if let math = cell as? PasteboardIllustration,
                   let pdf = math.pdf(dark: dark) {
                    m.replaceCharacters(
                        in: range,
                        with: NSAttributedString(
                            attachment: Self.illustration(pdf)))
                }
            }
            return m
        }

        // A pasteboard flavour covers the whole copy, so this fires
        // only when the selection IS exactly one formula, nothing else.
        private static func lonePDF(_ slice: NSAttributedString,
                                    dark: Bool) -> Data? {
            var result: Data? = nil
            let full = NSRange(location: 0, length: slice.length)
            let found = Self.attachments(in: slice, full)
            if found.count == 1 {
                let rest = (slice.string as NSString)
                    .replacingCharacters(in: found[0], with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let cell = (slice.attribute(.attachment,
                                            at: found[0].location,
                                            effectiveRange: nil)
                            as? NSTextAttachment)?.attachmentCell
                if rest.isEmpty,
                   let math = cell as? PasteboardIllustration {
                    result = math.pdf(dark: dark)
                }
            }
            return result
        }

        // A FileWrapper stores the PDF bytes verbatim; an NSImage-backed
        // attachment rasterizes them into a bitmap instead.
        private static func illustration(_ pdf: Data) -> NSTextAttachment {
            let wrapper = FileWrapper(regularFileWithContents: pdf)
            wrapper.preferredFilename = "formula.pdf"
            return NSTextAttachment(fileWrapper: wrapper)
        }

        private static func attachments(in m: NSAttributedString,
                                        _ full: NSRange) -> [NSRange] {
            var found: [NSRange] = []
            m.enumerateAttribute(.attachment, in: full,
                                 options: []) { value, range, _ in
                if value != nil { found.append(range) }
            }
            return found
        }

        override func layout() {
            super.layout()
            let resized = bounds.size != lastBounds
            if resized {
                lastBounds = bounds.size
                invalidateIntrinsicContentSize()
            }
            if resized || overlayGeneration != contentGeneration {
                overlayGeneration = contentGeneration
                computeCopySpots()
            }
        }

        // layout() may run inside a SwiftUI update, where setting
        // @State directly is illegal, so the report is dispatched async.
        private func computeCopySpots() {
            var spots: [CopyBlockSpot] = []
            if let lm = layoutManager, let tc = textContainer,
               let ts = textStorage {
                lm.ensureLayout(for: tc)
                let origin = textContainerOrigin
                let full = NSRange(location: 0, length: ts.length)
                var pos = 0
                while pos < ts.length {
                    var run = NSRange(location: 0, length: 0)
                    let id = ts.attribute(atomicIdKey, at: pos,
                                          longestEffectiveRange: &run,
                                          in: full) as? String
                    let copy = id == nil ? nil
                        : ts.attribute(atomicCopyKey, at: run.location,
                                       effectiveRange: nil) as? String
                    let kind = id == nil ? nil
                        : ts.attribute(atomicKindKey, at: run.location,
                                       effectiveRange: nil) as? String
                    let cell = (ts.attribute(.attachment,
                                            at: run.location,
                                            effectiveRange: nil)
                                as? NSTextAttachment)?.attachmentCell
                    let label = id == nil ? nil
                        : ts.attribute(atomicLabelKey, at: run.location,
                                       effectiveRange: nil) as? String
                    if let id, let copy {
                        let gr = lm.glyphRange(forCharacterRange: run,
                                               actualCharacterRange: nil)
                        let block = lm.boundingRect(forGlyphRange: gr,
                                                    in: tc)
                        let line = lm.lineFragmentUsedRect(
                            forGlyphAt: gr.location, effectiveRange: nil)
                        let table = kind == AtomicKind.table.rawValue
                            ? ((ts.attribute(.paragraphStyle,
                                             at: run.location,
                                             effectiveRange: nil)
                                as? NSParagraphStyle)?.textBlocks.first
                                as? NSTextTableBlock)?.table
                            : nil
                        let style = MarkdownStyle.current
                        let right: CGFloat
                        if kind == AtomicKind.math.rawValue {
                            right = lm.lineFragmentRect(
                                forGlyphAt: gr.location,
                                effectiveRange: nil).maxX
                        } else if let table {
                            right = lm.boundsRect(for: table,
                                                  glyphRange: gr).maxX
                        } else if kind == AtomicKind.code.rawValue {
                            right = codeBlockRects(
                                in: ts, layoutManager: lm, container: tc,
                                within: run, padding: style.codePadding,
                                trailing: style.blockSpacing)
                                .first?.maxX ?? block.maxX
                        } else {
                            right = block.maxX
                        }
                        let x = right + origin.x - copyButtonGutter
                        let y = line.minY + origin.y +
                                (line.height - 22) / 2
                        spots.append(CopyBlockSpot(
                            id: id,
                            rect: CGRect(x: x, y: y,
                                         width: 22, height: 22),
                            copy: copy,
                            label: label,
                            illustration:
                                cell as? PasteboardIllustration))
                    }
                    pos = max(NSMaxRange(run), pos + 1)
                }
            }
            if spots != lastSpots {
                lastSpots = spots
                let report = spots
                DispatchQueue.main.async { [weak self] in
                    self?.onCopySpots?(report)
                }
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
