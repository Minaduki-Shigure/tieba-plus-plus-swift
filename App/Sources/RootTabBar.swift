import Combine
import SwiftUI
import UIKit

/// Owns only the native selection control. SwiftUI continues to own the four
/// navigation stacks, their environment, presentations, and retained state.
struct RootTabBar: View {
  var isVisible: Bool = true
  let selectedTab: RootMainTab
  let showsExploreTab: Bool
  let notificationBadge: String?
  let allowsExploreRefresh: Bool
  let allowsHomeRefresh: Bool
  let onSelect: (RootMainTab) -> Void

  @Environment(\.appAccentColor) private var accentColor
  @Environment(\.wallpaperTheme) private var wallpaper
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.layoutDirection) private var layoutDirection
  @State private var keyboardCoversBottom = false

  var body: some View {
    let showsBar = isVisible && !keyboardCoversBottom
    // Keep the representable attached even in a wide layout. Recreating it on
    // a width change would lose the current keyboard frame and subscription.
    RootTabBarControl(
      selectedTab: selectedTab,
      showsExploreTab: showsExploreTab,
      notificationBadge: notificationBadge,
      allowsExploreRefresh: allowsExploreRefresh,
      allowsHomeRefresh: allowsHomeRefresh,
      accentColor: accentColor.uiColor,
      colorScheme: colorScheme,
      layoutDirection: layoutDirection,
      showsSeparator: wallpaper == nil,
      onSelect: onSelect,
      onKeyboardCoverageChanged: { keyboardCoversBottom = $0 }
    )
    .fixedSize(horizontal: false, vertical: true)
    .frame(height: showsBar ? nil : 0)
    .opacity(showsBar ? 1 : 0)
    .allowsHitTesting(showsBar)
    .accessibilityHidden(!showsBar)
    .background {
      if wallpaper == nil, showsBar {
        // SwiftUI extends this material through the bottom safe area. The
        // native bar itself is transparent, so there is only one backdrop.
        Rectangle().fill(.bar)
          .ignoresSafeArea(.container, edges: .bottom)
      }
    }
  }
}

struct RootTabBarControl: UIViewRepresentable {
  let selectedTab: RootMainTab
  let showsExploreTab: Bool
  let notificationBadge: String?
  let allowsExploreRefresh: Bool
  let allowsHomeRefresh: Bool
  let accentColor: UIColor
  let colorScheme: ColorScheme
  let layoutDirection: LayoutDirection
  let showsSeparator: Bool
  let onSelect: (RootMainTab) -> Void
  let onKeyboardCoverageChanged: (Bool) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> RootNativeTabBar {
    let bar = RootNativeTabBar()
    bar.accessibilityIdentifier = "root-tab-bar"
    bar.delegate = context.coordinator
    configure(bar, coordinator: context.coordinator)
    return bar
  }

  func updateUIView(_ bar: RootNativeTabBar, context: Context) {
    configure(bar, coordinator: context.coordinator)
  }

  func sizeThatFits(
    _ proposal: ProposedViewSize,
    uiView: RootNativeTabBar,
    context: Context
  ) -> CGSize? {
    guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
    let fitting = uiView.sizeThatFits(CGSize(width: width, height: 0))
    // The outer layout respects the home-indicator inset. Only reserve UIKit's
    // measured control height; never add the window's bottom inset again.
    return CGSize(width: width, height: max(0, fitting.height - uiView.safeAreaInsets.bottom))
  }

  private func configure(_ bar: RootNativeTabBar, coordinator: Coordinator) {
    coordinator.update(
      bar: bar,
      selectedTab: selectedTab,
      showsExploreTab: showsExploreTab,
      notificationBadge: notificationBadge,
      allowsExploreRefresh: allowsExploreRefresh,
      allowsHomeRefresh: allowsHomeRefresh,
      onSelect: onSelect
    )
    bar.onKeyboardCoverageChanged = onKeyboardCoverageChanged
    bar.tintColor = accentColor
    bar.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
    bar.semanticContentAttribute =
      layoutDirection == .rightToLeft ? .forceRightToLeft : .forceLeftToRight

    let appearance = UITabBarAppearance()
    appearance.configureWithTransparentBackground()
    appearance.shadowColor = showsSeparator ? .separator : .clear
    bar.standardAppearance = appearance
    bar.scrollEdgeAppearance = appearance
  }

  @MainActor
  final class Coordinator: NSObject, UITabBarDelegate {
    private var itemsByTab: [RootMainTab: UITabBarItem] = [:]
    private var visibleTabs: [RootMainTab] = []
    private var isApplyingState = false
    private var onSelect: ((RootMainTab) -> Void)?

    func update(
      bar: UITabBar,
      selectedTab: RootMainTab,
      showsExploreTab: Bool,
      notificationBadge: String?,
      allowsExploreRefresh: Bool,
      allowsHomeRefresh: Bool = false,
      onSelect: @escaping (RootMainTab) -> Void
    ) {
      self.onSelect = onSelect
      isApplyingState = true
      defer { isApplyingState = false }

      let tabs = RootMainTabVisibilityPolicy.visibleTabs(showsExploreTab: showsExploreTab)
      for tab in tabs where itemsByTab[tab] == nil {
        let item = UITabBarItem(
          title: tab.title, image: UIImage(systemName: tab.systemImage), selectedImage: nil)
        item.accessibilityIdentifier = "root-tab-\(tab.rawValue)"
        itemsByTab[tab] = item
      }
      if visibleTabs != tabs {
        visibleTabs = tabs
        bar.setItems(tabs.compactMap { itemsByTab[$0] }, animated: false)
      }
      let resolved = RootMainTabVisibilityPolicy.resolvedSelection(
        selectedTab, showsExploreTab: showsExploreTab)
      if bar.selectedItem !== itemsByTab[resolved] {
        bar.selectedItem = itemsByTab[resolved]
      }
      itemsByTab[.notifications]?.badgeValue = notificationBadge
      itemsByTab[.explore]?.accessibilityHint =
        allowsExploreRefresh ? "再次选择以刷新当前频道" : nil
      itemsByTab[.home]?.accessibilityHint =
        allowsHomeRefresh ? "再次选择以刷新首页" : nil
    }

    func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
      guard !isApplyingState,
        let tab = visibleTabs.first(where: { itemsByTab[$0] === item })
      else { return }
      // Do not use onChange or filter equal values: a real user selection of
      // the current item is exactly the event the caller needs to receive.
      onSelect?(tab)
    }
  }
}

@MainActor
final class RootNativeTabBar: UITabBar {
  var onKeyboardCoverageChanged: ((Bool) -> Void)?
  private var keyboardObservation: AnyCancellable?
  private var keyboardFrameInScreen: CGRect?
  private var keyboardFrameScreen: UIScreen?
  private var reportedKeyboardCoverage = false
  private var keyboardCoverageRevision: UInt64 = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    keyboardObservation = NotificationCenter.default.publisher(
      for: UIResponder.keyboardWillChangeFrameNotification
    )
    .merge(with: NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification))
    .receive(on: RunLoop.main)
    .sink { [weak self] notification in
      MainActor.assumeIsolated {
        guard let self, let window = self.window,
          RootTabBarKeyboardPolicy.acceptsNotification(
            notificationScreen: notification.object as AnyObject?,
            windowScreen: window.screen,
            isLocal: notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool)
        else { return }
        if notification.name == UIResponder.keyboardWillHideNotification {
          self.keyboardFrameInScreen = nil
          self.keyboardFrameScreen = nil
        } else {
          self.keyboardFrameInScreen =
            (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
          // iOS 16.1+ supplies a UIScreen as the notification object. A nil
          // object on earlier systems refers to the receiving window's screen.
          self.keyboardFrameScreen = window.screen
        }
        self.updateKeyboardCoverage()
      }
    }
  }

  required init?(coder: NSCoder) { return nil }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateKeyboardCoverage()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateKeyboardCoverage()
  }

  private func updateKeyboardCoverage() {
    // While attached to a different display we ignore the original display's
    // notifications, including its keyboard dismissal. Discard that frame now
    // so returning later cannot resurrect stale coverage. Temporary detachment
    // and reattachment on the same screen still preserve the current frame.
    keyboardFrameInScreen = RootTabBarKeyboardPolicy.retainedFrame(
      keyboardFrameInScreen, frameScreen: keyboardFrameScreen, attachedScreen: window?.screen)
    if keyboardFrameInScreen == nil { keyboardFrameScreen = nil }
    let coversBottom: Bool
    if let window, let frame = keyboardFrameInScreen, keyboardFrameScreen === window.screen {
      coversBottom = RootTabBarKeyboardPolicy.coversBottom(
        keyboardFrame: window.convert(frame, from: window.screen.coordinateSpace),
        windowBounds: window.bounds,
        bottomSafeArea: window.safeAreaInsets.bottom
      )
    } else {
      coversBottom = false
    }
    guard coversBottom != reportedKeyboardCoverage else { return }
    reportedKeyboardCoverage = coversBottom
    keyboardCoverageRevision &+= 1
    let revision = keyboardCoverageRevision
    // Layout can run during a SwiftUI update. Publish only after that update,
    // and drop an obsolete result if the keyboard moved again in the meantime.
    DispatchQueue.main.async { [weak self] in
      guard let self, keyboardCoverageRevision == revision else { return }
      onKeyboardCoverageChanged?(coversBottom)
    }
  }
}

enum RootTabBarKeyboardPolicy {
  static func retainedFrame(
    _ frame: CGRect?, frameScreen: AnyObject?, attachedScreen: AnyObject?
  ) -> CGRect? {
    guard let attachedScreen else { return frame }
    guard let frameScreen, frameScreen === attachedScreen else { return nil }
    return frame
  }

  static func acceptsNotification(
    notificationScreen: AnyObject?, windowScreen: AnyObject?, isLocal: Bool?
  ) -> Bool {
    guard isLocal != false, let windowScreen else { return false }
    // Identity matters: equal coordinates on another display do not describe
    // this window. Nil preserves compatibility with iOS 16.0 notifications.
    return notificationScreen == nil || notificationScreen === windowScreen
  }

  static func coversBottom(
    keyboardFrame: CGRect,
    windowBounds: CGRect,
    bottomSafeArea: CGFloat
  ) -> Bool {
    guard !keyboardFrame.isNull, !keyboardFrame.isInfinite,
      !windowBounds.isEmpty, !windowBounds.isNull, !windowBounds.isInfinite
    else { return false }
    let intersection = windowBounds.intersection(keyboardFrame)
    return !intersection.isNull && intersection.width > 0
      && intersection.height > max(0, bottomSafeArea)
      && keyboardFrame.maxY >= windowBounds.maxY - 1
  }
}

enum RootTabSelectionAction: Equatable {
  case select(RootMainTab)
  case refreshExplore
  case refreshHome
  case none
}

enum RootTabSelectionPolicy {
  static func action(
    selecting tab: RootMainTab,
    navigation: RootMainNavigationState,
    showsExploreTab: Bool,
    sceneIsActive: Bool,
    hasActiveAccount: Bool = false
  ) -> RootTabSelectionAction {
    guard RootMainTabVisibilityPolicy.visibleTabs(showsExploreTab: showsExploreTab).contains(tab)
    else { return .none }
    guard tab == navigation.selectedTab else { return .select(tab) }
    guard RootMainTabActivationPolicy.isActive(
        sceneIsActive: sceneIsActive, navigation: navigation, tab: tab)
    else { return .none }
    switch tab {
    case .explore: return .refreshExplore
    case .home: return hasActiveAccount ? .refreshHome : .none
    case .notifications, .account: return .none
    }
  }
}
