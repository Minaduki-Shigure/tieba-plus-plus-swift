import Foundation
import SwiftUI
@preconcurrency import WebKit

enum TiebaLoginNavigationPolicy {
  private static let mainFrameHosts: Set<String> = [
    "wappass.baidu.com",
    "passport.baidu.com",
    "tieba.baidu.com",
    "tiebac.baidu.com",
  ]
  private static let subframeHosts = mainFrameHosts.union(["dlswbr.baidu.com"])

  static let loginURL = URL(
    string:
      "https://wappass.baidu.com/passport?login&u=https%3A%2F%2Ftieba.baidu.com%2Findex%2Ftbwise%2Fmine"
  )!

  static func allowsMainFrame(_ url: URL) -> Bool {
    allowsHTTPS(url, hosts: mainFrameHosts)
  }

  static func allowsSubframe(_ url: URL) -> Bool {
    allowsHTTPS(url, hosts: subframeHosts)
  }

  static func isCompletionURL(_ url: URL) -> Bool {
    guard allowsMainFrame(url), let host = url.host?.lowercased() else { return false }
    let path = url.path
    return (host == "tieba.baidu.com" || host == "tiebac.baidu.com")
      && (path == "/index/tbwise" || path.hasPrefix("/index/tbwise/"))
  }

  static func credentials(from cookies: [HTTPCookie]) -> AccountCredentials? {
    let now = Date()
    var selected: (value: String, priority: Int, expires: Date)?

    for cookie in cookies {
      let namePriority: Int
      if cookie.name.caseInsensitiveCompare("BDUSS_BFESS") == .orderedSame {
        namePriority = 1
      } else if cookie.name.caseInsensitiveCompare("BDUSS") == .orderedSame {
        namePriority = 0
      } else {
        continue
      }

      let rawDomain = cookie.domain.lowercased()
      let domain = rawDomain.hasPrefix(".") ? String(rawDomain.dropFirst()) : rawDomain
      let isUnexpired = cookie.expiresDate.map { $0 > now } ?? true
      let value = cookie.value
      guard
        domain == "baidu.com",
        cookie.path == "/",
        cookie.isSecure,
        isUnexpired,
        value.utf8.count == 192,
        value.unicodeScalars.allSatisfy({ scalar in
          scalar.value >= 0x21 && scalar.value <= 0x7E
        })
      else { continue }

      let expires = cookie.expiresDate ?? .distantFuture
      if let current = selected {
        guard
          namePriority > current.priority
            || (namePriority == current.priority && expires > current.expires)
        else { continue }
      }
      selected = (value, namePriority, expires)
    }

    return selected.map { AccountCredentials(bduss: $0.value) }
  }

  private static func allowsHTTPS(_ url: URL, hosts: Set<String>) -> Bool {
    guard
      url.scheme?.lowercased() == "https",
      let host = url.host?.lowercased(),
      hosts.contains(host),
      url.port == nil || url.port == 443,
      url.user == nil,
      url.password == nil
    else { return false }
    return true
  }
}

struct TiebaLoginCredentialRetryPolicy: Sendable {
  enum Decision: Sendable {
    case captured(AccountCredentials)
    case retry(afterNanoseconds: UInt64)
    case failed
    case ignored
  }

  private static let retryDelays: [UInt64] = [
    100_000_000,
    200_000_000,
    400_000_000,
    800_000_000,
    1_000_000_000,
  ]

  private(set) var completedAttempts = 0
  private(set) var isTerminal = false

  mutating func evaluate(_ credentials: AccountCredentials?) -> Decision {
    guard !isTerminal else { return .ignored }
    completedAttempts += 1
    if let credentials {
      isTerminal = true
      return .captured(credentials)
    }
    let delayIndex = completedAttempts - 1
    guard Self.retryDelays.indices.contains(delayIndex) else {
      isTerminal = true
      return .failed
    }
    return .retry(afterNanoseconds: Self.retryDelays[delayIndex])
  }
}

struct SecureTiebaLoginWebView: UIViewRepresentable {
  let onHostChange: @MainActor @Sendable (String) -> Void
  let onCredentialCaptureStateChange: @MainActor @Sendable (Bool) -> Void
  let onCredentials: @MainActor @Sendable (AccountCredentials) -> Void
  let onCredentialCaptureFailure: @MainActor @Sendable () -> Void
  let onBlockedNavigation: @MainActor @Sendable (String) -> Void
  let onLoadFailure: @MainActor @Sendable () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onHostChange: onHostChange,
      onCredentialCaptureStateChange: onCredentialCaptureStateChange,
      onCredentials: onCredentials,
      onCredentialCaptureFailure: onCredentialCaptureFailure,
      onBlockedNavigation: onBlockedNavigation,
      onLoadFailure: onLoadFailure
    )
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    configuration.defaultWebpagePreferences.preferredContentMode = .mobile

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.allowsBackForwardNavigationGestures = true
    if #available(iOS 16.4, *) {
      webView.isInspectable = false
    }
    context.coordinator.webView = webView
    webView.load(
      URLRequest(
        url: TiebaLoginNavigationPolicy.loginURL,
        cachePolicy: .reloadIgnoringLocalCacheData,
        timeoutInterval: 30
      )
    )
    return webView
  }

  func updateUIView(_ uiView: WKWebView, context: Context) {}

  static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
    coordinator.invalidate()
    uiView.stopLoading()
    uiView.navigationDelegate = nil
    uiView.uiDelegate = nil
    coordinator.webView = nil
    uiView.configuration.websiteDataStore.removeData(
      ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
      modifiedSince: .distantPast
    ) {}
  }

  @MainActor
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let captureTimeoutNanoseconds: UInt64 = 8_000_000_000

    weak var webView: WKWebView?

    private let onHostChange: @MainActor @Sendable (String) -> Void
    private let onCredentialCaptureStateChange: @MainActor @Sendable (Bool) -> Void
    private let onCredentials: @MainActor @Sendable (AccountCredentials) -> Void
    private let onCredentialCaptureFailure: @MainActor @Sendable () -> Void
    private let onBlockedNavigation: @MainActor @Sendable (String) -> Void
    private let onLoadFailure: @MainActor @Sendable () -> Void
    private var isActive = true
    private var isCompleting = false
    private var isTerminal = false
    private var captureID: UUID?
    private var retryPolicy: TiebaLoginCredentialRetryPolicy?
    private var retryTask: Task<Void, Never>?
    private var captureTimeoutTask: Task<Void, Never>?

    init(
      onHostChange: @escaping @MainActor @Sendable (String) -> Void,
      onCredentialCaptureStateChange: @escaping @MainActor @Sendable (Bool) -> Void,
      onCredentials: @escaping @MainActor @Sendable (AccountCredentials) -> Void,
      onCredentialCaptureFailure: @escaping @MainActor @Sendable () -> Void,
      onBlockedNavigation: @escaping @MainActor @Sendable (String) -> Void,
      onLoadFailure: @escaping @MainActor @Sendable () -> Void
    ) {
      self.onHostChange = onHostChange
      self.onCredentialCaptureStateChange = onCredentialCaptureStateChange
      self.onCredentials = onCredentials
      self.onCredentialCaptureFailure = onCredentialCaptureFailure
      self.onBlockedNavigation = onBlockedNavigation
      self.onLoadFailure = onLoadFailure
    }

    func invalidate() {
      isActive = false
      isTerminal = true
      resetCredentialCapture(notifyStateChange: false)
    }

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
      guard isActive else {
        decisionHandler(.cancel)
        return
      }
      if navigationAction.targetFrame?.isMainFrame == false {
        let isAllowed = navigationAction.request.url.map(
          TiebaLoginNavigationPolicy.allowsSubframe
        ) ?? false
        decisionHandler(isAllowed ? .allow : .cancel)
        return
      }
      let url = navigationAction.request.url
      guard let url, TiebaLoginNavigationPolicy.allowsMainFrame(url) else {
        resetCredentialCapture(notifyStateChange: true)
        onBlockedNavigation(url?.host ?? "")
        decisionHandler(.cancel)
        return
      }
      if isCompleting, !TiebaLoginNavigationPolicy.isCompletionURL(url) {
        resetCredentialCapture(notifyStateChange: true)
      }
      onHostChange(url.host?.lowercased() ?? "")
      if navigationAction.targetFrame == nil {
        webView.load(navigationAction.request)
        decisionHandler(.cancel)
      } else {
        decisionHandler(.allow)
      }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
      guard
        isActive,
        !isCompleting,
        !isTerminal,
        let url = webView.url,
        TiebaLoginNavigationPolicy.isCompletionURL(url)
      else { return }
      beginCredentialCapture(in: webView)
    }

    private func beginCredentialCapture(in webView: WKWebView) {
      isCompleting = true
      let id = UUID()
      captureID = id
      retryPolicy = TiebaLoginCredentialRetryPolicy()
      onCredentialCaptureStateChange(true)
      captureTimeoutTask = Task { @MainActor [weak self] in
        do {
          try await Task.sleep(nanoseconds: Self.captureTimeoutNanoseconds)
        } catch {
          return
        }
        guard
          let self,
          self.isActive,
          self.captureID == id,
          !Task.isCancelled
        else { return }
        self.failCredentialCapture()
      }
      readCredentials(captureID: id)
    }

    private func readCredentials(captureID id: UUID) {
      guard let webView else {
        failCredentialCapture()
        return
      }
      webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
        let credentials = TiebaLoginNavigationPolicy.credentials(from: cookies)
        Task { @MainActor [weak self] in
          guard let self, self.isActive, self.captureID == id else { return }
          guard let webView = self.webView else {
            self.failCredentialCapture()
            return
          }
          guard
            let url = webView.url,
            TiebaLoginNavigationPolicy.isCompletionURL(url)
          else {
            self.resetCredentialCapture(notifyStateChange: true)
            return
          }
          guard var retryPolicy = self.retryPolicy else { return }

          let decision = retryPolicy.evaluate(credentials)
          self.retryPolicy = retryPolicy
          switch decision {
          case .captured(let credentials):
            self.isTerminal = true
            self.resetCredentialCapture(notifyStateChange: true)
            self.onCredentials(credentials)
          case .retry(let delay):
            self.retryTask?.cancel()
            self.retryTask = Task { @MainActor [weak self] in
              do {
                try await Task.sleep(nanoseconds: delay)
              } catch is CancellationError {
                return
              } catch {
                return
              }
              guard
                let self,
                self.isActive,
                self.captureID == id,
                !Task.isCancelled
              else { return }
              guard let webView = self.webView else {
                self.failCredentialCapture()
                return
              }
              guard
                let url = webView.url,
                TiebaLoginNavigationPolicy.isCompletionURL(url)
              else {
                self.resetCredentialCapture(notifyStateChange: true)
                return
              }
              self.retryTask = nil
              self.readCredentials(captureID: id)
            }
          case .failed:
            self.failCredentialCapture()
          case .ignored:
            return
          }
        }
      }
    }

    private func failCredentialCapture() {
      guard isActive, !isTerminal else { return }
      isTerminal = true
      resetCredentialCapture(notifyStateChange: true)
      onCredentialCaptureFailure()
    }

    private func resetCredentialCapture(notifyStateChange: Bool) {
      let wasCompleting = isCompleting
      retryTask?.cancel()
      retryTask = nil
      captureTimeoutTask?.cancel()
      captureTimeoutTask = nil
      captureID = nil
      retryPolicy = nil
      isCompleting = false
      if notifyStateChange, wasCompleting {
        onCredentialCaptureStateChange(false)
      }
    }

    func webView(
      _ webView: WKWebView,
      didFail navigation: WKNavigation?,
      withError error: any Error
    ) {
      reportLoadFailure(error)
    }

    func webView(
      _ webView: WKWebView,
      didFailProvisionalNavigation navigation: WKNavigation?,
      withError error: any Error
    ) {
      reportLoadFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
      guard isActive, !isTerminal else { return }
      isTerminal = true
      resetCredentialCapture(notifyStateChange: true)
      onLoadFailure()
    }

    func webView(
      _ webView: WKWebView,
      createWebViewWith configuration: WKWebViewConfiguration,
      for navigationAction: WKNavigationAction,
      windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
      guard isActive else { return nil }
      guard
        let url = navigationAction.request.url,
        TiebaLoginNavigationPolicy.allowsMainFrame(url)
      else {
        resetCredentialCapture(notifyStateChange: true)
        onBlockedNavigation(navigationAction.request.url?.host ?? "")
        return nil
      }
      webView.load(navigationAction.request)
      return nil
    }

    func webView(
      _ webView: WKWebView,
      requestMediaCapturePermissionFor origin: WKSecurityOrigin,
      initiatedByFrame frame: WKFrameInfo,
      type: WKMediaCaptureType,
      decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
      decisionHandler(.deny)
    }

    func webView(
      _ webView: WKWebView,
      requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
      initiatedByFrame frame: WKFrameInfo,
      decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
      decisionHandler(.deny)
    }

    private func reportLoadFailure(_ error: any Error) {
      guard isActive, !isTerminal else { return }
      let error = error as NSError
      guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
      isTerminal = true
      resetCredentialCapture(notifyStateChange: true)
      onLoadFailure()
    }
  }
}
