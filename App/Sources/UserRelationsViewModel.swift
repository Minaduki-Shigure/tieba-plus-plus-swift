import Combine
import Foundation

enum UserRelationFollowControlState: Equatable, Sendable {
  case hidden
  case followed(isEnabled: Bool)
  case notFollowed(isEnabled: Bool)
  case mutating(targetFollowed: Bool)
}

struct UserRelationFollowPrompt: Equatable, Sendable {
  let user: BrowseRelatedUser
  let lease: AccountSessionLease
  let previouslyFollowed: Bool
  let targetFollowed: Bool
}

@MainActor
final class UserRelationsViewModel: ObservableObject {
  @Published private(set) var users: [BrowseRelatedUser] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var totalCount = 0
  @Published private(set) var notice = ""
  @Published private(set) var visibilitySwitch: Int?
  @Published private(set) var paginationEpoch = 0
  @Published private(set) var managementLease: AccountSessionLease?
  @Published private(set) var mutatingUserID: Int64?
  @Published private(set) var relationshipMutationError: String?
  @Published private(set) var lockedRelationshipUserIDs = Set<Int64>()

  let userID: Int64
  let kind: UserRelationKind

  private let service: any UserProfileService
  private let accountAccess: AccountAccess?
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0
  private var managementResolutionGeneration = 0
  private var managementResolutionInFlight = false
  private var managementIsResolved = false
  private var knownLoadedUserIDs = Set<Int64>()
  private var loadedUsersByID: [Int64: BrowseRelatedUser] = [:]
  private var relationshipOverrides: [Int64: Bool] = [:]
  private var overrideLease: AccountSessionLease?
  private var relationshipStateRevision = 0
  private var relationshipMutationTask: Task<Void, Never>?
  private var activeRelationshipMutation: UserRelationFollowOperation?
  private var pendingReloadResetsRelationshipState: Bool?

  init(
    userID: Int64,
    kind: UserRelationKind,
    service: any UserProfileService,
    accountAccess: AccountAccess? = nil
  ) {
    self.userID = userID
    self.kind = kind
    self.service = service
    self.accountAccess = accountAccess
  }

  var displayableUsers: [BrowseRelatedUser] {
    users.filter { $0.localVisibility != .hidden }
  }

  var hasDisplayableUsers: Bool {
    !displayableUsers.isEmpty
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    requestReload(resetsRelationshipState: true)
  }

  func refresh() async {
    reload()
    let queuedBehindMutation = relationshipMutationTask
    await queuedBehindMutation?.value
    await loadTask?.value
    if kind == .following {
      await resolveManagementAccessIfNeeded()
    }
  }

  func reloadAfterContentFilterChange() {
    guard state != .idle else { return }
    requestReload(resetsRelationshipState: false)
  }

  func resolveManagementAccessIfNeeded() async {
    guard !managementIsResolved, !managementResolutionInFlight else { return }
    managementResolutionInFlight = true
    let generation = managementResolutionGeneration
    defer {
      if generation == managementResolutionGeneration {
        managementResolutionInFlight = false
      }
    }

    guard
      kind == .following,
      userID > 0,
      let accountAccess
    else {
      guard generation == managementResolutionGeneration else { return }
      managementIsResolved = true
      clearRelationshipManagementSnapshot()
      return
    }

    do {
      let session = try await accountAccess.vault.activeSession()
      try Task.checkCancellation()
      guard generation == managementResolutionGeneration else { return }
      managementIsResolved = true
      guard
        let session,
        session.id == userID,
        session.credentials != nil
      else {
        clearRelationshipManagementSnapshot()
        return
      }

      let lease = AccountSessionLease(session)
      if overrideLease != lease {
        clearRelationshipOverrides()
        overrideLease = lease
      }
      managementLease = lease
    } catch is CancellationError {
      guard generation == managementResolutionGeneration else { return }
      managementIsResolved = false
    } catch {
      guard generation == managementResolutionGeneration else { return }
      managementIsResolved = false
      clearRelationshipManagementSnapshot()
    }
  }

  @discardableResult
  func invalidateForAccountSessionChange() -> Int {
    managementResolutionGeneration &+= 1
    managementResolutionInFlight = false
    managementIsResolved = false
    activeRelationshipMutation = nil
    relationshipMutationTask = nil
    mutatingUserID = nil
    relationshipMutationError = nil
    clearRelationshipManagementSnapshot()

    if let resetsRelationshipState = pendingReloadResetsRelationshipState {
      pendingReloadResetsRelationshipState = nil
      beginReload(resetsRelationshipState: resetsRelationshipState)
    }
    return managementResolutionGeneration
  }

  func resolveManagementAccessAfterSessionChange(ifCurrent token: Int) async {
    guard token == managementResolutionGeneration else { return }
    await resolveManagementAccessIfNeeded()
  }

  func followControlState(for user: BrowseRelatedUser) -> UserRelationFollowControlState {
    guard
      user.id > 0,
      user.localVisibility == .visible,
      let lease = managementLease,
      lease.userID == userID,
      overrideLease == lease,
      exactLoadedUser(matching: user) != nil,
      user.id != lease.userID
    else { return .hidden }

    let isFollowed = relationshipOverrides[user.id] ?? true
    if let activeRelationshipMutation {
      if
        activeRelationshipMutation.prompt.lease == lease,
        activeRelationshipMutation.prompt.user.id == user.id
      {
        return .mutating(targetFollowed: activeRelationshipMutation.prompt.targetFollowed)
      }
      return isFollowed ? .followed(isEnabled: false) : .notFollowed(isEnabled: false)
    }
    let isEnabled = !lockedRelationshipUserIDs.contains(user.id)
    return isFollowed ? .followed(isEnabled: isEnabled) : .notFollowed(isEnabled: isEnabled)
  }

  func followedState(for user: BrowseRelatedUser) -> Bool? {
    switch followControlState(for: user) {
    case .hidden:
      nil
    case .followed:
      true
    case .notFollowed:
      false
    case .mutating(let targetFollowed):
      targetFollowed
    }
  }

  func followPrompt(for user: BrowseRelatedUser) -> UserRelationFollowPrompt? {
    guard let lease = managementLease else { return nil }
    let previouslyFollowed: Bool
    switch followControlState(for: user) {
    case .followed(isEnabled: true):
      previouslyFollowed = true
    case .notFollowed(isEnabled: true):
      previouslyFollowed = false
    case .hidden, .followed, .notFollowed, .mutating:
      return nil
    }
    return UserRelationFollowPrompt(
      user: user,
      lease: lease,
      previouslyFollowed: previouslyFollowed,
      targetFollowed: !previouslyFollowed
    )
  }

  func setFollowed(_ prompt: UserRelationFollowPrompt) {
    guard
      relationshipMutationTask == nil,
      activeRelationshipMutation == nil,
      managementLease == prompt.lease,
      overrideLease == prompt.lease,
      prompt.lease.userID == userID,
      prompt.user.id > 0,
      prompt.user.id != prompt.lease.userID,
      prompt.user.localVisibility == .visible,
      prompt.targetFollowed != prompt.previouslyFollowed,
      exactLoadedUser(matching: prompt.user) != nil,
      (relationshipOverrides[prompt.user.id] ?? true) == prompt.previouslyFollowed,
      !lockedRelationshipUserIDs.contains(prompt.user.id)
    else { return }

    let operation = UserRelationFollowOperation(prompt: prompt)
    activeRelationshipMutation = operation
    mutatingUserID = prompt.user.id
    relationshipMutationError = nil
    let access = accountAccess
    relationshipMutationTask = Task { [weak self] in
      guard let self else { return }
      await self.performRelationshipMutation(operation, access: access)
    }
  }

  func dismissRelationshipMutationError() {
    relationshipMutationError = nil
  }

  @discardableResult
  func userRelationshipDidChange(_ change: UserRelationshipChange) -> Bool {
    guard
      let lease = managementLease,
      change.accountID == lease.userID,
      change.sessionRevision == lease.sessionRevision,
      overrideLease == lease,
      knownLoadedUserIDs.contains(change.targetUserID)
    else { return false }
    applyConfirmedRelationship(
      targetUserID: change.targetUserID,
      isFollowed: change.isFollowed,
      lease: lease
    )
    return true
  }

  func loadMoreIfNeeded(current user: BrowseRelatedUser) {
    guard
      user.id == users.last?.id,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    loadUsers(page: currentPage + 1)
  }

  func retryLoadMore() {
    guard
      loadMoreError != nil,
      hasMore,
      !isLoadingMore,
      state == .loaded
    else { return }
    loadUsers(page: currentPage + 1)
  }

  func cancel() {
    let shouldRearmPagination = !users.isEmpty && isLoadingMore
    invalidateCurrentLoad()
    pendingReloadResetsRelationshipState = nil
    isLoadingMore = false
    if shouldRearmPagination {
      paginationEpoch &+= 1
    }
    if state == .loading {
      state = users.isEmpty ? .idle : .loaded
    }
  }

  private func requestReload(resetsRelationshipState: Bool) {
    guard activeRelationshipMutation == nil else {
      if let pendingReloadResetsRelationshipState {
        self.pendingReloadResetsRelationshipState =
          pendingReloadResetsRelationshipState || resetsRelationshipState
      } else {
        pendingReloadResetsRelationshipState = resetsRelationshipState
      }
      return
    }
    beginReload(resetsRelationshipState: resetsRelationshipState)
  }

  private func beginReload(resetsRelationshipState: Bool) {
    invalidateCurrentLoad()
    users = []
    loadedUsersByID = [:]
    currentPage = 0
    hasMore = true
    isLoadingMore = false
    loadMoreError = nil
    totalCount = 0
    notice = ""
    visibilitySwitch = nil
    state = .loading
    loadInitialPage(resetsRelationshipState: resetsRelationshipState)
  }

  private func loadInitialPage(resetsRelationshipState: Bool) {
    let service = service
    let userID = userID
    let kind = kind
    let relationshipRevision = relationshipStateRevision
    loadGeneration &+= 1
    let generation = loadGeneration
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          loadTask = nil
        }
      }
      do {
        let response = try await service.userRelations(userID: userID, kind: kind, page: 1)
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        users = unique(response.users)
        loadedUsersByID = Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
        knownLoadedUserIDs = Set(users.map(\.id))
        currentPage = response.currentPage
        hasMore = response.hasMore && !response.users.isEmpty
        totalCount = response.totalCount
        notice = response.notice
        visibilitySwitch = response.visibilitySwitch
        if resetsRelationshipState, relationshipRevision == relationshipStateRevision {
          clearRelationshipOverrides()
          overrideLease = managementLease
          relationshipMutationError = nil
        }
        state = .loaded
        paginationEpoch &+= 1
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        state = .failed(error.localizedDescription)
      }
    }
  }

  private func loadUsers(page: Int) {
    let service = service
    let userID = userID
    let kind = kind
    loadGeneration &+= 1
    let generation = loadGeneration
    loadMoreError = nil
    isLoadingMore = true
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          isLoadingMore = false
          loadTask = nil
        }
      }
      do {
        let response = try await service.userRelations(userID: userID, kind: kind, page: page)
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        let merged = merge(users, response.users)
        let addedItems = merged.count > users.count
        users = merged
        for user in response.users where loadedUsersByID[user.id] == nil {
          loadedUsersByID[user.id] = user
        }
        knownLoadedUserIDs.formUnion(response.users.map(\.id))
        currentPage = response.currentPage
        hasMore = response.hasMore && !response.users.isEmpty && addedItems
        totalCount = response.totalCount
        if !response.notice.isEmpty {
          notice = response.notice
        }
        if let responseSwitch = response.visibilitySwitch {
          visibilitySwitch = responseSwitch
        }
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        loadMoreError = error.localizedDescription
      }
    }
  }

  private func performRelationshipMutation(
    _ operation: UserRelationFollowOperation,
    access: AccountAccess?
  ) async {
    defer { finishRelationshipMutation(operation) }
    guard let access, relationshipOperationIsCurrent(operation) else { return }

    let session: StoredAccountSession
    do {
      let activeSession = try await access.vault.activeSession()
      guard relationshipOperationIsCurrent(operation) else { return }
      guard
        let activeSession,
        operation.prompt.lease.matches(activeSession),
        activeSession.credentials != nil
      else {
        invalidateRelationshipManagementAfterLeaseChange()
        return
      }
      session = activeSession
    } catch {
      guard relationshipOperationIsCurrent(operation) else { return }
      relationshipMutationError = "未能读取当前账户，尚未开始用户关注操作。"
      return
    }

    do {
      let relationship = try await access.service.setUserFollowed(
        session: session,
        targetUserID: operation.prompt.user.id,
        isFollowed: operation.prompt.targetFollowed
      )
      guard relationshipOperationIsCurrent(operation) else { return }
      guard
        relationship.userID == operation.prompt.lease.userID,
        relationship.targetUserID == operation.prompt.user.id
      else {
        throw BrowseError.unavailable("贴吧返回了不匹配的用户关注状态，请下拉刷新后再试。")
      }

      let leaseState = await relationshipLeaseState(operation.prompt.lease, access: access)
      guard relationshipOperationIsCurrent(operation) else { return }
      switch leaseState {
      case .current:
        applyConfirmedRelationship(
          targetUserID: operation.prompt.user.id,
          isFollowed: relationship.isFollowed,
          lease: operation.prompt.lease
        )
        AccountChangeNotifications.postUserRelationshipChange(
          UserRelationshipChange(
            accountID: operation.prompt.lease.userID,
            sessionRevision: operation.prompt.lease.sessionRevision,
            targetUserID: operation.prompt.user.id,
            isFollowed: relationship.isFollowed
          )
        )
        if relationship.isFollowed != operation.prompt.targetFollowed {
          relationshipMutationError = "贴吧没有确认新的用户关注状态，请下拉刷新后再试。"
        }
      case .changed:
        invalidateRelationshipManagementAfterLeaseChange()
      case .unavailable:
        lockRelationshipAfterUnknownOutcome(operation.prompt.user.id)
      }
    } catch {
      guard relationshipOperationIsCurrent(operation) else { return }
      let leaseState = await relationshipLeaseState(operation.prompt.lease, access: access)
      guard relationshipOperationIsCurrent(operation) else { return }
      switch leaseState {
      case .current, .unavailable:
        lockRelationshipAfterUnknownOutcome(
          operation.prompt.user.id,
          underlyingMessage: error.localizedDescription
        )
      case .changed:
        invalidateRelationshipManagementAfterLeaseChange()
      }
    }
  }

  private func relationshipOperationIsCurrent(_ operation: UserRelationFollowOperation) -> Bool {
    activeRelationshipMutation?.id == operation.id
      && managementLease == operation.prompt.lease
      && overrideLease == operation.prompt.lease
  }

  private func finishRelationshipMutation(_ operation: UserRelationFollowOperation) {
    guard activeRelationshipMutation?.id == operation.id else { return }
    activeRelationshipMutation = nil
    relationshipMutationTask = nil
    mutatingUserID = nil

    if let resetsRelationshipState = pendingReloadResetsRelationshipState {
      pendingReloadResetsRelationshipState = nil
      beginReload(resetsRelationshipState: resetsRelationshipState)
    }
  }

  private func relationshipLeaseState(
    _ lease: AccountSessionLease,
    access: AccountAccess
  ) async -> UserRelationLeaseState {
    do {
      guard let session = try await access.vault.activeSession() else { return .changed }
      return lease.matches(session) ? .current : .changed
    } catch {
      return .unavailable
    }
  }

  private func applyConfirmedRelationship(
    targetUserID: Int64,
    isFollowed: Bool,
    lease: AccountSessionLease
  ) {
    guard managementLease == lease, overrideLease == lease else { return }
    if isFollowed {
      relationshipOverrides.removeValue(forKey: targetUserID)
    } else {
      relationshipOverrides[targetUserID] = false
    }
    lockedRelationshipUserIDs.remove(targetUserID)
    relationshipStateRevision &+= 1
  }

  private func lockRelationshipAfterUnknownOutcome(
    _ targetUserID: Int64,
    underlyingMessage: String? = nil
  ) {
    lockedRelationshipUserIDs.insert(targetUserID)
    let message = underlyingMessage?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if message.isEmpty {
      relationshipMutationError =
        "用户关注结果尚未确认；请下拉刷新后再试，应用不会自动重发操作。"
    } else {
      relationshipMutationError =
        "\(message)\n用户关注结果尚未确认；请下拉刷新后再试，应用不会自动重发操作。"
    }
  }

  private func invalidateRelationshipManagementAfterLeaseChange() {
    managementResolutionGeneration &+= 1
    let resolutionToken = managementResolutionGeneration
    managementResolutionInFlight = false
    managementIsResolved = false
    activeRelationshipMutation = nil
    relationshipMutationTask = nil
    mutatingUserID = nil
    relationshipMutationError = nil
    clearRelationshipManagementSnapshot()
    if let resetsRelationshipState = pendingReloadResetsRelationshipState {
      pendingReloadResetsRelationshipState = nil
      beginReload(resetsRelationshipState: resetsRelationshipState)
    }
    Task { [weak self] in
      guard let self else { return }
      await self.resolveManagementAccessAfterSessionChange(ifCurrent: resolutionToken)
    }
  }

  private func clearRelationshipManagementSnapshot() {
    managementLease = nil
    overrideLease = nil
    clearRelationshipOverrides()
  }

  private func clearRelationshipOverrides() {
    relationshipOverrides.removeAll()
    lockedRelationshipUserIDs.removeAll()
    relationshipStateRevision &+= 1
  }

  private func exactLoadedUser(matching user: BrowseRelatedUser) -> BrowseRelatedUser? {
    guard loadedUsersByID[user.id] == user else { return nil }
    return user
  }

  private func invalidateCurrentLoad() {
    loadGeneration &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func unique(_ items: [BrowseRelatedUser]) -> [BrowseRelatedUser] {
    merge([], items)
  }

  private func merge(
    _ existing: [BrowseRelatedUser],
    _ newItems: [BrowseRelatedUser]
  ) -> [BrowseRelatedUser] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}

private enum UserRelationLeaseState: Sendable {
  case current
  case changed
  case unavailable
}

private struct UserRelationFollowOperation: Sendable {
  let id = UUID()
  let prompt: UserRelationFollowPrompt
}
