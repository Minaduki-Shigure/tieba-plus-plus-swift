import Combine
import Foundation
import UIKit

enum HomeScreenQuickAction: String, CaseIterable, Hashable, Sendable {
  case batchCheckIn = "io.github.minaduki.tieba-plus-plus.quick-action.batch-check-in"
  case cloudFavorites = "io.github.minaduki.tieba-plus-plus.quick-action.cloud-favorites"
  case search = "io.github.minaduki.tieba-plus-plus.quick-action.search"
  case notificationReplies = "io.github.minaduki.tieba-plus-plus.quick-action.notifications"

  var appRoute: TiebaAppRoute {
    switch self {
    case .batchCheckIn:
      .batchCheckIn
    case .cloudFavorites:
      .cloudFavorites
    case .search:
      .search
    case .notificationReplies:
      .notifications(.replies)
    }
  }

  static func parse(
    type: String,
    userInfoCount: Int?,
    hasTargetContentIdentifier: Bool
  ) -> Self? {
    guard
      userInfoCount == nil || userInfoCount == 0,
      !hasTargetContentIdentifier
    else { return nil }

    return Self(rawValue: type)
  }

  fileprivate init?(shortcutItem: UIApplicationShortcutItem) {
    guard
      let action = Self.parse(
        type: shortcutItem.type,
        userInfoCount: shortcutItem.userInfo?.count,
        hasTargetContentIdentifier: shortcutItem.targetContentIdentifier != nil
      )
    else { return nil }

    self = action
  }
}

struct HomeScreenQuickActionInvocation: Identifiable, Hashable, Sendable {
  let id: UUID
  let action: HomeScreenQuickAction

  init(id: UUID = UUID(), action: HomeScreenQuickAction) {
    self.id = id
    self.action = action
  }

  var appRoute: TiebaAppRoute {
    action.appRoute
  }
}

struct HomeScreenQuickActionPendingState: Equatable, Sendable {
  private(set) var invocation: HomeScreenQuickActionInvocation?

  @discardableResult
  mutating func receive(
    _ action: HomeScreenQuickAction,
    makeID: () -> UUID = { UUID() }
  ) -> HomeScreenQuickActionInvocation {
    if let invocation, invocation.action == action {
      return invocation
    }

    let invocation = HomeScreenQuickActionInvocation(id: makeID(), action: action)
    self.invocation = invocation
    return invocation
  }

  @discardableResult
  mutating func consume(_ invocation: HomeScreenQuickActionInvocation) -> Bool {
    guard self.invocation == invocation else { return false }
    self.invocation = nil
    return true
  }
}

@MainActor
final class TiebaApplicationDelegate: NSObject, UIApplicationDelegate {
  static func sceneConfiguration(for role: UISceneSession.Role) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: role)
    if role == .windowApplication {
      configuration.delegateClass = TiebaSceneDelegate.self
    }
    return configuration
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    Self.sceneConfiguration(for: connectingSceneSession.role)
  }
}

@MainActor
final class TiebaSceneDelegate: NSObject, UIWindowSceneDelegate, ObservableObject {
  @Published private(set) var pendingQuickAction: HomeScreenQuickActionInvocation? = nil

  private var pendingState = HomeScreenQuickActionPendingState()
  private var isSynchronizingPublishedState = false

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    guard let shortcutItem = connectionOptions.shortcutItem else { return }
    receive(shortcutItem)
  }

  func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(receive(shortcutItem))
  }

  @discardableResult
  func consume(_ invocation: HomeScreenQuickActionInvocation) -> Bool {
    guard pendingState.consume(invocation) else { return false }
    synchronizePublishedState()
    return true
  }

  @discardableResult
  func receive(_ action: HomeScreenQuickAction) -> HomeScreenQuickActionInvocation {
    let invocation = pendingState.receive(action)
    synchronizePublishedState()
    return invocation
  }

  @discardableResult
  private func receive(_ shortcutItem: UIApplicationShortcutItem) -> Bool {
    guard let action = HomeScreenQuickAction(shortcutItem: shortcutItem) else { return false }
    receive(action)
    return true
  }

  private func synchronizePublishedState() {
    guard !isSynchronizingPublishedState else { return }

    while pendingQuickAction != pendingState.invocation {
      let invocation = pendingState.invocation
      isSynchronizingPublishedState = true
      pendingQuickAction = invocation
      isSynchronizingPublishedState = false
    }
  }
}
