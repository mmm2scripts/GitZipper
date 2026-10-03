import SwiftUI

struct RootView: View {
    @EnvironmentObject var gh: GH
    @State private var repo: Repo?
    @State private var file: TreeItem?
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            List(gh.repos, selection: $repo) { r in
                Label(r.full_name, systemImage: r.private ? "lock.fill" : "shippingbox").tag(r)
            }
            .overlay { if gh.repos.isEmpty { ContentUnavailableLike(text: gh.error ?? "Add a token in Settings") } }
            .navigationTitle("Repositories")
            .toolbar {
                ToolbarItem { Button { Task { await gh.loadRepos() } } label: { Image(systemName: "arrow.clockwise") } }
                ToolbarItem { Button { showSettings = true } label: { Image(systemName: "gearshape") } }
            }
        } content: {
            if let repo { BrowserView(repo: repo, file: $file).id(repo) }
            else { ContentUnavailableLike(text: "Select a repository") }
        } detail: {
            if let repo, let file { FileView(repo: repo, item: file).id(file.sha) }
            else { ContentUnavailableLike(text: "Select a file") }
        }
        .navigationSplitViewStyle(.balanced)
        .task(id: gh.token) { await gh.loadRepos() }
        .onAppear { if gh.token.isEmpty { showSettings = true } }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: repo) { _ in file = nil }
    }
}

struct ContentUnavailableLike: View {
    let text: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "chevron.left.forwardslash.chevron.right").font(.system(size: 44))
            Text(text).multilineTextAlignment(.center)
        }.foregroundStyle(.secondary).padding()
    }
}

struct SettingsView: View {
    @EnvironmentObject var gh: GH
    @Environment(\.dismiss) var dismiss
    @State private var t = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("Personal access token") {
                    SecureField("ghp_… or github_pat_…", text: $t)
                    Text("Needs repo scope (classic) or Contents: read & write (fine-grained). Stored in the iOS Keychain.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !gh.token.isEmpty {
                    Button("Remove saved token", role: .destructive) { gh.token = ""; t = "" }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { if !t.isEmpty { gh.token = t.trimmingCharacters(in: .whitespacesAndNewlines) }; dismiss() }
                }
            }
        }.presentationDetents([.medium])
    }
}
