import SwiftUI
import UIKit

/// The caller owns section availability and selection reconciliation. Stable
/// section IDs keep page identity independent of server ordering or labels.
struct ForumSectionPager<Selection: Hashable, Content: View>: View {
  let sections: [Selection]
  @Binding private var selection: Selection
  private let content: (Selection) -> Content
  @Environment(\.layoutDirection) private var layoutDirection

  init(
    sections: [Selection],
    selection: Binding<Selection>,
    @ViewBuilder content: @escaping (Selection) -> Content
  ) {
    self.sections = sections
    _selection = selection
    self.content = content
  }

  var body: some View {
    GeometryReader { geometry in
      ScrollView(.horizontal, showsIndicators: false) {
        // A page-style TabView can preserve State while recreating a distant
        // page's native List and losing its reading position. Keep each page
        // mounted in this eager stack; List still virtualizes its own rows.
        HStack(spacing: 0) {
          ForEach(sections, id: \.self) { section in
            content(section)
              .frame(width: geometry.size.width, height: geometry.size.height)
              .accessibilityHidden(section != selection)
          }
        }
        .background {
          ForumSectionPagingBridge(
            sectionIDs: sections.map(AnyHashable.init),
            selectedIndex: sections.firstIndex(of: selection),
            pageWidth: geometry.size.width,
            rightToLeft: layoutDirection == .rightToLeft
          ) { index in
            guard sections.indices.contains(index), selection != sections[index] else { return }
            selection = sections[index]
          }
        }
      }
    }
  }
}

/// Configures SwiftUI's existing UIScrollView without replacing its delegate or
/// hosting the pages in another navigation environment. UIKit owns drag,
/// directional arbitration, paging, and deceleration.
private struct ForumSectionPagingBridge: UIViewRepresentable {
  let sectionIDs: [AnyHashable]
  let selectedIndex: Int?
  let pageWidth: CGFloat
  let rightToLeft: Bool
  let onSelect: (Int) -> Void

  func makeUIView(context: Context) -> ForumSectionPagingAttachment {
    ForumSectionPagingAttachment()
  }

  func updateUIView(_ view: ForumSectionPagingAttachment, context: Context) {
    view.configure(
      sectionIDs: sectionIDs, selectedIndex: selectedIndex,
      pageWidth: pageWidth, rightToLeft: rightToLeft, onSelect: onSelect)
  }

  static func dismantleUIView(_ uiView: ForumSectionPagingAttachment, coordinator: ()) {
    uiView.detach()
  }
}

@MainActor
private final class ForumSectionPagingAttachment: UIView {
  private weak var scrollView: UIScrollView?
  private var offsetObservation: NSKeyValueObservation?
  private var contentSizeObservation: NSKeyValueObservation?
  private var sectionIDs: [AnyHashable] = []
  private var selectedIndex: Int?
  private var pageWidth: CGFloat = 0
  private var rightToLeft = false
  private var onSelect: ((Int) -> Void)?
  private var needsAlignment = true
  private var isApplyingOffset = false
  private var workRevision: UInt64 = 0
  private var settlementScheduled = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
  }

  required init?(coder: NSCoder) { nil }

  func configure(
    sectionIDs: [AnyHashable], selectedIndex: Int?, pageWidth: CGFloat,
    rightToLeft: Bool, onSelect: @escaping (Int) -> Void
  ) {
    if self.sectionIDs != sectionIDs || self.selectedIndex != selectedIndex
      || self.pageWidth != pageWidth || self.rightToLeft != rightToLeft
    {
      needsAlignment = true
      workRevision &+= 1
      settlementScheduled = false
    }
    self.sectionIDs = sectionIDs
    self.selectedIndex = selectedIndex
    self.pageWidth = pageWidth
    self.rightToLeft = rightToLeft
    self.onSelect = onSelect
    scheduleAlignment()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window == nil { detach() } else { scheduleAlignment() }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    scheduleAlignment()
  }

  func detach() {
    workRevision &+= 1
    settlementScheduled = false
    offsetObservation = nil
    contentSizeObservation = nil
    scrollView = nil
    needsAlignment = true
  }

  private func scheduleAlignment() {
    DispatchQueue.main.async { [weak self] in self?.attachAndAlign() }
  }

  private func attachAndAlign() {
    guard window != nil, pageWidth.isFinite, pageWidth > 0 else { return }
    var ancestor = superview
    while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
    guard let scroll = ancestor as? UIScrollView else { return }
    if scrollView !== scroll {
      detach()
      scrollView = scroll
      offsetObservation = scroll.observe(\.contentOffset, options: []) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.scheduleSettlement() }
      }
      contentSizeObservation = scroll.observe(\.contentSize, options: []) { [weak self] _, _ in
        MainActor.assumeIsolated { self?.scheduleAlignment() }
      }
      // Give the existing interactive navigation pop priority over paging.
      var responder: UIResponder? = scroll
      while let current = responder {
        if let controller = current as? UIViewController,
          let pop = controller.navigationController?.interactivePopGestureRecognizer
        {
          scroll.panGestureRecognizer.require(toFail: pop)
          break
        }
        responder = current.next
      }
    }
    // SwiftUI can reconfigure the same UIScrollView when layout direction
    // changes and reset paging without replacing the view or its delegate.
    // Restore our public configuration on each attachment/layout update; only
    // a different scroll view needs new observations and gesture precedence.
    if !scroll.isPagingEnabled { scroll.isPagingEnabled = true }
    if !scroll.isDirectionalLockEnabled { scroll.isDirectionalLockEnabled = true }
    if scroll.bounces { scroll.bounces = false }
    if scroll.contentInsetAdjustmentBehavior != .never {
      scroll.contentInsetAdjustmentBehavior = .never
    }
    scroll.accessibilityIdentifier = "forum-section-pager-scroll"
    guard needsAlignment, let selectedIndex, sectionIDs.indices.contains(selectedIndex) else {
      return
    }
    scroll.layoutIfNeeded()
    // Wait for the HStack's new width before moving to a newly appended page.
    guard abs(scroll.bounds.width - pageWidth) < 1,
      scroll.contentSize.width >= CGFloat(sectionIDs.count) * pageWidth - 1
    else { return }
    needsAlignment = false
    isApplyingOffset = true
    if scroll.isDragging || scroll.isDecelerating {
      scroll.panGestureRecognizer.isEnabled = false
      scroll.panGestureRecognizer.isEnabled = true
    }
    let physicalIndex = rightToLeft ? sectionIDs.count - 1 - selectedIndex : selectedIndex
    scroll.setContentOffset(CGPoint(x: CGFloat(physicalIndex) * pageWidth, y: 0), animated: false)
    isApplyingOffset = false
  }

  private func scheduleSettlement() {
    guard !needsAlignment, !isApplyingOffset, !settlementScheduled else { return }
    settlementScheduled = true
    let revision = workRevision
    DispatchQueue.main.async { [weak self] in self?.settle(revision: revision) }
  }

  private func settle(revision: UInt64) {
    guard revision == workRevision else { return }
    guard let scroll = scrollView, window != nil, !needsAlignment,
      pageWidth > 0, !sectionIDs.isEmpty
    else {
      settlementScheduled = false
      return
    }
    if scroll.isTracking || scroll.isDragging || scroll.isDecelerating {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
        self?.settle(revision: revision)
      }
      return
    }
    settlementScheduled = false
    let physicalIndex = min(
      sectionIDs.count - 1, max(0, Int((scroll.contentOffset.x / pageWidth).rounded())))
    let index = rightToLeft ? sectionIDs.count - 1 - physicalIndex : physicalIndex
    // A cancelled native drag can stop between pages. Settle its nearest page
    // without altering the parent navigation stack or installing a drag gesture.
    isApplyingOffset = true
    scroll.setContentOffset(CGPoint(x: CGFloat(physicalIndex) * pageWidth, y: 0), animated: false)
    isApplyingOffset = false
    guard index != selectedIndex else { return }
    selectedIndex = index
    onSelect?(index)
  }
}
