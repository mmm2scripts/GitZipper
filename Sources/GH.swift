import Foundation
import Security

struct Repo: Identifiable, Decodable, Hashable {
    let id: Int
    let full_name: String
    let default_branch: String
    let `private`: Bool
}
struct TreeItem: Identifiable, Decodable, Hashable {
    let path: String, type: String, sha: String
    var id: String { path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}
struct GHError: LocalizedError { let errorDescription: String? }

enum Keychain {
    static func get() -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "token",
                                kSecReturnData as String: true]
        var r: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &r) == errSecSuccess, let d = r as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
    static func set(_ v: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: "token"]
        SecItemDelete(q as CFDictionary)
        if !v.isEmpty { var a = q; a[kSecValueData as String] = Data(v.utf8); SecItemAdd(a as CFDictionary, nil) }
    }
}

@MainActor final class GH: ObservableObject {
    @Published var token = Keychain.get() { didSet { Keychain.set(token) } }
    @Published var repos: [Repo] = []
    @Published var error: String?

    func call(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil, raw: Bool = false) async throws -> Data {
        var r = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        r.httpMethod = method
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue(raw ? "application/vnd.github.raw+json" : "application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (d, resp) = try await URLSession.shared.data(for: r)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            let m = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["message"] as? String
            throw GHError(errorDescription: "GitHub \(h.statusCode): \(m ?? "request failed")")
        }
        return d
    }
    func obj(_ path: String, _ method: String = "GET", _ body: [String: Any]? = nil) async throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: await call(path, method, body)) as? [String: Any] ?? [:]
    }

    func loadRepos() async {
        guard !token.isEmpty else { repos = []; return }
        var all: [Repo] = []
        do {
            for page in 1...10 {
                let d = try await call("/user/repos?per_page=100&sort=updated&page=\(page)")
                let batch = try JSONDecoder().decode([Repo].self, from: d)
                all += batch
                if batch.count < 100 { break }
            }
            repos = all; error = nil
        } catch { self.error = error.localizedDescription }
    }

    func tree(_ r: Repo) async throws -> [TreeItem] {
        let d = try await call("/repos/\(r.full_name)/git/trees/\(r.default_branch)?recursive=1")
        struct T: Decodable { let tree: [TreeItem] }
        return try JSONDecoder().decode(T.self, from: d).tree.filter { $0.type == "blob" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    func file(_ r: Repo, _ path: String) async throws -> Data {
        let p = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return try await call("/repos/\(r.full_name)/contents/\(p)?ref=\(r.default_branch)", raw: true)
    }

    /// One commit for any mix of changes. Entry: path + ("content" | "sha" | NSNull for delete)
    func commit(_ r: Repo, _ entries: [[String: Any]], _ message: String) async throws {
        let base = "/repos/\(r.full_name)/git"
        let ref = try await obj("\(base)/ref/heads/\(r.default_branch)")
        let head = (ref["object"] as! [String: Any])["sha"] as! String
        let c = try await obj("\(base)/commits/\(head)")
        let baseTree = (c["tree"] as! [String: Any])["sha"] as! String
        let tree = entries.map { e -> [String: Any] in
            var x = e; x["mode"] = "100644"; x["type"] = "blob"; return x
        }
        let t = try await obj("\(base)/trees", "POST", ["base_tree": baseTree, "tree": tree])
        let nc = try await obj("\(base)/commits", "POST", ["message": message, "tree": t["sha"] as Any, "parents": [head]])
        _ = try await obj("\(base)/refs/heads/\(r.default_branch)", "PATCH", ["sha": nc["sha"] as Any])
    }
    func save(_ r: Repo, path: String, text: String) async throws {
        try await commit(r, [["path": path, "content": text]], "Update \(path) via GitZipper")
    }
    func delete(_ r: Repo, paths: [String]) async throws {
        try await commit(r, paths.map { ["path": $0, "sha": NSNull()] }, "Delete \(paths.count) file(s) via GitZipper")
    }
    func upload(_ r: Repo, files: [(String, Data)]) async throws {
        var entries: [[String: Any]] = []
        for (p, d) in files {
            let b = try await obj("/repos/\(r.full_name)/git/blobs", "POST", ["content": d.base64EncodedString(), "encoding": "base64"])
            entries.append(["path": p, "sha": b["sha"] as Any])
        }
        try await commit(r, entries, "Upload \(files.count) file(s) via GitZipper")
    }
    func zipball(_ r: Repo) async throws -> Data {
        try await call("/repos/\(r.full_name)/zipball/\(r.default_branch)")
    }
}
