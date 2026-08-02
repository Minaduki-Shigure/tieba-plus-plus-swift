import Combine
import Foundation
import SwiftUI

struct RootView: View {
  let service:
    any BrowseService & SearchService & HotTopicService & UserProfileService
      & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let accountVault: any AccountVault
  let accountService: any AccountService

  @State private var query = ""
  @State private var path: [RootDestination] = []
  @StateObject private var favoritesViewModel: LocalFavoritesViewModel

  init(
    service: any BrowseService & SearchService & HotTopicService & UserProfileService
      & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    accountVault: any AccountVault,
    accountService: any AccountService
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.accountVault = accountVault
    self.accountService = accountService
    _favoritesViewModel = StateObject(
      wrappedValue: LocalFavoritesViewModel(repository: favoritesRepository)
    )
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
            .accessibilityLabel("搜索贴吧、帖子和用户")
            .help("搜索贴吧、帖子和用户")
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

        Section("\u{53d1}\u{73b0}") {
          NavigationLink(value: RootDestination.hotTopics) {
            Label("\u{70ed}\u{95e8}\u{8bdd}\u{9898}", systemImage: "flame.fill")
          }
        }

        if !favoritesViewModel.favoriteForums.isEmpty {
          Section("收藏的贴吧") {
            ForEach(Array(favoritesViewModel.favoriteForums.prefix(6)), id: \.name) { forum in
              Button {
                path.append(.forum(forum.name))
              } label: {
                HStack(spacing: 12) {
                  AvatarView(url: forum.avatarURL, name: forum.displayName, size: 36)
                  VStack(alignment: .leading, spacing: 2) {
                    Text(forum.displayName)
                      .foregroundStyle(.primary)
                    if forum.name != forum.displayName {
                      Text(forum.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                  }
                  Spacer(minLength: 0)
                  Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }

      }
      .listStyle(.insetGrouped)
      .navigationTitle("贴吧++")
      .toolbar {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
          Button {
            path.append(.account)
          } label: {
            Image(systemName: "person.crop.circle")
          }
          .accessibilityLabel("账户")
          .help("账户")

          Button {
            path.append(.favorites)
          } label: {
            Image(systemName: "bookmark")
          }
          .accessibilityLabel("本地收藏")
          .help("本地收藏")

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
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository
          )
        case .search(let query):
          SearchView(
            query: query,
            browseService: service,
            searchService: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository
          )
        case .hotTopics:
          HotTopicListView(
            service: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository
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
        case .favorites:
          LocalFavoritesView(repository: favoritesRepository) { target in
            switch target {
            case .forum(let forum):
              path.append(.forum(forum.name))
            case .thread(let thread):
              path.append(.thread(thread))
            }
          }
        case .account:
          AccountView(
            browseService: service,
            accountService: accountService,
            vault: accountVault,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository
          )
        case .thread(let thread):
          ThreadView(
            thread: thread.browseThread,
            service: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            historySnapshot: thread
          )
        }
      }
    }
    .onAppear { favoritesViewModel.reload() }
    .onReceive(NotificationCenter.default.publisher(for: .localFavoritesDidChange)) { _ in
      Task { @MainActor in favoritesViewModel.reload() }
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
  case hotTopics
  case history
  case favorites
  case account
  case thread(ThreadHistorySnapshot)
}
