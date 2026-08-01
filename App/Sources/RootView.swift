import SwiftUI

struct RootView: View {
  let service: any BrowseService & SearchService

  @AppStorage("recentForums") private var recentForumsStorage = ""
  @State private var query = ""
  @State private var path: [RootDestination] = []

  private var recentForums: [String] {
    recentForumsStorage
      .split(separator: "\n")
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  var body: some View {
    NavigationStack(path: $path) {
      List {
        Section {
          HStack(spacing: 10) {
            TextField("输入吧名或关键词", text: $query)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .submitLabel(.search)
              .onSubmit(search)
            Button(action: search) {
              Image(systemName: "magnifyingglass.circle.fill")
                .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("搜索贴吧和帖子")
            .help("搜索贴吧和帖子")
            Button(action: openForum) {
              Image(systemName: "arrow.right.circle.fill")
                .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("直接打开贴吧")
            .help("直接打开贴吧")
          }
        }

        if !recentForums.isEmpty {
          Section("最近访问") {
            ForEach(recentForums, id: \.self) { forum in
              Button {
                rememberAndOpen(forum)
              } label: {
                Label(forum, systemImage: "text.bubble")
              }
              .buttonStyle(.plain)
            }
            .onDelete(perform: removeRecentForums)
          }
        }
      }
      .listStyle(.insetGrouped)
      .navigationTitle("贴吧++")
      .navigationDestination(for: RootDestination.self) { destination in
        switch destination {
        case .forum(let forumName):
          ForumView(forumName: forumName, service: service)
        case .search(let query):
          SearchView(query: query, browseService: service, searchService: service)
        }
      }
    }
  }

  private func openForum() {
    rememberAndOpen(query)
  }

  private func search() {
    let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !searchQuery.isEmpty else { return }
    query = ""
    path.append(.search(searchQuery))
  }

  private func rememberAndOpen(_ rawName: String) {
    let forumName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !forumName.isEmpty else { return }
    var updated = recentForums.filter { $0.caseInsensitiveCompare(forumName) != .orderedSame }
    updated.insert(forumName, at: 0)
    recentForumsStorage = updated.prefix(12).joined(separator: "\n")
    query = ""
    path.append(.forum(forumName))
  }

  private func removeRecentForums(at offsets: IndexSet) {
    var updated = recentForums
    updated.remove(atOffsets: offsets)
    recentForumsStorage = updated.joined(separator: "\n")
  }
}

private enum RootDestination: Hashable {
  case forum(String)
  case search(String)
}
