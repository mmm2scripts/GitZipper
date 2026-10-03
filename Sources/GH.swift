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
struct GHError: LocalizedError { let errorDescription: String?; var code = 0 }

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
            var hint = ""
            if h.statusCode == 404 { hint = " — check the token can access this repo (fine-grained tokens need Contents: read & write on it)" }
            throw GHError(errorDescription: "GitHub \(h.statusCode): \(m ?? "request failed")\(hint)", code: h.statusCode)
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

    /// Latest commit + tree of the default branch, or nil if the repo is empty.
    func head(_ r: Repo) async throws -> (commit: String, tree: String)? {
        do {
            let ref = try await obj("/repos/\(r.full_name)/git/ref/heads/\(r.default_branch)")
            let sha = (ref["object"] as? [String: Any])?["sha"] as? String ?? ""
            let c = try await obj("/repos/\(r.full_name)/git/commits/\(sha)")
            return (sha, (c["tree"] as? [String: Any])?["sha"] as? String ?? "")
        } catch let e as GHError where e.code == 404 || e.code == 409 {
            _ = try await obj("/repos/\(r.full_name)")   // throws a clear access error if the repo itself is unreachable
            return nil
        }
    }
    func tree(_ r: Repo) async throws -> [TreeItem] {
        guard let h = try await head(r) else { return [] }
        let d = try await call("/repos/\(r.full_name)/git/trees/\(h.tree)?recursive=1")
        struct T: Decodable { let tree: [TreeItem] }
        return try JSONDecoder().decode(T.self, from: d).tree.filter { $0.type == "blob" }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
    /// Read by blob SHA: no path-encoding issues, works for files up to 100 MB.
    func file(_ r: Repo, sha: String) async throws -> Data {
        try await call("/repos/\(r.full_name)/git/blobs/\(sha)", raw: true)
    }

    /// One commit for any mix of changes. Entry: path + ("content" | "sha" | NSNull for delete)
    func commit(_ r: Repo, _ entries: [[String: Any]], _ message: String) async throws {
        let base = "/repos/\(r.full_name)/git"
        var h = try await head(r)
        if h == nil {   // empty repo: GitHub only allows the Contents API to make the first commit
            _ = try await obj("/repos/\(r.full_name)/contents/README.md", "PUT",
                ["message": "Initialize repository", "content": Data("# \(r.full_name)\n".utf8).base64EncodedString(), "branch": r.default_branch])
            h = try await head(r)
        }
        guard let h else { throw GHError(errorDescription: "Could not read the repository head") }
        if entries.isEmpty { return }
        let tree = entries.map { e -> [String: Any] in var x = e; x["mode"] = "100644"; x["type"] = "blob"; return x }
        let t = try await obj("\(base)/trees", "POST", ["base_tree": h.tree, "tree": tree])
        let nc = try await obj("\(base)/commits", "POST", ["message": message, "tree": t["sha"] as Any, "parents": [h.commit]])
        _ = try await obj("\(base)/refs/heads/\(r.default_branch)", "PATCH", ["sha": nc["sha"] as Any])
    }
    func save(_ r: Repo, path: String, text: String) async throws {
        try await commit(r, [["path": path, "content": text]], "Update \(path) via GitZipper")
    }
    func delete(_ r: Repo, paths: [String]) async throws {
        try await commit(r, paths.map { ["path": $0, "sha": NSNull()] }, "Delete \(paths.count) file(s) via GitZipper")
    }
    func upload(_ r: Repo, files: [(String, Data)]) async throws {
        if try await head(r) == nil { try await commit(r, [], "") }
        var entries: [[String: Any]] = []
        for (p, d) in files {
            let b = try await obj("/repos/\(r.full_name)/git/blobs", "POST", ["content": d.base64EncodedString(), "encoding": "base64"])
            entries.append(["path": p, "sha": b["sha"] as Any])
        }
        try await commit(r, entries, "Upload \(files.count) file(s) via GitZipper")
    }
    func zipball(_ r: Repo) async throws -> Data {
        guard let h = try await head(r) else { throw GHError(errorDescription: "Repository is empty") }
        return try await call("/repos/\(r.full_name)/zipball/\(h.commit)")
    }

    // MARK: optional upload server
    @Published var serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? "" {
        didSet { UserDefaults.standard.set(serverURL, forKey: "serverURL") } }
    @Published var serverKey = UserDefaults.standard.string(forKey: "serverKey") ?? "" {
        didSet { UserDefaults.standard.set(serverKey, forKey: "serverKey") } }

    func serverUpload(_ r: Repo, zip: URL, dir: String) async throws {
        let base = serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var c = URLComponents(string: base + "/upload") else { throw GHError(errorDescription: "Invalid server URL") }
        c.queryItems = [.init(name: "repo", value: r.full_name), .init(name: "branch", value: r.default_branch),
                        .init(name: "path", value: dir.trimmingCharacters(in: CharacterSet(charactersIn: "/")))]
        guard let url = c.url else { throw GHError(errorDescription: "Invalid server URL") }
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 900
        req.setValue(token, forHTTPHeaderField: "X-GitHub-Token")
        if !serverKey.isEmpty { req.setValue(serverKey, forHTTPHeaderField: "X-Api-Key") }
        let (d, resp) = try await URLSession.shared.upload(for: req, fromFile: zip)
        if let h = resp as? HTTPURLResponse, h.statusCode >= 400 {
            let m = (try? JSONSerialization.jsonObject(with: d) as? [String: Any])?["error"] as? String
            throw GHError(errorDescription: "Server \(h.statusCode): \(m ?? "upload failed")")
        }
    }
}
