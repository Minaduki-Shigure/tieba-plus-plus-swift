import SwiftUI
import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class RootAdaptiveNavigationTests: XCTestCase {
  func testModeBoundariesUseActualFiniteWidthAndProtectCompactTraits() {
    func mode(
      _ width: CGFloat,
      horizontal: UserInterfaceSizeClass? = .regular,
      vertical: UserInterfaceSizeClass? = .regular
    ) -> RootAdaptiveNavigationMode {
      RootAdaptiveNavigationPolicy.mode(
        width: width, horizontalSizeClass: horizontal, verticalSizeClass: vertical)
    }

    XCTAssertEqual(mode(599.99), .bottom)
    XCTAssertEqual(mode(600), .rail)
    XCTAssertEqual(mode(839.99), .rail)
    XCTAssertEqual(mode(840), .sidebar)
    XCTAssertEqual(mode(1366), .sidebar)
    for width: CGFloat in [-1, 0, .nan, .infinity, -.infinity] {
      XCTAssertEqual(mode(width), .bottom)
    }
    XCTAssertEqual(mode(1200, horizontal: .compact), .bottom)
    XCTAssertEqual(mode(1200, horizontal: nil), .bottom)
    XCTAssertEqual(mode(1200, vertical: .compact), .bottom)
    XCTAssertEqual(mode(840, vertical: nil), .sidebar)
  }

  func testContinuousResizeKeepsSwiftUIStateNativeViewsAndScrollPosition() async throws {
    let harness = try AdaptiveNavigationHostHarness()
    defer { harness.close() }
    harness.resize(width: 390, height: 720)
    await harness.settleLayout()
    let content = try XCTUnwrap(harness.recorder.contentViews.first)
    let bottom = try XCTUnwrap(harness.recorder.bottomViews.first)
    let stateID = try XCTUnwrap(content.stateID)
    let changeState = try XCTUnwrap(harness.recorder.changeContentState)
    changeState()
    await harness.settleLayout()
    XCTAssertEqual(content.stateValue, 1)
    content.scrollView.setContentOffset(CGPoint(x: 0, y: 173), animated: false)

    // Keep one hosting controller and one root view. Replacing rootView for each
    // case would miss the structural-identity regression this test is for.
    for (width, sideWidth, bottomHeight): (CGFloat, CGFloat, CGFloat) in [
      (599, 0, 49), (600, 80, 0), (740, 80, 0), (839, 80, 0),
      (840, 240, 0), (1024, 240, 0), (840, 240, 0), (839, 80, 0),
      (600, 80, 0), (599, 0, 49), (390, 0, 49),
    ] {
      harness.resize(width: width, height: 720)
      await harness.settleLayout()
      XCTAssertEqual(harness.recorder.contentViews.count, 1, "width=\(width)")
      XCTAssertEqual(harness.recorder.bottomViews.count, 1, "width=\(width)")
      XCTAssertTrue(harness.recorder.contentViews.last === content)
      XCTAssertTrue(harness.recorder.bottomViews.last === bottom)
      XCTAssertEqual(content.stateID, stateID, "SwiftUI StateObject must survive resizing")
      XCTAssertEqual(content.stateValue, 1)
      XCTAssertEqual(content.scrollView.contentOffset.y, 173, accuracy: 1)
      assertRegions(
        harness, content: content, bottom: bottom,
        size: CGSize(width: width, height: 720),
        sideWidth: sideWidth, bottomHeight: bottomHeight)
    }
    XCTAssertTrue(harness.recorder.selections.isEmpty, "Layout changes are not user selections")
  }

  func testTraitChangesAndRTLKeepContentIdentityAndReserveTheCorrectEdge() async throws {
    let harness = try AdaptiveNavigationHostHarness()
    defer { harness.close() }
    harness.resize(width: 1024, height: 650)
    await harness.settleLayout()
    let content = try XCTUnwrap(harness.recorder.contentViews.first)
    let bottom = try XCTUnwrap(harness.recorder.bottomViews.first)

    // Compact height protects landscape phones even when their width and
    // horizontal traits alone could otherwise qualify for a side navigation.
    for (horizontal, vertical): (UIUserInterfaceSizeClass, UIUserInterfaceSizeClass) in [
      (.compact, .regular), (.regular, .compact),
    ] {
      harness.setTraits(horizontal: horizontal, vertical: vertical)
      await harness.settleLayout()
      assertRegions(
        harness, content: content, bottom: bottom,
        size: CGSize(width: 1024, height: 650), sideWidth: 0, bottomHeight: 49)
    }

    harness.setTraits(horizontal: .regular, vertical: .regular)
    harness.configuration.layoutDirection = .rightToLeft
    await harness.settleLayout()
    assertRegions(
      harness, content: content, bottom: bottom,
      size: CGSize(width: 1024, height: 650), sideWidth: 240, bottomHeight: 0,
      rightToLeft: true)
    harness.resize(width: 700, height: 650)
    await harness.settleLayout()
    assertRegions(
      harness, content: content, bottom: bottom,
      size: CGSize(width: 700, height: 650), sideWidth: 80, bottomHeight: 0,
      rightToLeft: true)
    XCTAssertEqual(harness.recorder.contentViews.count, 1)
    XCTAssertEqual(harness.recorder.bottomViews.count, 1)
    XCTAssertTrue(harness.recorder.selections.isEmpty)
  }

  func testLargeTypeSideNavigationCanScrollInAShortRegularWindow() async throws {
    let harness = try AdaptiveNavigationHostHarness()
    defer { harness.close() }
    harness.configuration.dynamicTypeSize = .accessibility5
    harness.resize(width: 900, height: 180)
    await harness.settleLayout()
    let content = try XCTUnwrap(harness.recorder.contentViews.first)
    let bottom = try XCTUnwrap(harness.recorder.bottomViews.first)
    assertRegions(
      harness, content: content, bottom: bottom,
      size: CGSize(width: 900, height: 180), sideWidth: 240, bottomHeight: 0)
    let sideScroll = try XCTUnwrap(
      descendantScrollViews(in: harness.host.view).first {
        $0 !== content.scrollView && $0 !== bottom.scrollView
          && abs($0.bounds.width - 240) < 1
      })
    XCTAssertGreaterThan(sideScroll.contentSize.height, sideScroll.bounds.height)
    XCTAssertEqual(sideScroll.bounds.width, 240, accuracy: 1)
    XCTAssertEqual(sideScroll.bounds.height, 180, accuracy: 1)
    let offset = sideScroll.contentSize.height - sideScroll.bounds.height
    sideScroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
    XCTAssertGreaterThan(sideScroll.contentOffset.y, 0)
    XCTAssertTrue(harness.recorder.selections.isEmpty)
  }

  private func assertRegions(
    _ harness: AdaptiveNavigationHostHarness,
    content: AdaptiveNavigationProbeView,
    bottom: AdaptiveNavigationProbeView,
    size: CGSize,
    sideWidth: CGFloat,
    bottomHeight: CGFloat,
    rightToLeft: Bool = false,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let contentRect = content.convert(content.bounds, to: harness.host.view)
    let bottomRect = bottom.convert(bottom.bounds, to: harness.host.view)
    XCTAssertEqual(contentRect.minX, rightToLeft ? 0 : sideWidth, accuracy: 1, file: file, line: line)
    XCTAssertEqual(contentRect.minY, 0, accuracy: 1, file: file, line: line)
    XCTAssertEqual(contentRect.width, size.width - sideWidth, accuracy: 1, file: file, line: line)
    XCTAssertEqual(contentRect.height, size.height - bottomHeight, accuracy: 1, file: file, line: line)
    XCTAssertEqual(bottomRect.height, bottomHeight, accuracy: 1, file: file, line: line)
    XCTAssertEqual(bottomRect.minY, contentRect.maxY, accuracy: 1, file: file, line: line)
    XCTAssertEqual(bottomRect.maxY, size.height, accuracy: 1, file: file, line: line)
    XCTAssertEqual(bottomRect.minX, contentRect.minX, accuracy: 1, file: file, line: line)
    XCTAssertEqual(bottomRect.width, contentRect.width, accuracy: 1, file: file, line: line)
  }

  private func descendantScrollViews(in view: UIView) -> [UIScrollView] {
    let ownScrollView = (view as? UIScrollView).map { [$0] } ?? []
    return ownScrollView + view.subviews.flatMap { descendantScrollViews(in: $0) }
  }
}

@MainActor
private final class AdaptiveNavigationHostHarness {
  let recorder = AdaptiveNavigationProbeRecorder()
  let configuration = AdaptiveNavigationTestConfiguration()
  let host: UIHostingController<AdaptiveNavigationTestRoot>
  private let parent = UIViewController()
  private let window: UIWindow
  private let previousKeyWindow: UIWindow?

  init() throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive })
    previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    window = UIWindow(windowScene: scene)
    window.frame = scene.coordinateSpace.bounds
    host = UIHostingController(
      rootView: AdaptiveNavigationTestRoot(recorder: recorder, configuration: configuration))
    window.rootViewController = parent
    parent.loadViewIfNeeded()
    parent.addChild(host)
    parent.view.addSubview(host.view)
    host.view.autoresizingMask = []
    host.didMove(toParent: parent)
    setTraits(horizontal: .regular, vertical: .regular)
    window.makeKeyAndVisible()
    resize(width: 390, height: 720)
  }

  func setTraits(horizontal: UIUserInterfaceSizeClass, vertical: UIUserInterfaceSizeClass) {
    parent.setOverrideTraitCollection(
      UITraitCollection(traitsFrom: [
        UITraitCollection(horizontalSizeClass: horizontal),
        UITraitCollection(verticalSizeClass: vertical),
      ]), forChild: host)
  }

  func resize(width: CGFloat, height: CGFloat) {
    // The real parent container changes size without replacing its hosting
    // controller, rootView, state, or navigation content. It may extend beyond
    // the test phone's display; these tests assert native layout, not pixels.
    host.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
    host.view.setNeedsLayout()
  }

  func settleLayout() async {
    for _ in 0..<3 {
      host.view.layoutIfNeeded()
      await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
      }
    }
    host.view.layoutIfNeeded()
  }

  func close() {
    window.isHidden = true
    host.willMove(toParent: nil)
    host.view.removeFromSuperview()
    host.removeFromParent()
    window.rootViewController = nil
    previousKeyWindow?.makeKey()
  }
}

@MainActor
private final class AdaptiveNavigationTestConfiguration: ObservableObject {
  @Published var layoutDirection: LayoutDirection = .leftToRight
  @Published var dynamicTypeSize: DynamicTypeSize = .large
}

private struct AdaptiveNavigationTestRoot: View {
  let recorder: AdaptiveNavigationProbeRecorder
  @ObservedObject var configuration: AdaptiveNavigationTestConfiguration

  var body: some View {
    RootAdaptiveNavigation(
      selectedTab: .explore, showsExploreTab: true, notificationBadge: "7",
      allowsExploreRefresh: true, allowsHomeRefresh: false,
      onSelect: { recorder.selections.append($0) }
    ) {
      AdaptiveNavigationStatefulContent(recorder: recorder)
    } bottomBar: { isVisible in
      AdaptiveNavigationNativeProbe(role: .bottom, recorder: recorder)
        .frame(height: isVisible ? 49 : 0)
        .clipped()
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
    }
    .environment(\.layoutDirection, configuration.layoutDirection)
    .environment(\.dynamicTypeSize, configuration.dynamicTypeSize)
    .ignoresSafeArea()
  }
}

@MainActor
private final class AdaptiveNavigationContentState: ObservableObject {
  let identity = UUID()
  @Published var value = 0
}

private struct AdaptiveNavigationStatefulContent: View {
  let recorder: AdaptiveNavigationProbeRecorder
  @StateObject private var state = AdaptiveNavigationContentState()

  var body: some View {
    AdaptiveNavigationNativeProbe(
      role: .content, recorder: recorder, stateID: state.identity, stateValue: state.value
    )
    .onAppear {
      recorder.changeContentState = { state.value += 1 }
    }
  }
}

@MainActor
private final class AdaptiveNavigationProbeRecorder {
  var contentViews: [AdaptiveNavigationProbeView] = []
  var bottomViews: [AdaptiveNavigationProbeView] = []
  var selections: [RootMainTab] = []
  var changeContentState: (@MainActor () -> Void)?
}

private struct AdaptiveNavigationNativeProbe: UIViewRepresentable {
  enum Role { case content, bottom }

  let role: Role
  let recorder: AdaptiveNavigationProbeRecorder
  var stateID: UUID?
  var stateValue = 0

  func makeUIView(context: Context) -> AdaptiveNavigationProbeView {
    let view = AdaptiveNavigationProbeView()
    switch role {
    case .content: recorder.contentViews.append(view)
    case .bottom: recorder.bottomViews.append(view)
    }
    return view
  }

  func updateUIView(_ view: AdaptiveNavigationProbeView, context: Context) {
    view.stateID = stateID
    view.stateValue = stateValue
  }
}

@MainActor
private final class AdaptiveNavigationProbeView: UIView {
  let scrollView = UIScrollView()
  var stateID: UUID?
  var stateValue = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    scrollView.contentInsetAdjustmentBehavior = .never
    addSubview(scrollView)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func layoutSubviews() {
    super.layoutSubviews()
    scrollView.frame = bounds
    scrollView.contentSize = CGSize(width: bounds.width, height: 3000)
  }
}
