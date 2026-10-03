import SwiftUI
import UniformTypeIdentifiers
import ZIPFoundation

struct BrowserView: View {
    @EnvironmentObject var gh: GH
    let repo: Repo
    @Binding var file: TreeItem?

    @State private var tree: [TreeItem] = []
    @State private var dir = ""
    @State private var query = ""
    @State private var selecting = false
    @State private var selected = Set<String>()   // file paths or "folder/" prefixes
    @State private var busy = false
    @State private var msg: String?
    @State private var confirmDelete = false
    @State private var newName = ""
    @State private var showNew = false
    @State private var importing = false
    @State private var exportDoc: ZipDoc?
    @State private var exporting = false

    struct Row: Identifiable { let id: String; let name: String; let isDir: Bool; let item: TreeItem? }

    var rows: [Row] {
        if !query.isEmpty {
            return tree.filter { $0.path.localizedCaseInsensitiveContains(query) }.map { Row(id: $0.path, name: $0.path, isDir: false, item: $0) }
        }
        var dirs = Set<String>(); var files: [Row] = []
        for t in tree where t.path.hasPrefix(dir) {
            let rest = t.path.dropFirst(dir.count)
            if let i = rest.firstIndex(of: "/") { dirs.insert(String(rest[..<i])) }
            else { files.append(Row(id: t.path, name: t.name, isDir: false, item: t)) }
        }
        return dirs.sorted().map { Row(id: dir + $0 + "/", name: $0, isDir: true, item: nil) } + files
    }
    func expand() -> [String] {
        tree.map(\.path).filter { p in selected.contains { $0.hasSuffix("/") ? p.hasPrefix($0) : p == $0 } }
    }

    var body: some View {
        List(rows) { row in
            Button {
                if selecting { if !selected.insert(row.id).inserted { selected.remove(row.id) } }
                else if row.isDir { dir = row.id }
                else { file = row.item }
            } label: {
                HStack {
                    if selecting { Image(systemName: selected.contains(row.id) ? "checkmark.circle.fill" : "circle") }
                    Image(systemName: row.isDir ? "folder.fill" : icon(row.name))
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if row.isDir && !selecting { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .listRowBackground(file?.path == row.id ? Color.white.opacity(0.15) : nil)
        }
        .searchable(text: $query, prompt: "Search files")
        .navigationTitle(dir.isEmpty ? repo.full_name : String(dir.dropLast()))
        .navigationBarTitleDisplayMode(.inline)
        .overlay { if busy { ProgressView().controlSize(.large).padding(30).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                if !dir.isEmpty && query.isEmpty {
                    Button { dir = String(dir.dropLast().split(separator: "/").dropLast().joined(separator: "/")); if !dir.isEmpty { dir += "/" } } label: { Image(systemName: "chevron.up") }
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if selecting {
                    Button("All") { selected = Set(rows.map(\.id)) }
                    Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }.disabled(selected.isEmpty)
                    Button("Done") { selecting = false; selected = [] }
                } else {
                    Menu {
                        Button { showNew = true } label: { Label("New file", systemImage: "doc.badge.plus") }
                        Button { importing = true } label: { Label("Upload ZIP", systemImage: "square.and.arrow.up") }
                        Button { run { exportDoc = ZipDoc(data: try await gh.zipball(repo)); exporting = true } } label: { Label("Download repo ZIP", systemImage: "arrow.down.circle") }
                        Button { selecting = true } label: { Label("Select & delete", systemImage: "checkmark.circle") }
                        Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            ToolbarItem(placement: .bottomBar) {
                Text("\(tree.count) files · \(repo.default_branch)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await reload() }
        .alert("Delete \(expand().count) file(s)?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let p = expand()
                run { try await gh.delete(repo, paths: p); selected = []; selecting = false; if let f = file, p.contains(f.path) { file = nil } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This is one commit, so it can be reverted from GitHub history.") }
        .alert("New file", isPresented: $showNew) {
            TextField("name.txt", text: $newName)
            Button("Create") {
                let p = dir + newName; newName = ""
                run { try await gh.save(repo, path: p, text: "") }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Created in /\(dir)") }
        .alert("GitZipper", isPresented: Binding(get: { msg != nil }, set: { if !$0 { msg = nil } })) { Button("OK") {} } message: { Text(msg ?? "") }
        .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .zip,
                      defaultFilename: repo.full_name.replacingOccurrences(of: "/", with: "-")) { res in
            if case .failure(let e) = res { msg = e.localizedDescription }
            exportDoc = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { res in
            guard case .success(let url) = res else { return }
            run { try await uploadZip(url) }
        }
    }

    func icon(_ n: String) -> String {
        switch (n as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic": return "photo"
        case "md", "txt": return "doc.text"
        case "swift", "js", "ts", "py", "json", "yml", "yaml", "html", "css", "sh": return "curlybraces"
        default: return "doc"
        }
    }
    func reload() async {
        do { tree = try await gh.tree(repo) } catch { msg = error.localizedDescription }
    }
    func run(_ work: @escaping () async throws -> Void) {
        busy = true
        Task {
            do { try await work(); await reload() } catch { msg = error.localizedDescription }
            busy = false
        }
    }
    func uploadZip(_ url: URL) async throws {
        // copy out of the security-scoped location first
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".zip")
        try FileManager.default.copyItem(at: url, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        if !gh.serverURL.isEmpty { try await gh.serverUpload(repo, zip: tmp, dir: dir); return }

        guard let archive = try? Archive(url: tmp, accessMode: .read) else {
            throw GHError(errorDescription: "Not a valid zip archive")
        }
        var items: [(path: String, data: Data)] = []
        for e in archive {
            guard e.type == .file else { continue }
            let path = e.path
            if path.hasPrefix("__MACOSX/") || path.hasSuffix(".DS_Store") { continue }
            var d = Data()
            _ = try archive.extract(e) { chunk in d.append(chunk) }
            items.append((path, d))
        }
        guard !items.isEmpty else { throw GHError(errorDescription: "The zip contains no files") }

        // strip a single top-level folder
        let roots = Set(items.map { String($0.path.split(separator: "/").first ?? "") })
        let strip = roots.count == 1 && items.allSatisfy { $0.path.contains("/") }
        let prefix = dir
        let final: [(String, Data)] = items.map { item in
            var rel = item.path
            if strip, let slash = rel.firstIndex(of: "/") { rel = String(rel[rel.index(after: slash)...]) }
            return (prefix + rel, item.data)
        }
        try await gh.upload(repo, files: final)
    }
}

struct ZipDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
