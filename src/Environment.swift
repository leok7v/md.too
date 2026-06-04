import SwiftUI

struct PrefetchedImagesKey: EnvironmentKey {
    static let defaultValue: [URL: Image] = [:]
}

extension EnvironmentValues {
    var prefetchedImages: [URL: Image] {
        get { self[PrefetchedImagesKey.self] }
        set { self[PrefetchedImagesKey.self] = newValue }
    }
}

struct SecondaryTextKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var secondaryText: Bool {
        get { self[SecondaryTextKey.self] }
        set { self[SecondaryTextKey.self] = newValue }
    }
}

enum ThemeMode: String, CaseIterable {

    case system, light, dark

    var colorScheme: ColorScheme? {
        switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
        }
    }

    var symbol: String {
        switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max.fill"
            case .dark: return "moon.fill"
        }
    }

    var help: String {
        switch self {
            case .system: return "Theme: System (click for Light)"
            case .light: return "Theme: Light (click for Dark)"
            case .dark: return "Theme: Dark (click for System)"
        }
    }

    var next: ThemeMode {
        switch self {
            case .system: return .light
            case .light: return .dark
            case .dark: return .system
        }
    }

}

struct ThemeButton: View {

    let theme: ThemeMode
    let onCycle: () -> Void

    var body: some View {
        Button(action: onCycle) {
            Image(systemName: theme.symbol)
        }
        .help(theme.help)
    }

}

struct SourceButton: View {

    let showingSource: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Image(systemName: showingSource ? "doc.richtext" : "doc.plaintext")
        }
        .help(showingSource ? "View rendered" : "View source")
    }

}

enum ImagePrefetch {

    static func collectURLs(in blocks: [Block]) -> Set<URL> {
        var urls: Set<URL> = []
        for b in blocks {
            switch b {
                case .image(_, let u, _, _): urls.insert(u)
                case .table(_, let rows):
                    for row in rows {
                        for cell in row {
                            if let info = imageInCell(cell) {
                                urls.insert(info.0)
                            }
                        }
                    }
                default: break
            }
        }
        return urls
    }

    static func imageInCell(_ cell: String)
        -> (URL, CGFloat?, CGFloat?)? {
        var result: (URL, CGFloat?, CGFloat?)? = nil
        let parsed = Markdown.parse(cell)
        if let first = parsed.first,
           case .image(_, let url, let width, let height) = first {
            result = (url, width, height)
        }
        return result
    }

    static func fetch(_ urls: Set<URL>) async -> [URL: Data] {
        let agent = "Markdown.Preview/1.0" +
                    " (https://github.com/leok7v/md.too)"
        return await withTaskGroup(of: (URL, Data?).self) { group in
            for u in urls {
                group.addTask {
                    var req = URLRequest(url: u)
                    req.setValue(agent, forHTTPHeaderField: "User-Agent")
                    let data = try? await URLSession.shared
                        .data(for: req).0
                    return (u, data)
                }
            }
            var result: [URL: Data] = [:]
            for await (u, d) in group { if let d { result[u] = d } }
            return result
        }
    }

}
