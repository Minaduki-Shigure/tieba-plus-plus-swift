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
  private static let maximumCheckURLDepth = 4

  static func disposition(
    for url: URL,
    mode: ExternalWebOpenMode
  ) -> BrowseContentLinkDisposition {
    disposition(
      for: url,
      mode: mode,
      checkURLDepth: 0,
      visitedCheckURLs: []
    )
  }

  private static func disposition(
    for url: URL,
    mode: ExternalWebOpenMode,
    checkURLDepth: Int,
    visitedCheckURLs: Set<String>
  ) -> BrowseContentLinkDisposition {
    switch BaiduCheckURLWrapper.resolve(url) {
    case .notWrapper:
      break
    case .rejected:
      return .rejected
    case .target(let targetURL):
      guard
        checkURLDepth < maximumCheckURLDepth,
        targetURL.absoluteString.utf8.count < url.absoluteString.utf8.count
      else { return .rejected }
      var visitedCheckURLs = visitedCheckURLs
      guard visitedCheckURLs.insert(url.absoluteString).inserted else { return .rejected }
      return disposition(
        for: targetURL,
        mode: mode,
        checkURLDepth: checkURLDepth + 1,
        visitedCheckURLs: visitedCheckURLs
      )
    }

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
    case TiebaLink.appScheme:
      // App-only navigation links must never escape rich content through the system.
      return .rejected
    default:
      return .system(url)
    }
  }
}

private enum BaiduCheckURLResolution {
  case notWrapper
  case target(URL)
  case rejected
}

private enum BaiduCheckURLWrapper {
  private static let hosts: Set<String> = ["tieba.baidu.com", "wapp.baidu.com"]
  private static let path = "/mo/q/checkurl"
  private static let maximumEnvelopeBytes = 32_768
  private static let maximumPayloadBytes = 8_192
  private static let maximumQueryItems = 16
  private static let duplicatedSchemePrefix = "http://https://"

  static func resolve(_ url: URL) -> BaiduCheckURLResolution {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let normalizedHost = components.host?.lowercased()
    else { return .notWrapper }
    var canonicalHost = normalizedHost
    while canonicalHost.hasSuffix(".") { canonicalHost.removeLast() }
    guard hosts.contains(canonicalHost) else { return .notWrapper }
    guard pathResolvesToCheckURL(components.path) else { return .notWrapper }
    guard normalizedHost == canonicalHost else { return .rejected }
    guard components.percentEncodedPath == path else { return .rejected }

    guard
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    else { return .rejected }

    let standardPort = scheme == "http" ? 80 : 443
    guard
      components.user == nil,
      components.password == nil,
      components.port == nil || components.port == standardPort,
      components.fragment == nil,
      strictAuthority(in: url.absoluteString)?.lowercased()
        == (components.port == nil
          ? normalizedHost
          : "\(normalizedHost):\(standardPort)"),
      isBoundedAndControlFree(
        url.absoluteString,
        maximumBytes: maximumEnvelopeBytes
      ),
      components.percentEncodedQuery != nil,
      let queryItems = components.queryItems,
      let percentEncodedQueryItems = components.percentEncodedQueryItems,
      !queryItems.isEmpty,
      queryItems.count <= maximumQueryItems,
      percentEncodedQueryItems.count == queryItems.count
    else { return .rejected }

    let urlItemIndices = queryItems.indices.filter {
      queryItems[$0].name.lowercased() == "url"
    }
    guard
      urlItemIndices.count == 1,
      let urlItemIndex = urlItemIndices.first,
      queryItems[urlItemIndex].name == "url",
      percentEncodedQueryItems[urlItemIndex].name == "url",
      var targetValue = queryItems[urlItemIndex].value,
      !targetValue.isEmpty
    else { return .rejected }

    if targetValue.hasPrefix(duplicatedSchemePrefix) {
      targetValue.removeFirst("http://".count)
    }
    guard
      !targetValue.unicodeScalars.contains(
        where: CharacterSet.whitespacesAndNewlines.contains
      ),
      isBoundedAndControlFree(
        targetValue,
        maximumBytes: maximumPayloadBytes
      ),
      let targetAuthority = strictAuthority(in: targetValue),
      !targetAuthority.isEmpty,
      !targetAuthority.hasSuffix(":"),
      let targetURL = URL(string: targetValue),
      targetURL.absoluteString.utf8.count <= maximumPayloadBytes,
      let targetComponents = URLComponents(
        url: targetURL,
        resolvingAgainstBaseURL: false
      ),
      targetComponents.user == nil,
      targetComponents.password == nil,
      targetComponents.scheme.map({ $0.lowercased() })
        .map({ $0 == "http" || $0 == "https" }) == true,
      targetComponents.host.map({ !$0.isEmpty }) == true
    else { return .rejected }
    return .target(targetURL)
  }

  private static func pathResolvesToCheckURL(_ decodedPath: String) -> Bool {
    var candidate = decodedPath
    for _ in 0..<2 {
      if normalizedRoutingPath(candidate) == path { return true }
      let nextCandidate = decodingValidPercentEscapes(in: candidate)
      if nextCandidate == candidate { return false }
      candidate = nextCandidate
    }
    return normalizedRoutingPath(candidate) == path
  }

  private static func normalizedRoutingPath(_ decodedPath: String) -> String {
    var segments: [Substring] = []
    for segment in decodedPath.split(separator: "/", omittingEmptySubsequences: false) {
      let routingSegment = segment.prefix { $0 != ";" }
      if routingSegment.isEmpty || routingSegment == "." { continue }
      if routingSegment == ".." {
        if !segments.isEmpty { segments.removeLast() }
      } else {
        segments.append(routingSegment)
      }
    }
    return "/\(segments.joined(separator: "/"))".lowercased()
  }

  private static func strictAuthority(in absoluteString: String) -> Substring? {
    guard let separator = absoluteString.range(of: "://") else { return nil }
    let remainder = absoluteString[separator.upperBound...]
    let authorityEnd = remainder.firstIndex { character in
      character == "/" || character == "?" || character == "#"
    } ?? remainder.endIndex
    return remainder[..<authorityEnd]
  }

  private static func isBoundedAndControlFree(
    _ value: String,
    maximumBytes: Int
  ) -> Bool {
    guard
      value.utf8.count <= maximumBytes,
      !containsControlCharacters(value)
    else { return false }

    var decodedValue = value
    for _ in 0..<2 {
      let nextValue = decodingValidPercentEscapes(in: decodedValue)
      guard !containsControlCharacters(nextValue) else { return false }
      if nextValue == decodedValue { break }
      decodedValue = nextValue
    }
    return true
  }

  private static func containsControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func decodingValidPercentEscapes(in value: String) -> String {
    let source = Array(value.utf8)
    var decoded: [UInt8] = []
    decoded.reserveCapacity(source.count)
    var index = 0
    while index < source.count {
      if
        source[index] == 0x25,
        index + 2 < source.count,
        let high = hexadecimalValue(source[index + 1]),
        let low = hexadecimalValue(source[index + 2])
      {
        decoded.append((high << 4) | low)
        index += 3
      } else {
        decoded.append(source[index])
        index += 1
      }
    }
    return String(decoding: decoded, as: UTF8.self)
  }

  private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
    return switch byte {
    case 0x30...0x39: byte - 0x30
    case 0x41...0x46: byte - 0x41 + 10
    case 0x61...0x66: byte - 0x61 + 10
    default: nil
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
  final class HostViewController: UIViewController,
    @preconcurrency SFSafariViewControllerDelegate,
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
