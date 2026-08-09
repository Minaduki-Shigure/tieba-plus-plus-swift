import Combine
import Foundation
import SwiftUI

struct CloudFavoriteRemovalIntent: Identifiable, Equatable, Sendable {
  let id: UUID
  let lease: CloudFavoritesSessionLease
  let thread: CloudFavoriteThread

  init(lease: CloudFavoritesSessionLease, thread: CloudFavoriteThread) {
    id = UUID()
    self.lease = lease
    self.thread = thread
  }

  var title: String {
    let value = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty ? "帖子 \(thread.id)" : value
  }
}

struct CloudFavoriteRemovalFailure: Equatable, Sendable {
  let threadID: Int64
  let message: String
}

struct CloudFavoriteTargetResolver: Sendable {
  let service: any BrowseService

  func resolve(_ favorite: CloudFavoriteThread) async throws -> ThreadCloudFavoriteTarget {
    let resolved: BrowseThreadIdentity
    do {
      resolved = try await service.resolveThreadIdentity(
        threadID: favorite.id,
        expectedForumName: favorite.forumName
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw BrowseError.unavailable(
        "无法确认该主题所属的贴吧，因此没有发送删除请求。主题若已被彻底删除，暂时无法安全移除。"
      )
    }

    let expectedForumName = Self.canonicalForumName(favorite.forumName)
    let resolvedForumName = Self.canonicalForumName(resolved.forumName)
    guard
      resolved.threadID == favorite.id,
      resolved.forumID > 0,
      !resolvedForumName.isEmpty,
      expectedForumName.isEmpty || resolvedForumName == expectedForumName,
      let target = ThreadCloudFavoriteTarget(
        forumID: resolved.forumID,
        forumName: resolvedForumName,
        threadID: favorite.id
      )
    else {
      throw BrowseError.unavailable(
        "无法验证该主题与所属贴吧的对应关系，因此没有发送删除请求。"
      )
    }
    return target
  }

  private static func canonicalForumName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }
}

@MainActor
final class CloudFavoritesViewModel: ObservableObject {
  @Published private(set) var threads: [CloudFavoriteThread] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var pendingRemoval: CloudFavoriteRemovalIntent?
  @Published private(set) var removingThreadID: Int64?
  @Published private(set) var removalFailure: CloudFavoriteRemovalFailure?

  private let service: any AccountService
  private let vault: any AccountVault
  private let targetResolver: CloudFavoriteTargetResolver?
  private let cloudFavoriteStore: ThreadCloudFavoriteStore?
  private let pageSize: Int
  private var nextOffset: Int? = 0
  private var hasMore = true
  private var loadedLease: CloudFavoritesSessionLease?
  private var loadTask: Task<Void, Never>?
  private var removalTask: Task<Void, Never>?
  private var removalOperationID: UUID?
  private var removalTarget: ThreadCloudFavoriteTarget?
  private var reloadAfterRemoval = false
  private var cloudFavoriteChangeSequence: UInt64 = 0
  private var latestChangeSequenceByLease: [CloudFavoritesSessionLease: UInt64] = [:]
  private var epoch = 0

  init(
    service: any AccountService,
    vault: any AccountVault,
    browseService: (any BrowseService)? = nil,
    cloudFavoriteStore: ThreadCloudFavoriteStore? = nil,
    pageSize: Int = 30
  ) {
    self.service = service
    self.vault = vault
    self.targetResolver = browseService.map(CloudFavoriteTargetResolver.init(service:))
    self.cloudFavoriteStore = cloudFavoriteStore
    self.pageSize = min(max(pageSize, 1), 100)
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    guard removalTask == nil else {
      reloadAfterRemoval = true
      return
    }
    pendingRemoval = nil
    beginNewEpoch(loadImmediately: true)
  }

  func refresh() async {
    if let removalTask {
      reloadAfterRemoval = true
      await removalTask.value
      let task = loadTask
      await task?.value
      return
    }
    reload()
    let task = loadTask
    await task?.value
  }

  func accountSessionDidChange() {
    // Remove the previous account's data before starting the replacement request.
    invalidateRemoval()
    beginNewEpoch(loadImmediately: true)
  }

  func requestRemoval(of thread: CloudFavoriteThread) {
    guard
      removingThreadID == nil,
      let loadedLease,
      threads.contains(thread),
      targetResolver != nil,
      cloudFavoriteStore != nil
    else {
      if targetResolver == nil || cloudFavoriteStore == nil {
        removalFailure = CloudFavoriteRemovalFailure(
          threadID: thread.id,
          message: "当前页面无法安全更新贴吧云收藏，请重新打开后再试。"
        )
      }
      return
    }
    removalFailure = nil
    pendingRemoval = CloudFavoriteRemovalIntent(lease: loadedLease, thread: thread)
  }

  func cancelPendingRemoval() {
    pendingRemoval = nil
  }

  func confirmPendingRemoval() {
    guard
      removalTask == nil,
      let intent = pendingRemoval,
      loadedLease == intent.lease,
      threads.contains(intent.thread),
      let targetResolver,
      let cloudFavoriteStore
    else {
      pendingRemoval = nil
      return
    }

    pendingRemoval = nil
    removalFailure = nil
    reloadAfterRemoval = false
    let operationID = UUID()
    removalOperationID = operationID
    removingThreadID = intent.thread.id
    let vault = vault

    removalTask = Task { [weak self] in
      guard let self else { return }
      do {
        try await Self.requireCurrentLease(intent.lease, vault: vault)
        guard loadedLease == intent.lease, threads.contains(intent.thread) else {
          throw CancellationError()
        }

        let target = try await targetResolver.resolve(intent.thread)
        try Task.checkCancellation()
        try await Self.requireCurrentLease(intent.lease, vault: vault)
        guard loadedLease == intent.lease, threads.contains(intent.thread) else {
          throw CancellationError()
        }
        removalTarget = target

        let snapshot = try await cloudFavoriteStore.removeCloudFavorite(
          target,
          expectedSession: ThreadCloudFavoriteSessionExpectation(
            userID: intent.lease.userID,
            sessionRevision: intent.lease.sessionRevision
          )
        )
        try Task.checkCancellation()
        guard !snapshot.isFavorited else {
          throw BrowseError.unavailable("贴吧没有确认移除云端收藏，请重新读取当前状态。")
        }
        guard
          removalOperationID == operationID,
          loadedLease == intent.lease,
          threads.contains(intent.thread)
        else { throw CancellationError() }

        finishRemoval(operationID: operationID)
        beginNewEpoch(loadImmediately: true)
      } catch is CancellationError {
        guard removalOperationID == operationID else { return }
        guard !Task.isCancelled, loadedLease == intent.lease else {
          finishRemoval(operationID: operationID)
          return
        }
        finishRemoval(operationID: operationID)
        removalFailure = CloudFavoriteRemovalFailure(
          threadID: intent.thread.id,
          message: "云端收藏结果尚未确认；再次操作时会先重新读取状态，不会自动重发删除请求。"
        )
        if reloadAfterRemoval {
          reloadAfterRemoval = false
          beginNewEpoch(loadImmediately: true)
        }
      } catch {
        guard removalOperationID == operationID, loadedLease == intent.lease else { return }
        finishRemoval(operationID: operationID)
        removalFailure = CloudFavoriteRemovalFailure(
          threadID: intent.thread.id,
          message: error.localizedDescription
        )
        if reloadAfterRemoval {
          reloadAfterRemoval = false
          beginNewEpoch(loadImmediately: true)
        }
      }
    }
  }

  func clearRemovalFailure() {
    removalFailure = nil
  }

  func threadCloudFavoriteDidChange(_ change: ThreadCloudFavoriteChange) {
    cloudFavoriteChangeSequence &+= 1
    let changeLease = CloudFavoritesSessionLease(change)
    latestChangeSequenceByLease[changeLease] = cloudFavoriteChangeSequence
    guard let loadedLease, loadedLease == changeLease else { return }
    if
      removingThreadID == change.target.threadID,
      removalTarget == change.target,
      !change.snapshot.isFavorited
    {
      reloadAfterRemoval = true
      return
    }
    if removalTask != nil {
      reloadAfterRemoval = true
      return
    }
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
    pendingRemoval = nil
    isLoadingMore = false
    if state == .loading {
      state = threads.isEmpty ? .idle : .loaded
    }
  }

  private func beginNewEpoch(loadImmediately: Bool) {
    invalidateTask()
    pendingRemoval = nil
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
    let changeSequenceAtStart = cloudFavoriteChangeSequence
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
        if (latestChangeSequenceByLease[lease] ?? 0) > changeSequenceAtStart {
          beginNewEpoch(loadImmediately: true)
          return
        }

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

  private func invalidateRemoval() {
    removalTask?.cancel()
    removalTask = nil
    removalOperationID = nil
    removalTarget = nil
    removingThreadID = nil
    pendingRemoval = nil
    removalFailure = nil
    reloadAfterRemoval = false
  }

  private func finishRemoval(operationID: UUID) {
    guard removalOperationID == operationID else { return }
    removalTask = nil
    removalOperationID = nil
    removalTarget = nil
    removingThreadID = nil
  }

  private static func requireCurrentLease(
    _ expected: CloudFavoritesSessionLease,
    vault: any AccountVault
  ) async throws {
    guard try await currentLease(vault: vault) == expected else {
      throw CancellationError()
    }
  }

  private static func currentLease(
    vault: any AccountVault
  ) async throws -> CloudFavoritesSessionLease? {
    let session = try await vault.activeSession()
    return session.map(CloudFavoritesSessionLease.init)
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

struct CloudFavoritesSessionLease: Hashable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }

  init(_ change: ThreadCloudFavoriteChange) {
    userID = change.accountID
    sessionRevision = change.sessionRevision
  }

  func matches(_ session: StoredAccountSession) -> Bool {
    userID == session.id && sessionRevision == session.sessionRevision
  }

  func matches(_ change: ThreadCloudFavoriteChange) -> Bool {
    userID == change.accountID && sessionRevision == change.sessionRevision
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
    cloudFavoriteStore: ThreadCloudFavoriteStore? = nil,
    historyRepository: any BrowsingHistoryRepository,
    favoritesRepository: any LocalFavoritesRepository,
    searchHistoryRepository: any ForumSearchHistoryRepository
  ) {
    self.browseService = browseService
    self.historyRepository = historyRepository
    self.favoritesRepository = favoritesRepository
    self.searchHistoryRepository = searchHistoryRepository
    _viewModel = StateObject(
      wrappedValue: CloudFavoritesViewModel(
        service: accountService,
        vault: vault,
        browseService: browseService,
        cloudFavoriteStore: cloudFavoriteStore
      )
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
    .onReceive(NotificationCenter.default.publisher(for: .threadCloudFavoriteDidChange)) {
      notification in
      guard let change = ThreadCloudFavoriteChange(notification) else { return }
      viewModel.threadCloudFavoriteDidChange(change)
    }
    .confirmationDialog(
      "从贴吧云收藏移除？",
      isPresented: Binding(
        get: { viewModel.pendingRemoval != nil },
        set: { if !$0 { viewModel.cancelPendingRemoval() } }
      ),
      titleVisibility: .visible
    ) {
      Button("移除", role: .destructive) {
        viewModel.confirmPendingRemoval()
      }
      Button("取消", role: .cancel) {
        viewModel.cancelPendingRemoval()
      }
    } message: {
      if let intent = viewModel.pendingRemoval {
        Text("将从当前贴吧账户移除“\(intent.title)”。此操作会先重新验证主题与所属贴吧。")
      }
    }
    .alert(
      "无法移除云端收藏",
      isPresented: Binding(
        get: { viewModel.removalFailure != nil },
        set: { if !$0 { viewModel.clearRemovalFailure() } }
      )
    ) {
      Button("好", role: .cancel) { viewModel.clearRemovalFailure() }
    } message: {
      Text(viewModel.removalFailure?.message ?? "无法确认云端收藏状态。")
    }
    .onDisappear(perform: viewModel.cancel)
  }

  private var favoriteList: some View {
    List {
      ForEach(viewModel.threads) { thread in
        favoriteRow(thread)
          .onAppear { viewModel.loadMoreIfNeeded(current: thread) }
          .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
              viewModel.requestRemoval(of: thread)
            } label: {
              Label("移除", systemImage: "trash")
            }
            .disabled(viewModel.removingThreadID != nil)
            .accessibilityIdentifier("cloud-favorite-remove-\(thread.id)")
          }
          .disabled(viewModel.removingThreadID != nil)
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

  @ViewBuilder
  private func favoriteRow(_ thread: CloudFavoriteThread) -> some View {
    if thread.isDeleted {
      CloudFavoriteThreadRow(
        thread: thread,
        isRemoving: viewModel.removingThreadID == thread.id
      )
    } else {
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
        CloudFavoriteThreadRow(
          thread: thread,
          isRemoving: viewModel.removingThreadID == thread.id
        )
      }
    }
  }
}

private struct CloudFavoriteThreadRow: View {
  let thread: CloudFavoriteThread
  let isRemoving: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(displayTitle)
          .font(.headline)
          .foregroundStyle(thread.isDeleted ? Color.secondary : Color.primary)
          .lineLimit(2)
        Spacer(minLength: 0)
        if isRemoving {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("正在移除云端收藏")
        } else if thread.isDeleted {
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
