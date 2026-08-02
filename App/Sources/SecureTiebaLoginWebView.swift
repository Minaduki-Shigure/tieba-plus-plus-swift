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
    let path = url.path.lowercased()
    return (host == "tieba.baidu.com" || host == "tiebac.baidu.com")
      && (path == "/index/tbwise/mine" || path == "/index/tbwise/mine/")
  }

  static func credentials(from cookies: [HTTPCookie]) -> AccountCredentials? {
    let now = Date()
    func preferredValue(named name: String, domains: Set<String>) -> String? {
      cookies
        .filter { cookie in
          let domain = cookie.domain.lowercased().trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
          )
          let isUnexpired = cookie.expiresDate.map { $0 > now } ?? true
          return cookie.name.caseInsensitiveCompare(name) == .orderedSame
            && domains.contains(domain)
            && cookie.isSecure
            && isUnexpired
            && cookie.path == "/"
            && !cookie.value.isEmpty
        }
        .max {
          ($0.expiresDate ?? .distantPast) < ($1.expiresDate ?? .distantPast)
        }?
        .value
    }
    guard
      let bduss = preferredValue(named: "BDUSS", domains: ["baidu.com"]),
      bduss.count == 192,
      bduss.allSatisfy({ $0.isASCII && !$0.isWhitespace })
    else { return nil }
    return AccountCredentials(bduss: bduss)
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

struct SecureTiebaLoginWebView: UIViewRepresentable {
  let onHostChange: @MainActor @Sendable (String) -> Void
  let onCredentials: @MainActor @Sendable (AccountCredentials) -> Void
  let onBlockedNavigation: @MainActor @Sendable (String) -> Void
  let onLoadFailure: @MainActor @Sendable () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(
      onHostChange: onHostChange,
      onCredentials: onCredentials,
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
    weak var webView: WKWebView?

    private let onHostChange: @MainActor @Sendable (String) -> Void
    private let onCredentials: @MainActor @Sendable (AccountCredentials) -> Void
    private let onBlockedNavigation: @MainActor @Sendable (String) -> Void
    private let onLoadFailure: @MainActor @Sendable () -> Void
    private var isActive = true
    private var isCompleting = false

    init(
      onHostChange: @escaping @MainActor @Sendable (String) -> Void,
      onCredentials: @escaping @MainActor @Sendable (AccountCredentials) -> Void,
      onBlockedNavigation: @escaping @MainActor @Sendable (String) -> Void,
      onLoadFailure: @escaping @MainActor @Sendable () -> Void
    ) {
      self.onHostChange = onHostChange
      self.onCredentials = onCredentials
      self.onBlockedNavigation = onBlockedNavigation
      self.onLoadFailure = onLoadFailure
    }

    func invalidate() {
      isActive = false
      isCompleting = false
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
        onBlockedNavigation(url?.host ?? "")
        decisionHandler(.cancel)
        return
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
        let url = webView.url,
        TiebaLoginNavigationPolicy.isCompletionURL(url)
      else { return }
      isCompleting = true
      webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
        let credentials = TiebaLoginNavigationPolicy.credentials(from: cookies)
        Task { @MainActor [weak self] in
          guard let self, self.isActive else { return }
          guard let credentials else {
            self.isCompleting = false
            return
          }
          self.onCredentials(credentials)
        }
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
      guard isActive else { return }
      let error = error as NSError
      guard error.domain != NSURLErrorDomain || error.code != NSURLErrorCancelled else { return }
      onLoadFailure()
    }
  }
}
