import SwiftUI

#if DEBUG

@MainActor
final class Driver: ObservableObject {

    struct Outcome {
        let ok: Bool
        let detail: String
    }

    nonisolated static let script = through(quit: values(of: "--step"))
    nonisolated static let openURL = values(of: "--open").first.map { p in
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(p)
    }
    nonisolated static let folder = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "md.too")
        .appendingPathComponent("drive", isDirectory: true)
    private static let onOff = ["on": true, "off": false]
    private static let keys = ["themeMode", "singleSurface", Zoom.key,
                                ReadingColumn.key]
    private static let warmup = Duration.milliseconds(500)
    private static let settle = Duration.milliseconds(100)

    private static let session = (log: openLog(), saved: snapshot())
    private static var started = false

    private static func openLog() -> FileHandle? {
        let fm = FileManager.default
        let log = folder.appendingPathComponent("log.txt")
        try? fm.removeItem(at: folder)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        fm.createFile(atPath: log.path, contents: Data())
        return try? FileHandle(forWritingTo: log)
    }

    private static func snapshot() -> [String: Any] {
        keys.reduce(into: [:]) { kept, key in
            kept[key] = UserDefaults.standard.object(forKey: key)
        }
    }

    nonisolated static func values(of name: String) -> [String] {
        let argv = ProcessInfo.processInfo.arguments
        return argv.indices.dropLast().filter { i in argv[i] == name }
            .map { i in argv[i + 1] }
    }

    nonisolated static func through(quit steps: [String]) -> [String] {
        let end = steps.firstIndex(of: "quit").map { i in i + 1 }
        return Array(steps.prefix(end ?? steps.count))
    }

    func run(text: String, find: MarkdownFindController,
             source: Binding<Bool>,
             findBar: (String) -> Void) async {
        if !Driver.script.isEmpty, !Driver.started {
            Driver.started = true
            say("start \(Driver.script.count) steps")
            await pause(Driver.warmup)
            for (i, line) in Driver.script.enumerated() {
                let r = await execute(line, text: text, find: find,
                                      source: source, findBar: findBar)
                say("\(i + 1) \(line) \(r.ok ? "ok" : "fail") \(r.detail)")
                await pause(Driver.settle)
            }
            restore()
            await pause(Driver.settle)
            say("done")
            if Driver.script.last == "quit" { platformQuit() }
        }
    }

    private func restore() {
        for key in Driver.keys {
            UserDefaults.standard.set(Driver.session.saved[key], forKey: key)
        }
    }

    private func say(_ line: String) {
        let data = Data("[drive] \(line)\n".utf8)
        try? FileHandle.standardError.write(contentsOf: data)
        try? Driver.session.log?.write(contentsOf: data)
    }

    private func pause(_ length: Duration) async {
        await Task.yield()
        try? await Task.sleep(for: length)
    }

    private func execute(_ line: String, text: String,
                         find: MarkdownFindController,
                         source: Binding<Bool>,
                         findBar: (String) -> Void) async -> Outcome {
        let words = line.split(separator: " ", maxSplits: 1)
            .map { w in String(w) }
        let arg = words.count > 1 ? words[1] : ""
        switch words.first ?? "" {
            case "wait": return await wait(arg)
            case "find": return search(arg, find)
            case "next": return stepped(find, forward: true)
            case "prev": return stepped(find, forward: false)
            case "clear": return cleared(find)
            case "zoom": return zoomed(arg)
            case "theme": return themed(arg)
            case "source": return sourced(arg, source)
            case "surface": return flagged(arg, key: "singleSurface")
            case "column": return flagged(arg, key: ReadingColumn.key)
            case "scroll": return scrolled(arg, find)
            case "findbar": return await barred(arg, find, findBar)
            case "shot": return shot(arg)
            case "copy": return copied(text)
            case "quit": return Outcome(ok: true, detail: "")
            default: return Outcome(ok: false, detail: "unknown command")
        }
    }

    private func applied<T>(_ value: T?, to arg: String,
                            _ apply: (T) -> Void) -> Outcome {
        var result = Outcome(ok: false, detail: "bad argument '\(arg)'")
        if let value {
            apply(value)
            result = Outcome(ok: true, detail: arg)
        }
        return result
    }

    private func wait(_ arg: String) async -> Outcome {
        let ms = Int(arg)
        if let ms { await pause(.milliseconds(ms)) }
        return Outcome(ok: ms != nil, detail: arg)
    }

    private func matches(_ find: MarkdownFindController) -> Outcome {
        Outcome(ok: find.matchCount > 0,
                detail: "match \(find.currentMatch) of \(find.matchCount)")
    }

    private func search(_ query: String,
                        _ find: MarkdownFindController) -> Outcome {
        find.find(query)
        return matches(find)
    }

    private func stepped(_ find: MarkdownFindController,
                         forward: Bool) -> Outcome {
        if forward { find.findNext() } else { find.findPrevious() }
        return matches(find)
    }

    private func cleared(_ find: MarkdownFindController) -> Outcome {
        find.clear()
        return Outcome(ok: true, detail: "")
    }

    private func zoomed(_ arg: String) -> Outcome {
        applied(Int(arg).map { n in Zoom.clamp(n) }, to: arg) { notch in
            UserDefaults.standard.set(notch, forKey: Zoom.key)
        }
    }

    private func themed(_ arg: String) -> Outcome {
        applied(ThemeMode(rawValue: arg), to: arg) { mode in
            UserDefaults.standard.set(mode.rawValue, forKey: "themeMode")
        }
    }

    private func sourced(_ arg: String, _ source: Binding<Bool>) -> Outcome {
        applied(Driver.onOff[arg], to: arg) { on in
            source.wrappedValue = on
        }
    }

    private func flagged(_ arg: String, key: String) -> Outcome {
        applied(Driver.onOff[arg], to: arg) { on in
            UserDefaults.standard.set(on, forKey: key)
        }
    }

    private func scrolled(_ arg: String,
                          _ find: MarkdownFindController) -> Outcome {
        var result = Outcome(ok: false, detail: "cannot scroll '\(arg)'")
        if let hook = find.scrollTo, let fraction = Double(arg) {
            hook(CGFloat(fraction))
            result = Outcome(ok: true, detail: arg)
        }
        return result
    }

    private func barred(_ query: String, _ find: MarkdownFindController,
                        _ open: (String) -> Void) async -> Outcome {
        open(query)
        await pause(Driver.warmup)
        return search(query, find)
    }

    private func shot(_ name: String) -> Outcome {
        let file = Driver.folder.appendingPathComponent(
            URL(fileURLWithPath: name).lastPathComponent + ".png")
        var result = Outcome(ok: false, detail: "no window")
        if let png = platformWindowPNG() {
            let wrote = (try? png.write(to: file)) != nil
            result = Outcome(ok: wrote,
                             detail: "file=\(file.lastPathComponent) " +
                                     "bytes=\(png.count)")
        }
        return result
    }

    private func copied(_ text: String) -> Outcome {
        Outcome(ok: true,
                detail: "\(CopyDocButton.copyDocument(text)) characters")
    }

}

#else

@MainActor
final class Driver: ObservableObject {

    nonisolated static let openURL: URL? = nil

    func run(text: String, find: MarkdownFindController,
             source: Binding<Bool>,
             findBar: (String) -> Void) async {}

}

#endif
