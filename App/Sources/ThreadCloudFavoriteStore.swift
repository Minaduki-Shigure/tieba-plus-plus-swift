import Combine
import Foundation
import SwiftUI

enum ThreadCloudFavoriteEntryState: Equatable {
  case unknown
  case signedOut
  case loading(previous: ThreadCloudFavoriteSnapshot?)
  case ready(ThreadCloudFavoriteSnapshot)
  case mutating(previous: ThreadCloudFavoriteSnapshot, requestedMarkedPostID: Int64?)
  case failed(previous: ThreadCloudFavoriteSnapshot?, message: String)
}

@MainActor
final class ThreadCloudFavoriteEntry: ObservableObject {
  let target: ThreadCloudFavoriteTarget
  @Published private(set) var state: ThreadCloudFavoriteEntryState = .unknown

  fileprivate var lease: ThreadCloudFavoriteSessionLease?
  fileprivate var epoch: UInt64 = 0
  fileprivate var lastAccessOrdinal: UInt64 = 0

  init(target: ThreadCloudFavoriteTarget) {
    self.target = target
  }

  var displayedSnapshot: ThreadCloudFavoriteSnapshot? {
    switch state {
    case .loading(let previous), .failed(let previous, _):
      previous
    case .ready(let snapshot), .mutating(let snapshot, _):
      snapshot
    case .unknown, .signedOut:
      nil
    }
  }

  fileprivate func setState(_ state: ThreadCloudFavoriteEntryState) {
    self.state = state
  }
}

private struct ThreadCloudFavoriteSessionLease: Hashable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }
}

@MainActor
final class ThreadCloudFavoriteStore {
  private struct ReadFlight {
    let id: UUID
    let lease: ThreadCloudFavoriteSessionLease
    let task: Task<ThreadCloudFavoriteSnapshot, Error>
  }

  private struct MutationFlight {
    let id: UUID
    let lease: ThreadCloudFavoriteSessionLease
    let requestedMarkedPostID: Int64?
    let task: Task<ThreadCloudFavoriteSnapshot, Error>
  }

  private struct SessionReadFlight {
    let id: UUID
    let task: Task<StoredAccountSession?, Error>
  }

  private enum SessionResolution {
    case unknown
    case signedOut
    case active(ThreadCloudFavoriteSessionLease)
    case failed
  }

  private let access: AccountAccess
  private let capacity: Int
  private var entries: [ThreadCloudFavoriteTarget: ThreadCloudFavoriteEntry] = [:]
  private var scopeTargets: [UUID: ThreadCloudFavoriteTarget] = [:]
  private var readFlights: [ThreadCloudFavoriteTarget: ReadFlight] = [:]
  private var mutationFlights: [ThreadCloudFavoriteTarget: MutationFlight] = [:]
  private var sessionReadFlight: SessionReadFlight?
  private var sessionResolution: SessionResolution = .unknown
  private var generation: UInt64 = 0
  private var epoch: UInt64 = 0
  private var accessOrdinal: UInt64 = 0
  private var sessionChangeCancellable: AnyCancellable?

  init(access: AccountAccess, capacity: Int = 128) {
    self.access = access
    self.capacity = max(capacity, 1)
    observeAccountSessionChanges()
  }

  init(
    access: AccountAccess,
    capacity: Int = 128,
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

  func entry(for target: ThreadCloudFavoriteTarget) -> ThreadCloudFavoriteEntry {
    if let entry = entries[target] {
      touch(entry)
      return entry
    }
    let entry = ThreadCloudFavoriteEntry(target: target)
    if case .signedOut = sessionResolution {
      entry.setState(.signedOut)
    }
    entries[target] = entry
    touch(entry)
    evictIfNeeded(protecting: [target])
    return entry
  }

  func activate(_ target: ThreadCloudFavoriteTarget, for scope: UUID) async {
    let previousTarget = scopeTargets.updateValue(target, forKey: scope)
    if let previousTarget, previousTarget != target {
      cancelReadIfInactive(previousTarget)
    }
    let entry = entry(for: target)
    if
      case .ready = entry.state,
      let lease = entry.lease,
      generationMatches(lease: lease)
    {
      return
    }
    if case .mutating = entry.state { return }
    do {
      _ = try await reload(target)
    } catch {
      // The entry retains a retryable failure state for this active surface.
    }
  }

  func deactivate(_ scope: UUID) {
    guard let target = scopeTargets.removeValue(forKey: scope) else { return }
    cancelReadIfInactive(target)
    evictIfNeeded()
  }

  @discardableResult
  func reload(
    _ target: ThreadCloudFavoriteTarget
  ) async throws -> ThreadCloudFavoriteSnapshot? {
    if let flight = readFlights[target] {
      return try await flight.task.value
    }

    let requestGeneration = generation
    let session: StoredAccountSession
    do {
      guard let activeSession = try await resolvedActiveSession() else {
        guard requestGeneration == generation else { throw CancellationError() }
        transitionToSignedOut()
        return nil
      }
      session = activeSession
    } catch {
      guard requestGeneration == generation else { throw CancellationError() }
      sessionResolution = .failed
      let entry = entry(for: target)
      entry.lease = nil
      entry.setState(.failed(previous: nil, message: error.localizedDescription))
      throw error
    }
    let lease = ThreadCloudFavoriteSessionLease(session)
    guard requestGeneration == generation || generationMatches(lease: lease) else {
      throw CancellationError()
    }
    adopt(lease: lease)
    if let mutation = mutationFlights[target], mutation.lease == lease {
      let waitingGeneration = generation
      _ = await mutation.task.result
      guard
        waitingGeneration == generation,
        generationMatches(lease: lease)
      else { throw CancellationError() }
    }
    if let flight = readFlights[target], flight.lease == lease {
      return try await flight.task.value
    }
    let operationGeneration = generation
    let entry = entry(for: target)
    let operationEpoch = beginRead(entry, lease: lease)
    let operationID = UUID()
    let service = access.service
    let task: Task<ThreadCloudFavoriteSnapshot, Error> = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      defer { clearReadFlight(target: target, id: operationID) }
      do {
        let data = try await service.threadCloudFavorite(session: session, target: target)
        try Task.checkCancellation()
        let snapshot = try validatedSnapshot(
          data,
          expectedLease: lease,
          expectedTarget: target
        )
        guard
          operationGeneration == generation,
          entry.epoch == operationEpoch,
          entry.lease == lease,
          try await leaseIsCurrent(lease)
        else { throw CancellationError() }
        entry.setState(.ready(snapshot))
        return snapshot
      } catch {
        guard
          operationGeneration == generation,
          entry.epoch == operationEpoch,
          entry.lease == lease
        else { throw CancellationError() }
        if error is CancellationError || Task.isCancelled {
          entry.setState(
            .failed(
              previous: entry.displayedSnapshot,
              message: "云端收藏状态尚未确认，请重新读取当前状态。"
            )
          )
          throw CancellationError()
        }
        entry.setState(
          .failed(previous: entry.displayedSnapshot, message: error.localizedDescription)
        )
        throw error
      }
    }
    readFlights[target] = ReadFlight(id: operationID, lease: lease, task: task)
    return try await task.value
  }

  @discardableResult
  func setMarkedPostID(
    _ markedPostID: Int64?,
    for target: ThreadCloudFavoriteTarget
  ) async throws -> ThreadCloudFavoriteSnapshot {
    guard markedPostID.map({ $0 > 0 }) ?? true else {
      throw BrowseError.unavailable("云端收藏位置无效，请滚动到有效楼层后再试。")
    }

    if let flight = mutationFlights[target] {
      let entryLease = entries[target]?.lease
      if flight.lease == entryLease, generationMatches(lease: flight.lease) {
        if flight.requestedMarkedPostID == markedPostID {
          return try await flight.task.value
        }
        let waitingGeneration = generation
        _ = await flight.task.result
        guard
          waitingGeneration == generation,
          generationMatches(lease: flight.lease)
        else { throw CancellationError() }
        let current = try await reload(target)
        if let current, current.markedPostID == markedPostID {
          return current
        }
        throw BrowseError.unavailable("先前的云端收藏操作已结束，已重新读取当前状态；请确认后再操作。")
      }
    }

    let entry = entry(for: target)
    guard
      case .ready(let previous) = entry.state,
      let expectedLease = entry.lease
    else {
      throw BrowseError.unavailable("请先读取当前云端收藏状态。")
    }
    guard previous.markedPostID != markedPostID else { return previous }

    let preflightGeneration = generation
    let session: StoredAccountSession
    do {
      guard let activeSession = try await access.vault.activeSession() else {
        throw CancellationError()
      }
      session = activeSession
    } catch {
      guard
        preflightGeneration == generation,
        entry.lease == expectedLease,
        generationMatches(lease: expectedLease)
      else { throw CancellationError() }
      throw error
    }
    guard
      preflightGeneration == generation,
      ThreadCloudFavoriteSessionLease(session) == expectedLease,
      entry.lease == expectedLease,
      generationMatches(lease: expectedLease)
    else { throw CancellationError() }

    readFlights[target]?.task.cancel()
    readFlights.removeValue(forKey: target)
    let operationEpoch = nextEpoch()
    entry.epoch = operationEpoch
    entry.setState(
      .mutating(previous: previous, requestedMarkedPostID: markedPostID)
    )
    let operationGeneration = generation
    let operationID = UUID()
    let service = access.service
    let task: Task<ThreadCloudFavoriteSnapshot, Error> = Task { @MainActor [weak self] in
      guard let self else { throw CancellationError() }
      defer { finishMutationFlight(target: target, id: operationID) }
      do {
        let data = try await service.setThreadCloudFavorite(
          session: session,
          target: target,
          markedPostID: markedPostID
        )
        let snapshot = try validatedSnapshot(
          data,
          expectedLease: expectedLease,
          expectedTarget: target
        )
        guard snapshot.markedPostID == markedPostID else {
          throw BrowseError.unavailable("贴吧没有确认新的云端收藏状态，请重新加载后再试。")
        }
        guard
          operationGeneration == generation,
          entry.epoch == operationEpoch,
          entry.lease == expectedLease,
          try await leaseIsCurrent(expectedLease)
        else { throw CancellationError() }
        entry.setState(.ready(snapshot))
        AccountChangeNotifications.postThreadCloudFavoriteChange(
          ThreadCloudFavoriteChange(
            accountID: expectedLease.userID,
            sessionRevision: expectedLease.sessionRevision,
            target: target,
            snapshot: snapshot
          )
        )
        return snapshot
      } catch {
        guard
          operationGeneration == generation,
          entry.epoch == operationEpoch,
          entry.lease == expectedLease
        else { throw CancellationError() }
        if error is CancellationError || Task.isCancelled {
          entry.setState(
            .failed(
              previous: previous,
              message: "云端收藏结果尚未确认，请重新读取当前状态。"
            )
          )
          throw CancellationError()
        }
        entry.setState(.failed(previous: previous, message: error.localizedDescription))
        throw error
      }
    }
    mutationFlights[target] = MutationFlight(
      id: operationID,
      lease: expectedLease,
      requestedMarkedPostID: markedPostID,
      task: task
    )
    return try await task.value
  }

  func accountSessionDidChange() {
    generation &+= 1
    sessionResolution = .unknown
    sessionReadFlight?.task.cancel()
    sessionReadFlight = nil
    for flight in readFlights.values {
      flight.task.cancel()
    }
    readFlights.removeAll()
    for entry in entries.values {
      entry.epoch = nextEpoch()
      entry.lease = nil
      entry.setState(.unknown)
    }
    let targets = activeTargets()
    guard !targets.isEmpty else {
      evictIfNeeded()
      return
    }
    for target in targets {
      Task { @MainActor [weak self] in
        guard let self else { return }
        _ = try? await reload(target)
      }
    }
  }

  private func beginRead(
    _ entry: ThreadCloudFavoriteEntry,
    lease: ThreadCloudFavoriteSessionLease
  ) -> UInt64 {
    let operationEpoch = nextEpoch()
    entry.epoch = operationEpoch
    entry.lease = lease
    entry.setState(.loading(previous: entry.displayedSnapshot))
    return operationEpoch
  }

  private func validatedSnapshot(
    _ data: ThreadCloudFavoriteData,
    expectedLease: ThreadCloudFavoriteSessionLease,
    expectedTarget: ThreadCloudFavoriteTarget
  ) throws -> ThreadCloudFavoriteSnapshot {
    guard data.userID == expectedLease.userID, data.target == expectedTarget else {
      throw BrowseError.unavailable("贴吧返回了不匹配的云端收藏状态。")
    }
    guard data.snapshot.markedPostID.map({ $0 > 0 }) ?? true else {
      throw BrowseError.unavailable("贴吧返回了异常的云端收藏位置。")
    }
    return data.snapshot
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

  private func leaseIsCurrent(_ lease: ThreadCloudFavoriteSessionLease) async throws -> Bool {
    guard let session = try await access.vault.activeSession() else { return false }
    return ThreadCloudFavoriteSessionLease(session) == lease
  }

  private func adopt(lease: ThreadCloudFavoriteSessionLease) {
    if case .active(let current) = sessionResolution, current == lease { return }
    generation &+= 1
    sessionResolution = .active(lease)
    for flight in readFlights.values {
      flight.task.cancel()
    }
    readFlights.removeAll()
    for entry in entries.values {
      entry.epoch = nextEpoch()
      entry.lease = nil
      entry.setState(.unknown)
    }
  }

  private func generationMatches(lease: ThreadCloudFavoriteSessionLease) -> Bool {
    guard case .active(let current) = sessionResolution else { return false }
    return current == lease
  }

  private func transitionToSignedOut() {
    if case .signedOut = sessionResolution {
      // Reapply to entries created while the session read was in flight.
    } else {
      generation &+= 1
    }
    sessionResolution = .signedOut
    for flight in readFlights.values {
      flight.task.cancel()
    }
    readFlights.removeAll()
    for entry in entries.values {
      entry.epoch = nextEpoch()
      entry.lease = nil
      entry.setState(.signedOut)
    }
  }

  private func activeTargets() -> Set<ThreadCloudFavoriteTarget> {
    Set(scopeTargets.values)
  }

  private func cancelReadIfInactive(_ target: ThreadCloudFavoriteTarget) {
    guard !activeTargets().contains(target), let flight = readFlights.removeValue(forKey: target)
    else { return }
    flight.task.cancel()
    guard let entry = entries[target], entry.lease == flight.lease else { return }
    let previous = entry.displayedSnapshot
    entry.epoch = nextEpoch()
    if let previous {
      entry.setState(.ready(previous))
    } else {
      entry.lease = nil
      entry.setState(.unknown)
    }
  }

  private func clearReadFlight(target: ThreadCloudFavoriteTarget, id: UUID) {
    guard readFlights[target]?.id == id else { return }
    readFlights.removeValue(forKey: target)
    evictIfNeeded()
  }

  private func finishMutationFlight(target: ThreadCloudFavoriteTarget, id: UUID) {
    guard mutationFlights[target]?.id == id else { return }
    mutationFlights.removeValue(forKey: target)
    evictIfNeeded()
  }

  private func nextEpoch() -> UInt64 {
    epoch &+= 1
    return epoch
  }

  private func touch(_ entry: ThreadCloudFavoriteEntry) {
    accessOrdinal &+= 1
    entry.lastAccessOrdinal = accessOrdinal
  }

  private func evictIfNeeded(
    protecting additionalTargets: Set<ThreadCloudFavoriteTarget> = []
  ) {
    guard entries.count > capacity else { return }
    let protectedTargets = activeTargets()
      .union(readFlights.keys)
      .union(mutationFlights.keys)
      .union(additionalTargets)
    let candidates = entries.values
      .filter { !protectedTargets.contains($0.target) }
      .sorted { $0.lastAccessOrdinal < $1.lastAccessOrdinal }
    for entry in candidates.prefix(max(entries.count - capacity, 0)) {
      entries.removeValue(forKey: entry.target)
    }
  }
}

struct ThreadCloudFavoritePosition: Equatable, Sendable {
  let postID: Int64
  let floor: Int

  init?(post: BrowsePost, threadID: Int64) {
    guard post.id > 0, post.threadID == threadID, post.floor > 0 else { return nil }
    postID = post.id
    floor = post.floor
  }
}

enum ThreadCloudFavoritePendingAction: Equatable {
  case add(target: ThreadCloudFavoriteTarget, position: ThreadCloudFavoritePosition)
  case update(target: ThreadCloudFavoriteTarget, position: ThreadCloudFavoritePosition)
  case remove(target: ThreadCloudFavoriteTarget)

  var requestedMarkedPostID: Int64? {
    switch self {
    case .add(_, let position), .update(_, let position):
      position.postID
    case .remove:
      nil
    }
  }

  var title: String {
    switch self {
    case .add:
      "添加到贴吧云收藏？"
    case .update:
      "更新贴吧云收藏位置？"
    case .remove:
      "从贴吧云收藏移除？"
    }
  }

  var actionTitle: String {
    switch self {
    case .add:
      "添加"
    case .update:
      "更新位置"
    case .remove:
      "移除"
    }
  }

  var message: String {
    switch self {
    case .add(_, let position):
      "这会使用当前贴吧账户收藏本主题，并将阅读位置保存到第 \(position.floor) 楼。"
    case .update(_, let position):
      "这会使用当前贴吧账户把本主题的云端阅读位置更新到第 \(position.floor) 楼。"
    case .remove:
      "这会使用当前贴吧账户移除本主题的云端收藏。"
    }
  }

  var isDestructive: Bool {
    if case .remove = self { return true }
    return false
  }

  var target: ThreadCloudFavoriteTarget {
    switch self {
    case .add(let target, _), .update(let target, _), .remove(let target):
      target
    }
  }
}

struct ThreadCloudFavoriteControlSlot: View {
  let store: ThreadCloudFavoriteStore?
  let target: ThreadCloudFavoriteTarget?
  let currentPosition: ThreadCloudFavoritePosition?
  let requestAction: (ThreadCloudFavoritePendingAction) -> Void
  let retry: (ThreadCloudFavoriteTarget) -> Void

  @ViewBuilder
  var body: some View {
    if let store, let target {
      ThreadCloudFavoriteControl(
        entry: store.entry(for: target),
        currentPosition: currentPosition,
        requestAction: requestAction,
        retry: retry
      )
    }
  }
}

private struct ThreadCloudFavoriteControl: View {
  @ObservedObject private var entry: ThreadCloudFavoriteEntry
  let currentPosition: ThreadCloudFavoritePosition?
  let requestAction: (ThreadCloudFavoritePendingAction) -> Void
  let retry: (ThreadCloudFavoriteTarget) -> Void

  init(
    entry: ThreadCloudFavoriteEntry,
    currentPosition: ThreadCloudFavoritePosition?,
    requestAction: @escaping (ThreadCloudFavoritePendingAction) -> Void,
    retry: @escaping (ThreadCloudFavoriteTarget) -> Void
  ) {
    _entry = ObservedObject(wrappedValue: entry)
    self.currentPosition = currentPosition
    self.requestAction = requestAction
    self.retry = retry
  }

  @ViewBuilder
  var body: some View {
    switch entry.state {
    case .unknown, .signedOut:
      fixedIcon(isFavorited: false, showsProgress: false)
        .foregroundStyle(.secondary)
        .accessibilityLabel(
          entry.state == .signedOut ? "登录后使用贴吧云收藏" : "贴吧云收藏不可用"
        )
    case .loading(let previous):
      fixedIcon(isFavorited: previous?.isFavorited == true, showsProgress: true)
        .foregroundStyle(.secondary)
        .accessibilityLabel("正在读取贴吧云收藏状态")
    case .ready(let snapshot):
      readyControl(snapshot)
    case .mutating(let previous, _):
      fixedIcon(isFavorited: previous.isFavorited, showsProgress: true)
        .foregroundStyle(.secondary)
        .accessibilityLabel("正在更新贴吧云收藏")
    case .failed(let previous, _):
      Button { retry(entry.target) } label: {
        ZStack(alignment: .bottomTrailing) {
          Image(systemName: previous?.isFavorited == true ? "star.fill" : "star")
          Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 9))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .red)
            .offset(x: 4, y: 4)
        }
        .frame(width: 24, height: 24)
      }
      .accessibilityLabel("重试读取贴吧云收藏状态")
      .help("重试读取贴吧云收藏状态")
      .accessibilityIdentifier("thread-cloud-favorite-retry")
    }
  }

  @ViewBuilder
  private func readyControl(_ snapshot: ThreadCloudFavoriteSnapshot) -> some View {
    if snapshot.isFavorited {
      Menu {
        if let currentPosition {
          Button {
            requestAction(.update(target: entry.target, position: currentPosition))
          } label: {
            Label("更新到第 \(currentPosition.floor) 楼", systemImage: "bookmark.circle")
          }
          .disabled(snapshot.markedPostID == currentPosition.postID)
        }
        Button(role: .destructive) {
          requestAction(.remove(target: entry.target))
        } label: {
          Label("移除云端收藏", systemImage: "trash")
        }
      } label: {
        Image(systemName: "star.fill")
          .frame(width: 24, height: 24)
      }
      .accessibilityLabel("管理贴吧云收藏")
      .accessibilityValue("已收藏")
      .help("管理贴吧云收藏")
      .accessibilityIdentifier("thread-cloud-favorite")
    } else {
      Button {
        guard let currentPosition else { return }
        requestAction(.add(target: entry.target, position: currentPosition))
      } label: {
        Image(systemName: "star")
          .frame(width: 24, height: 24)
      }
      .disabled(currentPosition == nil)
      .accessibilityLabel("添加到贴吧云收藏")
      .accessibilityValue(
        currentPosition.map { "保存到第 \($0.floor) 楼" } ?? "等待有效的可见楼层"
      )
      .help("添加到贴吧云收藏")
      .accessibilityIdentifier("thread-cloud-favorite")
    }
  }

  private func fixedIcon(isFavorited: Bool, showsProgress: Bool) -> some View {
    ZStack {
      Image(systemName: isFavorited ? "star.fill" : "star")
        .opacity(showsProgress ? 0.35 : 1)
      if showsProgress {
        ProgressView()
          .controlSize(.mini)
      }
    }
    .frame(width: 24, height: 24)
  }
}
