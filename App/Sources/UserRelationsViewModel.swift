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

enum UserRelationFollowingFilter: String, CaseIterable, Identifiable, Hashable, Sendable {
  case all
  case mutual

  var id: Self { self }

  var title: String {
    switch self {
    case .all:
      "我的关注"
    case .mutual:
      "互相关注"
    }
  }
}

enum UserRelationEmptyPresentation: Equatable, Sendable {
  case none
  case noRelations
  case locallyFiltered
  case searchingMutual
  case mutualScanPaused
  case noMutual
}

@MainActor
final class UserRelationsViewModel: ObservableObject {
  static let maximumAutomaticMutualPages = 5

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
  @Published private(set) var followingFilter: UserRelationFollowingFilter = .all
  @Published private(set) var mutualScanIsPaused = false
  @Published private(set) var concernMetadataIsComplete = false

  let userID: Int64
  let kind: UserRelationKind

  private let service: any UserProfileService
  private let accountAccess: AccountAccess?
  private var currentPage = 0
  private var hasMore = true
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0
  private var managementResolutionGeneration = 0
  private var loadedPageBinding: UserRelationPageBinding?
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
    users.filter { user in
      user.localVisibility != .hidden
        && (followingFilter == .all || user.concernState == .mutual)
    }
  }

  var hasDisplayableUsers: Bool {
    !displayableUsers.isEmpty
  }

  var hasLoadedMutual: Bool {
    users.contains { $0.concernState == .mutual }
  }

  var canSelectFollowingFilter: Bool {
    guard
      kind == .following,
      state == .loaded,
      let managementLease,
      loadedPageBinding == .authenticatedOwner(managementLease),
      concernMetadataIsComplete
    else { return false }
    return true
  }

  var emptyPresentation: UserRelationEmptyPresentation {
    guard !hasDisplayableUsers else { return .none }
    guard !users.isEmpty else { return .noRelations }
    guard followingFilter == .mutual else { return .locallyFiltered }
    if hasLoadedMutual {
      return .locallyFiltered
    }
    if loadMoreError != nil { return .none }
    if isLoadingMore { return .searchingMutual }
    if mutualScanIsPaused, hasMore { return .mutualScanPaused }
    return hasMore ? .searchingMutual : .noMutual
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
  }

  func reloadAfterContentFilterChange() {
    guard state != .idle else { return }
    requestReload(resetsRelationshipState: false)
  }

  func resolveManagementAccessIfNeeded() async {
    if state == .idle { loadIfNeeded() }
    await loadTask?.value
  }

  @discardableResult
  func invalidateForAccountSessionChange() -> Int {
    managementResolutionGeneration &+= 1
    resetForAccountSessionChange(loadImmediately: false)
    return managementResolutionGeneration
  }

  func resolveManagementAccessAfterSessionChange(ifCurrent token: Int) async {
    guard token == managementResolutionGeneration else { return }
    loadIfNeeded()
    await loadTask?.value
  }

  func accountSessionDidChange(reloadIfActive: Bool) {
    managementResolutionGeneration &+= 1
    resetForAccountSessionChange(loadImmediately: reloadIfActive)
  }

  func selectFollowingFilter(_ filter: UserRelationFollowingFilter) {
    guard
      canSelectFollowingFilter,
      !isLoadingMore,
      followingFilter != filter
    else { return }
    followingFilter = filter
    mutualScanIsPaused = false
    paginationEpoch &+= 1
    guard
      filter == .mutual,
      !hasLoadedMutual,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    loadUsers(page: currentPage + 1)
  }

  func continueMutualScan() {
    guard
      canSelectFollowingFilter,
      followingFilter == .mutual,
      mutualScanIsPaused,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else { return }
    mutualScanIsPaused = false
    loadUsers(page: currentPage + 1)
  }

  func followControlState(for user: BrowseRelatedUser) -> UserRelationFollowControlState {
    guard
      user.id > 0,
      user.localVisibility == .visible,
      let lease = managementLease,
      lease.userID == userID,
      loadedPageBinding == .authenticatedOwner(lease),
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
      state == .loaded,
      !(
        followingFilter == .mutual
          && (
            mutualScanIsPaused
              || (displayableUsers.isEmpty && hasLoadedMutual)
          )
      )
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
    knownLoadedUserIDs = []
    currentPage = 0
    hasMore = true
    isLoadingMore = false
    loadMoreError = nil
    mutualScanIsPaused = false
    totalCount = 0
    notice = ""
    visibilitySwitch = nil
    state = .loading
    loadInitialPage(resetsRelationshipState: resetsRelationshipState)
  }

  private func loadInitialPage(resetsRelationshipState: Bool) {
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
        let identity = try await initialRequestIdentity()
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        let response = try await relationPage(identity: identity, page: 1)
        try Task.checkCancellation()
        try await validateCurrent(identity)
        try Task.checkCancellation()
        guard generation == loadGeneration else { return }
        try applyInitialPage(
          response,
          identity: identity,
          resetsRelationshipState: resetsRelationshipState,
          relationshipRevision: relationshipRevision
        )
      } catch is CancellationError {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        state = .failed("读取用户关系已取消，请重新加载。")
      } catch UserRelationPageLoadError.sessionChanged {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        discardResultsFromChangedSession()
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        state = .failed(error.localizedDescription)
      }
    }
  }

  private func loadUsers(page: Int) {
    let scansMutual = followingFilter == .mutual
    let maximumPages = scansMutual ? Self.maximumAutomaticMutualPages : 1
    let initialDisplayableMutualIDs: Set<Int64> = scansMutual
      ? Set(displayableUsers.map(\.id))
      : []
    loadGeneration &+= 1
    let generation = loadGeneration
    loadMoreError = nil
    mutualScanIsPaused = false
    isLoadingMore = true
    loadTask = Task {
      var requestedPage = page
      var loadedPageCount = 0
      defer {
        if generation == loadGeneration {
          isLoadingMore = false
          loadTask = nil
        }
      }
      do {
        while loadedPageCount < maximumPages {
          let identity = try await continuationRequestIdentity()
          try Task.checkCancellation()
          guard generation == loadGeneration else { return }
          let response = try await relationPage(identity: identity, page: requestedPage)
          try Task.checkCancellation()
          try await validateCurrent(identity)
          try Task.checkCancellation()
          guard generation == loadGeneration else { return }
          try applyContinuationPage(response, identity: identity, requestedPage: requestedPage)
          loadedPageCount &+= 1

          guard
            followingFilter == .mutual,
            hasMore
          else {
            mutualScanIsPaused = false
            return
          }
          let addedDisplayableMutual = displayableUsers.contains { user in
            !initialDisplayableMutualIDs.contains(user.id)
          }
          if addedDisplayableMutual
            || (initialDisplayableMutualIDs.isEmpty && hasLoadedMutual)
          {
            mutualScanIsPaused = false
            return
          }
          guard loadedPageCount < maximumPages else {
            mutualScanIsPaused = true
            paginationEpoch &+= 1
            return
          }
          guard currentPage < Int(Int32.max) else {
            hasMore = false
            return
          }
          requestedPage = currentPage + 1
        }
      } catch is CancellationError {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        loadMoreError = "读取更多用户关系已取消，请重试。"
      } catch UserRelationPageLoadError.sessionChanged {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        discardResultsFromChangedSession()
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        loadMoreError = error.localizedDescription
      }
    }
  }

  private func initialRequestIdentity() async throws -> UserRelationRequestIdentity {
    guard
      kind == .following,
      userID > 0,
      let accountAccess
    else { return .publicProfile }

    do {
      guard
        let session = try await accountAccess.vault.activeSession(),
        session.id == userID,
        session.credentials != nil
      else { return .publicProfile }
      return .authenticatedOwner(
        session: session,
        lease: AccountSessionLease(session)
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      return .publicProfile
    }
  }

  private func continuationRequestIdentity() async throws -> UserRelationRequestIdentity {
    guard let loadedPageBinding else {
      throw BrowseError.unavailable("用户关系列表缺少可靠的分页来源，请重新加载。")
    }
    switch loadedPageBinding {
    case .publicProfile:
      return .publicProfile
    case .authenticatedOwner(let lease):
      guard let accountAccess else { throw UserRelationPageLoadError.sessionChanged }
      let session = try await accountAccess.vault.activeSession()
      guard
        let session,
        lease.matches(session),
        session.credentials != nil
      else { throw UserRelationPageLoadError.sessionChanged }
      return .authenticatedOwner(session: session, lease: lease)
    }
  }

  private func relationPage(
    identity: UserRelationRequestIdentity,
    page: Int
  ) async throws -> UserRelationPageData {
    switch identity {
    case .publicProfile:
      return try await service.userRelations(userID: userID, kind: kind, page: page)
    case .authenticatedOwner(let session, let lease):
      guard
        kind == .following,
        userID == lease.userID,
        let accountAccess
      else { throw UserRelationPageLoadError.sessionChanged }
      return try await accountAccess.service.ownFollowing(session: session, page: page)
    }
  }

  private func validateCurrent(_ identity: UserRelationRequestIdentity) async throws {
    guard case .authenticatedOwner(_, let lease) = identity else { return }
    guard let accountAccess else { throw UserRelationPageLoadError.sessionChanged }
    let session = try await accountAccess.vault.activeSession()
    guard
      let session,
      lease.matches(session),
      session.credentials != nil
    else { throw UserRelationPageLoadError.sessionChanged }
  }

  private func applyInitialPage(
    _ response: UserRelationPageData,
    identity: UserRelationRequestIdentity,
    resetsRelationshipState: Bool,
    relationshipRevision: Int
  ) throws {
    guard response.currentPage == 1 else {
      throw BrowseError.unavailable("贴吧返回了错误的用户关系页码，请重新加载后再试。")
    }
    install(identity.binding)
    users = unique(response.users)
    updateConcernMetadataCompleteness(for: identity.binding)
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
  }

  private func applyContinuationPage(
    _ response: UserRelationPageData,
    identity: UserRelationRequestIdentity,
    requestedPage: Int
  ) throws {
    guard
      identity.binding == loadedPageBinding,
      response.currentPage == requestedPage,
      requestedPage == currentPage + 1
    else {
      throw BrowseError.unavailable("贴吧返回了错误的用户关系页码，请重新加载后再试。")
    }
    let merged = merge(users, response.users)
    let addedItems = merged.count > users.count
    users = merged
    updateConcernMetadataCompleteness(for: identity.binding)
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
  }

  private func install(_ binding: UserRelationPageBinding) {
    if loadedPageBinding != binding {
      followingFilter = .all
      mutualScanIsPaused = false
      clearRelationshipManagementSnapshot()
      relationshipMutationError = nil
    }
    loadedPageBinding = binding
    switch binding {
    case .publicProfile:
      clearRelationshipManagementSnapshot()
    case .authenticatedOwner(let lease):
      if overrideLease != lease {
        clearRelationshipOverrides()
        overrideLease = lease
      }
      managementLease = lease
    }
  }

  private func discardResultsFromChangedSession() {
    resetForAccountSessionChange(loadImmediately: false)
    state = .failed("账户会话已变化，请重新加载后再试。")
  }

  private func resetForAccountSessionChange(loadImmediately: Bool) {
    invalidateCurrentLoad()
    activeRelationshipMutation = nil
    relationshipMutationTask = nil
    pendingReloadResetsRelationshipState = nil
    mutatingUserID = nil
    relationshipMutationError = nil
    followingFilter = .all
    mutualScanIsPaused = false
    concernMetadataIsComplete = false
    loadedPageBinding = nil
    users = []
    loadedUsersByID = [:]
    knownLoadedUserIDs = []
    currentPage = 0
    hasMore = true
    isLoadingMore = false
    loadMoreError = nil
    totalCount = 0
    notice = ""
    visibilitySwitch = nil
    clearRelationshipManagementSnapshot()
    paginationEpoch &+= 1
    state = loadImmediately ? .loading : .idle
    if loadImmediately {
      loadInitialPage(resetsRelationshipState: true)
    }
  }

  private func updateConcernMetadataCompleteness(for binding: UserRelationPageBinding) {
    guard case .authenticatedOwner = binding else {
      concernMetadataIsComplete = false
      return
    }
    concernMetadataIsComplete = users.allSatisfy { user in
      guard let concernState = user.concernState else { return false }
      switch concernState {
      case .notFollowing, .following, .mutual:
        true
      case .unknown:
        false
      }
    }
    guard !concernMetadataIsComplete else { return }
    followingFilter = .all
    mutualScanIsPaused = false
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
      && loadedPageBinding == .authenticatedOwner(operation.prompt.lease)
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
    resetForAccountSessionChange(loadImmediately: true)
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

private enum UserRelationPageBinding: Equatable, Sendable {
  case publicProfile
  case authenticatedOwner(AccountSessionLease)
}

private enum UserRelationRequestIdentity: Sendable {
  case publicProfile
  case authenticatedOwner(session: StoredAccountSession, lease: AccountSessionLease)

  var binding: UserRelationPageBinding {
    switch self {
    case .publicProfile:
      .publicProfile
    case .authenticatedOwner(_, let lease):
      .authenticatedOwner(lease)
    }
  }
}

private enum UserRelationPageLoadError: Error {
  case sessionChanged
}

private struct UserRelationFollowOperation: Sendable {
  let id = UUID()
  let prompt: UserRelationFollowPrompt
}
