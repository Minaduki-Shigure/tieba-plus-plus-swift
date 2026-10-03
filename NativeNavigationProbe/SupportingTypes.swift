import SwiftUI
import UIKit

// This diagnostic host compiles the unmodified production navigation views and
// their native tests. Only unrelated route/theme dependencies are reduced here;
// complete application behavior is still gated by the full candidate workflow.
enum RootMainTab: String, CaseIterable, Hashable, Identifiable {
  case home, explore, notifications, account
  var id: Self { self }
  var title: String {
    switch self {
    case .home: "首页"
    case .explore: "发现"
    case .notifications: "消息"
    case .account: "我的"
    }
  }
  var systemImage: String {
    switch self {
    case .home: "house.fill"
    case .explore: "sparkles"
    case .notifications: "bell.fill"
    case .account: "person.crop.circle.fill"
    }
  }
}
enum RootMainTabVisibilityPolicy {
  static func visibleTabs(showsExploreTab: Bool) -> [RootMainTab] {
    showsExploreTab ? RootMainTab.allCases : [.home, .notifications, .account]
  }
  static func resolvedSelection(_ selectedTab: RootMainTab, showsExploreTab: Bool) -> RootMainTab {
    visibleTabs(showsExploreTab: showsExploreTab).contains(selectedTab) ? selectedTab : .home
  }
}
enum ExploreSection { case personalized, hot }
enum RootDestination: Equatable { case forum(String) }
struct RootMainNavigationState: Equatable {
  var selectedTab: RootMainTab = .home
  var exploreSection: ExploreSection = .personalized
  var paths: [RootMainTab: [RootDestination]] = [:]
  mutating func append(_ route: RootDestination, to tab: RootMainTab) {
    paths[tab, default: []].append(route)
  }
}
enum RootMainTabActivationPolicy {
  static func isActive(sceneIsActive: Bool, navigation: RootMainNavigationState, tab: RootMainTab) -> Bool {
    sceneIsActive && navigation.selectedTab == tab && navigation.paths[tab, default: []].isEmpty
  }
}
struct ProbeAccent {
  var color: Color { .blue }
  var uiColor: UIColor { .systemBlue }
}
extension EnvironmentValues {
  var appAccentColor: ProbeAccent { ProbeAccent() }
  var wallpaperTheme: Bool? { nil }
}
extension View {
  func appBarMaterialSurface() -> some View { background(.bar) }
}
