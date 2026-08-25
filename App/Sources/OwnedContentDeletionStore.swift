import Combine
import SwiftUI

enum OwnedContentDeletionEntryState: Equatable {
  case resolvingAccount
  case signedOut
  case unavailable
  case ready(AccountSessionLease)
  case deleting(AccountSessionLease)
  case accepted(OwnedContentDeletionReceipt)
  case failed(AccountSessionLease, message: String)
  case outcomeUnknown(AccountSessionLease, message: String)
}

@MainActor
final class OwnedContentDeletionEntry: ObservableObject {
  let target: OwnedContentDeletionTarget
  @Published private(set) var state: OwnedContentDeletionEntryState = .resolvingAccount

  init(target: OwnedContentDeletionTarget) {
    self.target = target
  }

  fileprivate func setState(_ state: OwnedContentDeletionEntryState) {
    self.state = state
  }
}

struct PendingOwnedContentDeletion: Equatable, Sendable {
  let target: OwnedContentDeletionTarget
  let lease: AccountSessionLease

  var confirmationTitle: String {
    switch target.kind {
    case .topic:
      "删除这个主题？"
    case .post:
      "删除第 \(target.floor) 楼？"
    }
  }

  var actionTitle: String {
    switch target.kind {
    case .topic: "删除主题"
    case .post: "删除本楼"
    }
  }

  var confirmationMessage: String {
    switch target.kind {
    case .topic:
      "将使用当前贴吧账户永久删除你发布的主题；成功后整个帖子将无法继续浏览。此操作无法撤销。"
    case .post:
      "将永久删除你发布的第 \(target.floor) 楼及其楼中楼回复。此操作无法撤销。"
    }
  }
}

@MainActor
final class OwnedContentDeletionStore {
  private struct OperationKey: Hashable {
    let lease: AccountSessionLease
    let target: OwnedContentDeletionTarget
  }

  private enum Terminal {
    case accepted(OwnedContentDeletionReceipt)
    case outcomeUnknown(String)
  }

  private struct Flight {
    let id: UUID
    let task: Task<OwnedContentDeletionReceipt, Error>
  }

  private let access: AccountAccess
  private var entries: [OwnedContentDeletionTarget: OwnedContentDeletionEntry] = [:]
  private var currentSession: StoredAccountSession?
  private var hasResolvedSession = false
  private var sessionGeneration = 0
  private var flights: [OperationKey: Flight] = [:]
  // Keep irreversible terminal outcomes bound to content, not a replaceable session lease.
  private var terminals: [OwnedContentDeletionTarget: Terminal] = [:]
  private var failures: [OperationKey: String] = [:]
  private var sessionChangeCancellable: AnyCancellable?

  init(access: AccountAccess, observesAccountSessionChanges: Bool = true) {
    self.access = access
    if observesAccountSessionChanges {
      sessionChangeCancellable = NotificationCenter.default.publisher(for: .accountSessionDidChange)
        .sink { [weak self] _ in
          Task { @MainActor [weak self] in
            await self?.reloadActiveSession()
          }
        }
    }
    Task { @MainActor [weak self] in
      await self?.reloadActiveSession()
    }
  }

  func entry(for target: OwnedContentDeletionTarget) -> OwnedContentDeletionEntry {
    if let entry = entries[target] { return entry }
    let entry = OwnedContentDeletionEntry(target: target)
    entries[target] = entry
    applyCurrentState(to: entry)
    return entry
  }

  func pendingRequest(for target: OwnedContentDeletionTarget) -> PendingOwnedContentDeletion? {
    let entry = entry(for: target)
    switch entry.state {
    case .ready(let lease), .failed(let lease, _):
      return PendingOwnedContentDeletion(target: target, lease: lease)
    case .resolvingAccount, .signedOut, .unavailable, .deleting, .accepted,
      .outcomeUnknown:
      return nil
    }
  }

  func outcomeUnknownTarget(threadID: Int64) -> OwnedContentDeletionTarget? {
    terminals.compactMap { target, terminal in
      guard target.threadID == threadID else { return nil }
      if case .outcomeUnknown = terminal { return target }
      return nil
    }
    .sorted { lhs, rhs in
      if lhs.floor != rhs.floor { return lhs.floor < rhs.floor }
      return lhs.objectID < rhs.objectID
    }
    .first
  }

  @discardableResult
  func delete(
    _ pending: PendingOwnedContentDeletion
  ) async throws -> OwnedContentDeletionReceipt {
    guard pending.target.authorID == pending.lease.userID else {
      throw OwnedContentDeletionError.unavailable("删除目标不属于当前账户。")
    }
    let key = OperationKey(lease: pending.lease, target: pending.target)
    if let outcome = try await existingOutcome(for: key, pending: pending) {
      return outcome
    }

    let session = try await access.vault.activeSession()
    guard
      let session,
      pending.lease.matches(session),
      session.credentials != nil
    else {
      await reloadActiveSession()
      throw OwnedContentDeletionError.unavailable(
        "当前账户已经变化，未发送删除请求。请重新确认后再试。"
      )
    }

    // The vault read suspends MainActor; another confirmation may have installed a flight.
    if let outcome = try await existingOutcome(for: key, pending: pending) {
      return outcome
    }

    failures.removeValue(forKey: key)
    entry(for: pending.target).setState(.deleting(pending.lease))
    let service = access.service
    let operationID = UUID()
    let task = Task.detached {
      try await service.deleteOwnedContent(session: session, target: pending.target)
    }
    flights[key] = Flight(id: operationID, task: task)
    defer {
      if flights[key]?.id == operationID {
        flights.removeValue(forKey: key)
      }
    }

    do {
      let receipt = try await validatedReceipt(task: task, for: pending)
      terminals[pending.target] = .accepted(receipt)
      applyCurrentState(to: entry(for: pending.target))
      return receipt
    } catch OwnedContentDeletionError.outcomeUnknown {
      recordOutcomeUnknown(for: pending)
      throw OwnedContentDeletionError.outcomeUnknown
    } catch {
      let message = error.localizedDescription
      failures[key] = message
      applyCurrentState(to: entry(for: pending.target))
      throw error
    }
  }

  func reloadActiveSession() async {
    sessionGeneration &+= 1
    let generation = sessionGeneration
    do {
      let session = try await access.vault.activeSession()
      guard generation == sessionGeneration else { return }
      currentSession = session
      hasResolvedSession = true
    } catch {
      guard generation == sessionGeneration else { return }
      currentSession = nil
      hasResolvedSession = true
    }
    for entry in entries.values {
      applyCurrentState(to: entry)
    }
  }

  private func applyCurrentState(to entry: OwnedContentDeletionEntry) {
    guard hasResolvedSession else {
      entry.setState(.resolvingAccount)
      return
    }
    guard let session = currentSession else {
      entry.setState(.signedOut)
      return
    }
    let lease = AccountSessionLease(session)
    guard session.id == entry.target.authorID, session.credentials != nil else {
      entry.setState(.unavailable)
      return
    }
    let key = OperationKey(lease: lease, target: entry.target)
    if let terminal = terminals[entry.target] {
      switch terminal {
      case .accepted(let receipt):
        entry.setState(.accepted(receipt))
      case .outcomeUnknown(let message):
        entry.setState(.outcomeUnknown(lease, message: message))
      }
    } else if flights[key] != nil {
      entry.setState(.deleting(lease))
    } else if let message = failures[key] {
      entry.setState(.failed(lease, message: message))
    } else {
      entry.setState(.ready(lease))
    }
  }

  private func validatedReceipt(
    task: Task<OwnedContentDeletionReceipt, Error>,
    for pending: PendingOwnedContentDeletion
  ) async throws -> OwnedContentDeletionReceipt {
    let receipt = try await task.value
    guard
      receipt.accountID == pending.lease.userID,
      receipt.sessionRevision == pending.lease.sessionRevision,
      receipt.target == pending.target
    else {
      throw OwnedContentDeletionError.outcomeUnknown
    }
    return receipt
  }

  private func existingOutcome(
    for key: OperationKey,
    pending: PendingOwnedContentDeletion
  ) async throws -> OwnedContentDeletionReceipt? {
    if let terminal = terminals[pending.target] {
      switch terminal {
      case .accepted(let receipt):
        return receipt
      case .outcomeUnknown:
        throw OwnedContentDeletionError.outcomeUnknown
      }
    }
    if let flight = flights[key] {
      do {
        return try await validatedReceipt(task: flight.task, for: pending)
      } catch OwnedContentDeletionError.outcomeUnknown {
        recordOutcomeUnknown(for: pending)
        throw OwnedContentDeletionError.outcomeUnknown
      }
    }
    if flights.keys.contains(where: { $0.target == pending.target }) {
      throw OwnedContentDeletionError.unavailable(
        "同一内容已有其他账户会话发起的删除操作。"
      )
    }
    return nil
  }

  private func recordOutcomeUnknown(for pending: PendingOwnedContentDeletion) {
    let message = OwnedContentDeletionError.outcomeUnknown.localizedDescription
    terminals[pending.target] = .outcomeUnknown(message)
    applyCurrentState(to: entry(for: pending.target))
  }
}

struct OwnedContentDeletionMenuSlot: View {
  let store: OwnedContentDeletionStore?
  let target: OwnedContentDeletionTarget?
  let requestDeletion: (PendingOwnedContentDeletion) -> Void

  @ViewBuilder
  var body: some View {
    if let store, let target {
      OwnedContentDeletionObservedMenuItem(
        entry: store.entry(for: target),
        store: store,
        requestDeletion: requestDeletion
      )
    }
  }
}

private struct OwnedContentDeletionObservedMenuItem: View {
  @ObservedObject private var entry: OwnedContentDeletionEntry
  let store: OwnedContentDeletionStore
  let requestDeletion: (PendingOwnedContentDeletion) -> Void

  init(
    entry: OwnedContentDeletionEntry,
    store: OwnedContentDeletionStore,
    requestDeletion: @escaping (PendingOwnedContentDeletion) -> Void
  ) {
    _entry = ObservedObject(wrappedValue: entry)
    self.store = store
    self.requestDeletion = requestDeletion
  }

  @ViewBuilder
  var body: some View {
    switch entry.state {
    case .ready, .failed:
      Button(role: .destructive) {
        if let pending = store.pendingRequest(for: entry.target) {
          requestDeletion(pending)
        }
      } label: {
        Label(actionTitle, systemImage: "trash")
      }
      .accessibilityIdentifier("delete-owned-content-\(entry.target.objectID)")
    case .deleting:
      Button {} label: {
        Label("正在删除", systemImage: "hourglass")
      }
      .disabled(true)
    case .resolvingAccount, .signedOut, .unavailable, .accepted, .outcomeUnknown:
      EmptyView()
    }
  }

  private var actionTitle: String {
    switch entry.target.kind {
    case .topic: "删除主题"
    case .post: "删除第 \(entry.target.floor) 楼"
    }
  }
}

struct ThreadTopicActionsMenu: View {
  let reportTarget: ContentReportTarget?
  let deletionStore: OwnedContentDeletionStore?
  let deletionTarget: OwnedContentDeletionTarget?
  let requestDeletion: (PendingOwnedContentDeletion) -> Void

  @ViewBuilder
  var body: some View {
    if reportTarget != nil || deletionTarget != nil {
      Menu {
        ContentReportMenuItem(
          target: reportTarget,
          title: "举报主题",
          accessibilityIdentifier: "thread-report-topic"
        )
        OwnedContentDeletionMenuSlot(
          store: deletionStore,
          target: deletionTarget,
          requestDeletion: requestDeletion
        )
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .accessibilityLabel("更多帖子操作")
      .help("更多帖子操作")
    }
  }
}
