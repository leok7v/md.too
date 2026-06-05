import SwiftUI
import UniformTypeIdentifiers

struct MarkdownDocument: FileDocument {

    static let readableContentTypes: [UTType] = {
        var t: [UTType] = []
        if let x = UTType(filenameExtension: "md") { t.append(x) }
        if let x = UTType(filenameExtension: "markdown") { t.append(x) }
        if let x = UTType(filenameExtension: "mdown") { t.append(x) }
        if let x = UTType(filenameExtension: "mkd") { t.append(x) }
        if let x = UTType("net.daringfireball.markdown") { t.append(x) }
        if let x = UTType("public.markdown") { t.append(x) }
        if t.isEmpty { t = [.plainText] }
        return t
    }()

    static let writableContentTypes: [UTType] = []

    var text: String = ""

    init() {}

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents,
           let str = String(data: data, encoding: .utf8) {
            text = str
        } else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }

}
