import SwiftUI
import UIKit

enum ImageGalleryPagingAxis: String, CaseIterable, Hashable, Identifiable, Sendable {
  case horizontal
  case vertical

  var id: Self { self }

  var toggled: Self {
    self == .horizontal ? .vertical : .horizontal
  }

  var title: String {
    switch self {
    case .horizontal:
      "横向翻页"
    case .vertical:
      "纵向翻页"
    }
  }

  var systemImage: String {
    switch self {
    case .horizontal:
      "arrow.left.and.right"
    case .vertical:
      "arrow.up.and.down"
    }
  }

  var previousSystemImage: String {
    self == .horizontal ? "chevron.left" : "chevron.up"
  }

  var nextSystemImage: String {
    self == .horizontal ? "chevron.right" : "chevron.down"
  }

  var pageViewControllerOrientation: UIPageViewController.NavigationOrientation {
    self == .horizontal ? .horizontal : .vertical
  }

  func transitionDirection(
    for accessibilityScrollDirection: UIAccessibilityScrollDirection
  ) -> ImageGalleryPagingTransitionDirection? {
    switch (self, accessibilityScrollDirection) {
    case (_, .next), (.horizontal, .left), (.vertical, .up):
      .forward
    case (_, .previous), (.horizontal, .right), (.vertical, .down):
      .reverse
    default:
      nil
    }
  }
}

enum ImageGalleryPagingTransitionDirection: Equatable, Sendable {
  case forward
  case reverse
}

struct ImageGalleryPagerSnapshot: Equatable, Sendable {
  let items: [ImageGalleryItem]
  let requestedSelection: ImageGalleryItem.ID?

  init(items: [ImageGalleryItem], requestedSelection: ImageGalleryItem.ID?) {
    var seen = Set<ImageGalleryItem.ID>()
    self.items = items.filter { seen.insert($0.id).inserted }
    self.requestedSelection = requestedSelection
  }

  var itemIDs: [ImageGalleryItem.ID] { items.map(\.id) }

  func contains(_ id: ImageGalleryItem.ID) -> Bool {
    items.contains(where: { $0.id == id })
  }

  func item(withID id: ImageGalleryItem.ID) -> ImageGalleryItem? {
    items.first(where: { $0.id == id })
  }

  func resolvedSelection(
    currentID: ImageGalleryItem.ID?,
    prefersCurrent: Bool = false
  ) -> ImageGalleryItem.ID? {
    if prefersCurrent, let currentID, contains(currentID) {
      return currentID
    }
    if let requestedSelection, contains(requestedSelection) {
      return requestedSelection
    }
    if requestedSelection == nil, let currentID, contains(currentID) {
      return currentID
    }
    return items.first?.id
  }

  func adjacentID(
    to id: ImageGalleryItem.ID,
    direction: ImageGalleryPagingTransitionDirection
  ) -> ImageGalleryItem.ID? {
    guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
    let adjacentIndex = direction == .forward ? index + 1 : index - 1
    guard items.indices.contains(adjacentIndex) else { return nil }
    return items[adjacentIndex].id
  }

  func transitionDirection(
    from currentID: ImageGalleryItem.ID?,
    to targetID: ImageGalleryItem.ID
  ) -> ImageGalleryPagingTransitionDirection {
    guard
      let currentID,
      let currentIndex = items.firstIndex(where: { $0.id == currentID }),
      let targetIndex = items.firstIndex(where: { $0.id == targetID })
    else { return .forward }
    return targetIndex >= currentIndex ? .forward : .reverse
  }

  func retainingIDs(around id: ImageGalleryItem.ID?, radius: Int = 2) -> Set<ImageGalleryItem.ID> {
    guard
      let id,
      let index = items.firstIndex(where: { $0.id == id }),
      !items.isEmpty
    else { return [] }
    let radius = max(radius, 0)
    let lowerBound = max(items.startIndex, index - radius)
    let upperBound = min(items.index(before: items.endIndex), index + radius)
    return Set(items[lowerBound...upperBound].map(\.id))
  }
}

enum ImageGalleryInteractiveTransitionPolicy {
  static func shouldPublishVisibleSelection(
    pendingRequestedSelection: ImageGalleryItem.ID?,
    hasPendingSnapshot: Bool,
    startingSelection: ImageGalleryItem.ID?,
    pendingContainsVisibleSelection: Bool
  ) -> Bool {
    !hasPendingSnapshot
      || (pendingRequestedSelection == startingSelection && pendingContainsVisibleSelection)
  }

  static func preferredVisibleSelection(
    pendingRequestedSelection: ImageGalleryItem.ID?,
    startingSelection: ImageGalleryItem.ID?,
    visibleSelection: ImageGalleryItem.ID?,
    pendingContainsVisibleSelection: Bool
  ) -> ImageGalleryItem.ID? {
    guard pendingContainsVisibleSelection else { return nil }
    return pendingRequestedSelection == startingSelection ? visibleSelection : nil
  }
}

enum ImageViewerControlPolicy {
  static func showsPagingControls(itemCount: Int, totalCount: Int?) -> Bool {
    max(max(itemCount, 0), max(totalCount ?? 0, 0)) > 1
  }
}

enum ImageGalleryAccessibilityPolicy {
  static func pageDescriptions(
    items: [ImageGalleryItem],
    selectedID: ImageGalleryItem.ID?,
    selectedDisplayIndex: Int?,
    totalCount: Int
  ) -> [ImageGalleryItem.ID: String] {
    var descriptions = [ImageGalleryItem.ID: String]()
    for (index, item) in items.enumerated() where descriptions[item.id] == nil {
      let displayIndex: Int
      if item.id == selectedID, let selectedDisplayIndex, selectedDisplayIndex > 0 {
        displayIndex = selectedDisplayIndex
      } else if case .remote(let overallIndex, _, _) = item.id, overallIndex > 0 {
        displayIndex = overallIndex
      } else {
        displayIndex = index + 1
      }
      let displayedTotal = max(max(totalCount, items.count), displayIndex)
      descriptions[item.id] = "第 \(displayIndex) 张，共 \(displayedTotal) 张"
    }
    return descriptions
  }
}

struct ImageGalleryZoomState: Equatable {
  static let identity = Self(scale: 1, offset: .zero)

  let scale: CGFloat
  let offset: CGSize

  init(scale: CGFloat, offset: CGSize) {
    let scale = ImageZoomGeometry.clampedScale(scale)
    self.scale = scale
    self.offset = ImageZoomGeometry.allowsPanning(at: scale) ? offset : .zero
  }

  var isZoomed: Bool {
    ImageZoomGeometry.allowsPanning(at: scale)
  }
}

@MainActor
final class ImageGalleryZoomStateStore: ObservableObject {
  private let maximumRetainedStates: Int
  private var states = [ImageGalleryItem.ID: ImageGalleryZoomState]()
  private var recency = [ImageGalleryItem.ID]()

  init(maximumRetainedStates: Int = 8) {
    self.maximumRetainedStates = max(maximumRetainedStates, 1)
  }

  var retainedStateCount: Int { states.count }

  func state(for id: ImageGalleryItem.ID) -> ImageGalleryZoomState {
    guard let state = states[id] else { return .identity }
    recency.removeAll(where: { $0 == id })
    recency.append(id)
    return state
  }

  func update(_ state: ImageGalleryZoomState, for id: ImageGalleryItem.ID) {
    if state == .identity {
      states[id] = nil
      recency.removeAll(where: { $0 == id })
      return
    }
    states[id] = state
    recency.removeAll(where: { $0 == id })
    recency.append(id)
    while states.count > maximumRetainedStates, let oldest = recency.first {
      recency.removeFirst()
      states[oldest] = nil
    }
  }

  func retainOnly(_ validIDs: Set<ImageGalleryItem.ID>) {
    states = states.filter { validIDs.contains($0.key) }
    recency.removeAll(where: { !validIDs.contains($0) })
  }
}

@MainActor
struct ImageGalleryPager: UIViewControllerRepresentable {
  let items: [ImageGalleryItem]
  let selection: Binding<ImageGalleryItem.ID?>
  let axis: ImageGalleryPagingAxis
  let zoomStateStore: ImageGalleryZoomStateStore
  let accessibilityPageDescriptions: [ImageGalleryItem.ID: String]

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIViewController(context: Context) -> ImageGalleryPageViewController {
    let viewController = ImageGalleryPageViewController(
      transitionStyle: .scroll,
      navigationOrientation: axis.pageViewControllerOrientation,
      options: [.interPageSpacing: 0]
    )
    viewController.view.backgroundColor = .black
    context.coordinator.attach(to: viewController, axis: axis)
    context.coordinator.receive(
      ImageGalleryPagerSnapshot(items: items, requestedSelection: selection.wrappedValue),
      zoomStateStore: zoomStateStore,
      accessibilityPageDescriptions: accessibilityPageDescriptions,
      onSelectionChange: { selection.wrappedValue = $0 }
    )
    return viewController
  }

  func updateUIViewController(
    _ viewController: ImageGalleryPageViewController,
    context: Context
  ) {
    context.coordinator.receive(
      ImageGalleryPagerSnapshot(items: items, requestedSelection: selection.wrappedValue),
      zoomStateStore: zoomStateStore,
      accessibilityPageDescriptions: accessibilityPageDescriptions,
      onSelectionChange: { selection.wrappedValue = $0 }
    )
  }

  static func dismantleUIViewController(
    _ viewController: ImageGalleryPageViewController,
    coordinator: Coordinator
  ) {
    coordinator.detach()
  }

  @MainActor
  final class Coordinator: NSObject, @preconcurrency UIPageViewControllerDataSource,
    @preconcurrency UIPageViewControllerDelegate
  {
    private weak var pageViewController: ImageGalleryPageViewController?
    private var axis = ImageGalleryPagingAxis.horizontal
    private var snapshot = ImageGalleryPagerSnapshot(items: [], requestedSelection: nil)
    private var pendingSnapshot: ImageGalleryPagerSnapshot?
    private var controllers = [ImageGalleryItem.ID: ImageGalleryPageHostingController]()
    private var zoomedIDs = Set<ImageGalleryItem.ID>()
    private var transitioningIDs = Set<ImageGalleryItem.ID>()
    private var isInteractiveTransition = false
    private var interactiveStartingSelection: ImageGalleryItem.ID?
    private var programmaticTransitionToken = 0
    private var programmaticTargetID: ImageGalleryItem.ID?
    private var accessibilityAnnouncementID: ImageGalleryItem.ID?
    private var accessibilityPageDescriptions = [ImageGalleryItem.ID: String]()
    private var zoomStateStore: ImageGalleryZoomStateStore?
    private var onSelectionChange: (ImageGalleryItem.ID?) -> Void = { _ in }

    override init() {
      super.init()
      NotificationCenter.default.addObserver(
        self,
        selector: #selector(didReceiveMemoryWarning),
        name: UIApplication.didReceiveMemoryWarningNotification,
        object: nil
      )
    }

    deinit {
      NotificationCenter.default.removeObserver(self)
    }

    func attach(
      to pageViewController: ImageGalleryPageViewController,
      axis: ImageGalleryPagingAxis
    ) {
      self.pageViewController = pageViewController
      self.axis = axis
      pageViewController.dataSource = self
      pageViewController.delegate = self
      pageViewController.onAccessibilityScroll = { [weak self] direction in
        self?.handleAccessibilityScroll(direction) ?? false
      }
    }

    func detach() {
      programmaticTransitionToken &+= 1
      pageViewController?.dataSource = nil
      pageViewController?.delegate = nil
      pageViewController?.onAccessibilityScroll = nil
      pageViewController = nil
      pendingSnapshot = nil
      isInteractiveTransition = false
      interactiveStartingSelection = nil
      programmaticTargetID = nil
      accessibilityAnnouncementID = nil
      accessibilityPageDescriptions.removeAll()
      snapshot = ImageGalleryPagerSnapshot(items: [], requestedSelection: nil)
      controllers.removeAll()
      zoomedIDs.removeAll()
      transitioningIDs.removeAll()
      zoomStateStore = nil
    }

    func receive(
      _ snapshot: ImageGalleryPagerSnapshot,
      zoomStateStore: ImageGalleryZoomStateStore,
      accessibilityPageDescriptions: [ImageGalleryItem.ID: String],
      onSelectionChange: @escaping (ImageGalleryItem.ID?) -> Void
    ) {
      self.zoomStateStore = zoomStateStore
      zoomStateStore.retainOnly(Set(snapshot.itemIDs))
      self.accessibilityPageDescriptions = accessibilityPageDescriptions
      self.onSelectionChange = onSelectionChange
      guard !isInteractiveTransition, programmaticTargetID == nil else {
        pendingSnapshot = snapshot
        return
      }
      apply(snapshot)
    }

    func pageViewController(
      _ pageViewController: UIPageViewController,
      viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
      adjacentController(to: viewController, direction: .reverse)
    }

    func pageViewController(
      _ pageViewController: UIPageViewController,
      viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
      adjacentController(to: viewController, direction: .forward)
    }

    func pageViewController(
      _ pageViewController: UIPageViewController,
      willTransitionTo pendingViewControllers: [UIViewController]
    ) {
      guard programmaticTargetID == nil else { return }
      isInteractiveTransition = true
      interactiveStartingSelection = snapshot.requestedSelection
      transitioningIDs = Set(pendingViewControllers.compactMap(controllerID))
    }

    func pageViewController(
      _ pageViewController: UIPageViewController,
      didFinishAnimating finished: Bool,
      previousViewControllers: [UIViewController],
      transitionCompleted completed: Bool
    ) {
      guard isInteractiveTransition else { return }
      isInteractiveTransition = false
      let startingSelection = interactiveStartingSelection
      interactiveStartingSelection = nil
      transitioningIDs.removeAll()
      let visibleID = currentVisibleID
      let pendingContainsVisibleSelection = visibleID.map { id in
        pendingSnapshot?.contains(id) == true
      } ?? false
      let shouldPublishVisibleSelection =
        ImageGalleryInteractiveTransitionPolicy.shouldPublishVisibleSelection(
          pendingRequestedSelection: pendingSnapshot?.requestedSelection,
          hasPendingSnapshot: pendingSnapshot != nil,
          startingSelection: startingSelection,
          pendingContainsVisibleSelection: pendingContainsVisibleSelection
        )
      if completed, shouldPublishVisibleSelection, let visibleID {
        onSelectionChange(visibleID)
        snapshot = ImageGalleryPagerSnapshot(
          items: snapshot.items,
          requestedSelection: visibleID
        )
      }
      updatePagingAvailability()
      drainPendingSnapshot(
        preferring: visibleID,
        onlyWhenRequestedSelectionEquals: startingSelection,
        pendingContainsVisibleSelection: pendingContainsVisibleSelection
      )
      pruneControllers(around: currentVisibleID)
    }

    private func apply(
      _ newSnapshot: ImageGalleryPagerSnapshot,
      preferredVisibleID: ImageGalleryItem.ID? = nil,
      animatesTransition: Bool? = nil
    ) {
      guard let pageViewController else { return }
      let previousIDs = snapshot.itemIDs
      let visibleID = currentVisibleID
      snapshot = newSnapshot
      refreshCachedControllers()

      let targetID: ImageGalleryItem.ID?
      if let preferredVisibleID, snapshot.contains(preferredVisibleID) {
        targetID = preferredVisibleID
      } else {
        targetID = snapshot.resolvedSelection(currentID: visibleID)
      }

      guard let targetID, let targetController = controller(for: targetID) else {
        programmaticTransitionToken &+= 1
        pageViewController.setViewControllers(
          nil,
          direction: .forward,
          animated: false
        )
        updatePagingAvailability()
        pruneControllers(around: nil)
        return
      }
      if accessibilityAnnouncementID != nil, accessibilityAnnouncementID != targetID {
        accessibilityAnnouncementID = nil
      }

      if visibleID == targetID {
        if previousIDs != snapshot.itemIDs {
          pageViewController.dataSource = nil
          pageViewController.dataSource = self
        }
        updatePagingAvailability()
        pruneControllers(around: targetID)
        return
      }

      let transition = snapshot.transitionDirection(from: visibleID, to: targetID)
      let direction: UIPageViewController.NavigationDirection =
        transition == .forward ? .forward : .reverse
      let animated = animatesTransition ?? (visibleID != nil && previousIDs == snapshot.itemIDs)
      programmaticTransitionToken &+= 1
      let token = programmaticTransitionToken
      programmaticTargetID = targetID
      pageViewController.setViewControllers(
        [targetController],
        direction: direction,
        animated: animated
      ) { [weak self] completed in
        guard let self, token == self.programmaticTransitionToken else { return }
        self.programmaticTargetID = nil
        self.updatePagingAvailability()
        if
          completed,
          self.accessibilityAnnouncementID == targetID,
          self.currentVisibleID == targetID,
          self.pendingSnapshot.map({ pending in
            pending.requestedSelection == targetID && pending.contains(targetID)
          }) ?? true
        {
          self.postAccessibilityPageScrolled(for: targetID)
        }
        if completed {
          self.drainPendingSnapshot()
        } else {
          self.recoverFromInterruptedProgrammaticTransition()
        }
        self.pruneControllers(around: self.currentVisibleID)
      }
    }

    private func drainPendingSnapshot(
      preferring visibleID: ImageGalleryItem.ID? = nil,
      onlyWhenRequestedSelectionEquals staleSelection: ImageGalleryItem.ID? = nil,
      pendingContainsVisibleSelection: Bool = false
    ) {
      guard let pendingSnapshot else { return }
      self.pendingSnapshot = nil
      let preferredVisibleID =
        ImageGalleryInteractiveTransitionPolicy.preferredVisibleSelection(
          pendingRequestedSelection: pendingSnapshot.requestedSelection,
          startingSelection: staleSelection,
          visibleSelection: visibleID,
          pendingContainsVisibleSelection: pendingContainsVisibleSelection
        )
      let reconciledSnapshot: ImageGalleryPagerSnapshot
      if let preferredVisibleID {
        reconciledSnapshot = ImageGalleryPagerSnapshot(
          items: pendingSnapshot.items,
          requestedSelection: preferredVisibleID
        )
      } else {
        reconciledSnapshot = pendingSnapshot
      }
      apply(reconciledSnapshot, preferredVisibleID: preferredVisibleID)
    }

    private func recoverFromInterruptedProgrammaticTransition() {
      guard let pageViewController else { return }
      let latestSnapshot = pendingSnapshot ?? snapshot
      pendingSnapshot = nil
      let previousVisibleID = currentVisibleID
      snapshot = latestSnapshot
      refreshCachedControllers()
      let targetID = latestSnapshot.resolvedSelection(currentID: previousVisibleID)
      if accessibilityAnnouncementID != nil, accessibilityAnnouncementID != targetID {
        accessibilityAnnouncementID = nil
      }

      programmaticTransitionToken &+= 1
      pageViewController.dataSource = nil
      if let targetID, let targetController = controller(for: targetID) {
        let transition = snapshot.transitionDirection(from: previousVisibleID, to: targetID)
        let direction: UIPageViewController.NavigationDirection =
          transition == .forward ? .forward : .reverse
        pageViewController.setViewControllers(
          [targetController],
          direction: direction,
          animated: false
        )
      } else {
        pageViewController.setViewControllers(nil, direction: .forward, animated: false)
      }
      pageViewController.dataSource = self

      let reconciledSelection = currentVisibleID.flatMap { id in
        latestSnapshot.contains(id) ? id : nil
      } ?? targetID
      snapshot = ImageGalleryPagerSnapshot(
        items: latestSnapshot.items,
        requestedSelection: reconciledSelection
      )
      if latestSnapshot.requestedSelection != reconciledSelection {
        onSelectionChange(reconciledSelection)
      }
      if let reconciledSelection, accessibilityAnnouncementID == reconciledSelection {
        postAccessibilityPageScrolled(for: reconciledSelection)
      }
      updatePagingAvailability()
      pruneControllers(around: reconciledSelection)
    }

    private func adjacentController(
      to viewController: UIViewController,
      direction: ImageGalleryPagingTransitionDirection
    ) -> UIViewController? {
      guard
        let id = controllerID(viewController),
        let adjacentID = snapshot.adjacentID(to: id, direction: direction)
      else { return nil }
      return controller(for: adjacentID)
    }

    private func controller(
      for id: ImageGalleryItem.ID
    ) -> ImageGalleryPageHostingController? {
      guard let item = snapshot.item(withID: id) else { return nil }
      if let controller = controllers[id] {
        controller.update(
          item: item,
          zoomState: zoomStateStore?.state(for: id) ?? .identity
        )
        return controller
      }
      let controller = ImageGalleryPageHostingController(
        item: item,
        zoomState: zoomStateStore?.state(for: id) ?? .identity,
        onZoomStateChange: { [weak self] itemID, state in
          self?.zoomStateDidChange(itemID: itemID, state: state)
        }
      )
      controllers[id] = controller
      return controller
    }

    private func controllerID(_ viewController: UIViewController) -> ImageGalleryItem.ID? {
      (viewController as? ImageGalleryPageHostingController)?.itemID
    }

    private var currentVisibleID: ImageGalleryItem.ID? {
      pageViewController?.viewControllers?.first.flatMap(controllerID)
    }

    private func refreshCachedControllers() {
      let validIDs = Set(snapshot.itemIDs)
      var invalidIDs = [ImageGalleryItem.ID]()
      for (id, controller) in controllers {
        guard validIDs.contains(id), let item = snapshot.item(withID: id) else {
          invalidIDs.append(id)
          continue
        }
        controller.update(
          item: item,
          zoomState: zoomStateStore?.state(for: id) ?? .identity
        )
      }
      for id in invalidIDs {
        controllers[id] = nil
        zoomedIDs.remove(id)
      }
    }

    private func pruneControllers(
      around id: ImageGalleryItem.ID?,
      radius: Int = 2
    ) {
      var retainedIDs = snapshot.retainingIDs(around: id, radius: radius)
      if let id { retainedIDs.insert(id) }
      retainedIDs.formUnion(transitioningIDs)
      if let programmaticTargetID { retainedIDs.insert(programmaticTargetID) }
      if let visibleID = currentVisibleID { retainedIDs.insert(visibleID) }
      controllers = controllers.filter { retainedIDs.contains($0.key) }
      zoomedIDs.formIntersection(retainedIDs)
    }

    private func zoomStateDidChange(
      itemID: ImageGalleryItem.ID,
      state: ImageGalleryZoomState
    ) {
      guard snapshot.contains(itemID) else { return }
      zoomStateStore?.update(state, for: itemID)
      if state.isZoomed {
        zoomedIDs.insert(itemID)
      } else {
        zoomedIDs.remove(itemID)
      }
      if itemID == currentVisibleID {
        updatePagingAvailability()
      }
    }

    private func updatePagingAvailability() {
      guard let pageViewController else { return }
      let isCurrentImageZoomed = currentVisibleID.map(zoomedIDs.contains) ?? false
      pageViewController.pagingScrollView?.isScrollEnabled = !isCurrentImageZoomed
    }

    private func handleAccessibilityScroll(
      _ direction: UIAccessibilityScrollDirection
    ) -> Bool {
      guard
        let pagingDirection = axis.transitionDirection(for: direction),
        let currentVisibleID,
        let targetID = snapshot.adjacentID(to: currentVisibleID, direction: pagingDirection)
      else { return false }
      accessibilityAnnouncementID = targetID
      onSelectionChange(targetID)
      return true
    }

    private func postAccessibilityPageScrolled(for id: ImageGalleryItem.ID) {
      accessibilityAnnouncementID = nil
      UIAccessibility.post(
        notification: .pageScrolled,
        argument: accessibilityPageDescriptions[id] ?? "已显示图片"
      )
    }

    @objc private func didReceiveMemoryWarning() {
      // UIPageViewController may retain its adjacent controllers internally.
      pruneControllers(around: currentVisibleID, radius: 1)
    }
  }
}

@MainActor
final class ImageGalleryPageViewController: UIPageViewController {
  var onAccessibilityScroll: ((UIAccessibilityScrollDirection) -> Bool)?

  var pagingScrollView: UIScrollView? {
    view.subviews.compactMap { $0 as? UIScrollView }.first
  }

  override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
    if onAccessibilityScroll?(direction) == true {
      return true
    }
    return super.accessibilityScroll(direction)
  }
}

@MainActor
private final class ImageGalleryPageHostingController: UIHostingController<AnyView> {
  let itemID: ImageGalleryItem.ID

  private var item: ImageGalleryItem
  private let onZoomStateChange: (ImageGalleryItem.ID, ImageGalleryZoomState) -> Void

  init(
    item: ImageGalleryItem,
    zoomState: ImageGalleryZoomState,
    onZoomStateChange: @escaping (ImageGalleryItem.ID, ImageGalleryZoomState) -> Void
  ) {
    itemID = item.id
    self.item = item
    self.onZoomStateChange = onZoomStateChange
    super.init(
      rootView: AnyView(
        ZoomableRemoteImage(
          item: item,
          initialZoomState: zoomState,
          onZoomStateChange: onZoomStateChange
        )
      )
    )
    view.backgroundColor = .black
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func update(item: ImageGalleryItem, zoomState: ImageGalleryZoomState) {
    guard self.item != item else { return }
    self.item = item
    rootView = AnyView(
      ZoomableRemoteImage(
        item: item,
        initialZoomState: zoomState,
        onZoomStateChange: onZoomStateChange
      )
    )
  }
}
