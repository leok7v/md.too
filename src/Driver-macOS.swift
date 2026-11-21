import AppKit

#if DEBUG

private typealias WindowImageFunction = @convention(c)
    (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

private let windowImage: WindowImageFunction? = {
    dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage").map { symbol in
        unsafeBitCast(symbol, to: WindowImageFunction.self)
    }
}()

@MainActor
func platformWindowPNG() -> Data? {
    var result: Data? = nil
    let window = NSApp.windows.first(where: { w in
        w.isVisible && !(w is NSPanel)
    })
    if let window,
       let image = windowImage?(.null, 8, UInt32(window.windowNumber), 1) {
        result = NSBitmapImageRep(cgImage: image.takeRetainedValue())
            .representation(using: .png, properties: [:])
    }
    return result
}

@MainActor
func platformQuit() {
    NSApp.terminate(nil)
}

#endif
