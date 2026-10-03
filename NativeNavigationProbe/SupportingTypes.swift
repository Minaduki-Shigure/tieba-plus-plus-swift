import SwiftUI
import UIKit

// This diagnostic host compiles the unmodified production navigation views and
// their native tests. Only unrelated route/theme dependencies are reduced here;
// complete application behavior is still gated by the full candidate workflow.
enum ExploreSection { case personalized, hot }
enum InboxKind { case replies }
enum RootDestination: Equatable { case forum(String) }
enum RootMainTabActivationPolicy {
  static func isActive(sceneIsActive: Bool, navigation: RootMainNavigationState, tab: RootMainTab) -> Bool {
    sceneIsActive && navigation.selectedTab == tab && navigation.path(for: tab).isEmpty
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
