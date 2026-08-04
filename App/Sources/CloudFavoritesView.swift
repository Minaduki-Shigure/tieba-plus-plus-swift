import Combine
import Foundation
import SwiftUI

@MainActor
final class CloudFavoritesViewModel: ObservableObject {
  @Published private(set) var threads: [CloudFavoriteThread] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?

  private let service: any AccountService
  private let vault: any AccountVault
  private let pageSize: Int
  private var nextOffset: Int? = 0
  private var hasMore = true
  private var loadedLease: CloudFavoritesSessionLease?
  private var loadTask: Task<Void, Never>?
  private var epoch = 0

  init(
    service: any AccountService,
    vault: any AccountVault,
    pageSize: Int = 30
  ) {
    self.service = service
    self.vault = vault
    self.pageSize = min(max(pageSize, 1), 100)
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    beginNewEpoch(loadImmediately: true)
  }

  func refresh() async {
    reload()
    let task = loadTask
    await task?.value
  }

  func accountSessionDidChange() {
    // Remove the previous account's data before starting the replacement request.
    beginNewEpoch(loadImmediately: true)
  }

  func loadMoreIfNeeded(current thread: CloudFavoriteThread) {
    guard
      thread.id == threads.last?.id,
      let offset = nextOffset,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    load(offset: offset, replacing: false)
  }

  func retryLoadMore() {
    guard
      let offset = nextOffset,
      hasMore,
      loadMoreError != nil,
      !isLoadingMore
    else { return }
    load(offset: offset, replacing: false)
  }

  func cancel() {
    invalidateTask()
    isLoadingMore = false
    if state == .loading {
      state = threads.isEmpty ? .idle : .loaded
    }
  }

  private func beginNewEpoch(loadImmediately: Bool) {
    invalidateTask()
    nextOffset = 0
    hasMore = true
    loadedLease = nil
    threads = []
    loadMoreError = nil
    isLoadingMore = false
    state = loadImmediately ? .loading : .idle
    if loadImmediately {
      load(offset: 0, replacing: true)
    }
  }

  private func load(offset: Int, replacing: Bool) {
    guard offset >= 0 else { return }
    let service = service
    let vault = vault
    let pageSize = pageSize
    epoch &+= 1
    let requestEpoch = epoch
    if !replacing {
      isLoadingMore = true
      loadMoreError = nil
    }

    loadTask = Task {
      defer {
        if requestEpoch == epoch {
          isLoadingMore = false
          loadTask = nil
        }
      }
      do {
        guard let sessionBeforeRequest = try await vault.activeSession() else {
          throw BrowseError.unavailable("请先登录账户。")
        }
        let lease = CloudFavoritesSessionLease(sessionBeforeRequest)
        guard replacing || loadedLease == lease else {
          discardResultsFromChangedSession(requestEpoch: requestEpoch)
          return
        }
        try Task.checkCancellation()
        let response = try await service.cloudFavorites(
          session: sessionBeforeRequest,
          offset: offset,
          pageSize: pageSize
        )
        try Task.checkCancellation()
        let sessionAfterRequest = try await vault.activeSession()
        try Task.checkCancellation()
        guard requestEpoch == epoch else { return }
        guard let sessionAfterRequest, lease.matches(sessionAfterRequest) else {
          discardResultsFromChangedSession(requestEpoch: requestEpoch)
          return
        }
        try Self.validate(response, lease: lease, requestedOffset: offset)

        let previousCount = replacing ? 0 : threads.count
        let merged = Self.merge(replacing ? [] : threads, response.items)
        let canContinue = response.hasMore && !response.items.isEmpty
        let madeProgress = merged.count > previousCount
        loadedLease = lease
        threads = merged
        hasMore = canContinue
        nextOffset = canContinue ? response.nextOffset : nil
        if !replacing, canContinue, !madeProgress {
          loadMoreError = "云端收藏列表已发生变化，请继续加载。"
        }
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard requestEpoch == epoch, !Task.isCancelled else { return }
        if replacing {
          state = .failed(error.localizedDescription)
        } else {
          loadMoreError = error.localizedDescription
        }
      }
    }
  }

  private func discardResultsFromChangedSession(requestEpoch: Int) {
    guard requestEpoch == epoch else { return }
    invalidateTask()
    nextOffset = 0
    hasMore = true
    loadedLease = nil
    threads = []
    loadMoreError = nil
    isLoadingMore = false
    state = .idle
  }

  private func invalidateTask() {
    epoch &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private static func merge(
    _ existing: [CloudFavoriteThread],
    _ newItems: [CloudFavoriteThread]
  ) -> [CloudFavoriteThread] {
    var result = existing
    var indexes: [Int64: Int] = [:]
    for index in existing.indices {
      indexes[existing[index].id] = index
    }
    for item in newItems {
      if let index = indexes[item.id] {
        result[index] = item
      } else {
        indexes[item.id] = result.endIndex
        result.append(item)
      }
    }
    return result
  }

  private static func validate(
    _ page: CloudFavoritePage,
    lease: CloudFavoritesSessionLease,
    requestedOffset: Int
  ) throws {
    guard page.userID == lease.userID else {
      throw BrowseError.unavailable("贴吧返回了不匹配的账户收藏，请重新加载后再试。")
    }
    guard page.items.allSatisfy(Self.isValid) else {
      throw BrowseError.unavailable("贴吧返回了异常的收藏数据，请重新加载后再试。")
    }
    if page.hasMore, !page.items.isEmpty {
      guard let nextOffset = page.nextOffset, nextOffset > requestedOffset else {
        throw BrowseError.unavailable("贴吧返回了异常的收藏分页位置，请重新加载后再试。")
      }
    }
  }

  private static func isValid(_ item: CloudFavoriteThread) -> Bool {
    guard item.id > 0 else { return false }
    if let markPostID = item.markPostID, markPostID <= 0 { return false }
    if let latestPostID = item.latestPostID, latestPostID <= 0 { return false }
    if let latestFloor = item.latestFloor, latestFloor <= 0 { return false }
    if item.hasUpdates, item.latestFloor == nil { return false }
    return true
  }
}

private struct CloudFavoritesSessionLease: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }

  func matches(_ session: StoredAccountSession) -> Bool {
    userID == session.id && sessionRevision == session.sessionRevision
  }
}

struct CloudFavoritesView: View {
  let browseService:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @StateObject private var viewModel: CloudFavoritesViewModel

  init(
    browseService: any BrowseService & ForumPostSearchService & UserProfileService
      & ForumInformationService,
    accountService: any AccountService,
    vault: any AccountVault,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.browseService = browseService
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _viewModel = StateObject(
      wrappedValue: CloudFavoritesViewModel(service: accountService, vault: vault)
    )
  }

  var body: some View {
    Group {
      if viewModel.threads.isEmpty {
        switch viewModel.state {
        case .idle, .loading:
          ProgressView()
        case .failed(let message):
          ErrorStateView(message: message, retry: viewModel.reload)
        case .loaded:
          EmptyStateView(title: "暂无贴吧收藏", systemImage: "bookmark")
        }
      } else {
        favoriteList
      }
    }
    .navigationTitle("贴吧收藏")
    .navigationBarTitleDisplayMode(.inline)
    .task { viewModel.loadIfNeeded() }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      viewModel.accountSessionDidChange()
    }
    .onDisappear(perform: viewModel.cancel)
  }

  private var favoriteList: some View {
    List {
      ForEach(viewModel.threads) { thread in
        NavigationLink {
          let route = thread.threadRoute
          ThreadView(
            thread: route.placeholderThread,
            service: browseService,
            historyRepository: historyRepository,
            favoritesRepository: favoritesRepository,
            searchHistoryRepository: searchHistoryRepository,
            linkRoute: route
          )
        } label: {
          CloudFavoriteThreadRow(thread: thread)
        }
        .onAppear { viewModel.loadMoreIfNeeded(current: thread) }
      }

      if viewModel.isLoadingMore {
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
        .listRowSeparator(.hidden)
      } else if let message = viewModel.loadMoreError {
        LoadMoreErrorView(message: message, retry: viewModel.retryLoadMore)
          .listRowSeparator(.hidden)
      }
    }
    .listStyle(.plain)
    .refreshable { await viewModel.refresh() }
  }
}

private struct CloudFavoriteThreadRow: View {
  let thread: CloudFavoriteThread

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(displayTitle)
          .font(.headline)
          .foregroundStyle(thread.isDeleted ? Color.secondary : Color.primary)
          .lineLimit(2)
        Spacer(minLength: 0)
        if thread.isDeleted {
          Label("已删除", systemImage: "trash")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if !thread.forumName.isEmpty || !thread.authorName.isEmpty {
        HStack(spacing: 8) {
          if !thread.forumName.isEmpty {
            Text("\(thread.forumName)吧")
          }
          if !thread.authorName.isEmpty {
            Text(thread.authorName)
          }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }

      HStack(spacing: 12) {
        if thread.hasUpdates, let latestFloor = thread.latestFloor {
          Label("更新到 \(latestFloor.formatted()) 楼", systemImage: "arrow.up.circle")
        }
        if thread.markPostID != nil {
          Label("收藏位置", systemImage: "bookmark.fill")
        }
        if let updatedAt = thread.updatedAt {
          Text(updatedAt, style: .relative)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .combine)
  }

  private var displayTitle: String {
    let title = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "帖子 \(thread.id)" : title
  }
}
