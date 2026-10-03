import SwiftUI

struct FileView: View {
    @EnvironmentObject var gh: GH
    let repo: Repo
    let item: TreeItem

    enum Kind { case loading, text(String), image(UIImage), binary(Int) }
    @State private var kind = Kind.loading
    @State private var text = ""
    @State private var original = ""
    @State private var editing = false
    @State private var busy = false
    @State private var error: String?
    @State private var fontSize: CGFloat = 14

    var dirty: Bool { text != original }
    var isMarkdown: Bool { item.path.lowercased().hasSuffix(".md") }

    var body: some View {
        Group {
            switch kind {
            case .loading: ProgressView()
            case .image(let img):
                ScrollView([.horizontal, .vertical]) { Image(uiImage: img).resizable().scaledToFit().padding() }
            case .binary(let n): ContentUnavailableLike(text: "Binary file · \(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file))")
            case .text:
                if editing {
                    TextEditor(text: $text).font(.system(size: fontSize, design: .monospaced))
                        .scrollContentBackground(.hidden).autocorrectionDisabled().textInputAutocapitalization(.never).padding(8)
                } else if isMarkdown, let a = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                    ScrollView { Text(a).font(.system(size: fontSize + 2)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }
                } else { codePreview }
            }
        }
        .background(Color.black)
        .navigationTitle(item.name + (dirty ? " •" : ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .text = kind {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { fontSize = max(10, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                    Button { fontSize = min(28, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                    if editing {
                        Button("Save") { Task { await save() } }.disabled(!dirty || busy).fontWeight(.bold)
                        Button("Cancel") { text = original; editing = false }
                    } else {
                        Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        ShareLink(item: text)
                    }
                }
            }
        }
        .alert("Error", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("OK") {} } message: { Text(error ?? "") }
        .task { await load() }
    }

    var codePreview: some View {
        let lines = text.components(separatedBy: "\n")
        return ScrollView([.vertical, .horizontal]) {
            HStack(alignment: .top, spacing: 12) {
                Text((1...max(lines.count, 1)).map(String.init).joined(separator: "\n"))
                    .foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                Text(text).textSelection(.enabled)
            }
            .font(.system(size: fontSize, design: .monospaced)).padding()
        }
    }

    func load() async {
        do {
            let d = try await gh.file(repo, sha: item.sha)
            if let img = UIImage(data: d) { kind = .image(img) }
            else if let s = String(data: d, encoding: .utf8) { text = s; original = s; kind = .text(s) }
            else { kind = .binary(d.count) }
        } catch { self.error = error.localizedDescription; kind = .binary(0) }
    }
    func save() async {
        busy = true; defer { busy = false }
        do { try await gh.save(repo, path: item.path, text: text); original = text; editing = false }
        catch { self.error = error.localizedDescription }
    }
}
