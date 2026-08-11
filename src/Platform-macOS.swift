import SwiftUI
import PDFKit
@_exported import AppKit

typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage

func monoFont(at size: CGFloat) -> PlatformFont {
    NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
}

func boldFont(of f: PlatformFont) -> PlatformFont {
    var traits = f.fontDescriptor.symbolicTraits
    traits.insert(.bold)
    let d = f.fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: d, size: f.pointSize) ?? f
}

func platformResizedFont(_ f: PlatformFont, to size: CGFloat) -> PlatformFont {
    var result = f
    if let r = NSFont(descriptor: f.fontDescriptor, size: size) {
        result = r
    }
    return result
}

func platformBoldItalicFont(of f: PlatformFont,
                            bold: Bool,
                            italic: Bool) -> PlatformFont {
    var traits = f.fontDescriptor.symbolicTraits
    if bold { traits.insert(.bold) }
    if italic { traits.insert(.italic) }
    let d = f.fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: d, size: f.pointSize) ?? f
}

func platformMergeFontTraits(of source: PlatformFont,
                             into base: PlatformFont,
                             additionalBold: Bool) -> PlatformFont {
    var traits = source.fontDescriptor.symbolicTraits
    traits.formUnion(base.fontDescriptor.symbolicTraits)
    if additionalBold { traits.insert(.bold) }
    let d = base.fontDescriptor.withSymbolicTraits(traits)
    return NSFont(descriptor: d, size: base.pointSize) ?? base
}

let platformDefaultTextColor: PlatformColor = NSColor.textColor
let platformSecondaryColor: PlatformColor = NSColor.secondaryLabelColor
let platformClearColor: PlatformColor = NSColor.clear

func platformWhite(_ white: CGFloat, alpha: CGFloat) -> PlatformColor {
    NSColor(white: white, alpha: alpha)
}

func platformAdaptiveColor(light: PlatformColor,
                            dark: PlatformColor) -> PlatformColor {
    NSColor(name: nil) { appearance in
        let darkMatches: [NSAppearance.Name] = [
            .darkAqua,
            .vibrantDark,
            .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastVibrantDark,
        ]
        let isDark = appearance.bestMatch(from: darkMatches) != nil
        return isDark ? dark : light
    }
}

func platformDecodeImage(_ data: Data) -> Image? {
    var result: Image? = nil
    if let ns = NSImage(data: data) { result = Image(nsImage: ns) }
    return result
}

func platformDocumentImage(_ data: Data) -> PlatformImage? {
    NSImage(data: data)
}

func platformDecodeCGImage(_ data: Data) -> CGImage? {
    NSImage(data: data)?
        .cgImage(forProposedRect: nil, context: nil, hints: nil)
}

func platformSetClipboardString(_ s: String) {
    platformSetClipboard(string: s, pdf: nil)
}

// The text always, and a PDF alongside it when the block has one. Both
// flavours on one board, so a plain editor takes the string and anything
// that draws takes the picture.
func platformSetClipboard(string: String, pdf: Data?) {
    let board = NSPasteboard.general
    board.clearContents()
    var types: [NSPasteboard.PasteboardType] = [.string]
    if pdf != nil { types.insert(.pdf, at: 0) }
    board.declareTypes(types, owner: nil)
    if let pdf { board.setData(pdf, forType: .pdf) }
    board.setString(string, forType: .string)
}

func platformPerformLightAppearance(_ body: () -> Void) {
    if let aqua = NSAppearance(named: .aqua) {
        aqua.performAsCurrentDrawingAppearance(body)
    } else {
        body()
    }
}

func platformPDFPageThumbnail(_ page: PDFPage, size: CGSize) -> Image {
    Image(nsImage: page.thumbnail(of: size, for: .cropBox))
}

var systemBackground: Color {
    return Color(nsColor: .textBackgroundColor)
}

nonisolated(unsafe) var pdfDataExporter: ((String, String) -> Data?)? = nil

final class CopyPdfProvider: NSObject, NSPasteboardItemDataProvider {

    static let shared = CopyPdfProvider()

    private var text: String = ""

    func set(text: String) { self.text = text }

    func pasteboard(_ pasteboard: NSPasteboard?,
                    item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        if type == .pdf,
           let exporter = pdfDataExporter,
           let data = exporter(text, "Document") {
            item.setData(data, forType: .pdf)
        }
    }

}

private func htmlToRtf(_ html: String) -> Data? {
    var result: Data? = nil
    if let data = html.data(using: .utf8),
       let attr = try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil) {
        result = try? attr.data(
            from: NSRange(location: 0, length: attr.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.rtf,
            ])
    }
    return result
}

func platformCopyMarkdown(plain: String, html: String, sourceText: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    let item = NSPasteboardItem()
    item.setString(plain, forType: .string)
    item.setString(html, forType: .html)
    if let rtf = htmlToRtf(html) { item.setData(rtf, forType: .rtf) }
    CopyPdfProvider.shared.set(text: sourceText)
    item.setDataProvider(CopyPdfProvider.shared, forTypes: [.pdf])
    pb.writeObjects([item])
}
