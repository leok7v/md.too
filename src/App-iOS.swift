import SwiftUI
import UIKit

@main struct App: SwiftUI.App {

    init() {
        TempPDFs.cleanOnLaunch()
    }

    var body: some Scene {
        WindowGroup {
            IOSDocumentRoot()
        }
    }

}

struct IOSDocumentRoot: View {

    @State private var url: URL?
    @State private var text: String = ""
    @State private var showPicker = false
    @State private var didAutoShowPicker = false

    var body: some View {
        Group {
            if let url {
                ContentView(text: text, fileURL: url, onClose: close)
            } else {
                empty
            }
        }
        .onOpenURL { load($0) }
        .fileImporter(
            isPresented: $showPicker,
            allowedContentTypes: MarkdownDocument.readableContentTypes
        ) { result in
            if case .success(let pickedURL) = result {
                load(pickedURL)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Pick a .md file to open")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !didAutoShowPicker {
                didAutoShowPicker = true
                showPicker = true
            }
        }
        .onTapGesture { showPicker = true }
    }

    private func load(_ pickedURL: URL) {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        if let read = try? String(contentsOf: pickedURL, encoding: .utf8) {
            url = pickedURL
            text = read
            showPicker = false
            didAutoShowPicker = true
        }
        if scoped { pickedURL.stopAccessingSecurityScopedResource() }
    }

    private func close() {
        url = nil
        text = ""
        if let filesAppURL = URL(string: "shareddocuments://") {
            UIApplication.shared.open(filesAppURL)
        }
    }

}
