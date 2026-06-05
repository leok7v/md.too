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

    static func fetchAndDecode<T>(in blocks: [Block],
                                  decode: (Data) -> T?)
        async -> [URL: T] {
        await fetch(collectURLs(in: blocks)).compactMapValues(decode)
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
