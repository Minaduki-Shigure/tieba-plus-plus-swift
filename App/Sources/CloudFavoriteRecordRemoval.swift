import Foundation
import TiebaCore

/// This identifies a saved-list record, not a post or a forum membership.
/// It deliberately cannot be passed to the normal FID/PID favorite APIs.
struct CloudFavoriteRecordTarget: Hashable, Sendable {
  let userID: Int64
  let threadID: Int64
  let sessionRevision: UUID

  init?(userID: Int64, threadID: Int64, sessionRevision: UUID) {
    guard userID > 0, threadID > 0 else { return nil }
    self.userID = userID
    self.threadID = threadID
    self.sessionRevision = sessionRevision
  }

  var key: CloudFavoriteMutationLedgerKey {
    // The initializer above and the ledger use the same positive-ID contract.
    CloudFavoriteMutationLedgerKey(userID: userID, threadID: threadID)!
  }

  func matches(_ session: StoredAccountSession) -> Bool {
    session.id == userID && session.sessionRevision == sessionRevision
  }
}

struct CloudFavoriteRecordRemovalStatus: Equatable, Sendable, Identifiable {
  let threadID: Int64
  let phase: CloudFavoriteMutationLedgerPhase
  let receiptAcknowledged: Bool
  let observation: TiebaCloudFavoriteRecordObservation?

  var id: Int64 { threadID }
  var requiresVerification: Bool { phase != .observedAbsent }

  var message: String {
    switch phase {
    case .observedAbsent:
      return receiptAcknowledged
        ? "贴吧已接受移除请求；两轮完整列表中均未再找到这条收藏。"
        : "两轮完整列表中均未再找到这条收藏；此前写入是否被接受仍无回执。"
    case .acceptedAwaitingVerification:
      return "贴吧已接受移除请求，但尚未确认列表中已移除。可以继续只读核验，不会重发请求。"
    case .dispatchPending, .outcomeUnknown:
      return "移除请求的结果尚未确认。该主题的云收藏写入已暂停；继续核验只读取列表，不会重发请求。"
    }
  }
}

enum CloudFavoriteRecordRemovalError: LocalizedError, Equatable, Sendable {
  case unavailable
  case sessionChanged
  case busy
  case pendingVerification
  case verificationCompleted
  case rejected(String)

  var errorDescription: String? {
    switch self {
    case .unavailable: "无法安全读取云收藏操作记录，请重新打开后再试。"
    case .sessionChanged: "账户或登录凭据已变化，请刷新列表后重新确认。"
    case .busy: "该主题正在更新云收藏，请等待当前操作完成。"
    case .pendingVerification: "此前的云收藏移除尚未核验，请在“贴吧收藏”中继续核验；不会重发写入请求。"
    case .verificationCompleted: "旧操作已经核验完成，当前列表已变化。请刷新后重新确认，不会根据旧记录再次移除。"
    case .rejected(let message): message
    }
  }
}

/// The same UID/TID gate surrounds ordinary add/update/remove and record cleanup.
/// A durable pending/unknown cleanup blocks every writer, including after login
/// renewal; only an explicit read-only absence observation can release it.
actor CloudFavoriteMutationGate {
  let ledger: any CloudFavoriteMutationLedgerRepository
  private var active: [CloudFavoriteMutationLedgerKey: UUID] = [:]
  private var failedClosed: Set<CloudFavoriteMutationLedgerKey> = []

  init(ledger: any CloudFavoriteMutationLedgerRepository) {
    self.ledger = ledger
  }

  func acquire(
    _ key: CloudFavoriteMutationLedgerKey,
    allowsVerification: Bool = false
  ) async throws -> UUID {
    guard active[key] == nil else { throw CloudFavoriteRecordRemovalError.busy }
    guard allowsVerification || !failedClosed.contains(key) else {
      throw CloudFavoriteRecordRemovalError.unavailable
    }
    let token = UUID()
    active[key] = token
    do {
      if let record = try await ledger.record(for: key), record.blocksWrites,
        !allowsVerification
      {
        throw CloudFavoriteRecordRemovalError.pendingVerification
      }
      return token
    } catch {
      active.removeValue(forKey: key)
      throw error
    }
  }

  func release(_ key: CloudFavoriteMutationLedgerKey, token: UUID) {
    guard active[key] == token else { return }
    active.removeValue(forKey: key)
  }

  func failClosed(_ key: CloudFavoriteMutationLedgerKey) {
    failedClosed.insert(key)
  }

  func requiresReadOnlyRecovery(_ key: CloudFavoriteMutationLedgerKey) -> Bool {
    failedClosed.contains(key)
  }

  func didPersistVerifiedAbsence(_ key: CloudFavoriteMutationLedgerKey) {
    failedClosed.remove(key)
  }

  func performOrdinaryWrite<Value: Sendable>(
    key: CloudFavoriteMutationLedgerKey,
    operation: @escaping @Sendable () async throws -> Value
  ) async throws -> Value {
    let token = try await acquire(key)
    defer { release(key, token: token) }
    return try await operation()
  }
}

actor CloudFavoriteRecordRemovalCoordinator {
  private let client: any TiebaAuthenticatedAccountClient
  private let gate: CloudFavoriteMutationGate
  private let vault: (any AccountVault)?

  init(
    client: any TiebaAuthenticatedAccountClient,
    gate: CloudFavoriteMutationGate,
    vault: (any AccountVault)?
  ) {
    self.client = client
    self.gate = gate
    self.vault = vault
  }

  func statuses(session: StoredAccountSession) async throws -> [CloudFavoriteRecordRemovalStatus] {
    try await requireCurrent(session)
    let records = try await gate.ledger.records()
    try await requireCurrent(session)
    return records.filter { $0.key.userID == session.id && $0.blocksWrites }
      .map { Self.status($0) }.sorted { $0.threadID < $1.threadID }
  }

  func remove(
    session: StoredAccountSession, target: CloudFavoriteRecordTarget
  ) async throws -> CloudFavoriteRecordRemovalStatus {
    try await requireCurrent(session, target: target)
    let token = try await gate.acquire(target.key, allowsVerification: true)
    do {
      let result = try await removeWhileReserved(session: session, target: target)
      await gate.release(target.key, token: token)
      return result
    } catch {
      await gate.release(target.key, token: token)
      throw error
    }
  }

  func verify(
    session: StoredAccountSession, target: CloudFavoriteRecordTarget
  ) async throws -> CloudFavoriteRecordRemovalStatus {
    try await requireCurrent(session, target: target)
    let token = try await gate.acquire(target.key, allowsVerification: true)
    do {
      guard let record = try await gate.ledger.record(for: target.key) else {
        throw CloudFavoriteRecordRemovalError.unavailable
      }
      let result = try await verifyWhileReserved(session: session, target: target, record: record)
      await gate.release(target.key, token: token)
      return result
    } catch {
      await gate.release(target.key, token: token)
      throw error
    }
  }

  private func removeWhileReserved(
    session: StoredAccountSession, target: CloudFavoriteRecordTarget
  ) async throws -> CloudFavoriteRecordRemovalStatus {
    if let record = try await gate.ledger.record(for: target.key), record.blocksWrites {
      // A second tap, a restored pending operation or renewed credentials are
      // verification only. They must never cause another rmstore dispatch.
      return try await verifyWhileReserved(session: session, target: target, record: record)
    }
    guard !(await gate.requiresReadOnlyRecovery(target.key)) else {
      throw CloudFavoriteRecordRemovalError.unavailable
    }
    let credential = try credential(session)
    let operationID = UUID()
    let receipt = try await client.cleanupCloudFavoriteRecord(
      credential: credential, expectedUserID: session.id, threadID: target.threadID,
      beforeDispatch: { [self] in
        try await prepareDispatch(session: session, target: target, operationID: operationID)
      }
    )
    guard receipt.target.userID == session.id, receipt.target.threadID == target.threadID else {
      await gate.failClosed(target.key)
      throw CloudFavoriteRecordRemovalError.unavailable
    }
    switch receipt.outcome {
    case .rejected(let code, _):
      do {
        try await removePreparedOperation(key: target.key, operationID: operationID)
      } catch {
        await gate.failClosed(target.key)
        throw error
      }
      try await requireCurrent(session, target: target)
      throw CloudFavoriteRecordRemovalError.rejected("贴吧拒绝了移除请求（错误码 \(code)）；没有自动重试。")
    case .acceptedAwaitingVerification, .unknown:
      let phase: CloudFavoriteMutationLedgerPhase =
        receipt.outcome == .acceptedAwaitingVerification
        ? .acceptedAwaitingVerification : .outcomeUnknown
      let record: CloudFavoriteMutationLedgerRecord
      do {
        let ledger = gate.ledger
        // Keep already-received protocol evidence even if the presenting task
        // was cancelled. This task retains only the journal key and receipt
        // phase, never session credentials, and is always awaited to completion.
        record = try await Task.detached {
          try await ledger.transition(key: target.key, operationID: operationID, phase: phase)
        }.value
      } catch {
        // The persisted dispatchPending record remains a restart-safe lock.
        await gate.failClosed(target.key)
        throw error
      }
      // Persist the receipt even if the account changed after dispatch. No
      // result from the old lease is then allowed to change the visible list.
      try await requireCurrent(session, target: target)
      do {
        return try await verifyWhileReserved(session: session, target: target, record: record)
      } catch is CancellationError {
        throw CancellationError()
      } catch CloudFavoriteRecordRemovalError.sessionChanged {
        throw CloudFavoriteRecordRemovalError.sessionChanged
      } catch {
        return Self.status(record)
      }
    }
  }

  private func prepareDispatch(
    session: StoredAccountSession, target: CloudFavoriteRecordTarget, operationID: UUID
  ) async throws {
    try await requireCurrent(session, target: target)
    _ = try await gate.ledger.prepare(
      key: target.key, operationID: operationID,
      sessionRevision: session.sessionRevision, now: Date()
    )
    do {
      try await requireCurrent(session, target: target)
    } catch {
      do {
        try await removePreparedOperation(key: target.key, operationID: operationID)
      } catch {
        await gate.failClosed(target.key)
        throw error
      }
      throw error
    }
  }

  private func removePreparedOperation(
    key: CloudFavoriteMutationLedgerKey, operationID: UUID
  ) async throws {
    let ledger = gate.ledger
    // A definite non-dispatch/rejection must also survive parent cancellation;
    // otherwise a harmless cancelled confirmation could become an unknown lock.
    try await Task.detached {
      try await ledger.removeAfterDefiniteFailure(key: key, operationID: operationID)
    }.value
  }

  private func verifyWhileReserved(
    session: StoredAccountSession, target: CloudFavoriteRecordTarget,
    record: CloudFavoriteMutationLedgerRecord
  ) async throws -> CloudFavoriteRecordRemovalStatus {
    try await requireCurrent(session, target: target)
    let observation = try await client.verifyCloudFavoriteRecordAbsence(
      credential: credential(session), expectedUserID: session.id, threadID: target.threadID
    )
    try await requireCurrent(session, target: target)
    guard observation == .observedAbsent else {
      guard record.blocksWrites else {
        // A prior observation is not evidence about a subsequently re-added
        // favorite. Never label present/inconclusive readback as absent.
        throw CloudFavoriteRecordRemovalError.verificationCompleted
      }
      return Self.status(record, observation: observation)
    }
    do {
      let observed = try await gate.ledger.transition(
        key: target.key, operationID: record.operationID, phase: .observedAbsent
      )
      await gate.didPersistVerifiedAbsence(target.key)
      return Self.status(observed, observation: observation)
    } catch {
      await gate.failClosed(target.key)
      throw error
    }
  }

  private func requireCurrent(
    _ session: StoredAccountSession, target: CloudFavoriteRecordTarget? = nil
  ) async throws {
    guard let vault else { throw CloudFavoriteRecordRemovalError.unavailable }
    try Task.checkCancellation()
    guard session.id > 0, target?.matches(session) != false,
      let current = try await vault.activeSession(), current.id == session.id,
      current.sessionRevision == session.sessionRevision
    else { throw CloudFavoriteRecordRemovalError.sessionChanged }
    try Task.checkCancellation()
  }

  private func credential(_ session: StoredAccountSession) throws -> TiebaSessionCredential {
    guard let value = session.credentials else { throw CloudFavoriteRecordRemovalError.unavailable }
    return TiebaSessionCredential(
      bduss: value.bduss, stoken: value.stoken,
      bdussCookieName: value.bdussCookieName == .bdussBFESS ? .bdussBFESS : .bduss
    )
  }

  private static func status(
    _ record: CloudFavoriteMutationLedgerRecord,
    observation: TiebaCloudFavoriteRecordObservation? = nil
  ) -> CloudFavoriteRecordRemovalStatus {
    CloudFavoriteRecordRemovalStatus(
      threadID: record.key.threadID, phase: record.restoredPhase,
      receiptAcknowledged: record.receiptAcknowledged, observation: observation
    )
  }
}
