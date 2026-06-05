import Foundation
import CoreGraphics

enum TempPDFs {

    static let dirName = "Markdown.Preview-Exports"

    static var directory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(dirName, isDirectory: true)
    }

    static func cleanOnLaunch() {
        let dir = directory
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
    }
}

func prefetchDocumentImages(in blocks: [Block])
    async -> [URL: DocumentText.DocumentImage] {
    await ImagePrefetch.fetchAndDecode(in: blocks,
                                       decode: platformDocumentImage)
}

func exportPDFDataSync(text: String, title: String) -> Data? {
    let blocks = Markdown.parse(text)
    return PDFExport.data(blocks: blocks, title: title)
}

func exportPDF(text: String, title: String) async -> URL? {
    let blocks = Markdown.parse(text)
    let images = await PDFExport.prefetchImages(in: blocks)
    let safe = title
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: ":", with: "_")
    let dir = TempPDFs.directory
    try? FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    let temp = dir.appendingPathComponent("\(safe).pdf")
    try? FileManager.default.removeItem(at: temp)
    var result: URL? = nil
    do {
        try PDFExport.write(blocks: blocks,
                            to: temp,
                            title: title,
                            images: images)
        result = temp
    } catch {
        result = nil
    }
    return result
}

enum PDFExport {

    static func write(blocks: [Block],
                      to url: URL,
                       title: String,
                      images: [URL: CGImage] = [:]) throws {
        var thrown: Error?
        let body = {
            do {
                try writeImpl(blocks: blocks, to: url,
                              title: title, images: images)
            } catch {
                thrown = error
            }
        }
        platformPerformLightAppearance(body)
        if let e = thrown { throw e }
    }

    private static func writeImpl(blocks: [Block],
                                  to url: URL,
                                   title: String,
                                  images: [URL: CGImage]) throws {
        let pageSize = paperSize()
        var media = CGRect(origin: .zero, size: pageSize)
        if let consumer = CGDataConsumer(url: url as CFURL),
           let ctx = CGContext(consumer: consumer,
                               mediaBox: &media, nil) {
            let r = PDFRenderer(ctx: ctx, pageSize: pageSize,
                                title: title, images: images)
            r.startPage()
            for block in blocks { r.draw(block) }
            r.endPage()
            ctx.closePDF()
        } else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func prefetchImages(in blocks: [Block]) async -> [URL: CGImage] {
        await ImagePrefetch.fetchAndDecode(in: blocks,
                                           decode: platformDecodeCGImage)
    }

    static func data(blocks: [Block], title: String,
                     images: [URL: CGImage] = [:]) -> Data? {
        var result: Data? = nil
        let body = {
            let buffer = NSMutableData()
            let pageSize = paperSize()
            var media = CGRect(origin: .zero, size: pageSize)
            if let consumer = CGDataConsumer(data: buffer),
               let ctx = CGContext(consumer: consumer,
                                   mediaBox: &media, nil) {
                let r = PDFRenderer(ctx: ctx, pageSize: pageSize,
                                    title: title, images: images)
                r.startPage()
                for block in blocks { r.draw(block) }
                r.endPage()
                ctx.closePDF()
                result = buffer as Data
            }
        }
        platformPerformLightAppearance(body)
        return result
    }

    private static func paperSize() -> CGSize {
        let a4 = CGSize(width: 595, height: 842)
        let letter = CGSize(width: 612, height: 792)
        let letterRegions: Set<String> = [
            "US", "CA", "MX", "PH", "PR", "CL", "CO", "CR", "PA", "PE", "VE",
        ]
        let region = Locale.current.region?.identifier ?? ""
        return letterRegions.contains(region) ? letter : a4
    }

}
