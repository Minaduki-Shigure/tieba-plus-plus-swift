import Combine
import Foundation
import SwiftUI

struct RootView: View {
  let service:
    any BrowseService & SearchService & ForumPostSearchService & HotTopicService
      & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let accountVault: any AccountVault
  let accountService: any AccountService

  @State private var query = ""
  @State private var path: [RootDestination] = []
  @State private var showsAllSearchHistory = false
  @State private var searchHistoryAction: GlobalSearchHistoryAction?
  @StateObject private var favoritesViewModel: LocalFavoritesViewModel
  @StateObject private var globalSearchHistoryViewModel: GlobalSearchHistoryViewModel

  init(
    service: any BrowseService & SearchService & ForumPostSearchService & HotTopicService
      & UserProfileService & ForumInformationService,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository,
    globalSearchHistoryRepository: any GlobalSearchHistoryRepository,
    accountVault: any AccountVault,
    accountService: any AccountService
  ) {
    self.service = service
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    self.accountVault = accountVault
    self.accountService = accountService
    _favoritesViewModel = StateObject(
      wrappedValue: LocalFavoritesViewModel(repository: favoritesRepository)
    )
    _globalSearchHistoryViewModel = StateObject(
      wrappedValue: GlobalSearchHistoryViewModel(repository: globalSearchHistoryRepository)
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

        searchHistorySection

        if let errorMessage = globalSearchHistoryViewModel.errorMessage {
          Section("搜索记录错误") {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
            Button {
              Task { await globalSearchHistoryViewModel.retry() }
            } label: {
              Label("重试", systemImage: "arrow.clockwise")
            }
            Button(role: .destructive) {
              searchHistoryAction = .reset
            } label: {
              Label("重置搜索记录", systemImage: "trash")
            }
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
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository
          )
        case .search(let query):
          SearchView(
            query: query,
            browseService: service,
            searchService: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository,
            onSearchSubmitted: { globalSearchHistoryViewModel.record($0) }
          )
        case .hotTopics:
          HotTopicListView(
            service: service,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository
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
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository
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
    .task { await globalSearchHistoryViewModel.loadIfNeeded() }
    .onReceive(NotificationCenter.default.publisher(for: .localFavoritesDidChange)) { _ in
      Task { @MainActor in favoritesViewModel.reload() }
    }
    .confirmationDialog(
      searchHistoryActionTitle,
      isPresented: Binding(
        get: { searchHistoryAction != nil },
        set: { if !$0 { searchHistoryAction = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button(searchHistoryActionButtonTitle, role: .destructive) {
        let action = searchHistoryAction
        searchHistoryAction = nil
        Task {
          switch action {
          case .clear:
            await globalSearchHistoryViewModel.deleteAll()
          case .reset:
            await globalSearchHistoryViewModel.reset()
          case nil:
            break
          }
        }
      }
      Button("取消", role: .cancel) { searchHistoryAction = nil }
    } message: {
      Text(searchHistoryActionMessage)
    }
  }

  @ViewBuilder
  private var searchHistorySection: some View {
    if globalSearchHistoryViewModel.isLoading,
      globalSearchHistoryViewModel.entries.isEmpty
    {
      Section("最近搜索") {
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
      }
    } else if !globalSearchHistoryViewModel.entries.isEmpty {
      Section {
        ForEach(visibleSearchHistoryEntries) { entry in
          Button {
            search(for: entry.query)
          } label: {
            HStack(spacing: 10) {
              Image(systemName: "clock")
                .foregroundStyle(.secondary)
              Text(entry.query)
                .foregroundStyle(.primary)
                .lineLimit(1)
              Spacer(minLength: 8)
              Text(entry.searchedAt, style: .relative)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
              Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
        .onDelete(perform: deleteSearchHistory)

        if globalSearchHistoryViewModel.entries.count > 6 {
          Button {
            showsAllSearchHistory.toggle()
          } label: {
            Label(
              showsAllSearchHistory ? "收起" : "显示全部",
              systemImage: showsAllSearchHistory ? "chevron.up" : "chevron.down"
            )
          }
        }
      } header: {
        HStack {
          Text("最近搜索")
          Spacer()
          Button {
            searchHistoryAction = .clear
          } label: {
            Image(systemName: "trash")
              .frame(width: 32, height: 32)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel("清空搜索记录")
          .help("清空搜索记录")
        }
      }
    }
  }

  private var visibleSearchHistoryEntries: [GlobalSearchHistoryEntry] {
    if showsAllSearchHistory {
      return globalSearchHistoryViewModel.entries
    }
    return Array(globalSearchHistoryViewModel.entries.prefix(6))
  }

  private func deleteSearchHistory(at offsets: IndexSet) {
    let visibleEntries = visibleSearchHistoryEntries
    let ids = offsets.compactMap { index in
      visibleEntries.indices.contains(index)
        ? visibleEntries[index].id
        : nil
    }
    Task {
      for id in ids {
        await globalSearchHistoryViewModel.delete(id: id)
      }
    }
  }

  private var searchHistoryActionTitle: String {
    switch searchHistoryAction {
    case .clear:
      "清空全部搜索记录？"
    case .reset:
      "重置全部搜索记录？"
    case nil:
      "管理搜索记录"
    }
  }

  private var searchHistoryActionButtonTitle: String {
    switch searchHistoryAction {
    case .clear:
      "清空"
    case .reset:
      "重置"
    case nil:
      "确认"
    }
  }

  private var searchHistoryActionMessage: String {
    switch searchHistoryAction {
    case .clear:
      "只会删除保存在本机的全局搜索词。"
    case .reset:
      "这会删除保存在本机的全局搜索历史文件，用于恢复损坏或版本不兼容的数据。"
    case nil:
      ""
    }
  }

  private func openForum() {
    openForum(named: query)
  }

  private func search() {
    search(for: query)
  }

  private func search(for rawQuery: String) {
    let searchQuery = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !searchQuery.isEmpty else { return }
    globalSearchHistoryViewModel.record(searchQuery)
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

private enum GlobalSearchHistoryAction {
  case clear
  case reset
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
