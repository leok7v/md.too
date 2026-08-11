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

        // longestEffectiveRange, not effectiveRange: attribute runs
        // fragment at every cell's paragraph-style / tint boundary, so
        // the plain effective range of a table's atomic id is one cell,
        // not the table. The longest form coalesces equal values.
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
        let next = resolved()
        if let ts = v.textStorage, !ts.isEqual(to: next) {
            ts.beginEditing()
            applyIncremental(ts, next)
            ts.endEditing()
            v.invalidateIntrinsicContentSize()
            v.reapplyFind()
        }
    }

    final class ResizingTextView: NSTextView, FindableTextView {

        var nowrap: Bool = false
        weak var findController: MarkdownFindController?
        var onCopySpots: (([CopyBlockSpot]) -> Void)?
        private var lastBounds: NSSize = .zero
        private var lastSpots: [CopyBlockSpot] = []
        private var findMatches: [NSRange] = []
        private var activeIndex: Int? = nil
        private var findQuery = ""
        private var findCaseSensitive = false

        var liveFindCount: Int { findMatches.count }

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

        func setActive(_ index: Int?) {
            activeIndex = index
            highlightAll()
            let len = textStorage?.length ?? 0
            if let i = index, i >= 0, i < findMatches.count,
               NSMaxRange(findMatches[i]) <= len {
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
            if let i = activeIndex, i >= 0, i < findMatches.count,
               let lm = layoutManager, let tc = textContainer {
                let gr = lm.glyphRange(forCharacterRange: findMatches[i],
                                       actualCharacterRange: nil)
                let rect = lm.boundingRect(forGlyphRange: gr, in: tc)
                let used = lm.usedRect(for: tc)
                if used.height > 0 { result = rect.midY / used.height }
            }
            return result
        }

        // TEMPORARY attributes, not real .backgroundColor: they layer
        // over the text without mutating the storage, so code / table
        // backgrounds survive and the incremental splice diff is
        // undisturbed.
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

        // What a COPY carries. A display is a layout, not a run of
        // characters -- the fraction bar is a drawn rule and the radical a
        // stretched glyph assembly -- so no font and no rich text can spell
        // it, and the object-replacement character alone pastes as a gap.
        //
        // NSTextView does NOT route copy: through writeSelection(to:type:),
        // so the flavours are written here, where the command lands.
        // MEASURED with only that override in place: `clipboard info` showed
        // AppKit's defaults, 4 bytes of utf8 for the replacement character
        // and an RTFD with no picture in it.
        //
        // RTFD carries the picture and RTF carries the TeX, because plain
        // RTF CANNOT hold it: AppKit's RTF writer embeds nothing for an
        // image attachment (324 bytes, no \pict) while RTFD of the same
        // string is orders larger.

        override func copy(_ sender: Any?) {
            let picked = selectedRange()
            let store = picked.length > 0 ? textStorage : nil
            if let store {
                let slice = store.attributedSubstring(from: picked)
                let board = NSPasteboard.general
                board.clearContents()
                board.declareTypes([.rtfd, .rtf, .string], owner: nil)
                let rich = Self.illustrated(slice, dark: self.isDark)
                if let data = rich.rtfd(
                    from: NSRange(location: 0, length: rich.length),
                    documentAttributes: [:]) {
                    board.setData(data, forType: .rtfd)
                }
                let spelled = Self.spelled(slice)
                board.setString(spelled.string, forType: .string)
                if let data = spelled.rtf(
                    from: NSRange(location: 0, length: spelled.length),
                    documentAttributes: [:]) {
                    board.setData(data, forType: .rtf)
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

        // The selection with each display spelled out as the TeX it was
        // written from, in place of the object replacement character
        // that stands for it. The styling of the surrounding text is
        // kept, and the substituted TeX inherits the run it replaces
        // minus the attachment itself.
        //
        // Attributed rather than a bare String because RTF is written
        // from this too: RTF cannot carry the picture, but it can carry
        // bold and italic, and AppKit's own copy did. Flattening to a
        // plain String here dropped them from that flavour.
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

        // The same selection with every formula swapped for a picture of
        // itself, which is the only form a foreign document can render.
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

        // A FILE WRAPPER holding the PDF, not an NSImage made from it.
        // Both display the same, but AppKit serializes an image-backed
        // attachment by rasterizing it: the RTFD came out holding
        // Attachment.tiff, 570KB of bitmap for one small formula, and
        // logged a failed PNG encode on the way. A wrapper is stored
        // verbatim, so the bytes that arrive are the vector page that
        // was drawn -- 155KB instead of 717KB, same ink on screen.
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
            if bounds.size != lastBounds {
                lastBounds = bounds.size
                invalidateIntrinsicContentSize()
            }
            computeCopySpots()
        }

        // Walk MAXIMAL atomic runs (longestEffectiveRange; the plain
        // enumeration fragments at each cell's style boundary) and
        // report each copyable block's corner rect + source up to
        // SwiftUI, which overlays the actual Copy button there. The
        // report is async and deduped: layout() may run inside a
        // SwiftUI update, where setting @State directly is illegal.
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
                    if let id, let copy {
                        let gr = lm.glyphRange(forCharacterRange: run,
                                               actualCharacterRange: nil)
                        let block = lm.boundingRect(forGlyphRange: gr,
                                                    in: tc)
                        // Center the button on the FIRST line fragment,
                        // not the block's overall top: anchored to the
                        // block top the glyph reads as sitting on the
                        // first line's baseline (lower still for
                        // tables, whose first row sits below padding).
                        let line = lm.lineFragmentUsedRect(
                            forGlyphAt: gr.location, effectiveRange: nil)
                        // A code fence and a table start at the left
                        // margin, so a button set just inside their right
                        // edge lands in empty corner. A display is
                        // CENTRED, so that same inset lands on the
                        // formula -- it has to go out to the margin
                        // instead, which is where the eye looks for it
                        // anyway.
                        let right = kind == AtomicKind.math.rawValue
                            ? lm.lineFragmentRect(
                                forGlyphAt: gr.location,
                                effectiveRange: nil).maxX
                            : block.maxX
                        let x = right + origin.x - copyButtonGutter
                        let y = line.minY + origin.y +
                                (line.height - 22) / 2
                        spots.append(CopyBlockSpot(
                            id: id,
                            rect: CGRect(x: x, y: y,
                                         width: 22, height: 22),
                            copy: copy))
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
