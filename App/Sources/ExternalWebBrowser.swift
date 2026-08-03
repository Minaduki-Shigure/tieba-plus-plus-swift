import Foundation
@preconcurrency import SafariServices
import SwiftUI
import UIKit

enum BrowseContentLinkDisposition: Equatable, Sendable {
  case tieba(TiebaLinkTarget)
  case system(URL)
  case inAppSafari(URL)
  case rejected
}

enum BrowseContentLinkRouter {
  static func disposition(
    for url: URL,
    mode: ExternalWebOpenMode
  ) -> BrowseContentLinkDisposition {
    if let target = TiebaLink.target(from: url) {
      return .tieba(target)
    }

    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil,
      components.password == nil,
      let scheme = components.scheme?.lowercased(),
      !scheme.isEmpty
    else {
      return .rejected
    }

    switch scheme {
    case "https":
      guard let host = components.host, !host.isEmpty else { return .rejected }
      switch mode {
      case .systemBrowser:
        return .system(url)
      case .inAppSafari:
        return .inAppSafari(url)
      }
    case "http":
      guard let host = components.host, !host.isEmpty else { return .rejected }
      return .system(url)
    default:
      return .system(url)
    }
  }
}

struct ExternalWebPage: Identifiable, Equatable, Sendable {
  let id: UUID
  let url: URL

  init(id: UUID = UUID(), url: URL) {
    self.id = id
    self.url = url
  }
}

struct ExternalWebOpenAction: Sendable {
  private let handler: @MainActor @Sendable (URL) -> Bool

  init(_ handler: @escaping @MainActor @Sendable (URL) -> Bool) {
    self.handler = handler
  }

  @MainActor
  func callAsFunction(_ url: URL) -> Bool {
    handler(url)
  }

  static let unavailable = Self { _ in false }
}

private struct ExternalWebOpenActionEnvironmentKey: EnvironmentKey {
  static let defaultValue = ExternalWebOpenAction.unavailable
}

extension EnvironmentValues {
  var openExternalWeb: ExternalWebOpenAction {
    get { self[ExternalWebOpenActionEnvironmentKey.self] }
    set { self[ExternalWebOpenActionEnvironmentKey.self] = newValue }
  }
}

@MainActor
final class ExternalWebPresentationModel: ObservableObject {
  @Published private(set) var page: ExternalWebPage?

  @discardableResult
  func requestPresentation(for url: URL) -> Bool {
    guard
      case .inAppSafari(let validatedURL) = BrowseContentLinkRouter.disposition(
        for: url,
        mode: .inAppSafari
      )
    else { return false }

    guard page == nil else { return true }
    page = ExternalWebPage(url: validatedURL)
    return true
  }

  func dismiss(id: ExternalWebPage.ID) {
    guard page?.id == id else { return }
    page = nil
  }
}

struct ExternalWebBrowserPresenter: UIViewControllerRepresentable {
  let page: ExternalWebPage?
  let onFinish: @MainActor @Sendable (ExternalWebPage.ID) -> Void

  func makeUIViewController(context: Context) -> HostViewController {
    HostViewController(page: page, onFinish: onFinish)
  }

  func updateUIViewController(
    _ uiViewController: HostViewController,
    context: Context
  ) {
    uiViewController.update(page: page, onFinish: onFinish)
  }

  static func dismantleUIViewController(
    _ uiViewController: HostViewController,
    coordinator: Void
  ) {
    uiViewController.dismantle()
  }

  @MainActor
  final class HostViewController: UIViewController, SFSafariViewControllerDelegate,
    UIAdaptivePresentationControllerDelegate
  {
    private var requestedPage: ExternalWebPage?
    private var activePageID: ExternalWebPage.ID?
    private var safariViewController: SFSafariViewController?
    private var onFinish: @MainActor @Sendable (ExternalWebPage.ID) -> Void
    private var hasAppeared = false
    private var isDismantled = false
    private var isDismissing = false
    private var didNotifyFinish = false
    private var presentationRetryTask: Task<Void, Never>?
    private var presentationRetryID: UUID?
    private var presentationRetryDelayMilliseconds: Int64 = 100

    init(
      page: ExternalWebPage?,
      onFinish: @escaping @MainActor @Sendable (ExternalWebPage.ID) -> Void
    ) {
      requestedPage = page
      self.onFinish = onFinish
      super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
      let view = UIView(frame: .zero)
      view.backgroundColor = .clear
      view.isUserInteractionEnabled = false
      self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      hasAppeared = true
      reconcilePresentation()
    }

    func update(
      page: ExternalWebPage?,
      onFinish: @escaping @MainActor @Sendable (ExternalWebPage.ID) -> Void
    ) {
      if requestedPage?.id != page?.id {
        cancelPresentationRetry()
      }
      requestedPage = page
      self.onFinish = onFinish
      reconcilePresentation()
    }

    func dismantle() {
      isDismantled = true
      requestedPage = nil
      hasAppeared = false
      cancelPresentationRetry()

      guard let safariViewController else { return }
      safariViewController.delegate = nil
      safariViewController.presentationController?.delegate = nil
      clearActivePresentation(controller: safariViewController)
      if safariViewController.presentingViewController != nil {
        safariViewController.dismiss(animated: false)
      }
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
      guard
        controller === safariViewController,
        let pageID = activePageID,
        !isDismissing
      else { return }

      notifyFinishIfNeeded(pageID: pageID)
      clearActivePresentation(controller: controller)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
      guard
        let controller = safariViewController,
        presentationController.presentedViewController === controller,
        let pageID = activePageID
      else { return }

      if !isDismissing {
        notifyFinishIfNeeded(pageID: pageID)
      }
      clearActivePresentation(controller: controller)
    }

    private func reconcilePresentation() {
      guard !isDismantled else { return }

      if let activePageID {
        cancelPresentationRetry()
        if requestedPage?.id != activePageID {
          dismissActivePresentation(animated: true)
        }
        return
      }

      guard requestedPage != nil else {
        cancelPresentationRetry()
        return
      }

      guard
        !isDismissing,
        hasAppeared,
        viewIfLoaded?.window != nil,
        let page = requestedPage,
        let presenter = visiblePresentationHost(),
        !presenter.isBeingDismissed,
        presenter.transitionCoordinator == nil,
        presenter.presentedViewController == nil
      else {
        schedulePresentationRetry()
        return
      }

      cancelPresentationRetry()
      let controller = SFSafariViewController(url: page.url)
      controller.delegate = self
      safariViewController = controller
      activePageID = page.id
      didNotifyFinish = false
      presenter.present(controller, animated: true)
      controller.presentationController?.delegate = self
    }

    private func visiblePresentationHost() -> UIViewController? {
      guard viewIfLoaded?.window != nil else { return nil }
      var candidate: UIViewController = self
      while let parent = candidate.parent, parent.viewIfLoaded?.window != nil {
        candidate = parent
      }

      while
        let presented = candidate.presentedViewController,
        !presented.isBeingDismissed,
        presented.viewIfLoaded?.window != nil,
        presented !== safariViewController
      {
        candidate = presented
      }

      guard !(candidate is UIAlertController) else { return nil }
      return candidate
    }

    private func schedulePresentationRetry() {
      guard
        presentationRetryTask == nil,
        !isDismantled,
        requestedPage != nil,
        activePageID == nil
      else { return }

      let retryID = UUID()
      let delay = presentationRetryDelayMilliseconds
      presentationRetryID = retryID
      presentationRetryDelayMilliseconds = min(delay * 2, 1_000)
      presentationRetryTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(for: .milliseconds(delay))
        } catch {
          return
        }
        guard let self, self.presentationRetryID == retryID else { return }
        self.presentationRetryTask = nil
        self.presentationRetryID = nil
        self.reconcilePresentation()
      }
    }

    private func cancelPresentationRetry() {
      presentationRetryTask?.cancel()
      presentationRetryTask = nil
      presentationRetryID = nil
      presentationRetryDelayMilliseconds = 100
    }

    private func notifyFinishIfNeeded(pageID: ExternalWebPage.ID) {
      guard !didNotifyFinish else { return }
      didNotifyFinish = true
      if requestedPage?.id == pageID {
        requestedPage = nil
      }
      onFinish(pageID)
    }

    private func dismissActivePresentation(animated: Bool) {
      guard
        !isDismissing,
        let controller = safariViewController,
        let pageID = activePageID
      else { return }

      isDismissing = true
      guard controller.presentingViewController != nil else {
        clearActivePresentation(controller: controller)
        return
      }
      controller.dismiss(animated: animated) { [weak self, weak controller] in
        Task { @MainActor in
          guard let self, let controller, self.activePageID == pageID else { return }
          self.clearActivePresentation(controller: controller)
        }
      }
    }

    private func clearActivePresentation(controller: SFSafariViewController) {
      guard controller === safariViewController else { return }
      controller.delegate = nil
      controller.presentationController?.delegate = nil
      safariViewController = nil
      activePageID = nil
      isDismissing = false
      didNotifyFinish = false
      reconcilePresentation()
    }
  }
}
