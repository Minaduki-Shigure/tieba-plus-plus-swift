import Foundation
@preconcurrency import SafariServices
import SwiftUI
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class ExternalWebBrowserTests: XCTestCase {
  @MainActor
  func testPresenterUsesTopmostPresentedViewControllerAndFinishesOnce() async throws {
    guard
      let windowScene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene })
        .first(where: { $0.activationState == .foregroundActive })
    else {
      throw XCTSkip("The hosted test has no window scene.")
    }

    let window = UIWindow(windowScene: windowScene)
    window.frame = windowScene.coordinateSpace.bounds
    let root = UIViewController()
    window.rootViewController = root
    window.isHidden = false
    root.loadViewIfNeeded()

    let model = ExternalWebPresentationModel()
    let recorder = ExternalWebFinishRecorder()
    let host = ExternalWebBrowserPresenter.HostViewController(page: nil) { pageID in
      recorder.record(pageID)
      model.dismiss(id: pageID)
    }
    root.addChild(host)
    root.view.addSubview(host.view)
    host.didMove(toParent: root)
    host.beginAppearanceTransition(true, animated: false)
    host.endAppearanceTransition()

    let sheet = RecordingPresenterViewController()
    let sheetPresentation = expectation(description: "The test sheet is presented")
    root.present(sheet, animated: false) {
      sheetPresentation.fulfill()
    }
    await fulfillment(of: [sheetPresentation], timeout: 2)

    defer {
      host.dismantle()
      host.beginAppearanceTransition(false, animated: false)
      host.endAppearanceTransition()
      host.willMove(toParent: nil)
      host.view.removeFromSuperview()
      host.removeFromParent()
      root.dismiss(animated: false)
      window.isHidden = true
    }

    let blocker = UIAlertController(title: "Blocking transition", message: nil, preferredStyle: .alert)
    let blockerPresentation = expectation(description: "The temporary blocker is presented")
    sheet.present(blocker, animated: false) {
      blockerPresentation.fulfill()
    }
    await fulfillment(of: [blockerPresentation], timeout: 2)

    let safariPresentation = expectation(description: "Safari is presented after the blocker")
    sheet.onRecordedPresentation = { controller in
      guard controller is SFSafariViewController else { return }
      safariPresentation.fulfill()
    }

    let url = try XCTUnwrap(URL(string: "https://example.invalid/article"))
    XCTAssertTrue(model.requestPresentation(for: url))
    let page = try XCTUnwrap(model.page)

    host.update(page: page) { pageID in
      recorder.record(pageID)
      model.dismiss(id: pageID)
    }
    XCTAssertEqual(sheet.recordedPresentations.count, 0)

    let blockerDismissal = expectation(description: "The temporary blocker is dismissed")
    blocker.dismiss(animated: false) {
      blockerDismissal.fulfill()
    }
    await fulfillment(of: [blockerDismissal, safariPresentation], timeout: 2)
    sheet.onRecordedPresentation = nil

    let safari = try XCTUnwrap(
      sheet.recordedPresentations.single as? SFSafariViewController
    )
    XCTAssertTrue(root.presentedViewController === sheet)
    XCTAssertEqual(recorder.pageIDs, [])

    host.safariViewControllerDidFinish(safari)
    host.safariViewControllerDidFinish(safari)

    XCTAssertEqual(recorder.pageIDs, [page.id])
    XCTAssertNil(model.page)

    let secondBlocker = UIAlertController(
      title: "Cancellation blocker",
      message: nil,
      preferredStyle: .alert
    )
    let secondBlockerPresentation = expectation(
      description: "The cancellation blocker is presented"
    )
    sheet.present(secondBlocker, animated: false) {
      secondBlockerPresentation.fulfill()
    }
    await fulfillment(of: [secondBlockerPresentation], timeout: 2)

    let secondURL = try XCTUnwrap(URL(string: "https://example.invalid/cancelled"))
    XCTAssertTrue(model.requestPresentation(for: secondURL))
    let cancelledPage = try XCTUnwrap(model.page)
    host.update(page: cancelledPage) { pageID in
      recorder.record(pageID)
      model.dismiss(id: pageID)
    }
    model.dismiss(id: cancelledPage.id)
    host.update(page: nil) { _ in
      XCTFail("A cancelled presentation must not finish")
    }

    let secondBlockerDismissal = expectation(
      description: "The cancellation blocker is dismissed"
    )
    secondBlocker.dismiss(animated: false) {
      secondBlockerDismissal.fulfill()
    }
    await fulfillment(of: [secondBlockerDismissal], timeout: 2)
    try await Task.sleep(for: .milliseconds(250))

    XCTAssertEqual(sheet.recordedPresentations.count, 1)
    XCTAssertEqual(recorder.pageIDs, [page.id])
    XCTAssertNil(model.page)
  }

  @MainActor
  func testExternalWebOpenActionDefaultsToUnavailable() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/article"))

    XCTAssertFalse(ExternalWebOpenAction.unavailable(url))
    XCTAssertFalse(EnvironmentValues().openExternalWeb(url))
  }

  @MainActor
  func testPresentationModelConsumesOnlyOneValidatedExternalHTTPSRequest() throws {
    let model = ExternalWebPresentationModel()
    let acceptedURL = try XCTUnwrap(URL(string: "https://example.com/article?q=one#part"))
    let secondURL = try XCTUnwrap(URL(string: "https://example.org/second"))

    XCTAssertTrue(model.requestPresentation(for: acceptedURL))
    XCTAssertEqual(model.page?.url, acceptedURL)
    XCTAssertTrue(model.requestPresentation(for: secondURL))
    XCTAssertEqual(model.page?.url, acceptedURL)

    let acceptedID = try XCTUnwrap(model.page?.id)
    model.dismiss(id: UUID())
    XCTAssertEqual(model.page?.id, acceptedID)
    model.dismiss(id: acceptedID)
    XCTAssertNil(model.page)
    XCTAssertTrue(model.requestPresentation(for: secondURL))
  }

  @MainActor
  func testPresentationModelRejectsNonExternalHTTPSRequests() throws {
    let model = ExternalWebPresentationModel()
    let values = [
      "http://example.com/article",
      "https://user@example.com/article",
      "https:///missing-host",
      "https://tieba.baidu.com/p/42",
      "tieba-plus-plus://thread/42",
      "tieba-plus-plus://search",
      "tieba-plus-plus://notifications/1",
      "mailto:user@example.com",
    ]

    for value in values {
      let url = try XCTUnwrap(URL(string: value))
      XCTAssertFalse(model.requestPresentation(for: url), value)
      XCTAssertNil(model.page, value)
    }
  }

  func testExternalHTTPSUsesSelectedMode() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/article"))

    XCTAssertEqual(
      BrowseContentLinkRouter.disposition(for: url, mode: .systemBrowser),
      .system(url)
    )
    XCTAssertEqual(
      BrowseContentLinkRouter.disposition(for: url, mode: .inAppSafari),
      .inAppSafari(url)
    )
  }

  func testTiebaTargetsTakePriorityOverExternalModes() throws {
    let cases: [(URL, TiebaLinkTarget)] = [
      (
        try XCTUnwrap(
          URL(string: "https://tieba.baidu.com/p/42?see_lz=1&pid=99&from=share")
        ),
        .thread(TiebaThreadRoute(threadID: 42, onlyThreadAuthor: true, postID: 99))
      ),
      (
        try XCTUnwrap(URL(string: "http://tieba.baidu.com:80/f?kw=swift")),
        .forum("swift")
      ),
      (
        try XCTUnwrap(URL(string: "tieba-plus-plus://user/7")),
        .user(7)
      ),
      (
        try XCTUnwrap(
          URL(string: "com.baidu.tieba://unidispatch/pb?tid=43&see_lz=1&pid=100")
        ),
        .thread(TiebaThreadRoute(threadID: 43, onlyThreadAuthor: true, postID: 100))
      ),
    ]

    for mode in ExternalWebOpenMode.allCases {
      for (url, target) in cases {
        XCTAssertEqual(
          BrowseContentLinkRouter.disposition(for: url, mode: mode),
          .tieba(target),
          url.absoluteString
        )
      }
    }
  }

  func testAppOnlyRoutesAreRejectedInsteadOfReopenedThroughTheSystem() throws {
    let routes: [TiebaAppRoute] = [
      .search,
      .history,
      .cloudFavorites,
      .batchCheckIn,
      .notifications(.replies),
      .notifications(.mentions),
    ]

    for route in routes {
      let url = try XCTUnwrap(TiebaAppLink.appURL(for: route))
      XCTAssertNil(TiebaLink.target(from: url))
      for mode in ExternalWebOpenMode.allCases {
        XCTAssertEqual(
          BrowseContentLinkRouter.disposition(for: url, mode: mode),
          .rejected,
          url.absoluteString
        )
      }
    }
  }

  func testMalformedAppOwnedRoutesAreAlsoRejectedInsteadOfSystemDispatched() throws {
    let values = [
      "tieba-plus-plus://user@search",
      "tieba-plus-plus://search?",
      "tieba-plus-plus://search/%2F",
      "tieba-plus-plus://notifications/%31",
      "tieba-plus-plus://unknown",
    ]

    for value in values {
      let url = try XCTUnwrap(URL(string: value))
      XCTAssertNil(TiebaLink.target(from: url), value)
      for mode in ExternalWebOpenMode.allCases {
        XCTAssertEqual(
          BrowseContentLinkRouter.disposition(for: url, mode: mode),
          .rejected,
          value
        )
      }
    }
  }

  func testExternalHTTPAlwaysUsesSystemBrowser() throws {
    let url = try XCTUnwrap(URL(string: "http://example.com/article"))

    for mode in ExternalWebOpenMode.allCases {
      XCTAssertEqual(
        BrowseContentLinkRouter.disposition(for: url, mode: mode),
        .system(url)
      )
    }
  }

  func testCredentialedHostlessAndRelativeURLsAreRejected() throws {
    let values = [
      "https://user@example.com/path",
      "http://user:password@example.com/path",
      "custom://user@example.com/path",
      "https:///missing-host",
      "https:/missing-host",
      "http:?query=value",
      "/relative/path?query=value",
      "//example.com/scheme-relative",
    ]

    for value in values {
      let url = try XCTUnwrap(URL(string: value))
      for mode in ExternalWebOpenMode.allCases {
        XCTAssertEqual(
          BrowseContentLinkRouter.disposition(for: url, mode: mode),
          .rejected,
          value
        )
      }
    }
  }

  func testOtherAbsoluteSchemesNeverUseInAppSafari() throws {
    let values = [
      "file:///tmp/document.txt",
      "data:text/plain,hello",
      "javascript:alert(1)",
      "mailto:user@example.com",
      "ftp://example.com/file",
      "custom:opaque-value",
    ]

    for value in values {
      let url = try XCTUnwrap(URL(string: value))
      XCTAssertEqual(
        BrowseContentLinkRouter.disposition(for: url, mode: .inAppSafari),
        .system(url),
        value
      )
    }
  }

  func testExternalDestinationsPreserveQueryAndFragmentExactly() throws {
    let httpsValue =
      "https://example.com/a%2Fb?item=one&item=&flag&plus=a+b&encoded=a%2Bb#part%2Fone"
    let httpValue =
      "http://example.com/a%2Fb?item=one&item=&flag&plus=a+b&encoded=a%2Bb#part%2Fone"
    let httpsURL = try XCTUnwrap(URL(string: httpsValue))
    let httpURL = try XCTUnwrap(URL(string: httpValue))

    XCTAssertEqual(httpsURL.absoluteString, httpsValue)
    XCTAssertEqual(httpURL.absoluteString, httpValue)
    let systemHTTPSURL = try XCTUnwrap(
      BrowseContentLinkRouter.disposition(
        for: httpsURL,
        mode: .systemBrowser
      ).externalURL
    )
    let safariHTTPSURL = try XCTUnwrap(
      BrowseContentLinkRouter.disposition(
        for: httpsURL,
        mode: .inAppSafari
      ).externalURL
    )
    let systemHTTPURL = try XCTUnwrap(
      BrowseContentLinkRouter.disposition(
        for: httpURL,
        mode: .inAppSafari
      ).externalURL
    )

    XCTAssertEqual(systemHTTPSURL, httpsURL)
    XCTAssertEqual(safariHTTPSURL, httpsURL)
    XCTAssertEqual(systemHTTPURL, httpURL)
    XCTAssertEqual(
      systemHTTPSURL.absoluteString,
      httpsValue
    )
    XCTAssertEqual(
      safariHTTPSURL.absoluteString,
      httpsValue
    )
    XCTAssertEqual(
      systemHTTPURL.absoluteString,
      httpValue
    )
  }

  func testExternalWebPageKeepsExplicitIdentityAndURL() throws {
    let id = UUID()
    let url = try XCTUnwrap(URL(string: "https://example.com/page"))
    let page = ExternalWebPage(id: id, url: url)

    XCTAssertEqual(page.id, id)
    XCTAssertEqual(page.url, url)
  }
}

@MainActor
private final class ExternalWebFinishRecorder {
  private(set) var pageIDs = [ExternalWebPage.ID]()

  func record(_ pageID: ExternalWebPage.ID) {
    pageIDs.append(pageID)
  }
}

@MainActor
private final class RecordingPresenterViewController: UIViewController {
  private(set) var recordedPresentations = [UIViewController]()
  var onRecordedPresentation: ((UIViewController) -> Void)?

  override func present(
    _ viewControllerToPresent: UIViewController,
    animated flag: Bool,
    completion: (() -> Void)? = nil
  ) {
    if viewControllerToPresent is UIAlertController {
      super.present(viewControllerToPresent, animated: flag, completion: completion)
      return
    }
    recordedPresentations.append(viewControllerToPresent)
    onRecordedPresentation?(viewControllerToPresent)
    completion?()
  }
}

private extension Collection {
  var single: Element? {
    count == 1 ? first : nil
  }
}

private extension BrowseContentLinkDisposition {
  var externalURL: URL? {
    switch self {
    case .system(let url), .inAppSafari(let url):
      url
    case .tieba, .rejected:
      nil
    }
  }
}
