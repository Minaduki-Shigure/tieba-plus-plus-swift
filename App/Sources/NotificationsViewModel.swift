import Combine
import Foundation

struct InboxMessagePresentation: Identifiable, Hashable, Sendable {
  let message: InboxMessage
  let visibility: LocalContentVisibility

  var id: Int64 { message.id }
}

@MainActor
final class NotificationsViewModel: ObservableObject {
  @Published private(set) var selectedKind: InboxKind
  @Published private(set) var messages: [InboxMessage] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var contentFilterSnapshot = ContentFilterSnapshot.empty
  @Published private(set) var isResolvingContentFilter = false
  @Published private(set) var paginationEpoch = 0
  @Published private(set) var pausesAutomaticPagination = false

  private let service: any AccountService
  private let vault: any AccountVault
  private let contentFilterRepository: any ContentFilterRepository
  private var currentPage = 0
  private var hasMore = true
  private var loadedLease: InboxSessionLease?
  private var loadTask: Task<Void, Never>?
  private var contentFilterTask: Task<Void, Never>?
  private var epoch = 0
  private var contentFilterEpoch = 0

  init(
    service: any AccountService,
    vault: any AccountVault,
    contentFilterRepository: any ContentFilterRepository = EmptyContentFilterRepository(),
    selectedKind: InboxKind = .replies
  ) {
    self.service = service
    self.vault = vault
    self.contentFilterRepository = contentFilterRepository
    self.selectedKind = selectedKind
  }

  var messagePresentations: [InboxMessagePresentation] {
    messages.map {
      InboxMessagePresentation(
        message: $0,
        visibility: contentFilterSnapshot.visibility(for: $0)
      )
    }
  }

  var displayableMessages: [InboxMessagePresentation] {
    messagePresentations.filter { $0.visibility != .hidden }
  }

  var paginationTail: InboxMessage? { messages.last }

  var hasNextPage: Bool { hasMore }

  var requiresExplicitPagination: Bool {
    hasMore && (pausesAutomaticPagination || displayableMessages.isEmpty)
  }

  func loadIfNeeded() {
    switch state {
    case .idle:
      reload()
    case .loaded:
      refreshContentFilter(
        pausingAutomaticPagination: false,
        pausingIfSnapshotChanges: true
      )
    case .loading, .failed:
      break
    }
  }

  func select(_ kind: InboxKind) {
    guard kind != selectedKind else { return }
    selectedKind = kind
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
    // Clear synchronously so data from the old account cannot remain visible for one frame.
    beginNewEpoch(loadImmediately: true)
  }

  func contentFilterDidChange() {
    refreshContentFilter(
      pausingAutomaticPagination: true,
      pausingIfSnapshotChanges: false
    )
  }

  private func refreshContentFilter(
    pausingAutomaticPagination: Bool,
    pausingIfSnapshotChanges: Bool
  ) {
    contentFilterEpoch &+= 1
    let requestedEpoch = contentFilterEpoch
    contentFilterTask?.cancel()
    isResolvingContentFilter = true
    if pausingAutomaticPagination, hasMore, !messages.isEmpty {
      pausesAutomaticPagination = true
    }
    let repository = contentFilterRepository
    contentFilterTask = Task {
      let snapshot = await Self.readContentFilterSnapshot(from: repository)
      guard requestedEpoch == contentFilterEpoch, !Task.isCancelled else { return }
      if let snapshot {
        if
          pausingIfSnapshotChanges,
          snapshot != contentFilterSnapshot,
          hasMore,
          !messages.isEmpty
        {
          pausesAutomaticPagination = true
        }
        contentFilterSnapshot = snapshot
      }
      isResolvingContentFilter = false
      contentFilterTask = nil
    }
  }

  func replyIntent(for message: InboxMessage) -> InboxReplyIntent? {
    guard
      state == .loaded,
      let loadedLease,
      messages.contains(message),
      !isResolvingContentFilter,
      contentFilterSnapshot.visibility(for: message) == .visible
    else { return nil }
    return InboxReplyIntent(
      message: message,
      userID: loadedLease.userID,
      sessionRevision: loadedLease.sessionRevision
    )
  }

  func loadMoreIfNeeded(current message: InboxMessage) {
    guard
      message.id == messages.last?.id,
      hasMore,
      !requiresExplicitPagination,
      !isResolvingContentFilter,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    load(page: currentPage + 1, replacing: false)
  }

  func continuePagination() {
    guard
      !messages.isEmpty,
      hasMore,
      requiresExplicitPagination,
      !isResolvingContentFilter,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    pausesAutomaticPagination = false
    load(page: currentPage + 1, replacing: false)
  }

  func retryLoadMore() {
    guard hasMore, loadMoreError != nil, !isLoadingMore else { return }
    load(page: currentPage + 1, replacing: false)
  }

  func cancel() {
    let shouldRearmPagination = !messages.isEmpty && isLoadingMore && hasMore
    invalidateTask()
    invalidateContentFilterTask()
    isLoadingMore = false
    if shouldRearmPagination {
      paginationEpoch &+= 1
    }
    if state == .loading {
      state = messages.isEmpty ? .idle : .loaded
    }
  }

  private func beginNewEpoch(loadImmediately: Bool) {
    invalidateTask()
    invalidateContentFilterTask()
    currentPage = 0
    hasMore = true
    loadedLease = nil
    messages = []
    loadMoreError = nil
    pausesAutomaticPagination = false
    state = loadImmediately ? .loading : .idle
    if loadImmediately {
      load(page: 1, replacing: true)
    }
  }

  private func load(page: Int, replacing: Bool) {
    guard page > 0 else { return }
    let service = service
    let vault = vault
    let contentFilterRepository = contentFilterRepository
    let requestedKind = selectedKind
    let requestedContentFilterEpoch = contentFilterEpoch
    epoch &+= 1
    let requestEpoch = epoch
    if replacing {
      isResolvingContentFilter = true
    }
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
        if replacing {
          let replacementFilterSnapshot = await Self.readContentFilterSnapshot(
            from: contentFilterRepository
          )
          try Task.checkCancellation()
          guard requestEpoch == epoch else { return }
          if
            let replacementFilterSnapshot,
            requestedContentFilterEpoch == contentFilterEpoch
          {
            contentFilterSnapshot = replacementFilterSnapshot
          }
          if requestedContentFilterEpoch == contentFilterEpoch {
            isResolvingContentFilter = false
          }
        }
        guard let sessionBeforeRequest = try await vault.activeSession() else {
          throw BrowseError.unavailable("请先登录账户。")
        }
        try Task.checkCancellation()
        guard requestEpoch == epoch else { return }
        let lease = InboxSessionLease(sessionBeforeRequest)
        guard replacing || loadedLease == lease else {
          discardResultsFromChangedSession(requestEpoch: requestEpoch)
          return
        }
        let response = try await service.notifications(
          session: sessionBeforeRequest,
          kind: requestedKind,
          page: page
        )
        try Task.checkCancellation()
        let sessionAfterRequest = try await vault.activeSession()
        try Task.checkCancellation()
        guard requestEpoch == epoch, requestedKind == selectedKind else { return }
        guard let sessionAfterRequest, lease.matches(sessionAfterRequest) else {
          discardResultsFromChangedSession(requestEpoch: requestEpoch)
          return
        }
        try Self.validate(
          response,
          lease: lease,
          kind: requestedKind,
          requestedPage: page,
          replacing: replacing,
          currentPage: currentPage
        )
        let priorCount = replacing ? 0 : messages.count
        let mergedMessages = merge(replacing ? [] : messages, response.messages)
        currentPage = response.currentPage
        // A duplicate-only page cannot provide a new row whose appearance would advance paging.
        hasMore = response.hasMore && (replacing || mergedMessages.count > priorCount)
        loadedLease = lease
        if !hasMore {
          pausesAutomaticPagination = false
        }
        messages = mergedMessages
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
    currentPage = 0
    hasMore = true
    loadedLease = nil
    messages = []
    loadMoreError = nil
    pausesAutomaticPagination = false
    state = .idle
  }

  private func invalidateTask() {
    epoch &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func invalidateContentFilterTask() {
    contentFilterEpoch &+= 1
    contentFilterTask?.cancel()
    contentFilterTask = nil
    isResolvingContentFilter = false
  }

  private func merge(
    _ existing: [InboxMessage],
    _ newMessages: [InboxMessage]
  ) -> [InboxMessage] {
    var seen = Set(existing.map(\.id))
    return existing + newMessages.filter { seen.insert($0.id).inserted }
  }

  private static func validate(
    _ page: InboxPage,
    lease: InboxSessionLease,
    kind: InboxKind,
    requestedPage: Int,
    replacing: Bool,
    currentPage: Int
  ) throws {
    guard page.userID == lease.userID, page.kind == kind else {
      throw BrowseError.unavailable("贴吧返回了不匹配的账户消息，请重新加载后再试。")
    }
    let expectedPage = replacing ? 1 : currentPage + 1
    guard requestedPage == expectedPage, page.currentPage == requestedPage else {
      throw BrowseError.unavailable("贴吧返回了异常的消息页码，请重新加载后再试。")
    }
  }

  private static func readContentFilterSnapshot(
    from repository: any ContentFilterRepository
  ) async -> ContentFilterSnapshot? {
    do {
      return try await repository.snapshot()
    } catch {
      return nil
    }
  }
}

private struct InboxSessionLease: Equatable, Sendable {
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
