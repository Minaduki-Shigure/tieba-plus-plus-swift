import Combine
import Foundation

enum ContentAgreementEntryState: Equatable {
  case unknown
  case signedOut
  case loading(previous: ContentAgreementSnapshot?)
  case ready(ContentAgreementSnapshot)
  case mutating(previous: ContentAgreementSnapshot, targetAgreed: Bool)
  case failed(previous: ContentAgreementSnapshot?)
}

@MainActor
final class ContentAgreementEntry: ObservableObject {
  let target: ContentAgreementTarget
  @Published private(set) var state: ContentAgreementEntryState = .unknown

  fileprivate var lease: ContentAgreementSessionLease?
  fileprivate var epoch: UInt64 = 0
  fileprivate var activeWriteCount = 0
  fileprivate var lastAccessOrdinal: UInt64 = 0

  init(target: ContentAgreementTarget) {
    self.target = target
  }

  var displayedSnapshot: ContentAgreementSnapshot? {
    switch state {
    case .loading(let previous), .failed(let previous):
      previous
    case .ready(let snapshot), .mutating(let snapshot, _):
      snapshot
    case .unknown, .signedOut:
      nil
    }
  }

  fileprivate func setState(_ state: ContentAgreementEntryState) {
    self.state = state
  }
}

private struct ContentAgreementSessionLease: Hashable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }
}

@MainActor
final class ContentAgreementStore {
  private struct DescriptorTaskKey: Hashable {
    let lease: ContentAgreementSessionLease
    let request: ContentAgreementReadRequest
  }

  private struct DescriptorTask {
    let id: UUID
    let descriptor: ContentAgreementReadDescriptor
    let task: Task<Void, Never>
  }

  private struct MutationFlight {
    let id: UUID
    let lease: ContentAgreementSessionLease
    let targetAgreed: Bool
    let task: Task<ContentAgreementSnapshot, Error>
  }

  private struct SessionReadFlight {
    let id: UUID
    let task: Task<StoredAccountSession?, Error>
  }

  private enum SessionResolution {
    case unknown
    case signedOut
    case active(ContentAgreementSessionLease)
    case failed
  }

  private let access: AccountAccess
  private let capacity: Int
  private var entries: [ContentAgreementTarget: ContentAgreementEntry] = [:]
  private var scopeDescriptors: [UUID: Set<ContentAgreementReadDescriptor>] = [:]
  private var activeTargetsCache: Set<ContentAgreementTarget> = []
  private var activeEntryCount = 0
  private var descriptorTasks: [DescriptorTaskKey: DescriptorTask] = [:]
  private var loadedDescriptors: [DescriptorTaskKey: ContentAgreementReadDescriptor] = [:]
  private var mutationFlights: [ContentAgreementTarget: MutationFlight] = [:]
  private var sessionReadFlight: SessionReadFlight?
  private var sessionResolution: SessionResolution = .unknown
  private var generation: UInt64 = 0
  private var epoch: UInt64 = 0
  private var accessOrdinal: UInt64 = 0
  private(set) var evictionCandidateScanCount = 0
  private var sessionChangeCancellable: AnyCancellable?

  init(access: AccountAccess, capacity: Int = 512) {
    self.access = access
    self.capacity = max(capacity, 1)
    observeAccountSessionChanges()
  }

  init(
    access: AccountAccess,
    capacity: Int = 512,
    observesAccountSessionChanges: Bool
  ) {
    self.access = access
    self.capacity = max(capacity, 1)
    if observesAccountSessionChanges {
      observeAccountSessionChanges()
    }
  }

  private func observeAccountSessionChanges() {
    sessionChangeCancellable = NotificationCenter.default.publisher(for: .accountSessionDidChange)
      .sink { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.accountSessionDidChange()
        }
      }
  }

  func entry(for target: ContentAgreementTarget) -> ContentAgreementEntry {
    if let entry = entries[target] {
      touch(entry)
      return entry
    }
    let entry = ContentAgreementEntry(target: target)
    switch sessionResolution {
    case .signedOut:
      entry.setState(.signedOut)
    case .unknown, .active, .failed:
      break
    }
    entries[target] = entry
    if activeTargetsCache.contains(target) {
      activeEntryCount += 1
    }
    touch(entry)
    evictIfNeeded()
    return entry
  }

  func replaceDescriptors(
    _ descriptors: [ContentAgreementReadDescriptor],
    for scope: UUID
  ) async {
    let normalized = Set(descriptors)
    if normalized.isEmpty {
      scopeDescriptors.removeValue(forKey: scope)
    } else {
      scopeDescriptors[scope] = normalized
    }
    rebuildActiveTargetsCache()
    reconcileDescriptorTasks()
    guard !scopeDescriptors.isEmpty else {
      evictIfNeeded()
      return
    }
    await refreshRegisteredDescriptors()
  }

  func removeScope(_ scope: UUID) {
    guard scopeDescriptors.removeValue(forKey: scope) != nil else { return }
    rebuildActiveTargetsCache()
    reconcileDescriptorTasks()
    evictIfNeeded()
    if !scopeDescriptors.isEmpty {
      Task { @MainActor [weak self] in
        await self?.refreshRegisteredDescriptors()
      }
    }
  }

  func refreshDescriptors(for scope: UUID) async {
    guard let descriptors = scopeDescriptors[scope], !descriptors.isEmpty else { return }
    let requests = Set(descriptors.map(\.request))
    let taskKeys = descriptorTasks.keys.filter { requests.contains($0.request) }
    for key in taskKeys {
      descriptorTasks[key]?.task.cancel()
      descriptorTasks.removeValue(forKey: key)
    }
    let loadedKeys = loadedDescriptors.keys.filter { requests.contains($0.request) }
    for key in loadedKeys {
      loadedDescriptors.removeValue(forKey: key)
    }
    await refreshRegisteredDescriptors()
  }

  func reload(_ target: ContentAgreementTarget) async throws {
    let requestGeneration = generation
    let session = try await resolvedActiveSession()
    guard requestGeneration == generation else { throw CancellationError() }
    guard let session else {
      transitionToSignedOut()
      return
    }
    let lease = ContentAgreementSessionLease(session)
    adopt(lease: lease)
    let readGeneration = generation
    let entry = entry(for: target)
    guard entry.activeWriteCount == 0 else {
      throw BrowseError.unavailable("当前点赞操作尚未结束。")
    }
    let readEpoch = beginRead(entry, lease: lease)
    do {
      let agreement = try await access.service.contentAgreement(session: session, target: target)
      try Task.checkCancellation()
      guard
        readGeneration == generation,
        entry.epoch == readEpoch,
        try await leaseIsCurrent(lease)
      else { throw CancellationError() }
      let snapshot = try validatedSnapshot(
        agreement,
        expectedLease: lease,
        expectedTarget: target
      )
      entry.lease = lease
      entry.setState(.ready(snapshot))
    } catch {
      if readGeneration == generation, entry.epoch == readEpoch {
        entry.setState(.failed(previous: entry.displayedSnapshot))
      }
      throw error
    }
  }

  @discardableResult
  func setAgreed(
    _ isAgreed: Bool,
    for target: ContentAgreementTarget
  ) async throws -> ContentAgreementSnapshot {
    if let flight = mutationFlights[target] {
      if flight.targetAgreed == isAgreed {
        return try await flight.task.value
      }
      _ = await flight.task.result
      try await reload(target)
      if case .ready(let snapshot) = entry(for: target).state, snapshot.isAgreed == isAgreed {
        return snapshot
      }
      throw BrowseError.unavailable("先前的内容点赞操作已结束，请重新读取当前状态。")
    }

    let entry = entry(for: target)
    guard
      case .ready(let previous) = entry.state,
      let expectedLease = entry.lease
    else {
      throw BrowseError.unavailable("请先读取当前点赞状态。")
    }
    guard previous.isAgreed != isAgreed else { return previous }

    let operationEpoch = nextEpoch()
    entry.epoch = operationEpoch
    entry.activeWriteCount += 1
    entry.setState(.mutating(previous: previous, targetAgreed: isAgreed))
    let operationGeneration = generation
    let vault = access.vault
    let service = access.service
    let operationID = UUID()
    let task: Task<ContentAgreementSnapshot, Error> = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      var confirmedLeaseIsCurrent: Bool?
      var didStartWrite = false
      do {
        guard let session = try await vault.activeSession() else {
          confirmedLeaseIsCurrent = false
          throw BrowseError.unavailable("当前账户已经变化，请重新读取点赞状态。")
        }
        let sessionLeaseIsCurrent =
          ContentAgreementSessionLease(session) == expectedLease
          && generationMatches(lease: expectedLease)
          && operationGeneration == generation
          && entry.epoch == operationEpoch
          && entry.lease == expectedLease
        confirmedLeaseIsCurrent = sessionLeaseIsCurrent
        guard sessionLeaseIsCurrent else {
          throw BrowseError.unavailable("当前账户已经变化，请重新读取点赞状态。")
        }
        didStartWrite = true
        let agreement = try await service.setContentAgreed(
          session: session,
          target: target,
          isAgreed: isAgreed
        )
        let snapshot = try validatedSnapshot(
          agreement,
          expectedLease: expectedLease,
          expectedTarget: target
        )
        guard snapshot.isAgreed == isAgreed else {
          throw BrowseError.unavailable("贴吧没有确认新的点赞状态，请重新加载后再试。")
        }
        let leaseIsCurrent = try await leaseIsCurrent(expectedLease)
        confirmedLeaseIsCurrent = leaseIsCurrent
        guard
          leaseIsCurrent,
          operationGeneration == generation,
          entry.epoch == operationEpoch,
          entry.lease == expectedLease
        else {
          throw BrowseError.unavailable("点赞完成时当前账户已经变化，结果未应用。")
        }
        entry.setState(.ready(snapshot))
        finishMutationActivity(
          entry: entry,
          target: target,
          operationID: operationID,
          needsRefresh: false
        )
        return snapshot
      } catch {
        let resultWasDiscardedForNewLease =
          operationGeneration != generation
          || entry.lease != expectedLease
          || !generationMatches(lease: expectedLease)
          || confirmedLeaseIsCurrent == false
        if
          operationGeneration == generation,
          entry.epoch == operationEpoch,
          entry.lease == expectedLease
        {
          entry.setState(didStartWrite ? .failed(previous: previous) : .ready(previous))
        }
        finishMutationActivity(
          entry: entry,
          target: target,
          operationID: operationID,
          needsRefresh: resultWasDiscardedForNewLease
        )
        if resultWasDiscardedForNewLease {
          throw CancellationError()
        }
        throw error
      }
    }
    mutationFlights[target] = MutationFlight(
      id: operationID,
      lease: expectedLease,
      targetAgreed: isAgreed,
      task: task
    )
    return try await task.value
  }

  func accountSessionDidChange() {
    generation &+= 1
    sessionResolution = .unknown
    sessionReadFlight?.task.cancel()
    sessionReadFlight = nil
    for task in descriptorTasks.values {
      task.task.cancel()
    }
    descriptorTasks.removeAll()
    loadedDescriptors.removeAll()
    for entry in entries.values {
      entry.epoch = nextEpoch()
      entry.lease = nil
      entry.setState(.unknown)
    }
    guard !scopeDescriptors.isEmpty else { return }
    Task { @MainActor [weak self] in
      await self?.refreshRegisteredDescriptors()
    }
  }

  private func refreshRegisteredDescriptors() async {
    guard !scopeDescriptors.isEmpty else { return }
    let requestGeneration = generation
    do {
      let session = try await resolvedActiveSession()
      guard requestGeneration == generation else { return }
      guard let session else {
        transitionToSignedOut()
        return
      }
      let lease = ContentAgreementSessionLease(session)
      adopt(lease: lease)
      startDescriptorTasks(session: session, lease: lease, generation: generation)
    } catch {
      guard requestGeneration == generation else { return }
      sessionResolution = .failed
      for target in activeTargets() {
        let entry = entry(for: target)
        entry.lease = nil
        entry.setState(.failed(previous: nil))
      }
    }
  }

  private func startDescriptorTasks(
    session: StoredAccountSession,
    lease: ContentAgreementSessionLease,
    generation requestGeneration: UInt64
  ) {
    let descriptorsByRequest = activeDescriptorsByRequest()
    for (request, descriptor) in descriptorsByRequest {
      let key = DescriptorTaskKey(lease: lease, request: request)
      if loadedDescriptors[key] == descriptor { continue }
      if let existing = descriptorTasks[key], existing.descriptor == descriptor { continue }
      descriptorTasks[key]?.task.cancel()
      loadedDescriptors.removeValue(forKey: key)

      var epochs: [ContentAgreementTarget: UInt64] = [:]
      for target in descriptor.expectedTargets {
        let entry = entry(for: target)
        guard entry.activeWriteCount == 0 else { continue }
        epochs[target] = beginRead(entry, lease: lease)
      }
      let taskID = UUID()
      let task = Task { @MainActor [weak self] in
        guard let self else { return }
        defer { clearDescriptorTask(key: key, id: taskID) }
        do {
          let page = try await access.service.contentAgreements(
            session: session,
            descriptor: descriptor
          )
          try Task.checkCancellation()
          guard
            requestGeneration == generation,
            try await leaseIsCurrent(lease),
            activeDescriptorsByRequest()[request] == descriptor
          else { return }
          try apply(page: page, descriptor: descriptor, lease: lease, epochs: epochs)
          if epochs.count == descriptor.expectedTargets.count {
            loadedDescriptors[key] = descriptor
          }
        } catch is CancellationError {
          // A scope or account transition deliberately invalidated this read.
        } catch {
          failDescriptor(descriptor, lease: lease, epochs: epochs)
        }
      }
      descriptorTasks[key] = DescriptorTask(id: taskID, descriptor: descriptor, task: task)
    }
    reconcileDescriptorTasks()
  }

  private func apply(
    page: ContentAgreementPageData,
    descriptor: ContentAgreementReadDescriptor,
    lease: ContentAgreementSessionLease,
    epochs: [ContentAgreementTarget: UInt64]
  ) throws {
    guard
      page.userID == lease.userID,
      page.forumID == descriptor.request.forumID,
      page.threadID == descriptor.request.threadID
    else {
      throw BrowseError.unavailable("贴吧返回了不匹配的批量点赞状态。")
    }
    var resolved = Set<ContentAgreementTarget>()
    for agreement in page.agreements {
      guard descriptor.expectedTargets.contains(agreement.target) else { continue }
      guard let readEpoch = epochs[agreement.target] else { continue }
      guard resolved.insert(agreement.target).inserted else {
        throw BrowseError.unavailable("贴吧返回了重复的点赞对象状态。")
      }
      let entry = entry(for: agreement.target)
      guard
        entry.activeWriteCount == 0,
        entry.epoch == readEpoch,
        entry.lease == lease
      else { continue }
      let snapshot = try validatedSnapshot(
        agreement,
        expectedLease: lease,
        expectedTarget: agreement.target
      )
      entry.setState(.ready(snapshot))
    }
    for (target, readEpoch) in epochs where !resolved.contains(target) {
      let entry = entry(for: target)
      guard
        entry.activeWriteCount == 0,
        entry.epoch == readEpoch,
        entry.lease == lease
      else { continue }
      entry.setState(.failed(previous: entry.displayedSnapshot))
    }
  }

  private func failDescriptor(
    _ descriptor: ContentAgreementReadDescriptor,
    lease: ContentAgreementSessionLease,
    epochs: [ContentAgreementTarget: UInt64]
  ) {
    guard generationMatches(lease: lease) else { return }
    for target in descriptor.expectedTargets {
      guard let readEpoch = epochs[target] else { continue }
      let entry = entry(for: target)
      guard
        entry.activeWriteCount == 0,
        entry.epoch == readEpoch,
        entry.lease == lease
      else { continue }
      entry.setState(.failed(previous: entry.displayedSnapshot))
    }
  }

  private func validatedSnapshot(
    _ agreement: ContentAgreementData,
    expectedLease: ContentAgreementSessionLease,
    expectedTarget: ContentAgreementTarget
  ) throws -> ContentAgreementSnapshot {
    guard agreement.userID == expectedLease.userID, agreement.target == expectedTarget else {
      throw BrowseError.unavailable("贴吧返回了不匹配的点赞状态。")
    }
    return agreement.snapshot
  }

  private func beginRead(
    _ entry: ContentAgreementEntry,
    lease: ContentAgreementSessionLease
  ) -> UInt64 {
    let previous = entry.displayedSnapshot
    let readEpoch = nextEpoch()
    entry.epoch = readEpoch
    entry.lease = lease
    entry.setState(.loading(previous: previous))
    return readEpoch
  }

  private func resolvedActiveSession() async throws -> StoredAccountSession? {
    if let sessionReadFlight {
      return try await sessionReadFlight.task.value
    }
    let vault = access.vault
    let flightID = UUID()
    let task = Task.detached { try await vault.activeSession() }
    sessionReadFlight = SessionReadFlight(id: flightID, task: task)
    defer {
      if sessionReadFlight?.id == flightID {
        sessionReadFlight = nil
      }
    }
    return try await task.value
  }

  private func leaseIsCurrent(_ lease: ContentAgreementSessionLease) async throws -> Bool {
    guard let session = try await access.vault.activeSession() else { return false }
    return ContentAgreementSessionLease(session) == lease
  }

  private func adopt(lease: ContentAgreementSessionLease) {
    if case .active(let current) = sessionResolution, current == lease { return }
    generation &+= 1
    sessionResolution = .active(lease)
    for task in descriptorTasks.values {
      task.task.cancel()
    }
    descriptorTasks.removeAll()
    loadedDescriptors.removeAll()
    for entry in entries.values where entry.activeWriteCount == 0 {
      entry.epoch = nextEpoch()
      entry.lease = nil
      entry.setState(.unknown)
    }
  }

  private func generationMatches(lease: ContentAgreementSessionLease) -> Bool {
    guard case .active(let current) = sessionResolution else { return false }
    return current == lease
  }

  private func activeDescriptorsByRequest()
    -> [ContentAgreementReadRequest: ContentAgreementReadDescriptor]
  {
    var targetsByRequest: [ContentAgreementReadRequest: Set<ContentAgreementTarget>] = [:]
    for descriptor in scopeDescriptors.values.flatMap({ $0 }) {
      targetsByRequest[descriptor.request, default: []].formUnion(descriptor.expectedTargets)
    }
    return targetsByRequest.reduce(into: [:]) { result, item in
      if let descriptor = ContentAgreementReadDescriptor(
        request: item.key,
        expectedTargets: item.value
      ) {
        result[item.key] = descriptor
      }
    }
  }

  private func activeTargets() -> Set<ContentAgreementTarget> {
    activeTargetsCache
  }

  private func rebuildActiveTargetsCache() {
    activeTargetsCache = scopeDescriptors.values.reduce(
      into: Set<ContentAgreementTarget>()
    ) { result, descriptors in
      for descriptor in descriptors {
        result.formUnion(descriptor.expectedTargets)
      }
    }
    activeEntryCount = entries.keys.reduce(into: 0) { count, target in
      if activeTargetsCache.contains(target) {
        count += 1
      }
    }
  }

  private func transitionToSignedOut() {
    if case .signedOut = sessionResolution {
      // Still reapply this to entries created while the previous refresh was in flight.
    } else {
      generation &+= 1
    }
    sessionResolution = .signedOut
    for task in descriptorTasks.values {
      task.task.cancel()
    }
    descriptorTasks.removeAll()
    loadedDescriptors.removeAll()
    for entry in entries.values {
      entry.epoch = nextEpoch()
      entry.lease = nil
      entry.setState(.signedOut)
    }
  }

  private func reconcileDescriptorTasks() {
    let activeByRequest = activeDescriptorsByRequest()
    let staleKeys = descriptorTasks.compactMap { key, task -> DescriptorTaskKey? in
      let activeDescriptor = activeByRequest[key.request]
      let leaseIsActive: Bool
      if case .active(let lease) = sessionResolution {
        leaseIsActive = lease == key.lease
      } else {
        leaseIsActive = false
      }
      return !leaseIsActive || activeDescriptor != task.descriptor ? key : nil
    }
    for key in staleKeys {
      descriptorTasks[key]?.task.cancel()
      descriptorTasks.removeValue(forKey: key)
    }
    let staleLoadedKeys = loadedDescriptors.compactMap { key, descriptor -> DescriptorTaskKey? in
      let activeDescriptor = activeByRequest[key.request]
      let leaseIsActive: Bool
      if case .active(let lease) = sessionResolution {
        leaseIsActive = lease == key.lease
      } else {
        leaseIsActive = false
      }
      return !leaseIsActive || activeDescriptor != descriptor ? key : nil
    }
    for key in staleLoadedKeys {
      loadedDescriptors.removeValue(forKey: key)
    }
  }

  private func clearDescriptorTask(key: DescriptorTaskKey, id: UUID) {
    guard descriptorTasks[key]?.id == id else { return }
    descriptorTasks.removeValue(forKey: key)
  }

  private func finishMutationActivity(
    entry: ContentAgreementEntry,
    target: ContentAgreementTarget,
    operationID: UUID,
    needsRefresh: Bool
  ) {
    entry.activeWriteCount = max(entry.activeWriteCount - 1, 0)
    if mutationFlights[target]?.id == operationID {
      mutationFlights.removeValue(forKey: target)
    }
    evictIfNeeded()
    if
      needsRefresh,
      activeTargets().contains(target),
      !scopeDescriptors.isEmpty
    {
      let matchingKeys = descriptorTasks.compactMap { key, task in
        task.descriptor.expectedTargets.contains(target) ? key : nil
      }
      for key in matchingKeys {
        descriptorTasks[key]?.task.cancel()
        descriptorTasks.removeValue(forKey: key)
        loadedDescriptors.removeValue(forKey: key)
      }
      Task { @MainActor [weak self] in
        await self?.refreshRegisteredDescriptors()
      }
    }
  }

  private func nextEpoch() -> UInt64 {
    epoch &+= 1
    return epoch
  }

  private func touch(_ entry: ContentAgreementEntry) {
    accessOrdinal &+= 1
    entry.lastAccessOrdinal = accessOrdinal
  }

  private func evictIfNeeded() {
    guard entries.count > capacity else { return }
    if mutationFlights.isEmpty, activeEntryCount == entries.count {
      return
    }
    evictionCandidateScanCount += 1
    let protectedTargets = activeTargets().union(mutationFlights.keys)
    let candidates = entries.values
      .filter { $0.activeWriteCount == 0 && !protectedTargets.contains($0.target) }
      .sorted { $0.lastAccessOrdinal < $1.lastAccessOrdinal }
    for entry in candidates.prefix(max(entries.count - capacity, 0)) {
      entries.removeValue(forKey: entry.target)
    }
  }
}
