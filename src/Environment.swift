import SwiftUI

struct SizedImage {
    let image: Image
    let size: CGSize
}

struct PrefetchedImagesKey: EnvironmentKey {
    static let defaultValue: [URL: SizedImage] = [:]
}

extension EnvironmentValues {
    var prefetchedImages: [URL: SizedImage] {
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

// A UserDefaults read is invisible to SwiftUI; the scale flows through
// the environment instead so a text view re-renders when it changes.
struct TextZoomKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var textZoom: CGFloat {
        get { self[TextZoomKey.self] }
        set { self[TextZoomKey.self] = newValue }
    }
}

// A multiplier, not a dynamicTypeSize shift: AppKit has no content size
// category for the environment value to move.

enum Zoom {

    static let key = "textZoom"
    static let limit = 2

    static func clamp(_ notch: Int) -> Int {
        min(max(notch, -limit), limit)
    }

    static func scale(_ notch: Int) -> CGFloat {
        1 + CGFloat(clamp(notch)) / 10
    }

    // Clamped before conversion: a pinch can report a ratio of any size,
    // and the whole notch ladder spans only 0.4.
    static func notch(nearest scale: CGFloat) -> Int {
        clamp(Int(((min(max(scale, 0.5), 2) - 1) * 10).rounded()))
    }

    static var current: CGFloat {
        scale(UserDefaults.standard.integer(forKey: key))
    }

    static func percent(_ notch: Int) -> String {
        "\(Int(scale(notch) * 100))%"
    }

}

enum ReadingColumn {
    static let key = "readingColumn"
}

enum ThemeMode: String, CaseIterable {

    case system, light, dark

    init(raw: String) {
        self = ThemeMode(rawValue: raw) ?? .system
    }

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

