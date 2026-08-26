import Combine
import SwiftUI

struct ThreadSummaryImageOpenAction: Sendable {
  private let handler: @MainActor @Sendable (BrowseThread, Int) -> Bool
  let isAvailable: Bool

  init(_ handler: @escaping @MainActor @Sendable (BrowseThread, Int) -> Bool) {
    self.handler = handler
    isAvailable = true
  }

  private init() {
    handler = { _, _ in false }
    isAvailable = false
  }

  @MainActor
  func callAsFunction(thread: BrowseThread, contentOffset: Int) -> Bool {
    handler(thread, contentOffset)
  }

  static let unavailable = Self()
}

private struct ThreadSummaryImageOpenActionEnvironmentKey: EnvironmentKey {
  static let defaultValue = ThreadSummaryImageOpenAction.unavailable
}

extension EnvironmentValues {
  var openThreadSummaryImage: ThreadSummaryImageOpenAction {
    get { self[ThreadSummaryImageOpenActionEnvironmentKey.self] }
    set { self[ThreadSummaryImageOpenActionEnvironmentKey.self] = newValue }
  }
}

struct ThreadSummaryImageGalleryRoute: Identifiable {
  enum Content {
    case local(ImageGalleryPresentation)
    case thread(ThreadImageGalleryRoute)
  }

  let id: UUID
  let content: Content

  static func local(_ presentation: ImageGalleryPresentation) -> Self {
    Self(id: UUID(), content: .local(presentation))
  }

  static func thread(_ route: ThreadImageGalleryRoute) -> Self {
    Self(id: route.id, content: .thread(route))
  }
}

@MainActor
final class ThreadSummaryImageGalleryCoordinator: ObservableObject {
  @Published private(set) var route: ThreadSummaryImageGalleryRoute?

  private let remoteService: (any ThreadPictureGalleryService)?
  private let contentFilterRepository: any ContentFilterRepository
  private var policyTask: Task<Void, Never>?

  init(
    remoteService: (any ThreadPictureGalleryService)?,
    contentFilterRepository: any ContentFilterRepository
  ) {
    self.remoteService = remoteService
    self.contentFilterRepository = contentFilterRepository
  }

  lazy var openAction = ThreadSummaryImageOpenAction { [weak self] thread, contentOffset in
    self?.open(thread: thread, contentOffset: contentOffset) ?? false
  }

  @discardableResult
  func open(thread: BrowseThread, contentOffset: Int) -> Bool {
    guard
      route == nil,
      thread.id > 0,
      !thread.isPinned,
      thread.localVisibility == .visible,
      let presentation = ImageGalleryPresentation(
        contents: thread.contents,
        selectedContentOffset: contentOffset
      )
    else { return false }

    guard
      thread.contentPostID > 0,
      let threadRoute = ThreadImageGalleryRouteFactory.make(
        context: ThreadPictureGalleryContext(
          forumID: thread.forumID,
          forumName: thread.forumName,
          threadID: thread.id,
          source: .index
        ),
        postID: thread.contentPostID,
        presentation: presentation,
        remoteService: remoteService
      )
    else {
      route = .local(presentation)
      return true
    }

    let summaryRoute = ThreadSummaryImageGalleryRoute.thread(threadRoute)
    route = summaryRoute
    scheduleWholeThreadPolicy(
      for: thread,
      routeID: summaryRoute.id,
      viewModel: threadRoute.viewModel
    )
    return true
  }

  func dismiss() {
    policyTask?.cancel()
    policyTask = nil
    if case .thread(let route)? = route?.content {
      route.viewModel.cancel()
    }
    route = nil
  }

  func contentFilterDidChange() {
    dismiss()
  }

  func waitForPolicyEvaluation() async {
    await policyTask?.value
  }

  private func scheduleWholeThreadPolicy(
    for thread: BrowseThread,
    routeID: ThreadSummaryImageGalleryRoute.ID,
    viewModel: ThreadImageGalleryViewModel
  ) {
    guard remoteService != nil, thread.kind == .article else { return }
    let repository = contentFilterRepository
    policyTask = Task { @MainActor [weak self, weak viewModel] in
      do {
        let snapshot = try await repository.snapshot()
        try Task.checkCancellation()
        guard
          let self,
          let viewModel,
          self.route?.id == routeID
        else { return }
        viewModel.setRemoteLoadingEnabled(snapshot.allowsWholeThreadPictureGallery)
      } catch {
        // The same-post gallery stays available when the local policy cannot be read.
      }
    }
  }
}

private struct ThreadSummaryImageGalleryModifier: ViewModifier {
  @ObservedObject var coordinator: ThreadSummaryImageGalleryCoordinator

  func body(content: Content) -> some View {
    content
      .environment(\.openThreadSummaryImage, coordinator.openAction)
      .fullScreenCover(
        item: routeBinding,
        onDismiss: coordinator.dismiss
      ) { route in
        switch route.content {
        case .local(let presentation):
          ImageViewer(
            items: presentation.items,
            initialIndex: presentation.initialIndex,
            onClose: coordinator.dismiss
          )
        case .thread(let route):
          ThreadImageGalleryView(
            viewModel: route.viewModel,
            onClose: coordinator.dismiss
          )
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
        coordinator.contentFilterDidChange()
      }
  }

  private var routeBinding: Binding<ThreadSummaryImageGalleryRoute?> {
    Binding(
      get: { coordinator.route },
      set: { route in
        if route == nil {
          coordinator.dismiss()
        }
      }
    )
  }
}

extension View {
  func threadSummaryImageGallery(
    _ coordinator: ThreadSummaryImageGalleryCoordinator
  ) -> some View {
    modifier(ThreadSummaryImageGalleryModifier(coordinator: coordinator))
  }
}
