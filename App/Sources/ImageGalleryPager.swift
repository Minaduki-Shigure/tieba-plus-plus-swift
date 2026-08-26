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

struct ImageGalleryItemIDMigration: Equatable, Sendable {
  private(set) var destinations: [ImageGalleryItem.ID: ImageGalleryItem.ID]

  init(_ destinations: [ImageGalleryItem.ID: ImageGalleryItem.ID] = [:]) {
    self.destinations = destinations
  }

  func destination(for id: ImageGalleryItem.ID) -> ImageGalleryItem.ID {
    destinations[id] ?? id
  }

  func normalized(for targetIDs: Set<ImageGalleryItem.ID>) -> Self {
    Self().merging(self, targetIDs: targetIDs)
  }

  func merging(
    _ newer: Self,
    targetIDs: Set<ImageGalleryItem.ID>
  ) -> Self {
    let intermediateIDs = Set(destinations.values)
    let newerIntermediateIDs = Set(newer.destinations.values)
    let newerRoots = Set(newer.destinations.keys)
      .subtracting(intermediateIDs)
      .subtracting(newerIntermediateIDs)
    let roots = Set(destinations.keys).union(newerRoots)

    var candidates = [ImageGalleryItem.ID: ImageGalleryItem.ID]()
    for source in roots {
      let destination: ImageGalleryItem.ID?
      if newer.destinations[source] != nil {
        destination = newer.terminalDestination(for: source)
      } else {
        let intermediate = destinations[source] ?? source
        destination = newer.destinations[intermediate] == nil
          ? intermediate
          : newer.terminalDestination(for: intermediate)
      }
      guard
        let destination,
        source != destination,
        !targetIDs.contains(source),
        targetIDs.contains(destination)
      else { continue }
      candidates[source] = destination
    }

    let destinationCounts = Dictionary(grouping: candidates.values, by: { $0 })
      .mapValues(\.count)
    candidates = candidates.filter { destinationCounts[$0.value] == 1 }
    return Self(candidates)
  }

  private func terminalDestination(for source: ImageGalleryItem.ID) -> ImageGalleryItem.ID? {
    var visited = Set<ImageGalleryItem.ID>()
    var current = source
    while let next = destinations[current] {
      guard visited.insert(current).inserted else { return nil }
      current = next
    }
    return current
  }
}

struct ImageGalleryPagerUpdate: Equatable, Sendable {
  let snapshot: ImageGalleryPagerSnapshot
  let migration: ImageGalleryItemIDMigration
  let accessibilityPageDescriptions: [ImageGalleryItem.ID: String]

  init(
    snapshot: ImageGalleryPagerSnapshot,
    idMigrations: [ImageGalleryItem.ID: ImageGalleryItem.ID] = [:],
    accessibilityPageDescriptions: [ImageGalleryItem.ID: String]
  ) {
    self.snapshot = snapshot
    migration = ImageGalleryItemIDMigration(idMigrations)
    self.accessibilityPageDescriptions = accessibilityPageDescriptions
  }

  private init(
    snapshot: ImageGalleryPagerSnapshot,
    migration: ImageGalleryItemIDMigration,
    accessibilityPageDescriptions: [ImageGalleryItem.ID: String]
  ) {
    self.snapshot = snapshot
    self.migration = migration
    self.accessibilityPageDescriptions = accessibilityPageDescriptions
  }

  func normalized() -> Self {
    Self(
      snapshot: snapshot,
      migration: migration.normalized(for: Set(snapshot.itemIDs)),
      accessibilityPageDescriptions: accessibilityPageDescriptions
    )
  }

  func merging(_ newer: Self) -> Self {
    Self(
      snapshot: newer.snapshot,
      migration: migration.merging(
        newer.migration,
        targetIDs: Set(newer.snapshot.itemIDs)
      ),
      accessibilityPageDescriptions: newer.accessibilityPageDescriptions
    )
  }

  func selecting(_ id: ImageGalleryItem.ID) -> Self {
    Self(
      snapshot: ImageGalleryPagerSnapshot(items: snapshot.items, requestedSelection: id),
      migration: migration,
      accessibilityPageDescriptions: accessibilityPageDescriptions
    )
  }
}

struct ImageGalleryInteractiveTransitionResolution: Equatable, Sendable {
  let selectionToPublish: ImageGalleryItem.ID?
  let preferredVisibleSelection: ImageGalleryItem.ID?
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

  static func resolve(
    completed: Bool,
    pendingUpdate: ImageGalleryPagerUpdate?,
    startingSelection: ImageGalleryItem.ID?,
    visibleSelection: ImageGalleryItem.ID?
  ) -> ImageGalleryInteractiveTransitionResolution {
    guard let pendingUpdate else {
      return ImageGalleryInteractiveTransitionResolution(
        selectionToPublish: completed ? visibleSelection : nil,
        preferredVisibleSelection: nil
      )
    }

    let mappedStartingSelection = startingSelection.map {
      pendingUpdate.migration.destination(for: $0)
    }
    let mappedVisibleSelection = visibleSelection.map {
      pendingUpdate.migration.destination(for: $0)
    }
    let containsVisibleSelection = mappedVisibleSelection.map {
      pendingUpdate.snapshot.contains($0)
    } ?? false
    let publishesVisibleSelection = shouldPublishVisibleSelection(
      pendingRequestedSelection: pendingUpdate.snapshot.requestedSelection,
      hasPendingSnapshot: true,
      startingSelection: mappedStartingSelection,
      pendingContainsVisibleSelection: containsVisibleSelection
    )
    let preferredSelection = preferredVisibleSelection(
      pendingRequestedSelection: pendingUpdate.snapshot.requestedSelection,
      startingSelection: mappedStartingSelection,
      visibleSelection: mappedVisibleSelection,
      pendingContainsVisibleSelection: containsVisibleSelection
    )
    return ImageGalleryInteractiveTransitionResolution(
      selectionToPublish: completed && publishesVisibleSelection
        ? mappedVisibleSelection
        : nil,
      preferredVisibleSelection: preferredSelection
    )
  }
}

struct ImageGalleryAnimationPlaybackOwnership: Equatable, Sendable {
  enum Transition: Equatable, Sendable {
    case idle
    case interactive(startingOwnerID: ImageGalleryItem.ID?)
    case programmatic(
      startingOwnerID: ImageGalleryItem.ID?,
      targetID: ImageGalleryItem.ID
    )
  }

  private(set) var ownerID: ImageGalleryItem.ID?
  private(set) var transition = Transition.idle

  var enabledIDs: Set<ImageGalleryItem.ID> {
    guard let ownerID else { return [] }
    return [ownerID]
  }

  mutating func reconcileVisible(
    _ visibleID: ImageGalleryItem.ID?,
    validIDs: Set<ImageGalleryItem.ID>
  ) {
    guard transition == .idle else {
      retainOnly(validIDs)
      return
    }
    ownerID = validated(visibleID, validIDs: validIDs)
  }

  mutating func beginInteractive(
    visibleID: ImageGalleryItem.ID?,
    validIDs: Set<ImageGalleryItem.ID>
  ) {
    let startingOwnerID = validated(ownerID, validIDs: validIDs)
      ?? validated(visibleID, validIDs: validIDs)
    ownerID = startingOwnerID
    transition = .interactive(startingOwnerID: startingOwnerID)
  }

  mutating func finishInteractive(
    completed: Bool,
    visibleID: ImageGalleryItem.ID?,
    validIDs: Set<ImageGalleryItem.ID>
  ) {
    let startingOwnerID: ImageGalleryItem.ID?
    if case .interactive(let ownerID) = transition {
      startingOwnerID = ownerID
    } else {
      startingOwnerID = self.ownerID
    }
    transition = .idle
    ownerID = validated(
      completed ? visibleID : startingOwnerID,
      validIDs: validIDs
    )
  }

  mutating func beginProgrammatic(
    targetID: ImageGalleryItem.ID,
    visibleID: ImageGalleryItem.ID?,
    validIDs: Set<ImageGalleryItem.ID>
  ) {
    let startingOwnerID = validated(ownerID, validIDs: validIDs)
      ?? validated(visibleID, validIDs: validIDs)
    ownerID = startingOwnerID
    transition = .programmatic(
      startingOwnerID: startingOwnerID,
      targetID: targetID
    )
  }

  mutating func finishProgrammatic(
    completed: Bool,
    visibleID: ImageGalleryItem.ID?,
    validIDs: Set<ImageGalleryItem.ID>
  ) {
    let startingOwnerID: ImageGalleryItem.ID?
    let targetID: ImageGalleryItem.ID?
    if case .programmatic(let startingID, let destinationID) = transition {
      startingOwnerID = startingID
      targetID = destinationID
    } else {
      startingOwnerID = ownerID
      targetID = nil
    }
    transition = .idle
    let candidateID = completed
      ? (visibleID ?? targetID)
      : (visibleID ?? startingOwnerID)
    ownerID = validated(candidateID, validIDs: validIDs)
  }

  mutating func migrate(
    _ migration: ImageGalleryItemIDMigration,
    validIDs: Set<ImageGalleryItem.ID>
  ) {
    func mapped(_ id: ImageGalleryItem.ID?) -> ImageGalleryItem.ID? {
      id.map { migration.destination(for: $0) }
    }

    ownerID = mapped(ownerID)
    switch transition {
    case .idle:
      break
    case .interactive(let startingOwnerID):
      transition = .interactive(startingOwnerID: mapped(startingOwnerID))
    case .programmatic(let startingOwnerID, let targetID):
      transition = .programmatic(
        startingOwnerID: mapped(startingOwnerID),
        targetID: migration.destination(for: targetID)
      )
    }
    retainOnly(validIDs)
  }

  mutating func retainOnly(_ validIDs: Set<ImageGalleryItem.ID>) {
    ownerID = validated(ownerID, validIDs: validIDs)
  }

  mutating func detach() {
    ownerID = nil
    transition = .idle
  }

  private func validated(
    _ id: ImageGalleryItem.ID?,
    validIDs: Set<ImageGalleryItem.ID>
  ) -> ImageGalleryItem.ID? {
    guard let id, validIDs.contains(id) else { return nil }
    return id
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

enum ImageGalleryZoomMode: Equatable {
  case fit
  case reading
  case custom
}

struct ImageGalleryZoomState: Equatable {
  static let identity = Self(scale: 1, offset: .zero, mode: .fit)

  let scale: CGFloat
  let offset: CGSize
  let mode: ImageGalleryZoomMode
  let referenceViewportSize: CGSize?
  let panLimits: ImageZoomPanLimits?
  let panLimitsViewportSize: CGSize?

  init(
    scale: CGFloat,
    offset: CGSize,
    mode: ImageGalleryZoomMode? = nil,
    referenceViewportSize: CGSize? = nil,
    panLimits: ImageZoomPanLimits? = nil,
    panLimitsViewportSize: CGSize? = nil
  ) {
    let scale = ImageZoomGeometry.clampedScale(
      scale,
      maximumScale: ImageZoomGeometry.absoluteMaximumScale
    )
    self.scale = scale
    self.offset = ImageZoomGeometry.allowsPanning(at: scale)
      && offset.width.isFinite
      && offset.height.isFinite ? offset : .zero
    let mode = mode ?? (ImageZoomGeometry.allowsPanning(at: scale) ? .custom : .fit)
    self.mode = mode
    if
      mode == .reading,
      let referenceViewportSize,
      referenceViewportSize.width.isFinite,
      referenceViewportSize.height.isFinite,
      referenceViewportSize.width > 0,
      referenceViewportSize.height > 0
    {
      self.referenceViewportSize = referenceViewportSize
    } else {
      self.referenceViewportSize = nil
    }
    if
      ImageZoomGeometry.allowsPanning(at: scale),
      let panLimits,
      panLimits.horizontal.isFinite,
      panLimits.vertical.isFinite,
      panLimits.horizontal >= 0,
      panLimits.vertical >= 0,
      let panLimitsViewportSize,
      ImageZoomGeometry.isValidViewport(panLimitsViewportSize)
    {
      self.panLimits = panLimits
      self.panLimitsViewportSize = panLimitsViewportSize
    } else {
      self.panLimits = nil
      self.panLimitsViewportSize = nil
    }
  }
}

struct ImageGalleryZoomConfiguration: Equatable {
  static let unconfigured = Self(state: .identity, isConfigured: false)

  let state: ImageGalleryZoomState
  let isConfigured: Bool

  static func configured(_ state: ImageGalleryZoomState) -> Self {
    Self(state: state, isConfigured: true)
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
    configuration(for: id).state
  }

  func configuration(for id: ImageGalleryItem.ID) -> ImageGalleryZoomConfiguration {
    guard let state = states[id] else { return .unconfigured }
    recency.removeAll(where: { $0 == id })
    recency.append(id)
    return .configured(state)
  }

  func update(_ state: ImageGalleryZoomState, for id: ImageGalleryItem.ID) {
    states[id] = state
    recency.removeAll(where: { $0 == id })
    recency.append(id)
    while states.count > maximumRetainedStates, let oldest = recency.first {
      recency.removeFirst()
      states[oldest] = nil
    }
  }

  func migrate(
    _ migration: ImageGalleryItemIDMigration,
    destinationWins: Set<ImageGalleryItem.ID> = []
  ) {
    for (source, destination) in migration.destinations {
      guard source != destination, let sourceState = states[source] else { continue }
      let keepsDestination = states[destination] != nil || destinationWins.contains(destination)
      if !keepsDestination {
        states[destination] = sourceState
        recency = recency.map { $0 == source ? destination : $0 }
      }
      states[source] = nil
      recency.removeAll(where: { $0 == source })
    }
    removeDuplicateRecencyEntries()
  }

  func retainOnly(_ validIDs: Set<ImageGalleryItem.ID>) {
    states = states.filter { validIDs.contains($0.key) }
    recency.removeAll(where: { !validIDs.contains($0) })
  }

  private func removeDuplicateRecencyEntries() {
    var seen = Set<ImageGalleryItem.ID>()
    recency = Array(recency.reversed().filter { id in
      states[id] != nil && seen.insert(id).inserted
    }.reversed())
  }
}

@MainActor
struct ImageGalleryPager: UIViewControllerRepresentable {
  let items: [ImageGalleryItem]
  let selection: Binding<ImageGalleryItem.ID?>
  let axis: ImageGalleryPagingAxis
  let zoomStateStore: ImageGalleryZoomStateStore
  let idMigrations: [ImageGalleryItem.ID: ImageGalleryItem.ID]
  let accessibilityPageDescriptions: [ImageGalleryItem.ID: String]
  let onInteractiveDismiss: (ImageViewerDismissGestureEvent) -> Void

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
      ImageGalleryPagerUpdate(
        snapshot: ImageGalleryPagerSnapshot(
          items: items,
          requestedSelection: selection.wrappedValue
        ),
        idMigrations: idMigrations,
        accessibilityPageDescriptions: accessibilityPageDescriptions
      ),
      zoomStateStore: zoomStateStore,
      onSelectionChange: { selection.wrappedValue = $0 },
      onInteractiveDismiss: onInteractiveDismiss
    )
    return viewController
  }

  func updateUIViewController(
    _ viewController: ImageGalleryPageViewController,
    context: Context
  ) {
    context.coordinator.receive(
      ImageGalleryPagerUpdate(
        snapshot: ImageGalleryPagerSnapshot(
          items: items,
          requestedSelection: selection.wrappedValue
        ),
        idMigrations: idMigrations,
        accessibilityPageDescriptions: accessibilityPageDescriptions
      ),
      zoomStateStore: zoomStateStore,
      onSelectionChange: { selection.wrappedValue = $0 },
      onInteractiveDismiss: onInteractiveDismiss
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
    @preconcurrency UIPageViewControllerDelegate, UIGestureRecognizerDelegate
  {
    private weak var pageViewController: ImageGalleryPageViewController?
    private var axis = ImageGalleryPagingAxis.horizontal
    private var snapshot = ImageGalleryPagerSnapshot(items: [], requestedSelection: nil)
    private var pendingUpdate: ImageGalleryPagerUpdate?
    private var controllers = [ImageGalleryItem.ID: ImageGalleryPageHostingController]()
    private var transitioningIDs = Set<ImageGalleryItem.ID>()
    private var isInteractiveTransition = false
    private var interactiveStartingSelection: ImageGalleryItem.ID?
    private var programmaticTransitionToken = 0
    private var programmaticTargetID: ImageGalleryItem.ID?
    private var animationPlaybackOwnership = ImageGalleryAnimationPlaybackOwnership()
    private var accessibilityAnnouncementID: ImageGalleryItem.ID?
    private var accessibilityPageDescriptions = [ImageGalleryItem.ID: String]()
    private var zoomStateStore: ImageGalleryZoomStateStore?
    private var onSelectionChange: (ImageGalleryItem.ID?) -> Void = { _ in }
    private var onInteractiveDismiss: (ImageViewerDismissGestureEvent) -> Void = { _ in }

    lazy var interactiveDismissPanGestureRecognizer: UIPanGestureRecognizer = {
      let recognizer = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleInteractiveDismissPan)
      )
      recognizer.minimumNumberOfTouches = 1
      recognizer.maximumNumberOfTouches = 1
      recognizer.cancelsTouchesInView = false
      recognizer.delegate = self
      return recognizer
    }()

    var animationPlaybackOwnerID: ImageGalleryItem.ID? {
      animationPlaybackOwnership.ownerID
    }

    var animationPlaybackEnabledControllerIDs: Set<ImageGalleryItem.ID> {
      Set(controllers.compactMap { id, controller in
        controller.animationPlaybackEnabled ? id : nil
      })
    }

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
      configurePagingGesture()
      configureInteractiveDismissGesture()
      reconcileAnimationPlaybackWithVisibleController()
    }

    func detach() {
      programmaticTransitionToken &+= 1
      pageViewController?.dataSource = nil
      pageViewController?.delegate = nil
      pageViewController?.onAccessibilityScroll = nil
      interactiveDismissPanGestureRecognizer.view?.removeGestureRecognizer(
        interactiveDismissPanGestureRecognizer
      )
      pageViewController = nil
      pendingUpdate = nil
      isInteractiveTransition = false
      interactiveStartingSelection = nil
      programmaticTargetID = nil
      accessibilityAnnouncementID = nil
      accessibilityPageDescriptions.removeAll()
      snapshot = ImageGalleryPagerSnapshot(items: [], requestedSelection: nil)
      animationPlaybackOwnership.detach()
      synchronizeAnimationPlaybackControllers()
      controllers.removeAll()
      transitioningIDs.removeAll()
      zoomStateStore = nil
      onSelectionChange = { _ in }
      onInteractiveDismiss = { _ in }
    }

    func receive(
      _ update: ImageGalleryPagerUpdate,
      zoomStateStore: ImageGalleryZoomStateStore,
      onSelectionChange: @escaping (ImageGalleryItem.ID?) -> Void,
      onInteractiveDismiss: @escaping (ImageViewerDismissGestureEvent) -> Void = { _ in }
    ) {
      self.zoomStateStore = zoomStateStore
      self.onSelectionChange = onSelectionChange
      self.onInteractiveDismiss = onInteractiveDismiss
      guard !isInteractiveTransition, programmaticTargetID == nil else {
        if let pendingUpdate {
          self.pendingUpdate = pendingUpdate.merging(update)
        } else {
          pendingUpdate = update.normalized()
        }
        return
      }
      apply(update.normalized())
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
      animationPlaybackOwnership.beginInteractive(
        visibleID: currentVisibleID,
        validIDs: Set(snapshot.itemIDs)
      )
      synchronizeAnimationPlaybackControllers()
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
      animationPlaybackOwnership.finishInteractive(
        completed: completed,
        visibleID: visibleID,
        validIDs: Set(snapshot.itemIDs)
      )
      let resolution = ImageGalleryInteractiveTransitionPolicy.resolve(
        completed: completed,
        pendingUpdate: pendingUpdate,
        startingSelection: startingSelection,
        visibleSelection: visibleID
      )

      if let pendingUpdate {
        self.pendingUpdate = nil
        let reconciledUpdate = resolution.preferredVisibleSelection.map {
          pendingUpdate.selecting($0)
        } ?? pendingUpdate
        apply(
          reconciledUpdate,
          preferredVisibleID: resolution.preferredVisibleSelection
        )
      } else if let selectionToPublish = resolution.selectionToPublish {
        snapshot = ImageGalleryPagerSnapshot(
          items: snapshot.items,
          requestedSelection: selectionToPublish
        )
      }

      if let selectionToPublish = resolution.selectionToPublish {
        onSelectionChange(selectionToPublish)
      }
      configurePagingGesture()
      synchronizeAnimationPlaybackControllers()
      pruneControllers(around: currentVisibleID)
    }

    private func apply(
      _ update: ImageGalleryPagerUpdate,
      preferredVisibleID: ImageGalleryItem.ID? = nil,
      animatesTransition: Bool? = nil
    ) {
      guard let pageViewController else { return }
      let update = update.normalized()
      let previousIDs = snapshot.itemIDs
      let visibleID = currentVisibleID
      let mappedVisibleID = visibleID.map { update.migration.destination(for: $0) }
      install(update)

      let targetID: ImageGalleryItem.ID?
      if let preferredVisibleID, snapshot.contains(preferredVisibleID) {
        targetID = preferredVisibleID
      } else {
        targetID = snapshot.resolvedSelection(currentID: mappedVisibleID)
      }

      guard let targetID, let targetController = controller(for: targetID) else {
        programmaticTransitionToken &+= 1
        pageViewController.setViewControllers(
          nil,
          direction: .forward,
          animated: false
        )
        animationPlaybackOwnership.reconcileVisible(
          nil,
          validIDs: Set(snapshot.itemIDs)
        )
        synchronizeAnimationPlaybackControllers()
        configurePagingGesture()
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
        animationPlaybackOwnership.reconcileVisible(
          targetID,
          validIDs: Set(snapshot.itemIDs)
        )
        synchronizeAnimationPlaybackControllers()
        configurePagingGesture()
        pruneControllers(around: targetID)
        return
      }

      let transition = snapshot.transitionDirection(from: mappedVisibleID, to: targetID)
      let direction: UIPageViewController.NavigationDirection =
        transition == .forward ? .forward : .reverse
      let animated = animatesTransition ?? (visibleID != nil && previousIDs == snapshot.itemIDs)
      programmaticTransitionToken &+= 1
      let token = programmaticTransitionToken
      programmaticTargetID = targetID
      animationPlaybackOwnership.beginProgrammatic(
        targetID: targetID,
        visibleID: mappedVisibleID ?? visibleID,
        validIDs: Set(snapshot.itemIDs)
      )
      synchronizeAnimationPlaybackControllers()
      pageViewController.setViewControllers(
        [targetController],
        direction: direction,
        animated: animated
      ) { [weak self] completed in
        guard let self, token == self.programmaticTransitionToken else { return }
        self.programmaticTargetID = nil
        if completed {
          self.animationPlaybackOwnership.finishProgrammatic(
            completed: true,
            visibleID: self.currentVisibleID,
            validIDs: Set(self.snapshot.itemIDs)
          )
          self.synchronizeAnimationPlaybackControllers()
          self.drainPendingUpdate(
            preferring: self.currentVisibleID,
            onlyWhenRequestedSelectionEquals: targetID
          )
        } else {
          self.recoverFromInterruptedProgrammaticTransition()
          self.animationPlaybackOwnership.finishProgrammatic(
            completed: false,
            visibleID: self.currentVisibleID,
            validIDs: Set(self.snapshot.itemIDs)
          )
          self.synchronizeAnimationPlaybackControllers()
        }
        self.configurePagingGesture()
        if
          let announcementID = self.accessibilityAnnouncementID,
          self.programmaticTargetID == nil,
          self.snapshot.requestedSelection == announcementID,
          self.currentVisibleID == announcementID
        {
          self.postAccessibilityPageScrolled(for: announcementID)
        }
        self.pruneControllers(around: self.currentVisibleID)
      }
    }

    private func drainPendingUpdate(
      preferring visibleID: ImageGalleryItem.ID? = nil,
      onlyWhenRequestedSelectionEquals staleSelection: ImageGalleryItem.ID? = nil
    ) {
      guard let pendingUpdate else { return }
      self.pendingUpdate = nil
      let mappedVisibleID = visibleID.map { pendingUpdate.migration.destination(for: $0) }
      let mappedStaleSelection = staleSelection.map {
        pendingUpdate.migration.destination(for: $0)
      }
      let preferredVisibleID: ImageGalleryItem.ID?
      if
        staleSelection != nil,
        pendingUpdate.snapshot.requestedSelection == mappedStaleSelection,
        let mappedVisibleID,
        pendingUpdate.snapshot.contains(mappedVisibleID)
      {
        preferredVisibleID = mappedVisibleID
      } else {
        preferredVisibleID = nil
      }
      let reconciledUpdate = preferredVisibleID.map { pendingUpdate.selecting($0) }
        ?? pendingUpdate
      apply(reconciledUpdate, preferredVisibleID: preferredVisibleID)
    }

    private func recoverFromInterruptedProgrammaticTransition() {
      guard let pageViewController else { return }
      let previousVisibleID = currentVisibleID
      let mappedPreviousVisibleID = previousVisibleID.map { id in
        pendingUpdate?.migration.destination(for: id) ?? id
      }
      if let pendingUpdate {
        self.pendingUpdate = nil
        install(pendingUpdate.normalized())
      }
      let latestSnapshot = snapshot
      let targetID = latestSnapshot.resolvedSelection(currentID: mappedPreviousVisibleID)
      if accessibilityAnnouncementID != nil, accessibilityAnnouncementID != targetID {
        accessibilityAnnouncementID = nil
      }

      programmaticTransitionToken &+= 1
      pageViewController.dataSource = nil
      if let targetID, let targetController = controller(for: targetID) {
        let transition = snapshot.transitionDirection(from: mappedPreviousVisibleID, to: targetID)
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
      configurePagingGesture()
      pruneControllers(around: reconciledSelection)
    }

    private func install(_ update: ImageGalleryPagerUpdate) {
      let validIDs = Set(update.snapshot.itemIDs)
      animationPlaybackOwnership.migrate(update.migration, validIDs: validIDs)
      zoomStateStore?.migrate(
        update.migration,
        destinationWins: Set(controllers.keys)
      )
      zoomStateStore?.retainOnly(validIDs)
      if let accessibilityAnnouncementID {
        let mappedID = update.migration.destination(for: accessibilityAnnouncementID)
        self.accessibilityAnnouncementID = validIDs.contains(mappedID) ? mappedID : nil
      }
      accessibilityPageDescriptions = update.accessibilityPageDescriptions
      snapshot = update.snapshot
      refreshCachedControllers()
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
          zoomConfiguration: zoomConfiguration(for: id),
          animationPlaybackEnabled: controller.animationPlaybackEnabled
        )
        return controller
      }
      let controller = ImageGalleryPageHostingController(
        item: item,
        zoomConfiguration: zoomConfiguration(for: id),
        animationPlaybackEnabled: false,
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
          zoomConfiguration: zoomConfiguration(for: id),
          animationPlaybackEnabled: controller.animationPlaybackEnabled
        )
      }
      for id in invalidIDs {
        controllers[id]?.setAnimationPlaybackEnabled(
          false,
          zoomConfiguration: .configured(.identity)
        )
        controllers[id] = nil
      }
      synchronizeAnimationPlaybackControllers()
    }

    private func pruneControllers(
      around id: ImageGalleryItem.ID?,
      radius: Int = 2
    ) {
      var retainedIDs = snapshot.retainingIDs(around: id, radius: radius)
      if let id { retainedIDs.insert(id) }
      retainedIDs.formUnion(transitioningIDs)
      if let programmaticTargetID { retainedIDs.insert(programmaticTargetID) }
      if let ownerID = animationPlaybackOwnership.ownerID { retainedIDs.insert(ownerID) }
      if let visibleID = currentVisibleID { retainedIDs.insert(visibleID) }
      let removedIDs = Set(controllers.keys).subtracting(retainedIDs)
      for id in removedIDs {
        controllers[id]?.setAnimationPlaybackEnabled(
          false,
          zoomConfiguration: .configured(.identity)
        )
        controllers[id] = nil
      }
      animationPlaybackOwnership.retainOnly(Set(snapshot.itemIDs))
      synchronizeAnimationPlaybackControllers()
    }

    private func reconcileAnimationPlaybackWithVisibleController() {
      animationPlaybackOwnership.reconcileVisible(
        currentVisibleID,
        validIDs: Set(snapshot.itemIDs)
      )
      synchronizeAnimationPlaybackControllers()
    }

    private func synchronizeAnimationPlaybackControllers() {
      let ownerID = animationPlaybackOwnership.ownerID
      // Stop the previous owner before starting the next one so two players never run together.
      for (id, controller) in controllers where id != ownerID {
        controller.setAnimationPlaybackEnabled(
          false,
          zoomConfiguration: zoomConfiguration(for: id)
        )
      }
      if let ownerID, let ownerController = controllers[ownerID] {
        ownerController.setAnimationPlaybackEnabled(
          true,
          zoomConfiguration: zoomConfiguration(for: ownerID)
        )
      }
    }

    private func zoomStateDidChange(
      itemID: ImageGalleryItem.ID,
      state: ImageGalleryZoomState
    ) {
      guard snapshot.contains(itemID) else { return }
      zoomStateStore?.update(state, for: itemID)
    }

    private func zoomConfiguration(
      for itemID: ImageGalleryItem.ID
    ) -> ImageGalleryZoomConfiguration {
      zoomStateStore?.configuration(for: itemID) ?? .unconfigured
    }

    private func configurePagingGesture() {
      guard let pagingScrollView = pageViewController?.pagingScrollView else { return }
      pagingScrollView.isScrollEnabled = true
      pagingScrollView.isDirectionalLockEnabled = true
      pagingScrollView.panGestureRecognizer.maximumNumberOfTouches = 1
    }

    private func configureInteractiveDismissGesture() {
      guard let pageViewController else { return }
      let recognizer = interactiveDismissPanGestureRecognizer
      if recognizer.view !== pageViewController.view {
        recognizer.view?.removeGestureRecognizer(recognizer)
        pageViewController.view.addGestureRecognizer(recognizer)
      }
      pageViewController.pagingScrollView?.panGestureRecognizer.require(toFail: recognizer)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard
        gestureRecognizer === interactiveDismissPanGestureRecognizer,
        let view = gestureRecognizer.view
      else { return true }
      let velocity = interactiveDismissPanGestureRecognizer.velocity(in: view)
      return shouldInteractiveDismissBegin(
        velocity: CGSize(width: velocity.x, height: velocity.y)
      )
    }

    func shouldInteractiveDismissBegin(velocity: CGSize) -> Bool {
      guard
        !isInteractiveTransition,
        programmaticTargetID == nil,
        let pageViewController,
        let currentVisibleID
      else { return false }
      return ImageViewerDismissGesturePolicy.shouldBegin(
        velocity: velocity,
        axis: axis,
        zoomState: zoomStateStore?.state(for: currentVisibleID) ?? .identity,
        viewportSize: pageViewController.view.bounds.size
      )
    }

    @objc private func handleInteractiveDismissPan(_ recognizer: UIPanGestureRecognizer) {
      guard let view = recognizer.view else { return }
      let translation = recognizer.translation(in: view)
      let velocity = recognizer.velocity(in: view)
      processInteractiveDismiss(
        state: recognizer.state,
        translation: CGSize(width: translation.x, height: translation.y),
        velocity: CGSize(width: velocity.x, height: velocity.y),
        viewportSize: view.bounds.size
      )
    }

    func processInteractiveDismiss(
      state: UIGestureRecognizer.State,
      translation: CGSize,
      velocity: CGSize,
      viewportSize: CGSize
    ) {
      switch state {
      case .began, .changed:
        onInteractiveDismiss(
          .changed(
            translation: max(translation.height, 0),
            progress: ImageViewerDismissGesturePolicy.progress(
              translation: translation,
              viewportSize: viewportSize
            )
          )
        )
      case .ended:
        onInteractiveDismiss(
          .ended(
            shouldDismiss: ImageViewerDismissGesturePolicy.shouldDismiss(
              translation: translation,
              velocity: velocity,
              viewportSize: viewportSize
            )
          )
        )
      case .cancelled, .failed:
        onInteractiveDismiss(.cancelled)
      case .possible:
        break
      @unknown default:
        onInteractiveDismiss(.cancelled)
      }
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
class ImageGalleryPageViewController: UIPageViewController {
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
  private(set) var animationPlaybackEnabled: Bool
  private let onZoomStateChange: (ImageGalleryItem.ID, ImageGalleryZoomState) -> Void

  init(
    item: ImageGalleryItem,
    zoomConfiguration: ImageGalleryZoomConfiguration,
    animationPlaybackEnabled: Bool,
    onZoomStateChange: @escaping (ImageGalleryItem.ID, ImageGalleryZoomState) -> Void
  ) {
    itemID = item.id
    self.item = item
    self.animationPlaybackEnabled = animationPlaybackEnabled
    self.onZoomStateChange = onZoomStateChange
    super.init(
      rootView: AnyView(
        ZoomableRemoteImage(
          item: item,
          initialZoomState: zoomConfiguration.state,
          initialZoomWasConfigured: zoomConfiguration.isConfigured,
          animationPlaybackEnabled: animationPlaybackEnabled,
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

  func update(
    item: ImageGalleryItem,
    zoomConfiguration: ImageGalleryZoomConfiguration,
    animationPlaybackEnabled: Bool
  ) {
    guard self.item != item || self.animationPlaybackEnabled != animationPlaybackEnabled else {
      return
    }
    self.item = item
    self.animationPlaybackEnabled = animationPlaybackEnabled
    rootView = AnyView(
      ZoomableRemoteImage(
        item: item,
        initialZoomState: zoomConfiguration.state,
        initialZoomWasConfigured: zoomConfiguration.isConfigured,
        animationPlaybackEnabled: animationPlaybackEnabled,
        onZoomStateChange: onZoomStateChange
      )
    )
  }

  func setAnimationPlaybackEnabled(
    _ enabled: Bool,
    zoomConfiguration: ImageGalleryZoomConfiguration
  ) {
    update(
      item: item,
      zoomConfiguration: zoomConfiguration,
      animationPlaybackEnabled: enabled
    )
  }
}
