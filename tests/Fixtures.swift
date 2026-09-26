import Foundation

// The documents the parser and the exporters are pinned against, cut
// into one fixture per `##` section so a golden diff names the section
// that moved. EXAMPLE.md is the feature tour.
enum Fixtures {

    struct Fixture {
        let name: String
        let markdown: String
    }

    static var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    static func all() throws -> [Fixture] {
        let example = root.deletingLastPathComponent()
            .appendingPathComponent("EXAMPLE.md")
        let edge = root.appendingPathComponent("fixtures")
            .appendingPathComponent("edge.md")
        var out: [Fixture] = []
        out += try sections(of: example, prefix: "example")
        out += try sections(of: edge, prefix: "edge")
        return out
    }

    // Split on `## ` headings that sit OUTSIDE a code fence, so a fence
    // that quotes markdown does not start a fixture of its own. The
    // fence that opened is the one that closes: a ``` inside a ~~~ body
    // is content.

    static func sections(of url: URL, prefix: String) throws -> [Fixture] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var result: [Fixture] = []
        var name = "\(prefix)-intro"
        var body: [String] = []
        var fence = ""
        var index = 0
        for line in text.split(separator: "\n",
                               omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let opener = String(trimmed.prefix(3))
            if fence.isEmpty, opener == "```" || opener == "~~~" {
                fence = opener
            } else if trimmed.hasPrefix(fence), !fence.isEmpty {
                fence = ""
            } else if fence.isEmpty, line.hasPrefix("## ") {
                result.append(Fixture(name: name,
                                      markdown: body.joined(separator: "\n")))
                index += 1
                let title = slug(String(line.dropFirst(3)))
                name = "\(prefix)-\(index)-\(title)"
                body = []
            }
            body.append(String(line))
        }
        result.append(Fixture(name: name,
                              markdown: body.joined(separator: "\n")))
        return result
    }

    private static func slug(_ s: String) -> String {
        var out = ""
        var dash = false
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                dash = false
            } else if !dash, !out.isEmpty {
                out.append("-")
                dash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(40))
    }

    // Reads the golden file next to the tests, or rewrites it when the
    // named environment variable is set. Returns the recorded text.

    static func golden(_ file: String, update env: String,
                       now: String) throws -> String {
        let url = root.appendingPathComponent(file)
        let updating = ProcessInfo.processInfo.environment[env] != nil
        if updating {
            try now.write(to: url, atomically: true, encoding: .utf8)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // The first dozen lines that differ, golden against now, for a
    // failure message a reader can act on wherever in the file the
    // drift sits.

    static func drift(golden: String, now: String) -> String {
        let was = golden.split(separator: "\n",
                               omittingEmptySubsequences: false)
        let is0 = now.split(separator: "\n",
                            omittingEmptySubsequences: false)
        var out: [String] = []
        let n = max(was.count, is0.count)
        var i = 0
        while i < n, out.count < 12 {
            let a = i < was.count ? String(was[i]) : "<missing>"
            let b = i < is0.count ? String(is0[i]) : "<missing>"
            if a != b {
                out.append("  line \(i + 1)\n  golden: \(a)\n  now:    \(b)")
            }
            i += 1
        }
        return out.joined(separator: "\n")
    }

}
