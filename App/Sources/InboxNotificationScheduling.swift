import Foundation

/// Keeps scheduling inside the lifetime of the foreground callback or background task.
/// In particular, entering the background must not depend on a new asynchronous permission
/// lookup: iOS may suspend the process before that lookup completes.
@MainActor
final class InboxNotificationScheduling {
  enum Result: Equatable {
    case scheduled, skipped, failed
  }

  private(set) var isEnabled: Bool
  private let minimumInterval: TimeInterval
  private let now: @MainActor () -> Date
  private let isBackgroundRefreshAvailable: @MainActor () -> Bool
  private let isAuthorized: @MainActor () async -> Bool
  private let submit: @MainActor (Date) throws -> Void
  private let cancel: @MainActor () -> Void
  private var cachedAuthorization: Bool?
  private var generation = 0

  init(
    enabled: Bool = false,
    minimumInterval: TimeInterval = 30 * 60,
    now: @escaping @MainActor () -> Date = Date.init,
    isBackgroundRefreshAvailable: @escaping @MainActor () -> Bool,
    isAuthorized: @escaping @MainActor () async -> Bool,
    submit: @escaping @MainActor (Date) throws -> Void,
    cancel: @escaping @MainActor () -> Void
  ) {
    isEnabled = enabled
    self.minimumInterval = minimumInterval
    self.now = now
    self.isBackgroundRefreshAvailable = isBackgroundRefreshAvailable
    self.isAuthorized = isAuthorized
    self.submit = submit
    self.cancel = cancel
  }

  func setEnabled(_ enabled: Bool) {
    if enabled != isEnabled { generation &+= 1 }
    isEnabled = enabled
    if !enabled {
      cachedAuthorization = nil
      cancel()
    }
  }

  /// Account changes invalidate suspended work, but system permission is not account scoped.
  /// Retain its last observation so a subsequent background transition can schedule in time.
  func invalidate() {
    generation &+= 1
    cancel()
  }

  /// A completed permission prompt or fresh settings read can supply its result directly.
  /// Register immediately, before the initial network baseline can suspend the caller.
  @discardableResult
  func authorizationDidChange(_ authorized: Bool) -> Result {
    generation &+= 1
    guard isEnabled else { return .skipped }
    cachedAuthorization = authorized
    return scheduleUsingCachedAuthorization()
  }

  @discardableResult
  func scheduleUsingCachedAuthorization() -> Result {
    guard isEnabled, isBackgroundRefreshAvailable() else {
      cancel()
      return .skipped
    }
    // On cold launch, preserve any existing OS request until permission has been checked.
    guard let cachedAuthorization else { return .skipped }
    cancel()
    guard cachedAuthorization else { return .skipped }
    do {
      try submit(now().addingTimeInterval(minimumInterval))
      return .scheduled
    } catch {
      return .failed
    }
  }

  /// The caller must await this before reporting a background task completed. No detached
  /// continuation is left responsible for registering the next refresh after completion.
  @discardableResult
  func refreshAuthorizationAndSchedule() async -> Result {
    guard isEnabled, !Task.isCancelled else { return .skipped }
    generation &+= 1
    let requestGeneration = generation
    let authorized = await isAuthorized()
    guard isEnabled, !Task.isCancelled, generation == requestGeneration else {
      return .skipped
    }
    cachedAuthorization = authorized
    return scheduleUsingCachedAuthorization()
  }
}
