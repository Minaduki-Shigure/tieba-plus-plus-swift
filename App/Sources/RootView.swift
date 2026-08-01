import SwiftUI

struct RootView: View {
  let service: any BrowseService & SearchService
  let historyRepository: any BrowsingHistoryRepository

  @State private var query = ""
  @State private var path: [RootDestination] = []

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

      }
      .listStyle(.insetGrouped)
      .navigationTitle("贴吧++")
      .toolbar {
        ToolbarItem(placement: .navigationBarTrailing) {
          Button {
            path.append(.history)
          } label: {
            Image(systemName: "clock.arrow.circlepath")
          }
          .accessibilityLabel("浏览记录")
          .help("浏览记录")
        }
      }
      .navigationDestination(for: RootDestination.self) { destination in
        switch destination {
        case .forum(let forumName):
          ForumView(
            forumName: forumName,
            service: service,
            historyRepository: historyRepository
          )
        case .search(let query):
          SearchView(
            query: query,
            browseService: service,
            searchService: service,
            historyRepository: historyRepository
          )
        case .history:
          HistoryView(repository: historyRepository) { target in
            switch target {
            case .forum(let forum):
              path.append(.forum(forum.name))
            case .thread(let thread):
              path.append(.thread(thread))
            }
          }
        case .thread(let thread):
          ThreadView(
            thread: thread.browseThread,
            service: service,
            historyRepository: historyRepository,
            historySnapshot: thread
          )
        }
      }
    }
  }

  private func openForum() {
    openForum(named: query)
  }

  private func search() {
    let searchQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !searchQuery.isEmpty else { return }
    query = ""
    path.append(.search(searchQuery))
  }

  private func openForum(named rawName: String) {
    let forumName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !forumName.isEmpty else { return }
    query = ""
    path.append(.forum(forumName))
  }
}

private enum RootDestination: Hashable {
  case forum(String)
  case search(String)
  case history
  case thread(ThreadHistorySnapshot)
}
