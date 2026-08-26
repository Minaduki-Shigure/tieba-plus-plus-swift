import Foundation

enum RootMainTab: String, CaseIterable, Hashable, Identifiable, Sendable {
  case home
  case explore
  case notifications
  case account

  var id: Self { self }

  var title: String {
    switch self {
    case .home:
      "首页"
    case .explore:
      "发现"
    case .notifications:
      "消息"
    case .account:
      "我的"
    }
  }

  var systemImage: String {
    switch self {
    case .home:
      "house.fill"
    case .explore:
      "sparkles"
    case .notifications:
      "bell.fill"
    case .account:
      "person.crop.circle.fill"
    }
  }
}

struct RootMainNavigationState: Equatable {
  var selectedTab: RootMainTab
  var exploreSection: ExploreSection
  var exploreActivationID: UInt64
  var inboxKind: InboxKind
  var inboxActivationID: UInt64

  private var homePath: [RootDestination]
  private var explorePath: [RootDestination]
  private var notificationsPath: [RootDestination]
  private var accountPath: [RootDestination]

  init(
    selectedTab: RootMainTab = .home,
    exploreSection: ExploreSection = .personalized,
    exploreActivationID: UInt64 = 0,
    inboxKind: InboxKind = .replies,
    inboxActivationID: UInt64 = 0,
    homePath: [RootDestination] = [],
    explorePath: [RootDestination] = [],
    notificationsPath: [RootDestination] = [],
    accountPath: [RootDestination] = []
  ) {
    self.selectedTab = selectedTab
    self.exploreSection = exploreSection
    self.exploreActivationID = exploreActivationID
    self.inboxKind = inboxKind
    self.inboxActivationID = inboxActivationID
    self.homePath = homePath
    self.explorePath = explorePath
    self.notificationsPath = notificationsPath
    self.accountPath = accountPath
  }

  var selectedPath: [RootDestination] {
    path(for: selectedTab)
  }

  var primarySurface: RootMainTab { selectedTab }

  func path(for tab: RootMainTab) -> [RootDestination] {
    switch tab {
    case .home:
      homePath
    case .explore:
      explorePath
    case .notifications:
      notificationsPath
    case .account:
      accountPath
    }
  }

  mutating func setPath(_ path: [RootDestination], for tab: RootMainTab) {
    switch tab {
    case .home:
      homePath = path
    case .explore:
      explorePath = path
    case .notifications:
      notificationsPath = path
    case .account:
      accountPath = path
    }
  }

  mutating func append(_ destination: RootDestination, to tab: RootMainTab) {
    var updated = path(for: tab)
    updated.append(destination)
    setPath(updated, for: tab)
  }

  mutating func selectRoot(_ tab: RootMainTab) {
    selectedTab = tab
    setPath([], for: tab)
  }

  mutating func activateExplore(_ section: ExploreSection) {
    selectedTab = .explore
    exploreSection = section
    explorePath = []
    exploreActivationID &+= 1
  }

  mutating func activateInbox(_ kind: InboxKind) {
    selectedTab = .notifications
    inboxKind = kind
    notificationsPath = []
    inboxActivationID &+= 1
  }
}
