import SwiftUI

struct FindBar: View {

    @ObservedObject var find: MarkdownFindController
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused(focused)
                .frame(maxWidth: 360)
                .onSubmit { find.findNext() }
            Text(countLabel)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(action: { find.findPrevious() }) {
                Image(systemName: "chevron.up")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(find.matchCount == 0)
            Button(action: { find.findNext() }) {
                Image(systemName: "chevron.down")
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(find.matchCount == 0)
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .task(id: query) { find.find(query) }
    }

    private var countLabel: String {
        var result = ""
        if !query.isEmpty {
            result = find.matchCount == 0 ? "0"
                : "\(find.currentMatch)/\(find.matchCount)"
        }
        return result
    }

}
