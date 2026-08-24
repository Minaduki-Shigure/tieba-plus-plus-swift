import Foundation

enum ForumMembershipMutationConfirmationSource: Equatable, Sendable {
  case preflight
  case writeResponse
  case reconciliation
}

enum AccountSessionLeaseState: Equatable, Sendable {
  case current
  case changed
  case unavailable
}

struct ForumMembershipMutationConfirmation: Equatable, Sendable {
  let change: ForumMembershipChange
  let source: ForumMembershipMutationConfirmationSource
  let leaseState: AccountSessionLeaseState
  let warning: String?
}

enum ForumMembershipMutationOutcome: Equatable, Sendable {
  case confirmed(ForumMembershipMutationConfirmation)
  case unchanged(isFollowed: Bool, message: String)
  case sessionChanged
  case unavailable(previouslyFollowed: Bool, message: String)
  case rejected(message: String)
}

struct ForumMembershipMutationRequest: Equatable, Sendable {
  let forumID: Int64
  let forumName: String
  let previouslyFollowed: Bool
  let targetFollowed: Bool
  let expectedLease: AccountSessionLease
  let verifiesCurrentState: Bool
}

protocol ForumMembershipMutating: Sendable {
  func setFollowed(
    _ request: ForumMembershipMutationRequest
  ) async -> ForumMembershipMutationOutcome
}

actor ForumMembershipMutationCoordinator: ForumMembershipMutating {
  private struct OperationKey: Hashable, Sendable {
    let lease: AccountSessionLease
    let forumID: Int64
  }

  private struct InFlightOperation: Sendable {
    let id: UUID
    let normalizedForumName: String
    let targetFollowed: Bool
    let verifiesCurrentState: Bool
    let task: Task<ForumMembershipMutationOutcome, Never>
  }

  private let vault: any AccountVault
  private let service: any AccountService
  private var inFlightOperations: [OperationKey: InFlightOperation] = [:]
  private var sharedWaiterCounts: [OperationKey: Int] = [:]

  init(vault: any AccountVault, service: any AccountService) {
    self.vault = vault
    self.service = service
  }

  func setFollowed(
    _ request: ForumMembershipMutationRequest
  ) async -> ForumMembershipMutationOutcome {
    guard let normalizedForumName = Self.normalizedForumName(request.forumName) else {
      return .rejected(message: "贴吧缺少有效的标识或吧名。")
    }
    guard
      request.expectedLease.userID > 0,
      request.forumID > 0,
      request.previouslyFollowed != request.targetFollowed
    else {
      return .rejected(message: "当前关注状态没有可执行的变更。")
    }

    let normalizedRequest = ForumMembershipMutationRequest(
      forumID: request.forumID,
      forumName: request.forumName.trimmingCharacters(in: .whitespacesAndNewlines),
      previouslyFollowed: request.previouslyFollowed,
      targetFollowed: request.targetFollowed,
      expectedLease: request.expectedLease,
      verifiesCurrentState: request.verifiesCurrentState
    )
    let key = OperationKey(lease: request.expectedLease, forumID: request.forumID)
    if let inFlight = inFlightOperations[key] {
      guard
        inFlight.normalizedForumName == normalizedForumName,
        inFlight.targetFollowed == request.targetFollowed,
        inFlight.verifiesCurrentState == request.verifiesCurrentState
      else {
        return .rejected(message: "同一贴吧的另一项关注操作仍在进行，请稍后再试。")
      }
      sharedWaiterCounts[key, default: 0] += 1
      defer {
        let remaining = (sharedWaiterCounts[key] ?? 1) - 1
        if remaining > 0 {
          sharedWaiterCounts[key] = remaining
        } else {
          sharedWaiterCounts.removeValue(forKey: key)
        }
      }
      return await inFlight.task.value
    }

    let operationID = UUID()
    let vault = vault
    let service = service
    // After user confirmation, keep reconciliation independent of any presenting view.
    let task = Task {
      await Self.execute(
        normalizedRequest,
        vault: vault,
        service: service
      )
    }
    inFlightOperations[key] = InFlightOperation(
      id: operationID,
      normalizedForumName: normalizedForumName,
      targetFollowed: request.targetFollowed,
      verifiesCurrentState: request.verifiesCurrentState,
      task: task
    )
    let outcome = await task.value
    if inFlightOperations[key]?.id == operationID {
      inFlightOperations.removeValue(forKey: key)
    }
    return outcome
  }

  func sharedWaiterCount(lease: AccountSessionLease, forumID: Int64) -> Int {
    sharedWaiterCounts[OperationKey(lease: lease, forumID: forumID)] ?? 0
  }

  private static func execute(
    _ request: ForumMembershipMutationRequest,
    vault: any AccountVault,
    service: any AccountService
  ) async -> ForumMembershipMutationOutcome {
    let initialSession: StoredAccountSession
    switch await activeSession(expectedLease: request.expectedLease, vault: vault) {
    case .current(let session):
      initialSession = session
    case .changed:
      return .sessionChanged
    case .unavailable:
      return .unavailable(
        previouslyFollowed: request.previouslyFollowed,
        message: "无法读取当前账户，请稍后重试。"
      )
    }

    if request.verifiesCurrentState {
      do {
        let membership = try await service.forumMembership(
          session: initialSession,
          forumID: request.forumID,
          forumName: request.forumName
        )
        try validate(
          membership,
          request: request,
          expectedFollowed: nil
        )
        switch await leaseState(expectedLease: request.expectedLease, vault: vault) {
        case .current:
          if membership.isFollowed == request.targetFollowed {
            return await confirmed(
              request: request,
              source: .preflight,
              leaseState: .current,
              warning: nil
            )
          }
        case .changed:
          return .sessionChanged
        case .unavailable:
          return .unavailable(
            previouslyFollowed: request.previouslyFollowed,
            message: "无法读取当前账户，请稍后重试。"
          )
        }
      } catch {
        return .unavailable(
          previouslyFollowed: request.previouslyFollowed,
          message: error.localizedDescription
        )
      }
    }

    let writeSession: StoredAccountSession
    switch await activeSession(expectedLease: request.expectedLease, vault: vault) {
    case .current(let session):
      writeSession = session
    case .changed:
      return .sessionChanged
    case .unavailable:
      return .unavailable(
        previouslyFollowed: request.previouslyFollowed,
        message: "无法读取当前账户，请稍后重试。"
      )
    }

    do {
      let membership = try await service.setForumFollowed(
        session: writeSession,
        forumID: request.forumID,
        forumName: request.forumName,
        isFollowed: request.targetFollowed
      )
      try validate(
        membership,
        request: request,
        expectedFollowed: request.targetFollowed
      )
      let state = await leaseState(expectedLease: request.expectedLease, vault: vault)
      return await confirmed(
        request: request,
        source: .writeResponse,
        leaseState: state,
        warning: nil
      )
    } catch {
      return await reconcile(
        request,
        originalMessage: error.localizedDescription,
        vault: vault,
        service: service
      )
    }
  }

  private static func reconcile(
    _ request: ForumMembershipMutationRequest,
    originalMessage: String,
    vault: any AccountVault,
    service: any AccountService
  ) async -> ForumMembershipMutationOutcome {
    let session: StoredAccountSession
    switch await activeSession(expectedLease: request.expectedLease, vault: vault) {
    case .current(let currentSession):
      session = currentSession
    case .changed:
      return .sessionChanged
    case .unavailable:
      return .unavailable(
        previouslyFollowed: request.previouslyFollowed,
        message: originalMessage
      )
    }

    do {
      let membership = try await service.forumMembership(
        session: session,
        forumID: request.forumID,
        forumName: request.forumName
      )
      try validate(membership, request: request, expectedFollowed: nil)
      switch await leaseState(expectedLease: request.expectedLease, vault: vault) {
      case .current:
        if membership.isFollowed == request.targetFollowed {
          return await confirmed(
            request: request,
            source: .reconciliation,
            leaseState: .current,
            warning: originalMessage
          )
        }
        return .unchanged(isFollowed: membership.isFollowed, message: originalMessage)
      case .changed:
        return .sessionChanged
      case .unavailable:
        return .unavailable(
          previouslyFollowed: request.previouslyFollowed,
          message: originalMessage
        )
      }
    } catch {
      return .unavailable(
        previouslyFollowed: request.previouslyFollowed,
        message: originalMessage
      )
    }
  }

  private static func confirmed(
    request: ForumMembershipMutationRequest,
    source: ForumMembershipMutationConfirmationSource,
    leaseState: AccountSessionLeaseState,
    warning: String?
  ) async -> ForumMembershipMutationOutcome {
    let change = ForumMembershipChange(
      accountID: request.expectedLease.userID,
      sessionRevision: request.expectedLease.sessionRevision,
      forumID: request.forumID,
      isFollowed: request.targetFollowed
    )
    await AccountChangeNotifications.postForumMembershipChange(change)
    return .confirmed(
      ForumMembershipMutationConfirmation(
        change: change,
        source: source,
        leaseState: leaseState,
        warning: warning
      )
    )
  }

  private static func validate(
    _ membership: ForumMembershipData,
    request: ForumMembershipMutationRequest,
    expectedFollowed: Bool?
  ) throws {
    guard
      membership.userID == request.expectedLease.userID,
      membership.forumID == request.forumID,
      normalizedForumName(membership.forumName) == normalizedForumName(request.forumName),
      expectedFollowed.map({ membership.isFollowed == $0 }) ?? true
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的关注状态，请重新加载后再试。")
    }
  }

  private enum ActiveSessionResult: Sendable {
    case current(StoredAccountSession)
    case changed
    case unavailable
  }

  private static func activeSession(
    expectedLease: AccountSessionLease,
    vault: any AccountVault
  ) async -> ActiveSessionResult {
    do {
      guard let session = try await vault.activeSession() else { return .changed }
      guard expectedLease.matches(session) else { return .changed }
      return .current(session)
    } catch {
      return .unavailable
    }
  }

  private static func leaseState(
    expectedLease: AccountSessionLease,
    vault: any AccountVault
  ) async -> AccountSessionLeaseState {
    switch await activeSession(expectedLease: expectedLease, vault: vault) {
    case .current:
      return .current
    case .changed:
      return .changed
    case .unavailable:
      return .unavailable
    }
  }

  private static func normalizedForumName(_ forumName: String) -> String? {
    FollowedForumPin.normalizedForumName(forumName)
  }
}
