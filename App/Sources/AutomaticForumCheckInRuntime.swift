import BackgroundTasks
import Combine
import Foundation
import UIKit

@MainActor
protocol AutomaticForumCheckInRunning: AnyObject {
  var objectWillChange: ObservableObjectPublisher { get }
  var statusMessage: String { get }
  var resultDay: String? { get }
  var isRunning: Bool { get }
  var summary: ForumBatchCheckInSummary? { get }
  var entries: [ForumBatchCheckInEntry] { get }
  func run(
    policy: ForumBatchCheckInExecutionPolicy,
    authorization: @escaping @MainActor () -> Bool
  ) async -> AutomaticForumCheckInCoordinator.Outcome
  func reconcile(
    authorization: @escaping @MainActor () -> Bool
  ) async -> AutomaticForumCheckInCoordinator.Outcome
  func cancel()
  func accountSessionDidChange()
}

extension AutomaticForumCheckInCoordinator: AutomaticForumCheckInRunning {}

/// Owns scheduling, independently of the lifetime of a settings or check-in page.
/// The coordinator and its journal own dispatch, readback, and daily deduplication.
@MainActor
final class AutomaticForumCheckInRuntime: ObservableObject {
  typealias Registration = @MainActor (@escaping @Sendable (BGTask) -> Void) -> Bool
  static let shared = AutomaticForumCheckInRuntime(defaults: .standard)
  static let taskIdentifier = "io.github.minaduki.tieba-plus-plus.daily-check-in"
  static let enabledKey = "TiebaPlusPlus.automaticForumCheckInEnabled"
  static let minuteKey = "TiebaPlusPlus.automaticForumCheckInMinute"
  static let backgroundKey = "TiebaPlusPlus.automaticForumCheckInBackground"
  static let retryInterval: TimeInterval = 15 * 60
  static let backgroundBudget: TimeInterval = 25

  @Published private(set) var isEnabled: Bool
  @Published private(set) var minuteOfDay: Int
  @Published private(set) var usesBackgroundRefresh: Bool
  @Published private(set) var schedulingMessage: String?
  @Published private(set) var hasActiveOperation = false

  var isRunning: Bool { hasActiveOperation || coordinator?.isRunning == true }
  var statusMessage: String {
    coordinator?.statusMessage ?? "开启后，将在设定时间后为当前账号关注的贴吧签到。"
  }
  var summary: ForumBatchCheckInSummary? { coordinator?.summary }
  var entries: [ForumBatchCheckInEntry] { coordinator?.entries ?? [] }
  var resultDay: String? { coordinator?.resultDay }

  private let defaults: UserDefaults
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let registerTask: Registration
  private let backgroundIsAvailable: @MainActor () -> Bool
  private let submit: @MainActor (Date) throws -> Void
  private let cancelScheduled: @MainActor () -> Void
  private var coordinator: (any AutomaticForumCheckInRunning)?
  private var coordinatorObservation: AnyCancellable?
  private var accountObservation: AnyCancellable?
  private var clockObservation: AnyCancellable?
  private var activeScenes = Set<String>()
  private var registrationAttempted = false
  private var registered = false
  private var preferenceEpoch = 0
  private var nextAttemptAfter: Date?
  private var scheduledDate: Date?
  private var foregroundTimer: Task<Void, Never>?
  private var foregroundTimerID: UUID?
  private var operation: Operation?

  private final class Operation {
    let id = UUID()
    let epoch: Int
    let background: AutomaticForumCheckInBackgroundCompletion?
    var task: Task<Void, Never>?
    var budgetTask: Task<Void, Never>?

    init(epoch: Int, background: AutomaticForumCheckInBackgroundCompletion?) {
      self.epoch = epoch
      self.background = background
    }
  }

  init(
    defaults: UserDefaults,
    coordinator: (any AutomaticForumCheckInRunning)? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { interval in
      try await Task.sleep(nanoseconds: UInt64(max(0, min(interval, 86_400)) * 1_000_000_000))
    },
    registerTask: Registration? = nil,
    backgroundIsAvailable: @escaping @MainActor () -> Bool = {
      UIApplication.shared.backgroundRefreshStatus == .available
    },
    submit: (@MainActor (Date) throws -> Void)? = nil,
    cancelScheduled: (@MainActor () -> Void)? = nil
  ) {
    self.defaults = defaults
    self.now = now
    self.sleep = sleep
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    let storedMinute = defaults.object(forKey: Self.minuteKey) as? Int
    minuteOfDay =
      AutomaticForumCheckInSchedule(
        minuteOfDay: storedMinute ?? AutomaticForumCheckInSchedule.defaultMinuteOfDay
      ).minuteOfDay
    usesBackgroundRefresh = defaults.object(forKey: Self.backgroundKey) as? Bool ?? true
    self.backgroundIsAvailable = backgroundIsAvailable
    self.registerTask =
      registerTask ?? { handler in
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
          return false
        }
        return BGTaskScheduler.shared.register(
          forTaskWithIdentifier: Self.taskIdentifier, using: .main, launchHandler: handler
        )
      }
    self.submit =
      submit ?? { date in
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = date
        try BGTaskScheduler.shared.submit(request)
      }
    self.cancelScheduled =
      cancelScheduled ?? {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
      }
    install(coordinator)
  }

  func configure(access: AccountAccess) {
    guard coordinator == nil else { return }
    install(
      AutomaticForumCheckInCoordinator(
        access: access, journal: FileAutomaticForumCheckInLedger.live(), now: now
      )
    )
    accountObservation = NotificationCenter.default.publisher(for: .accountSessionDidChange)
      .sink { [weak self] _ in
        // AccountChangeNotifications posts synchronously on the MainActor.
        MainActor.assumeIsolated { self?.accountSessionDidChange() }
      }
    clockObservation = NotificationCenter.default.publisher(
      for: UIApplication.significantTimeChangeNotification
    ).sink { [weak self] _ in
      Task { @MainActor in self?.clockDidChange() }
    }
  }

  private func install(_ runner: (any AutomaticForumCheckInRunning)?) {
    coordinator = runner
    coordinatorObservation = runner?.objectWillChange.sink { [weak self] _ in
      MainActor.assumeIsolated { self?.objectWillChange.send() }
    }
  }

  func register() {
    guard !registrationAttempted else { return }
    registrationAttempted = true
    registered = registerTask { [weak self] task in
      MainActor.assumeIsolated {
        guard let self, let task = task as? BGAppRefreshTask else {
          task.setTaskCompleted(success: false)
          return
        }
        let completion = AutomaticForumCheckInBackgroundCompletion { success in
          task.expirationHandler = nil
          task.setTaskCompleted(success: success)
        }
        task.expirationHandler = { @Sendable [weak self, weak completion] in
          Task { @MainActor in
            guard let completion else { return }
            self?.expireBackgroundRefresh(completion)
          }
        }
        self.handleBackgroundRefresh(completion)
      }
    }
    refreshScheduling()
  }

  func setEnabled(_ enabled: Bool) {
    guard isEnabled != enabled else { return }
    let interrupted = invalidateOperation()
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
    nextAttemptAfter = nil
    refreshScheduling()
    interrupted?.finish(success: false)
    triggerForegroundIfDue()
  }

  func setMinuteOfDay(_ minute: Int) {
    let resolved = AutomaticForumCheckInSchedule(minuteOfDay: minute).minuteOfDay
    guard minuteOfDay != resolved else { return }
    let interrupted = invalidateOperation()
    minuteOfDay = resolved
    defaults.set(resolved, forKey: Self.minuteKey)
    nextAttemptAfter = nil
    cancelScheduled()
    scheduledDate = nil
    refreshScheduling()
    interrupted?.finish(success: false)
    triggerForegroundIfDue()
  }

  func setUsesBackgroundRefresh(_ enabled: Bool) {
    guard usesBackgroundRefresh != enabled else { return }
    let interrupted = operation?.background != nil ? invalidateOperation() : nil
    usesBackgroundRefresh = enabled
    defaults.set(enabled, forKey: Self.backgroundKey)
    refreshScheduling()
    interrupted?.finish(success: false)
  }

  func sceneDidBecomeActive(_ identifier: String) {
    activeScenes.insert(identifier)
    refreshScheduling()
    triggerForegroundIfDue()
  }

  func sceneDidEnterBackground(_ identifier: String) {
    activeScenes.remove(identifier)
    if activeScenes.isEmpty {
      cancelForegroundTimer()
      if let operation, operation.background == nil { _ = invalidateOperation() }
    }
    refreshScheduling()
  }

  func accountSessionDidChange() {
    let interrupted = invalidateOperation()
    coordinator?.accountSessionDidChange()
    nextAttemptAfter = nil
    refreshScheduling()
    interrupted?.finish(success: false)
    triggerForegroundIfDue()
  }

  func clockDidChange() {
    let interrupted = invalidateOperation()
    nextAttemptAfter = nil
    cancelScheduled()
    scheduledDate = nil
    refreshScheduling()
    interrupted?.finish(success: false)
    triggerForegroundIfDue()
  }

  func reconcile() {
    guard operation == nil, coordinator?.isRunning != true else { return }
    start(background: nil, readOnly: true)
  }

  private func triggerForegroundIfDue() {
    guard isEnabled, !activeScenes.isEmpty, operation == nil,
      coordinator != nil, coordinator?.isRunning != true
    else {
      scheduleForegroundTimer()
      return
    }
    let date = now()
    guard schedule.isDue(at: date), nextAttemptAfter.map({ date >= $0 }) ?? true else {
      scheduleForegroundTimer()
      return
    }
    start(background: nil)
  }

  func handleBackgroundRefresh(_ completion: AutomaticForumCheckInBackgroundCompletion) {
    // Register the next opportunity before completing even an expired/locked run.
    scheduledDate = nil
    refreshScheduling()
    guard registered, isEnabled, usesBackgroundRefresh, backgroundIsAvailable(),
      schedule.isDue(at: now()), nextAttemptAfter.map({ now() >= $0 }) ?? true,
      operation == nil, coordinator != nil, coordinator?.isRunning != true
    else {
      completion.finish(success: false)
      return
    }
    start(background: completion)
  }

  func expireBackgroundRefresh(_ completion: AutomaticForumCheckInBackgroundCompletion) {
    guard !completion.isFinished else { return }
    completion.isExpired = true
    if let operation, operation.background === completion {
      operation.task?.cancel()
      operation.budgetTask?.cancel()
      coordinator?.cancel()
    }
    refreshScheduling()
    completion.finish(success: false)
    // Keep the operation until its worker settles; cancellation is not evidence
    // that a dispatched request stopped, and a second runner must not overlap it.
  }

  private func start(
    background: AutomaticForumCheckInBackgroundCompletion?, readOnly: Bool = false
  ) {
    guard let coordinator, operation == nil else {
      background?.finish(success: false)
      return
    }
    cancelForegroundTimer()
    let active = Operation(epoch: preferenceEpoch, background: background)
    operation = active
    hasActiveOperation = true
    let policy = executionPolicy
    active.task = Task { [weak self, active] in
      guard let self else {
        background?.finish(success: false)
        return
      }
      let authorization: @MainActor () -> Bool = { [weak self, weak active] in
        guard let self, let active,
          self.operation === active, active.epoch == self.preferenceEpoch,
          !Task.isCancelled
        else { return false }
        if readOnly { return true }
        guard self.isEnabled else { return false }
        if let background = active.background {
          return self.usesBackgroundRefresh && !background.isExpired && !background.isFinished
        }
        return !self.activeScenes.isEmpty
      }
      let result =
        if readOnly {
          await coordinator.reconcile(authorization: authorization)
        } else {
          await coordinator.run(policy: policy, authorization: authorization)
        }
      active.budgetTask?.cancel()
      guard self.operation === active else {
        background?.finish(success: false)
        return
      }
      self.operation = nil
      self.hasActiveOperation = false
      if active.epoch == self.preferenceEpoch {
        switch result {
        case .finishedForToday, .needsReview:
          self.nextAttemptAfter = self.schedule.nextScheduledDate(after: self.now())
        case .needsResume, .notStarted:
          self.nextAttemptAfter = self.now().addingTimeInterval(Self.retryInterval)
        }
      }
      self.refreshScheduling()
      if let background {
        background.finish(
          success: !Task.isCancelled && !background.isExpired && result == .finishedForToday
        )
      }
      // A preference/account change may have arrived while the previous worker
      // was draining. Reconsider only after that exact worker has terminated.
      self.triggerForegroundIfDue()
    }
    if let background {
      let sleep = sleep
      active.budgetTask = Task { [weak self, weak background] in
        do { try await sleep(Self.backgroundBudget) } catch { return }
        guard !Task.isCancelled, let background else { return }
        self?.expireBackgroundRefresh(background)
      }
    }
  }

  private var schedule: AutomaticForumCheckInSchedule {
    AutomaticForumCheckInSchedule(minuteOfDay: minuteOfDay)
  }

  private var executionPolicy: ForumBatchCheckInExecutionPolicy {
    ForumBatchCheckInExecutionPolicy(
      delayMode: .resolved(
        defaults.string(forKey: AppPreferenceKey.forumBatchCheckInDelayMode) ?? ""
      ),
      usesOfficialBatch: defaults.object(
        forKey: AppPreferenceKey.forumBatchCheckInUsesOfficialBatch
      ) as? Bool ?? AppPreferenceDefaults.forumBatchCheckInUsesOfficialBatch,
      stopsAfterSingleFailure: defaults.object(
        forKey: AppPreferenceKey.forumBatchCheckInStopsAfterSingleFailure
      ) as? Bool ?? AppPreferenceDefaults.forumBatchCheckInStopsAfterSingleFailure
    )
  }

  private func invalidateOperation() -> AutomaticForumCheckInBackgroundCompletion? {
    preferenceEpoch &+= 1
    cancelForegroundTimer()
    operation?.task?.cancel()
    operation?.budgetTask?.cancel()
    coordinator?.cancel()
    if let background = operation?.background {
      background.isExpired = true
    }
    // Callers update/cancel the next scheduled request before completing the
    // current background task, since completion may suspend this process.
    return operation?.background
  }

  private func nextOpportunity(at date: Date) -> Date? {
    guard let scheduled = schedule.scheduledDate(on: date) else { return nil }
    if date < scheduled { return scheduled }
    return max(date, nextAttemptAfter ?? date)
  }

  private func refreshScheduling() {
    guard isEnabled, usesBackgroundRefresh else {
      cancelScheduled()
      scheduledDate = nil
      schedulingMessage = nil
      scheduleForegroundTimer()
      return
    }
    guard registered, backgroundIsAvailable() else {
      cancelScheduled()
      scheduledDate = nil
      schedulingMessage =
        registered
        ? "系统后台刷新不可用，仍会在前台自动签到。"
        : "当前运行环境未能注册后台补签，仍会在前台自动签到。"
      scheduleForegroundTimer()
      return
    }
    let date = now()
    if let opportunity = nextOpportunity(at: date) {
      let next = max(opportunity, date.addingTimeInterval(Self.retryInterval))
      // An existing earlier opportunity remains valid; avoid delaying it each
      // time a scene becomes active or a settings view re-renders.
      if scheduledDate == nil || scheduledDate! > next || scheduledDate! <= date {
        cancelScheduled()
        do {
          try submit(next)
          scheduledDate = next
          schedulingMessage = "已向 iOS 申请后台补签，实际执行时间由系统决定。"
        } catch {
          scheduledDate = nil
          schedulingMessage = "暂时无法预约后台补签，仍会在前台自动签到。"
        }
      }
    }
    scheduleForegroundTimer()
  }

  private func scheduleForegroundTimer() {
    cancelForegroundTimer()
    guard isEnabled, !activeScenes.isEmpty, operation == nil, coordinator != nil,
      let next = nextOpportunity(at: now()), next > now()
    else { return }
    let id = UUID()
    foregroundTimerID = id
    let delay = max(0, next.timeIntervalSince(now()))
    let sleep = sleep
    foregroundTimer = Task { [weak self] in
      do { try await sleep(delay) } catch { return }
      guard !Task.isCancelled, let self, self.foregroundTimerID == id else { return }
      self.foregroundTimer = nil
      self.foregroundTimerID = nil
      self.triggerForegroundIfDue()
    }
  }

  private func cancelForegroundTimer() {
    foregroundTimer?.cancel()
    foregroundTimer = nil
    foregroundTimerID = nil
  }
}

@MainActor
final class AutomaticForumCheckInBackgroundCompletion {
  private let completion: (Bool) -> Void
  private(set) var isFinished = false
  var isExpired = false

  init(completion: @escaping (Bool) -> Void) { self.completion = completion }

  func finish(success: Bool) {
    guard !isFinished else { return }
    isFinished = true
    completion(success)
  }
}
