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
    @State private var shareURL: URL?

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
                    if let u = shareURL { ShareLink(item: u) }
                    Menu {
                        Button { showNew = true } label: { Label("New file", systemImage: "doc.badge.plus") }
                        Button { importing = true } label: { Label("Upload ZIP", systemImage: "square.and.arrow.up") }
                        Button { run { shareURL = try await gh.zipball(repo) } } label: { Label("Download repo ZIP", systemImage: "arrow.down.circle") }
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
        let ok = url.startAccessingSecurityScopedResource(); defer { if ok { url.stopAccessingSecurityScopedResource() } }
        let archive = try Archive(url: url, accessMode: .read)
        var items: [(String, Data)] = []
        for e in archive where e.type == .file && !e.path.hasPrefix("__MACOSX") && !e.path.contains(".DS_Store") {
            var d = Data(); _ = try archive.extract(e) { d.append($0) }; items.append((e.path, d))
        }
        guard !items.isEmpty else { throw GHError(errorDescription: "The zip contains no files") }
        let roots = Set(items.map { $0.0.split(separator: "/").first.map(String.init) ?? "" })
        let strip = roots.count == 1 && items.allSatisfy { $0.0.contains("/") }
        items = items.map { (dir + (strip ? String($0.0.drop { $0 != "/" }.dropFirst()) : $0.0), $0.1) }
        try await gh.upload(repo, files: items)
    }
}
