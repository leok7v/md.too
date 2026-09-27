import Foundation

func aspectFit(intrinsicWidth iw: CGFloat,
               intrinsicHeight ih: CGFloat,
               explicitWidth: CGFloat? = nil,
               explicitHeight: CGFloat? = nil,
               defaultScale: CGFloat = 1.0,
               maxWidth: CGFloat = .greatestFiniteMagnitude)
    -> (width: CGFloat, height: CGFloat) {
    var result: (width: CGFloat, height: CGFloat) = (0, 0)
    if iw > 0, ih > 0 {
        let aspect = iw / ih
        var w: CGFloat
        var h: CGFloat
        if let ew = explicitWidth, let eh = explicitHeight {
            w = ew; h = eh
        } else if let ew = explicitWidth {
            w = ew; h = ew / aspect
        } else if let eh = explicitHeight {
            h = eh; w = eh * aspect
        } else {
            w = min(maxWidth, iw * defaultScale); h = w / aspect
        }
        if w > maxWidth { w = maxWidth; h = w / aspect }
        result = (w, h)
    }
    return result
}

enum ImagePrefetch {

    static func collectURLs(in blocks: [Block]) -> Set<URL> {
        var urls: Set<URL> = []
        for b in blocks {
            switch b {
                case .image(_, let u, _, _): urls.insert(u)
                case .table(let headers, let rows, _):
                    for cell in headers + rows.joined() {
                        if let info = imageInCell(cell) {
                            urls.insert(info.0)
                        }
                    }
                case .quote(let inner):
                    urls.formUnion(collectURLs(in: inner))
                case .list(let items, _):
                    for item in items {
                        urls.formUnion(collectURLs(in: item.blocks))
                    }
                default: break
            }
        }
        return urls
    }

    static func imageInCell(_ cell: String)
        -> (URL, CGFloat?, CGFloat?)? {
        var result: (URL, CGFloat?, CGFloat?)? = nil
        let parsed = Markdown.parseCell(cell)
        if let first = parsed.first,
           case .image(_, let url, let width, let height) = first {
            result = (url, width, height)
        }
        return result
    }

    static func fetchAndDecode<T>(in blocks: [Block],
                                  decode: (Data) -> T?)
        async -> [URL: T] {
        await fetchAndDecode(collectURLs(in: blocks), decode: decode)
    }

    static func fetchAndDecode<T>(_ urls: Set<URL>,
                                  decode: (Data) -> T?)
        async -> [URL: T] {
        await fetch(urls).compactMapValues(decode)
    }

    static let byteLimit = 32 << 20
    static let timeout: TimeInterval = 20

    static func fetchable(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    static func fetch(_ urls: Set<URL>) async -> [URL: Data] {
        await withTaskGroup(of: (URL, Data?).self) { group in
            for u in urls where fetchable(u) {
                group.addTask { (u, await capped(u)) }
            }
            var result: [URL: Data] = [:]
            for await (u, d) in group { if let d { result[u] = d } }
            return result
        }
    }

    private static func capped(_ url: URL) async -> Data? {
        let agent = "Markdown.Preview/1.0" +
                    " (https://github.com/leok7v/md.too)"
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(agent, forHTTPHeaderField: "User-Agent")
        req.cachePolicy = .reloadRevalidatingCacheData
        var result: Data? = nil
        if let (bytes, response) = try? await URLSession.shared.bytes(
               for: req),
           response.expectedContentLength <= Int64(byteLimit) {
            var data = Data()
            let deadline = ContinuousClock.now + .seconds(timeout)
            do {
                var iterator = bytes.makeAsyncIterator()
                var byte = try await iterator.next()
                while let b = byte, data.count <= byteLimit,
                      ContinuousClock.now <= deadline {
                    data.append(b)
                    byte = try await iterator.next()
                }
                result = byte == nil ? data : nil
            } catch {
                result = nil
            }
        }
        return result
    }

}
