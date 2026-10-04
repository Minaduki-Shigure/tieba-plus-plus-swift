import SwiftUI
import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ForumSectionPagerTests: XCTestCase {
  func testFourNativePagesKeepLocalStateAndScrollOffsetAcrossDistantSelections() async throws {
    let harness = try ForumSectionPagerTestHarness(sections: [0, 1, 2, 3])
    defer { harness.close() }
    var originalViews: [Int: ForumSectionPagerScrollProbe] = [:]
    var originalStates: [Int: UUID] = [:]

    for section in 0..<4 {
      harness.selection.value = section
      let scroll = try await visiblePage(section, in: harness)
      let changeState = try XCTUnwrap(harness.recorder.changeState[section])
      changeState()
      try await waitForState(1, section: section, in: harness)
      let offset = CGFloat(125 + section * 90)
      scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
      XCTAssertEqual(scroll.contentOffset.y, offset, accuracy: 0.5)
      originalViews[section] = scroll
      originalStates[section] = try XCTUnwrap(scroll.stateID)
    }

    // Exercise jumps beyond UIKit's usual immediate-neighbor prefetch range.
    // Replacing the entire host or saving offsets in the fixture would hide
    // the lifecycle regression this test needs to detect.
    for section in [0, 3, 1, 2, 0, 2, 3, 1] {
      harness.selection.value = section
      let scroll = try await visiblePage(section, in: harness)
      XCTAssertTrue(scroll === originalViews[section], harness.diagnostics())
      XCTAssertEqual(harness.recorder.views[section]?.count, 1, harness.diagnostics())
      XCTAssertEqual(scroll.stateID, originalStates[section], harness.diagnostics())
      XCTAssertEqual(scroll.localValue, 1, harness.diagnostics())
      XCTAssertEqual(
        scroll.contentOffset.y, CGFloat(125 + section * 90), accuracy: 0.5,
        harness.diagnostics())
    }
  }

  func testAppendingReorderingAndRemovingOtherSectionsKeepSelectedNativePage() async throws {
    let harness = try ForumSectionPagerTestHarness(sections: [0, 1])
    defer { harness.close() }
    harness.selection.value = 1
    let original = try await visiblePage(1, in: harness)
    let changeState = try XCTUnwrap(harness.recorder.changeState[1])
    changeState()
    try await waitForState(1, section: 1, in: harness)
    let stateID = try XCTUnwrap(original.stateID)
    original.setContentOffset(CGPoint(x: 0, y: 287), animated: false)

    for sections in [[0, 1, 2, 3], [3, 0, 2, 1], [3, 2, 1]] {
      harness.selection.sections = sections
      // Let the same mounted root process the changed section collection before
      // checking it; an immediately true assertion could inspect its old tree.
      try await harness.settleLayout()
      let scroll = try await visiblePage(1, in: harness)
      XCTAssertEqual(harness.selection.value, 1)
      XCTAssertTrue(scroll === original, harness.diagnostics())
      XCTAssertEqual(harness.recorder.views[1]?.count, 1, harness.diagnostics())
      XCTAssertEqual(scroll.stateID, stateID, harness.diagnostics())
      XCTAssertEqual(scroll.localValue, 1, harness.diagnostics())
      XCTAssertEqual(scroll.contentOffset.y, 287, accuracy: 0.5, harness.diagnostics())
    }
  }

  func testNativeHorizontalSettlementUpdatesSelectionAndKeepsVerticalPosition() async throws {
    let harness = try ForumSectionPagerTestHarness(sections: [0, 1, 2, 3])
    defer { harness.close() }
    let first = try await visiblePage(0, in: harness)
    first.setContentOffset(CGPoint(x: 0, y: 321), animated: false)
    let pager = try XCTUnwrap(pagingScroll(containing: first))
    XCTAssertTrue(pager.isPagingEnabled)
    XCTAssertNotNil(pager.delegate, "SwiftUI keeps its own scroll delegate.")
    let originalDelegate = pager.delegate

    // Drive UIKit's content offset, not the binding. The bridge must report the
    // settled native page back to the caller. Actual swipes belong to UI tests.
    pager.setContentOffset(CGPoint(x: pager.bounds.width * 3, y: 0), animated: false)
    try await waitForSelection(3, in: harness)
    _ = try await visiblePage(3, in: harness)
    XCTAssertTrue(pager.delegate === originalDelegate)
    pager.setContentOffset(CGPoint(x: pager.bounds.width * 1.2, y: 0), animated: false)
    try await waitForSelection(1, in: harness)
    _ = try await visiblePage(1, in: harness)
    XCTAssertEqual(pager.contentOffset.x, pager.bounds.width, accuracy: 0.5)
    pager.setContentOffset(.zero, animated: false)
    try await waitForSelection(0, in: harness)
    let returned = try await visiblePage(0, in: harness)
    XCTAssertTrue(returned === first)
    XCTAssertEqual(returned.contentOffset.y, 321, accuracy: 0.5)
  }

  func testWidthChangesKeepSelectedPageAlignedWithoutRebuildingItsList() async throws {
    let harness = try ForumSectionPagerTestHarness(sections: [0, 1, 2, 3])
    defer { harness.close() }
    harness.selection.value = 3
    let original = try await visiblePage(3, in: harness)
    original.setContentOffset(CGPoint(x: 0, y: 411), animated: false)
    let pager = try XCTUnwrap(pagingScroll(containing: original))
    for width: CGFloat in [220, 300, 260] {
      harness.selection.width = width
      try await harness.settleLayout()
      let scroll = try await visiblePage(3, in: harness)
      XCTAssertEqual(harness.selection.value, 3)
      XCTAssertTrue(scroll === original)
      XCTAssertEqual(scroll.bounds.width, width, accuracy: 0.5)
      XCTAssertEqual(pager.contentOffset.x, width * 3, accuracy: 0.5)
      XCTAssertEqual(scroll.contentOffset.y, 411, accuracy: 0.5)
    }
    // The parent chooses the fallback when the current section disappears.
    harness.selection.value = 1
    harness.selection.sections = [0, 1, 2]
    _ = try await visiblePage(1, in: harness)
    XCTAssertEqual(harness.selection.value, 1)
  }

  func testRightToLeftPagesPreserveIdentityAndMapNativeSettlementBackToSection() async throws {
    let harness = try ForumSectionPagerTestHarness(sections: [0, 1, 2, 3])
    defer { harness.close() }
    let first = try await visiblePage(0, in: harness)
    first.setContentOffset(CGPoint(x: 0, y: 233), animated: false)
    harness.selection.layoutDirection = .rightToLeft
    try await harness.settleLayout()
    let sameFirst = try await visiblePage(0, in: harness)
    XCTAssertTrue(sameFirst === first)
    XCTAssertEqual(sameFirst.contentOffset.y, 233, accuracy: 0.5)
    let pager = try XCTUnwrap(pagingScroll(containing: sameFirst))
    XCTAssertEqual(pager.contentOffset.x, pager.bounds.width * 3, accuracy: 0.5)
    pager.setContentOffset(.zero, animated: false)
    try await waitForSelection(3, in: harness)
    _ = try await visiblePage(3, in: harness)
    harness.selection.layoutDirection = .leftToRight
    try await harness.settleLayout()
    _ = try await visiblePage(3, in: harness)
    XCTAssertEqual(harness.selection.value, 3)
    XCTAssertEqual(pager.contentOffset.x, pager.bounds.width * 3, accuracy: 0.5)
  }

  private func pagingScroll(containing view: UIView) -> UIScrollView? {
    var ancestor = view.superview
    while let current = ancestor {
      if let scroll = current as? UIScrollView,
        scroll.accessibilityIdentifier == "forum-section-pager-scroll"
      {
        return scroll
      }
      ancestor = current.superview
    }
    return nil
  }

  private func waitForSelection(
    _ selection: Int, in harness: ForumSectionPagerTestHarness,
    file: StaticString = #filePath, line: UInt = #line
  ) async throws {
    for _ in 0..<150 {
      if harness.selection.value == selection { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail(
      "Native settlement did not select \(selection). \(harness.diagnostics())", file: file,
      line: line)
    throw ForumSectionPagerTestError.timeout
  }

  private func visiblePage(
    _ section: Int,
    in harness: ForumSectionPagerTestHarness,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws -> ForumSectionPagerScrollProbe {
    for _ in 0..<150 {
      harness.host.view.layoutIfNeeded()
      if let scroll = harness.recorder.views[section]?.last,
        scroll.window === harness.window,
        scroll.renderedSections == harness.selection.sections,
        harness.recorder.changeState[section] != nil
      {
        let frame = scroll.convert(scroll.bounds, to: harness.host.view)
        let intersection = frame.intersection(harness.host.view.bounds)
        if frame.width > 100, frame.height > 100,
          intersection.width >= frame.width * 0.95,
          intersection.height >= frame.height * 0.95
        {
          return scroll
        }
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail(
      "Page \(section) did not become visible. \(harness.diagnostics())", file: file, line: line)
    throw ForumSectionPagerTestError.timeout
  }

  private func waitForState(
    _ expected: Int,
    section: Int,
    in harness: ForumSectionPagerTestHarness,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async throws {
    for _ in 0..<100 {
      if harness.recorder.views[section]?.last?.localValue == expected { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    XCTFail(
      "Page \(section) state did not update. \(harness.diagnostics())", file: file, line: line)
    throw ForumSectionPagerTestError.timeout
  }
}

@MainActor
private final class ForumSectionPagerTestHarness {
  let selection: ForumSectionPagerTestSelection
  let recorder = ForumSectionPagerTestRecorder()
  let host: UIHostingController<ForumSectionPagerTestRoot>
  let window: UIWindow
  private let previousKeyWindow: UIWindow?

  init(sections: [Int]) throws {
    let scene = try XCTUnwrap(
      UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .first { $0.activationState == .foregroundActive },
      "Pager retention needs the hosted native iOS test application.")
    selection = ForumSectionPagerTestSelection(sections: sections)
    host = UIHostingController(
      rootView: ForumSectionPagerTestRoot(selection: selection, recorder: recorder))
    previousKeyWindow = scene.windows.first { $0.isKeyWindow }
    window = UIWindow(windowScene: scene)
    window.frame = scene.coordinateSpace.bounds
    window.rootViewController = host
    window.makeKeyAndVisible()
    host.view.frame = window.bounds
    host.view.layoutIfNeeded()
  }

  func settleLayout() async throws {
    for _ in 0..<3 {
      host.view.layoutIfNeeded()
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  func diagnostics() -> String {
    let pages = recorder.views.keys.sorted().map { section in
      let views = recorder.views[section] ?? []
      let last = views.last
      return "page=\(section) creates=\(views.count) state=\(String(describing: last?.stateID)) "
        + "value=\(String(describing: last?.localValue)) offset=\(String(describing: last?.contentOffset)) "
        + "renderedSections=\(String(describing: last?.renderedSections)) "
        + "frame=\(String(describing: last.map { $0.convert($0.bounds, to: host.view) })) "
        + "attached=\(last?.window === window)"
    }
    return "selected=\(selection.value) sections=\(selection.sections) host=\(host.view.bounds) "
      + pages.joined(separator: "; ")
  }

  func close() {
    window.isHidden = true
    window.rootViewController = nil
    previousKeyWindow?.makeKey()
  }
}

@MainActor
private final class ForumSectionPagerTestSelection: ObservableObject {
  @Published var sections: [Int]
  @Published var value: Int
  @Published var width: CGFloat?
  @Published var layoutDirection: LayoutDirection = .leftToRight

  init(sections: [Int]) {
    self.sections = sections
    value = sections.first ?? 0
  }
}

@MainActor
private final class ForumSectionPagerTestRecorder {
  var views: [Int: [ForumSectionPagerScrollProbe]] = [:]
  var changeState: [Int: @MainActor () -> Void] = [:]
}

@MainActor
private struct ForumSectionPagerTestRoot: View {
  @ObservedObject var selection: ForumSectionPagerTestSelection
  let recorder: ForumSectionPagerTestRecorder

  var body: some View {
    ForumSectionPager(sections: selection.sections, selection: $selection.value) { section in
      ForumSectionPagerTestPage(
        section: section, sections: selection.sections, recorder: recorder)
    }
    .frame(width: selection.width)
    .environment(\.layoutDirection, selection.layoutDirection)
  }
}

@MainActor
private final class ForumSectionPagerTestPageIdentity: ObservableObject {
  let id = UUID()
}

@MainActor
private struct ForumSectionPagerTestPage: View {
  let section: Int
  let sections: [Int]
  let recorder: ForumSectionPagerTestRecorder
  @State private var localValue = 0
  @StateObject private var identity = ForumSectionPagerTestPageIdentity()

  var body: some View {
    ForumSectionPagerNativeProbe(
      section: section, sections: sections, recorder: recorder,
      stateID: identity.id, localValue: localValue
    )
    .onAppear {
      recorder.changeState[section] = { localValue += 1 }
    }
  }
}

private struct ForumSectionPagerNativeProbe: UIViewRepresentable {
  let section: Int
  let sections: [Int]
  let recorder: ForumSectionPagerTestRecorder
  let stateID: UUID
  let localValue: Int

  func makeUIView(context: Context) -> ForumSectionPagerScrollProbe {
    let view = ForumSectionPagerScrollProbe()
    view.accessibilityIdentifier = "forum-section-test-scroll-\(section)"
    recorder.views[section, default: []].append(view)
    return view
  }

  func updateUIView(_ uiView: ForumSectionPagerScrollProbe, context: Context) {
    uiView.stateID = stateID
    uiView.localValue = localValue
    uiView.renderedSections = sections
  }
}

@MainActor
private final class ForumSectionPagerScrollProbe: UIScrollView {
  var stateID: UUID?
  var localValue = 0
  var renderedSections: [Int] = []

  override func layoutSubviews() {
    super.layoutSubviews()
    contentSize = CGSize(width: bounds.width, height: 4_000)
  }
}

private enum ForumSectionPagerTestError: Error {
  case timeout
}
