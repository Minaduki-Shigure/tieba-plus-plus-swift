import BackgroundTasks
import Combine
import Foundation
import UIKit
import UserNotifications

struct InboxNotificationRoute: Identifiable, Equatable, Sendable {
  let id: UUID
  let kind: InboxKind
  let sessionRevision: UUID

  init?(identifier: String, userInfo: [AnyHashable: Any]) {
    guard
      let kind = InboxKind.allCases.first(where: {
        identifier == Self.notificationIdentifier(for: $0)
      }),
      userInfo.count == 2,
      userInfo["kind"] as? String == kind.rawValue,
      let revision = userInfo["sessionRevision"] as? String,
      let sessionRevision = UUID(uuidString: revision)
    else { return nil }
    self.id = UUID()
    self.kind = kind
    self.sessionRevision = sessionRevision
  }

  static func notificationIdentifier(for kind: InboxKind) -> String {
    "io.github.minaduki.tieba-plus-plus.unread.\(kind.rawValue)"
  }
}

@MainActor
final class DefaultsInboxNotificationStateStore: InboxNotificationStateStoring {
  static let key = "TiebaPlusPlus.inboxNotificationSnapshot"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) { self.defaults = defaults }

  func load() throws -> InboxNotificationSnapshot? {
    guard let raw = defaults.object(forKey: Self.key) else { return nil }
    guard let data = raw as? Data, data.count <= 2_048 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    let snapshot = try JSONDecoder().decode(InboxNotificationSnapshot.self, from: data)
    guard snapshot.isValid else { throw CocoaError(.fileReadCorruptFile) }
    return snapshot
  }

  func save(_ snapshot: InboxNotificationSnapshot?) throws {
    guard let snapshot else {
      defaults.removeObject(forKey: Self.key)
      return
    }
    guard snapshot.isValid else { throw CocoaError(.fileWriteUnknown) }
    let data = try JSONEncoder().encode(snapshot)
    guard data.count <= 2_048 else { throw CocoaError(.fileWriteUnknown) }
    defaults.set(data, forKey: Self.key)
  }
}

@MainActor
final class SystemInboxNotificationDelivery: InboxNotificationDelivering {
  private let center = UNUserNotificationCenter.current()

  func isAuthorized() async -> Bool {
    // UNNotificationSettings is not Sendable in the deployment SDK. Reduce it
    // inside its callback so only a Bool crosses back to the main actor.
    await withCheckedContinuation { continuation in
      center.getNotificationSettings { settings in
        let status = settings.authorizationStatus
        continuation.resume(
          returning: status == .authorized || status == .provisional || status == .ephemeral
        )
      }
    }
  }

  func deliver(
    kind: InboxKind,
    count: Int,
    totalCount: Int,
    sessionRevision: UUID
  ) async throws {
    try Task.checkCancellation()
    let content = UNMutableNotificationContent()
    content.title = kind.title
    content.body = kind == .replies
      ? "有 \(count.formatted()) 条未读回复"
      : "有 \(count.formatted()) 条未读提及"
    content.sound = .default
    content.badge = NSNumber(value: totalCount)
    content.userInfo = ["kind": kind.rawValue, "sessionRevision": sessionRevision.uuidString]
    try await center.add(UNNotificationRequest(
      identifier: InboxNotificationRoute.notificationIdentifier(for: kind),
      content: content,
      trigger: nil
    ))
  }

  func clear(kind: InboxKind) {
    let ids = [InboxNotificationRoute.notificationIdentifier(for: kind)]
    center.removePendingNotificationRequests(withIdentifiers: ids)
    center.removeDeliveredNotifications(withIdentifiers: ids)
  }

  func clearAll() {
    InboxKind.allCases.forEach { clear(kind: $0) }
    setBadgeCount(0)
  }

  func setBadgeCount(_ count: Int) {
    UIApplication.shared.applicationIconBadgeNumber = max(0, count)
  }
}

/// One process-wide owner; the application delegate registers before launch completes.
@MainActor
final class InboxNotificationRuntime: NSObject, ObservableObject {
  static let shared = InboxNotificationRuntime(
    defaults: .standard, delivery: SystemInboxNotificationDelivery()
  )
  static let taskIdentifier = "io.github.minaduki.tieba-plus-plus.unread-refresh"
  static let enabledKey = "TiebaPlusPlus.inboxNotificationsEnabled"
  static let minimumRefreshInterval: TimeInterval = 30 * 60

  @Published private(set) var isEnabled: Bool
  @Published private(set) var isChangingPreference = false
  @Published private(set) var statusMessage = "未开启消息提醒。"
  @Published private(set) var pendingRoute: InboxNotificationRoute?

  private let defaults: UserDefaults
  private let delivery: any InboxNotificationDelivering
  private let requestAuthorization: @MainActor () async throws -> Bool
  private let scheduling: InboxNotificationScheduling
  private let observationOrder = InboxNotificationObservationOrder()
  private var coordinator: InboxNotificationCoordinator?
  private var vault: (any AccountVault)?
  private var service: (any AccountService)?
  private var accountObservation: AnyCancellable?
  private var activeRun: InboxBackgroundRefreshRun?
  private var registered = false
  private var registrationAttempted = false
  private var preferenceEpoch = 0
  private var statusEpoch = 0
  private var routeEpoch = 0
  private var baselineTask: Task<Bool, Never>?
  private var inboxReconciliationTask: Task<Void, Never>?

  init(
    defaults: UserDefaults,
    delivery: any InboxNotificationDelivering,
    vault: (any AccountVault)? = nil,
    scheduling: InboxNotificationScheduling? = nil,
    requestAuthorization: @escaping @MainActor () async throws -> Bool = {
      try await UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .sound, .badge]
      )
    }
  ) {
    self.defaults = defaults
    self.delivery = delivery
    self.vault = vault
    self.requestAuthorization = requestAuthorization
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    self.scheduling = scheduling ?? InboxNotificationScheduling(
      enabled: defaults.bool(forKey: Self.enabledKey),
      minimumInterval: Self.minimumRefreshInterval,
      isBackgroundRefreshAvailable: {
        UIApplication.shared.backgroundRefreshStatus == .available
      },
      isAuthorized: { await delivery.isAuthorized() },
      submit: { date in
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = date
        try BGTaskScheduler.shared.submit(request)
      },
      cancel: {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
      }
    )
    super.init()
  }

  func configure(service: any AccountService, vault: any AccountVault) {
    guard coordinator == nil else { return }
    self.vault = vault
    self.service = service
    let coordinator = InboxNotificationCoordinator(
      service: service,
      vault: vault,
      store: DefaultsInboxNotificationStateStore(defaults: defaults),
      delivery: delivery
    )
    self.coordinator = coordinator
    coordinator.setEnabled(isEnabled)
    if !isEnabled { coordinator.accountSessionDidChange() }
    accountObservation = NotificationCenter.default.publisher(for: .accountSessionDidChange)
      .sink { [weak self] _ in
        // All account changes are posted by the MainActor AccountChangeNotifications.
        // Invalidate before postSessionChange returns, without a queued main-thread hop.
        MainActor.assumeIsolated { self?.accountSessionDidChange() }
      }
  }

  func register() {
    guard !registrationAttempted else { return }
    registrationAttempted = true
    // Hosted unit tests must never install background jobs or notification delegates.
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
      return
    }
    UNUserNotificationCenter.current().delegate = self
    registered = BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.taskIdentifier,
      using: .main
    ) { [weak self] task in
      MainActor.assumeIsolated {
        guard let self, let task = task as? BGAppRefreshTask else {
          task.setTaskCompleted(success: false)
          return
        }
        self.handle(task)
      }
    }
  }

  func setEnabled(_ enabled: Bool) async {
    // Turning off must also revoke a pending authorization or initial count read.
    if enabled {
      guard !isChangingPreference, !isEnabled else { return }
    } else {
      guard isChangingPreference || isEnabled else { return }
    }
    preferenceEpoch &+= 1
    let epoch = preferenceEpoch
    if !enabled {
      isChangingPreference = false
      isEnabled = false
      defaults.set(false, forKey: Self.enabledKey)
      pendingRoute = nil
      routeEpoch &+= 1
      activeRun?.cancel()
      baselineTask?.cancel()
      baselineTask = nil
      inboxReconciliationTask?.cancel()
      observationOrder.invalidate()
      scheduling.setEnabled(false)
      coordinator?.setEnabled(false)
      delivery.clearAll()
      await refreshStatus()
      return
    }

    isChangingPreference = true
    defer {
      if epoch == preferenceEpoch { isChangingPreference = false }
    }
    do {
      let granted = try await requestAuthorization()
      guard epoch == preferenceEpoch, !Task.isCancelled else { return }
      // Authorization is the only noninterruptible UI phase. The following count
      // request may be slow and must not prevent the user from switching off.
      isChangingPreference = false
      guard granted else {
        statusMessage = "通知权限未开启，可在系统设置中允许通知后再开启。"
        return
      }
      isEnabled = true
      defaults.set(true, forKey: Self.enabledKey)
      scheduling.setEnabled(true)
      coordinator?.setEnabled(true)
      if registered { recordSchedulingResult(scheduling.authorizationDidChange(true)) }
      // Establish a silent initial baseline while the user has unlocked the app.
      if let coordinator {
        let task = Task { await coordinator.runRefresh() }
        baselineTask = task
        _ = await withTaskCancellationHandler {
          await task.value
        } onCancel: {
          task.cancel()
        }
        // An older enable call must not erase a newer enable call's task handle.
        if epoch == preferenceEpoch { baselineTask = nil }
      }
      guard epoch == preferenceEpoch else { return }
      await refreshStatus()
    } catch {
      if epoch == preferenceEpoch { statusMessage = "无法申请通知权限，请稍后重试。" }
    }
  }

  func refreshStatus() async {
    let epoch = preferenceEpoch
    statusEpoch &+= 1
    let requestStatusEpoch = statusEpoch
    guard isEnabled else {
      statusMessage = "未开启消息提醒。"
      return
    }
    let authorized = await delivery.isAuthorized()
    guard epoch == preferenceEpoch, requestStatusEpoch == statusEpoch, isEnabled else { return }
    guard authorized else {
      activeRun?.cancel()
      delivery.clearAll()
      scheduling.authorizationDidChange(false)
      statusMessage = "系统通知权限未开启，请前往系统设置允许通知。"
      return
    }
    guard registered else {
      statusMessage = "当前运行环境未能注册后台检查，仍可在前台查看消息。"
      return
    }
    guard UIApplication.shared.backgroundRefreshStatus == .available else {
      statusMessage = "系统暂未允许后台 App 刷新，提醒将在允许后恢复。"
      return
    }
    statusMessage = "已开启。仅检查当前账户的回复和提及，检查时间由 iOS 安排。"
    recordSchedulingResult(scheduling.authorizationDidChange(true))
  }

  func sceneDidBecomeActive() {
    activeRun?.cancel()
    Task { await refreshStatus() }
  }

  func sceneDidEnterBackground() {
    // The opt-in baseline is foreground work; don't strand it across suspension.
    if baselineTask != nil {
      baselineTask?.cancel()
      coordinator?.cancelRefresh()
    }
    inboxReconciliationTask?.cancel()
    if registered { recordSchedulingResult(scheduling.scheduleUsingCachedAuthorization()) }
  }

  func beginSummaryObservation() -> UUID? {
    guard isEnabled else { return nil }
    return observationOrder.begin()
  }

  func observeForeground(summary: InboxUnreadSummary, sessionRevision: UUID, token: UUID?) {
    guard isEnabled, let coordinator, let token, observationOrder.accepts(token) else { return }
    Task {
      await coordinator.observeForeground(
        summary: summary, sessionRevision: sessionRevision,
        isCurrentObservation: { self.observationOrder.accepts(token) }
      )
    }
  }

  /// Inbox retrieval may affect server unread counts. Reconcile from the server,
  /// never assume opening the page means every item has been read.
  func reconcileInbox(sessionRevision: UUID) {
    guard isEnabled, let coordinator, let service, let vault else { return }
    inboxReconciliationTask?.cancel()
    let epoch = preferenceEpoch
    let observation = observationOrder.begin()
    inboxReconciliationTask = Task { [weak self] in
      do {
        guard let self, let session = try await vault.activeSession(),
          session.sessionRevision == sessionRevision, isEnabled,
          preferenceEpoch == epoch, !Task.isCancelled
        else { return }
        let summary = try await service.inboxUnreadSummary(session: session)
        try Task.checkCancellation()
        guard preferenceEpoch == epoch, isEnabled else { return }
        guard observationOrder.accepts(observation) else { return }
        await coordinator.observeForeground(
          summary: summary, sessionRevision: sessionRevision,
          isCurrentObservation: { self.observationOrder.accepts(observation) }
        )
      } catch {
        // A failed count read never alters the visible inbox or invents a zero badge.
      }
    }
  }

  func consume(_ route: InboxNotificationRoute) async -> InboxKind? {
    guard pendingRoute == route, isEnabled, let vault else { return nil }
    let epoch = routeEpoch
    do {
      let session = try await vault.activeSession()
      guard
        epoch == routeEpoch, pendingRoute == route, isEnabled,
        let session, session.sessionRevision == route.sessionRevision,
        session.id > 0, AccountCredentialFormat.isValidBDUSS(session.bduss)
      else {
        if pendingRoute == route { pendingRoute = nil }
        return nil
      }
      pendingRoute = nil
      delivery.clear(kind: route.kind)
      return route.kind
    } catch {
      if pendingRoute == route { pendingRoute = nil }
      return nil
    }
  }

  func receive(_ route: InboxNotificationRoute) {
    guard isEnabled else { return }
    routeEpoch &+= 1
    pendingRoute = route
  }

  func accountSessionDidChange() {
    preferenceEpoch &+= 1
    isChangingPreference = false
    routeEpoch &+= 1
    pendingRoute = nil
    activeRun?.cancel()
    baselineTask?.cancel()
    baselineTask = nil
    inboxReconciliationTask?.cancel()
    observationOrder.invalidate()
    scheduling.invalidate()
    coordinator?.accountSessionDidChange()
    delivery.clearAll()
  }

  private func recordSchedulingResult(_ result: InboxNotificationScheduling.Result) {
    if result == .failed {
      statusMessage = "系统暂未接受后台检查，请稍后打开 App 再试。"
    }
  }

  private func handle(_ task: BGAppRefreshTask) {
    guard isEnabled, let coordinator, activeRun == nil else {
      if registered { recordSchedulingResult(scheduling.scheduleUsingCachedAuthorization()) }
      task.setTaskCompleted(success: false)
      return
    }
    let run = InboxBackgroundRefreshRun(completion: { success in
      task.expirationHandler = nil
      task.setTaskCompleted(success: success)
    }) { [weak self] in
      coordinator.cancelRefresh()
      self?.activeRun = nil
    }
    activeRun = run
    task.expirationHandler = { @Sendable [weak run] in
      Task { @MainActor in run?.cancel() }
    }
    run.work = Task { [weak self, run] in
      guard let self else { run.finish(success: false); return }
      // Keep the OS task alive through next-request registration, even if the
      // count read later fails immediately (for example, a locked Keychain).
      recordSchedulingResult(await scheduling.refreshAuthorizationAndSchedule())
      guard !Task.isCancelled else { run.finish(success: false); return }
      let success = await coordinator.runRefresh()
      run.finish(success: success && !Task.isCancelled)
      if activeRun === run { activeRun = nil }
    }
  }
}

@MainActor
final class InboxBackgroundRefreshRun {
  var work: Task<Void, Never>?
  private let completion: (Bool) -> Void
  private let cancellation: () -> Void
  private var completed = false

  init(completion: @escaping (Bool) -> Void, cancellation: @escaping () -> Void) {
    self.completion = completion
    self.cancellation = cancellation
  }

  func cancel() {
    guard !completed else { return }
    work?.cancel()
    cancellation()
    finish(success: false)
  }

  func finish(success: Bool) {
    guard !completed else { return }
    completed = true
    completion(success)
    work = nil
  }
}

extension InboxNotificationRuntime: UNUserNotificationCenterDelegate {
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    // Foreground inbox badges already expose the same counts without another banner.
    []
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse
  ) async {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let route = InboxNotificationRoute(
        identifier: response.notification.request.identifier,
        userInfo: response.notification.request.content.userInfo
      )
    else { return }
    await MainActor.run {
      receive(route)
    }
  }
}
