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
  @Published private(set) var isActive = false
  @Published private(set) var isResolvingSession = false
  @Published private(set) var messages: [InboxMessage] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var refreshError: String?
  @Published private(set) var contentFilterSnapshot = ContentFilterSnapshot.empty
  @Published private(set) var isResolvingContentFilter = false
  @Published private(set) var paginationEpoch = 0
  @Published private(set) var pausesAutomaticPagination = false

  private let service: any AccountService
  private let vault: any AccountVault
  private let contentFilterRepository: any ContentFilterRepository
  private let onValidatedFirstPage: @MainActor (UUID) -> Void
  private var currentPage = 0
  private var hasMore = true
  private var loadedLease: InboxSessionLease?
  private var loadTask: Task<Void, Never>?
  private var activationTask: Task<Void, Never>?
  private var loadCheckpoint: InboxLoadCheckpoint?
  private var contentFilterTask: Task<Void, Never>?
  private var epoch = 0
  private var contentFilterEpoch = 0

  init(
    service: any AccountService,
    vault: any AccountVault,
    contentFilterRepository: any ContentFilterRepository = EmptyContentFilterRepository(),
    selectedKind: InboxKind = .replies,
    onValidatedFirstPage: @escaping @MainActor (UUID) -> Void = { _ in }
  ) {
    self.service = service
    self.vault = vault
    self.contentFilterRepository = contentFilterRepository
    self.selectedKind = selectedKind
    self.onValidatedFirstPage = onValidatedFirstPage
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
    guard !Task.isCancelled else { return }
    isActive = true
    guard loadTask == nil, activationTask == nil else { return }
    if let loadedLease {
      validateCachedSession(loadedLease)
      return
    }
    switch state {
    case .idle:
      reload()
    case .loaded, .loading, .failed:
      break
    }
  }

  func select(_ kind: InboxKind) {
    guard kind != selectedKind else { return }
    selectedKind = kind
    beginNewEpoch(loadImmediately: isActive)
  }

  func reload() {
    guard isActive, !Task.isCancelled, loadTask == nil, activationTask == nil else { return }
    load(page: 1, replacing: true)
  }

  func refresh() async {
    guard isActive, !Task.isCancelled else { return }
    if let activationTask {
      await activationTask.value
      return
    }
    reload()
    let task = loadTask
    await task?.value
  }

  func clearRefreshError() { refreshError = nil }

  func accountSessionDidChange(loadImmediately: Bool = true) {
    // Clear synchronously so data from the old account cannot remain visible for one frame.
    beginNewEpoch(loadImmediately: loadImmediately && isActive)
  }

  private func validateCachedSession(_ lease: InboxSessionLease) {
    // Keep the native list and its rows, but do not expose or act on private
    // cached content until the current vault lease has been checked again.
    isResolvingSession = true
    let activationEpoch = epoch
    activationTask = Task {
      defer {
        if activationEpoch == epoch {
          activationTask = nil
          isResolvingSession = false
        }
      }
      do {
        let before = try await vault.activeSession()
        try Task.checkCancellation()
        guard isActive, activationEpoch == epoch else { return }
        guard let before, lease.matches(before) else {
          activationTask = nil
          beginNewEpoch(loadImmediately: true)
          return
        }
        refreshContentFilter(
          pausingAutomaticPagination: false,
          pausingIfSnapshotChanges: true
        )
        await contentFilterTask?.value
        try Task.checkCancellation()
        let after = try await vault.activeSession()
        try Task.checkCancellation()
        guard isActive, activationEpoch == epoch else { return }
        guard let after, lease.matches(after) else {
          activationTask = nil
          beginNewEpoch(loadImmediately: true)
          return
        }
      } catch is CancellationError {
        return
      } catch {
        guard isActive, activationEpoch == epoch, !Task.isCancelled else { return }
        // A vault error cannot establish that a private cached page still
        // belongs to the active account. A local filter error is handled above.
        activationTask = nil
        beginNewEpoch(loadImmediately: false)
        state = .failed(error.localizedDescription)
      }
    }
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
        if pausingIfSnapshotChanges,
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
      isActive,
      !isResolvingSession,
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
      isActive, !Task.isCancelled, !isResolvingSession, loadTask == nil,
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
      isActive, !Task.isCancelled, !isResolvingSession, loadTask == nil,
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
    guard
      isActive, !Task.isCancelled, !isResolvingSession, !isResolvingContentFilter,
      loadTask == nil, hasMore, loadMoreError != nil, !isLoadingMore
    else { return }
    load(page: currentPage + 1, replacing: false)
  }

  func cancel() {
    let shouldRearmPagination = !messages.isEmpty && isLoadingMore && hasMore
    let checkpoint = loadCheckpoint
    isActive = false
    invalidateTask()
    invalidateContentFilterTask()
    isLoadingMore = false
    if shouldRearmPagination {
      paginationEpoch &+= 1
    }
    restoreAfterCancellation(checkpoint)
  }

  private func beginNewEpoch(loadImmediately: Bool) {
    invalidateTask()
    invalidateContentFilterTask()
    clearSnapshot()
    state = .idle
    if loadImmediately && isActive {
      load(page: 1, replacing: true)
    }
  }

  private func load(page: Int, replacing: Bool) {
    guard isActive, !Task.isCancelled, page > 0, loadTask == nil else { return }
    if replacing { invalidateContentFilterTask() }
    let service = service
    let vault = vault
    let contentFilterRepository = contentFilterRepository
    let requestedKind = selectedKind
    let requestedContentFilterEpoch = contentFilterEpoch
    epoch &+= 1
    let requestEpoch = epoch
    let checkpoint = InboxLoadCheckpoint(
      state: state, loadMoreError: loadMoreError, refreshError: refreshError
    )
    loadCheckpoint = checkpoint
    isResolvingSession = loadedLease != nil
    if replacing {
      state = .loading
      refreshError = nil
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
          loadCheckpoint = nil
          isResolvingSession = false
        }
      }
      var validatedResponseLease: InboxSessionLease?
      do {
        try Task.checkCancellation()
        if replacing {
          let replacementFilterSnapshot = await Self.readContentFilterSnapshot(
            from: contentFilterRepository
          )
          try Task.checkCancellation()
          guard requestEpoch == epoch else { return }
          if let replacementFilterSnapshot,
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
        guard isActive, requestEpoch == epoch else { return }
        let lease = InboxSessionLease(sessionBeforeRequest)
        guard replacing || loadedLease == lease else {
          discardResultsFromChangedSession(requestEpoch: requestEpoch)
          return
        }
        if let loadedLease, loadedLease != lease {
          clearSnapshot()
        }
        isResolvingSession = false
        let outcome: InboxRequestOutcome
        do {
          outcome = .success(
            try await service.notifications(
              session: sessionBeforeRequest,
              kind: requestedKind,
              page: page
            ))
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          outcome = .failure(error.localizedDescription)
        }
        try Task.checkCancellation()
        let sessionAfterRequest = try await vault.activeSession()
        try Task.checkCancellation()
        guard isActive, requestEpoch == epoch, requestedKind == selectedKind else { return }
        guard let sessionAfterRequest, lease.matches(sessionAfterRequest) else {
          discardResultsFromChangedSession(requestEpoch: requestEpoch)
          return
        }
        validatedResponseLease = lease
        let response: InboxPage
        switch outcome {
        case .success(let page): response = page
        case .failure(let message):
          acceptFailure(message, replacing: replacing, checkpoint: checkpoint)
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
        if !hasMore || (replacing && requestedContentFilterEpoch == contentFilterEpoch) {
          pausesAutomaticPagination = false
        }
        messages = mergedMessages
        loadMoreError = nil
        refreshError = nil
        state = .loaded
        if replacing && page == 1 {
          // Opening the first inbox page may change server unread counts. The runtime reads
          // the aggregate again; message flags alone cannot establish the new total.
          onValidatedFirstPage(lease.sessionRevision)
        }
      } catch is CancellationError {
        if requestEpoch == epoch, !Task.isCancelled {
          restoreAfterCancellation(checkpoint)
          isResolvingContentFilter = false
        }
        return
      } catch {
        guard isActive, requestEpoch == epoch, !Task.isCancelled else { return }
        if loadedLease != nil && validatedResponseLease == nil {
          clearSnapshot()
        }
        acceptFailure(error.localizedDescription, replacing: replacing, checkpoint: checkpoint)
      }
    }
  }

  private func discardResultsFromChangedSession(requestEpoch: Int) {
    guard requestEpoch == epoch else { return }
    invalidateTask()
    clearSnapshot()
    state = .idle
  }

  private func clearSnapshot() {
    paginationEpoch &+= 1
    currentPage = 0
    hasMore = true
    loadedLease = nil
    messages = []
    loadMoreError = nil
    refreshError = nil
    pausesAutomaticPagination = false
  }

  private func acceptFailure(
    _ message: String, replacing: Bool, checkpoint: InboxLoadCheckpoint
  ) {
    if loadedLease == nil {
      state = .failed(message)
    } else if replacing {
      state = .loaded
      loadMoreError = checkpoint.loadMoreError
      refreshError = message
    } else {
      loadMoreError = message
    }
  }

  private func restoreAfterCancellation(_ checkpoint: InboxLoadCheckpoint?) {
    if let checkpoint, loadedLease != nil {
      state = checkpoint.state
      loadMoreError = checkpoint.loadMoreError
      refreshError = checkpoint.refreshError
    } else if state == .loading {
      state = loadedLease == nil ? .idle : .loaded
    }
  }

  private func invalidateTask() {
    epoch &+= 1
    loadTask?.cancel()
    loadTask = nil
    loadCheckpoint = nil
    activationTask?.cancel()
    activationTask = nil
    isResolvingSession = false
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

private struct InboxLoadCheckpoint {
  let state: LoadState
  let loadMoreError: String?
  let refreshError: String?
}

private enum InboxRequestOutcome {
  case success(InboxPage)
  case failure(String)
}
