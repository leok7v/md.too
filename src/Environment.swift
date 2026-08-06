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

// Text zoom as a multiplier of ours, NOT a dynamicTypeSize shift: AppKit
// has no content size category, so the environment value arrives and
// every size stays where it was. On iOS the system's own Dynamic Type
// still applies underneath and this multiplies on top of it.
//
// FontRole reads `current` straight from UserDefaults rather than being
// handed a scale, the way QuickLook reads themeMode: the alternative is
// threading a parameter through every block renderer and cell measurer
// for one app-wide preference. @AppStorage writes the same store, so the
// two always agree; the views take the notch as a parameter only so
// SwiftUI re-renders when it changes.

enum Zoom {

    static let key = "textZoom"
    static let limit = 2

    static func clamp(_ notch: Int) -> Int {
        min(max(notch, -limit), limit)
    }

    // A notch is a tenth: 0.8 to 1.2 across five stops. Far enough at
    // the ends to be worth reaching for, near enough that no layout has
    // to be redrawn to survive them.
    static func scale(_ notch: Int) -> CGFloat {
        1 + CGFloat(clamp(notch)) / 10
    }

    // The stop a free-running pinch lands on. Bounded before it is
    // converted: a two-finger fling reports a ratio of any size, and the
    // whole ladder spans 0.4.
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

