import Combine
import Foundation

enum PollVoteState: Equatable {
  case idle
  case signedOut
  case loading
  case ready(BrowsePoll)
  case submitting(previous: BrowsePoll, selectedOptionIDs: Set<Int32>)
  case failed(previous: BrowsePoll)
  case outcomeUnknown(previous: BrowsePoll)
}

@MainActor
final class PollVoteViewModel: ObservableObject {
  @Published private(set) var state: PollVoteState = .idle
  @Published private(set) var selectedOptionIDs: Set<Int32> = []
  @Published private(set) var errorMessage: String?
  @Published private(set) var anonymousPoll: BrowsePoll

  let forumID: Int64
  let threadID: Int64

  private let access: AccountAccess
  private let now: @Sendable () -> Date
  private var generation = 0
  private var activeOperation: PollVoteOperation?
  private var submissionTask: Task<Void, Never>?
  private var currentLease: PollVoteSessionLease?
  private var lastKnownPoll: BrowsePoll?

  init(
    anonymousPoll: BrowsePoll,
    forumID: Int64,
    threadID: Int64,
    access: AccountAccess,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.anonymousPoll = anonymousPoll
    self.forumID = forumID
    self.threadID = threadID
    self.access = access
    self.now = now
  }

  var displayedPoll: BrowsePoll {
    switch state {
    case .ready(let poll), .submitting(let poll, _), .failed(let poll),
      .outcomeUnknown(let poll):
      poll
    case .idle, .signedOut, .loading:
      lastKnownPoll ?? anonymousPoll
    }
  }

  var isSelectionEnabled: Bool {
    guard case .ready(let poll) = state, currentLease != nil else { return false }
    return poll.canVote(at: now())
  }

  var canSubmit: Bool {
    guard isSelectionEnabled, case .ready(let poll) = state else { return false }
    let optionIDs = Set(poll.options.map(\.id))
    return !selectedOptionIDs.isEmpty
      && selectedOptionIDs.isSubset(of: optionIDs)
      && (poll.isMultipleChoice || selectedOptionIDs.count == 1)
  }

  func loadIfNeeded() async {
    switch state {
    case .idle, .failed:
      await reload()
    case .signedOut, .loading, .ready, .submitting, .outcomeUnknown:
      return
    }
  }

  func reload() async {
    guard activeOperation == nil else { return }
    generation &+= 1
    let requestGeneration = generation
    let previousLease = currentLease
    errorMessage = nil
    currentLease = nil
    selectedOptionIDs = []

    guard forumID > 0, threadID > 0 else {
      lastKnownPoll = nil
      state = .failed(previous: anonymousPoll)
      errorMessage = "投票所属的贴吧或主题无效。"
      return
    }

    state = .loading
    do {
      let activeSession = try await access.vault.activeSession()
      guard requestGeneration == generation else { return }
      guard let session = activeSession else {
        lastKnownPoll = nil
        state = .signedOut
        return
      }
      let lease = PollVoteSessionLease(session)
      if let previousLease, previousLease != lease {
        lastKnownPoll = nil
      }
      currentLease = lease
      guard session.credentials != nil else {
        lastKnownPoll = nil
        state = .failed(previous: anonymousPoll)
        errorMessage = PollVoteError.fullCredentialsRequired.localizedDescription
        return
      }

      let data = try await access.service.pollState(
        session: session,
        forumID: forumID,
        threadID: threadID
      )
      try Task.checkCancellation()
      let poll = try resolve(data, lease: lease)
      guard requestGeneration == generation else { return }

      switch await sessionLeaseState(lease) {
      case .current:
        guard requestGeneration == generation else { return }
        lastKnownPoll = poll
        selectedOptionIDs = poll.isPolled ? poll.selectedOptionIDs : []
        state = .ready(poll)
      case .changed:
        clearAuthenticatedSnapshot()
        state = .idle
      case .unavailable:
        currentLease = nil
        state = .failed(previous: lastKnownPoll ?? anonymousPoll)
        errorMessage = "无法读取当前账户，请稍后重试。"
      }
    } catch is CancellationError {
      guard requestGeneration == generation else { return }
      clearAuthenticatedSnapshot()
      state = .idle
    } catch {
      guard requestGeneration == generation, !Task.isCancelled else { return }
      state = .failed(previous: lastKnownPoll ?? anonymousPoll)
      errorMessage = error.localizedDescription
    }
  }

  func toggleSelection(optionID: Int32) {
    guard
      isSelectionEnabled,
      case .ready(let poll) = state,
      poll.options.contains(where: { $0.id == optionID })
    else { return }

    if poll.isMultipleChoice {
      if selectedOptionIDs.contains(optionID) {
        selectedOptionIDs.remove(optionID)
      } else {
        selectedOptionIDs.insert(optionID)
      }
    } else {
      selectedOptionIDs = [optionID]
    }
  }

  func beginSubmitSelection() {
    _ = startSubmissionIfPossible()
  }

  func submitSelection() async {
    guard let task = startSubmissionIfPossible() else { return }
    await task.value
  }

  private func startSubmissionIfPossible() -> Task<Void, Never>? {
    guard
      submissionTask == nil,
      activeOperation == nil,
      canSubmit,
      case .ready(let previous) = state,
      let expectedLease = currentLease
    else { return nil }

    let requestedOptionIDs = selectedOptionIDs
    let operation = PollVoteOperation(
      lease: expectedLease,
      selectedOptionIDs: requestedOptionIDs
    )
    activeOperation = operation
    generation &+= 1
    let requestGeneration = generation
    errorMessage = nil
    state = .submitting(previous: previous, selectedOptionIDs: requestedOptionIDs)
    let task = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.performSubmission(
        operation: operation,
        previous: previous,
        requestGeneration: requestGeneration
      )
    }
    submissionTask = task
    return task
  }

  private func performSubmission(
    operation: PollVoteOperation,
    previous: BrowsePoll,
    requestGeneration: Int
  ) async {
    defer {
      if activeOperation?.id == operation.id {
        activeOperation = nil
        submissionTask = nil
      }
    }

    let session: StoredAccountSession
    do {
      let activeSession = try await access.vault.activeSession()
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      guard
        let activeSession,
        operation.lease.matches(activeSession),
        activeSession.credentials != nil
      else {
        clearAuthenticatedSnapshot()
        state = .idle
        return
      }
      session = activeSession
    } catch is CancellationError {
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      state = .ready(previous)
      errorMessage = "未能读取当前账户，尚未开始投票。"
      return
    } catch {
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      currentLease = nil
      lastKnownPoll = previous
      state = .failed(previous: previous)
      errorMessage = "无法读取当前账户，请稍后重试。"
      return
    }
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }

    do {
      let data = try await access.service.submitPollVote(
        session: session,
        forumID: forumID,
        threadID: threadID,
        selectedOptionIDs: operation.selectedOptionIDs
      )
      let poll = try resolve(data, lease: operation.lease)
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }

      let leaseState = await sessionLeaseState(operation.lease)
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      switch leaseState {
      case .current:
        lastKnownPoll = poll
        selectedOptionIDs = poll.selectedOptionIDs
        if poll.isPolled, poll.selectedOptionIDs == operation.selectedOptionIDs {
          state = .ready(poll)
        } else {
          state = .failed(previous: poll)
          errorMessage = "贴吧没有确认本次投票选项，请重新加载权威状态后再试。"
        }
      case .changed:
        clearAuthenticatedSnapshot()
        state = .idle
      case .unavailable:
        currentLease = nil
        lastKnownPoll = previous
        state = .failed(previous: previous)
        errorMessage = "无法读取当前账户，请稍后重试。"
      }
    } catch is CancellationError {
      await publishOutcomeUnknownIfCurrent(
        operation: operation,
        generation: requestGeneration,
        previous: previous
      )
    } catch let error as PollVoteError where error == .outcomeUnknown {
      await publishOutcomeUnknownIfCurrent(
        operation: operation,
        generation: requestGeneration,
        previous: previous
      )
    } catch {
      await publishSubmissionFailureIfCurrent(
        operation: operation,
        generation: requestGeneration,
        previous: previous,
        message: error.localizedDescription
      )
    }
  }

  func accountSessionDidChange() async {
    let token = invalidateForAccountSessionChange()
    await reloadAfterAccountSessionChange(ifCurrent: token)
  }

  @discardableResult
  func invalidateForAccountSessionChange() -> Int {
    cancelSubmissionTask()
    generation &+= 1
    clearAuthenticatedSnapshot()
    errorMessage = nil
    state = .idle
    return generation
  }

  func reloadAfterAccountSessionChange(ifCurrent token: Int) async {
    guard token == generation else { return }
    await reload()
  }

  func replaceAnonymousSnapshot(_ poll: BrowsePoll) {
    let previousAnonymousPoll = anonymousPoll
    anonymousPoll = poll
    guard lastKnownPoll == nil else { return }
    if case .failed(let previous) = state, previous == previousAnonymousPoll {
      state = .failed(previous: poll)
    }
  }

  func presentationDidDisappear() {
    cancelSubmissionTask()
    generation &+= 1
    clearAuthenticatedSnapshot()
    errorMessage = nil
    state = .idle
  }

  func dismissError() {
    errorMessage = nil
  }

  private func resolve(
    _ data: PollVoteData,
    lease: PollVoteSessionLease
  ) throws -> BrowsePoll {
    guard
      data.userID == lease.userID,
      data.forumID == forumID,
      data.threadID == threadID
    else {
      throw PollVoteError.unavailable("贴吧返回了不匹配的投票状态，请重新加载后再试。")
    }
    let poll = data.poll
    let optionIDs = poll.options.map(\.id)
    let uniqueOptionIDs = Set(optionIDs)
    guard
      (2...100).contains(optionIDs.count),
      optionIDs.allSatisfy({ $0 > 0 }),
      uniqueOptionIDs.count == optionIDs.count,
      poll.selectedOptionIDs.isSubset(of: uniqueOptionIDs),
      poll.isMultipleChoice || poll.selectedOptionIDs.count <= 1,
      poll.isPolled == !poll.selectedOptionIDs.isEmpty,
      poll.participantCount >= 0,
      poll.totalVoteCount >= 0,
      poll.endTimestamp >= 0,
      poll.status >= 0
    else {
      throw PollVoteError.unavailable("贴吧返回了无效的投票状态，请重新加载后再试。")
    }
    return poll
  }

  private func operationIsCurrent(
    _ operation: PollVoteOperation,
    generation requestGeneration: Int
  ) -> Bool {
    requestGeneration == generation && activeOperation?.id == operation.id
  }

  private func sessionLeaseState(
    _ lease: PollVoteSessionLease
  ) async -> PollVoteSessionLeaseState {
    do {
      guard let session = try await access.vault.activeSession() else { return .changed }
      return lease.matches(session) ? .current : .changed
    } catch {
      return .unavailable
    }
  }

  private func publishOutcomeUnknownIfCurrent(
    operation: PollVoteOperation,
    generation requestGeneration: Int,
    previous: BrowsePoll
  ) async {
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }
    switch await sessionLeaseState(operation.lease) {
    case .current:
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      lastKnownPoll = previous
      state = .outcomeUnknown(previous: previous)
      errorMessage = PollVoteError.outcomeUnknown.localizedDescription
    case .changed:
      clearAuthenticatedSnapshot()
      state = .idle
    case .unavailable:
      currentLease = nil
      lastKnownPoll = previous
      state = .outcomeUnknown(previous: previous)
      errorMessage = PollVoteError.outcomeUnknown.localizedDescription
    }
  }

  private func publishSubmissionFailureIfCurrent(
    operation: PollVoteOperation,
    generation requestGeneration: Int,
    previous: BrowsePoll,
    message: String
  ) async {
    guard operationIsCurrent(operation, generation: requestGeneration) else { return }
    switch await sessionLeaseState(operation.lease) {
    case .current:
      guard operationIsCurrent(operation, generation: requestGeneration) else { return }
      lastKnownPoll = previous
      state = .failed(previous: previous)
      errorMessage = message
    case .changed:
      clearAuthenticatedSnapshot()
      state = .idle
    case .unavailable:
      currentLease = nil
      lastKnownPoll = previous
      state = .failed(previous: previous)
      errorMessage = "无法读取当前账户，请稍后重试。"
    }
  }

  private func clearAuthenticatedSnapshot() {
    currentLease = nil
    lastKnownPoll = nil
    selectedOptionIDs = []
  }

  private func cancelSubmissionTask() {
    let task = submissionTask
    submissionTask = nil
    activeOperation = nil
    task?.cancel()
  }
}

private enum PollVoteSessionLeaseState: Sendable {
  case current
  case changed
  case unavailable
}

private struct PollVoteSessionLease: Equatable, Sendable {
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

private struct PollVoteOperation: Equatable, Sendable {
  let id = UUID()
  let lease: PollVoteSessionLease
  let selectedOptionIDs: Set<Int32>
}
