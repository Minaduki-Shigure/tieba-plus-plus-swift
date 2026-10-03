import SwiftUI

enum RootAdaptiveNavigationMode: String, Equatable, Sendable {
  case bottom
  case rail
  case sidebar

  var sideWidth: CGFloat {
    switch self {
    case .bottom: 0
    case .rail: 80
    case .sidebar: 240
    }
  }
}

enum RootAdaptiveNavigationPolicy {
  static func mode(
    width: CGFloat,
    horizontalSizeClass: UserInterfaceSizeClass?,
    verticalSizeClass: UserInterfaceSizeClass?
  ) -> RootAdaptiveNavigationMode {
    guard width.isFinite, width >= 600,
      horizontalSizeClass == .regular, verticalSizeClass != .compact
    else { return .bottom }
    return width < 840 ? .rail : .sidebar
  }
}

/// Only the navigation controls change their occupied space. The content and
/// bottom bar always remain in the same structural slots, including during a
/// live window resize, so their navigation, scroll and keyboard state survives.
struct RootAdaptiveNavigation<Content: View, BottomBar: View>: View {
  let selectedTab: RootMainTab
  let showsExploreTab: Bool
  let notificationBadge: String?
  let allowsExploreRefresh: Bool
  let allowsHomeRefresh: Bool
  let onSelect: (RootMainTab) -> Void
  private let content: Content
  private let bottomBar: (Bool) -> BottomBar

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @Environment(\.verticalSizeClass) private var verticalSizeClass

  init(
    selectedTab: RootMainTab,
    showsExploreTab: Bool,
    notificationBadge: String?,
    allowsExploreRefresh: Bool,
    allowsHomeRefresh: Bool,
    onSelect: @escaping (RootMainTab) -> Void,
    @ViewBuilder content: () -> Content,
    @ViewBuilder bottomBar: @escaping (_ isVisible: Bool) -> BottomBar
  ) {
    self.selectedTab = selectedTab
    self.showsExploreTab = showsExploreTab
    self.notificationBadge = notificationBadge
    self.allowsExploreRefresh = allowsExploreRefresh
    self.allowsHomeRefresh = allowsHomeRefresh
    self.onSelect = onSelect
    self.content = content()
    self.bottomBar = bottomBar
  }

  var body: some View {
    GeometryReader { geometry in
      let mode = RootAdaptiveNavigationPolicy.mode(
        width: geometry.size.width,
        horizontalSizeClass: horizontalSizeClass,
        verticalSizeClass: verticalSizeClass)
      HStack(spacing: 0) {
        RootSideNavigation(
          mode: mode,
          selectedTab: selectedTab,
          showsExploreTab: showsExploreTab,
          notificationBadge: notificationBadge,
          allowsExploreRefresh: allowsExploreRefresh,
          allowsHomeRefresh: allowsHomeRefresh,
          onSelect: onSelect
        )
        .frame(width: mode.sideWidth)
        .clipped()
        .opacity(mode == .bottom ? 0 : 1)
        .allowsHitTesting(mode != .bottom)
        .accessibilityHidden(mode == .bottom)

        VStack(spacing: 0) {
          content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          bottomBar(mode == .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      #if DEBUG
        .overlay(alignment: .topLeading) {
          // A separate fixture-readable element leaves every page and control
          // accessible. Release VoiceOver never exposes implementation modes.
          Color.clear
            .frame(width: 1, height: 1)
            .accessibilityElement()
            .accessibilityLabel("导航布局")
            .accessibilityValue(mode.rawValue)
            .accessibilityIdentifier("root-navigation-layout")
            .allowsHitTesting(false)
        }
      #endif
    }
  }
}

private struct RootSideNavigation: View {
  let mode: RootAdaptiveNavigationMode
  let selectedTab: RootMainTab
  let showsExploreTab: Bool
  let notificationBadge: String?
  let allowsExploreRefresh: Bool
  let allowsHomeRefresh: Bool
  let onSelect: (RootMainTab) -> Void

  @Environment(\.appAccentColor) private var accentColor

  private var resolvedSelection: RootMainTab {
    RootMainTabVisibilityPolicy.resolvedSelection(
      selectedTab, showsExploreTab: showsExploreTab)
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView(.vertical) {
        VStack(spacing: 12) {
          ForEach(RootMainTabVisibilityPolicy.visibleTabs(showsExploreTab: showsExploreTab)) { tab in
            tabButton(tab)
          }
        }
        .padding(.horizontal, mode == .sidebar ? 12 : 6)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .frame(minHeight: geometry.size.height, alignment: .center)
      }
    }
    .appBarMaterialSurface()
    .accessibilityElement(children: .contain)
    .accessibilityLabel("主导航")
    .accessibilityIdentifier("root-side-navigation")
  }

  private func tabButton(_ tab: RootMainTab) -> some View {
    let isSelected = tab == resolvedSelection
    return Button {
      // This also forwards a repeated selection. Root owns the account,
      // foreground and navigation-depth checks that decide whether to refresh.
      onSelect(tab)
    } label: {
      tabLabel(tab)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.vertical, 8)
        .padding(.horizontal, mode == .sidebar ? 10 : 2)
        .foregroundStyle(isSelected ? accentColor.color : Color.primary)
        .background {
          if isSelected {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(accentColor.color.opacity(0.15))
          }
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tab.title)
    .accessibilityValue(tab == .notifications ? (notificationBadge ?? "") : "")
    .accessibilityHint(refreshHint(for: tab))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("root-side-tab-\(tab.rawValue)")
  }

  @ViewBuilder
  private func tabLabel(_ tab: RootMainTab) -> some View {
    if mode == .sidebar {
      HStack(spacing: 10) {
        Image(systemName: tab.systemImage)
          .font(.title3)
          .accessibilityHidden(true)
        Text(tab.title)
          .font(.body)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        if tab == .notifications, let notificationBadge {
          badge(notificationBadge)
        }
      }
    } else {
      VStack(spacing: 5) {
        Image(systemName: tab.systemImage)
          .font(.title2)
          .accessibilityHidden(true)
        Text(tab.title)
          .font(.caption)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
        if tab == .notifications, let notificationBadge {
          badge(notificationBadge)
        }
      }
    }
  }

  private func badge(_ value: String) -> some View {
    Text(value)
      .font(.caption2.weight(.semibold))
      .monospacedDigit()
      .lineLimit(1)
      .minimumScaleFactor(0.65)
      .foregroundStyle(.white)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(Color.red, in: Capsule())
      .accessibilityHidden(true)
  }

  private func refreshHint(for tab: RootMainTab) -> String {
    switch tab {
    case .home where allowsHomeRefresh: "再次选择以刷新首页"
    case .explore where allowsExploreRefresh: "再次选择以刷新当前频道"
    default: ""
    }
  }
}
