import UIKit

#if DEBUG

@MainActor
func platformWindowPNG() -> Data? {
    let scene = UIApplication.shared.connectedScenes
        .compactMap { s in s as? UIWindowScene }.first
    let window = scene?.windows.first(where: { w in w.isKeyWindow }) ??
                 scene?.windows.first
    return window.map { w in
        UIGraphicsImageRenderer(bounds: w.bounds).pngData { _ in
            w.drawHierarchy(in: w.bounds, afterScreenUpdates: true)
        }
    }
}

@MainActor
func platformQuit() {
    exit(0)
}

#endif
