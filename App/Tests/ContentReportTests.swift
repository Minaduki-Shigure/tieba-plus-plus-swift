import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ContentReportTests: XCTestCase {
  func testExplicitToolbarScopeWinsAndEnvironmentRemainsFallback() {
    let explicit = reportUUID(1)
    let environment = reportUUID(2)

    XCTAssertEqual(
      ContentReportScopePolicy.resolved(
        explicitScopeID: explicit,
        environmentScopeID: environment
      ),
      explicit
    )
    XCTAssertEqual(
      ContentReportScopePolicy.resolved(
        explicitScopeID: nil,
        environmentScopeID: environment
      ),
      environment
    )
    XCTAssertNil(
      ContentReportScopePolicy.resolved(
        explicitScopeID: nil,
        environmentScopeID: nil
      )
    )
  }

  func testTargetsBindVisibleTopicPostAndSubpostIdentity() throws {
    let thread = reportThread()
    let topic = reportPost(id: 101, floor: 1)
    let post = reportPost(id: 102, floor: 2)
    let comment = reportComment(id: 103, parentPostID: post.id)

    XCTAssertEqual(ContentReportTarget(thread: thread, post: topic)?.kind, .topic)
    XCTAssertEqual(ContentReportTarget(thread: thread, post: topic)?.postID, topic.id)
    XCTAssertEqual(ContentReportTarget(thread: thread, post: post)?.kind, .post)
    XCTAssertEqual(
      ContentReportTarget(thread: thread, parentPostID: post.id, comment: comment)?.kind,
      .subpost
    )
    XCTAssertEqual(
      ContentReportTarget(thread: thread, parentPostID: post.id, comment: comment)?.parentPostID,
      post.id
    )
  }

  func testTargetsRejectFilteredAndMismatchedContent() {
    let thread = reportThread()
    XCTAssertNil(
      ContentReportTarget(
        thread: thread,
        post: reportPost(id: 101, floor: 1, visibility: .placeholder)
      )
    )
    XCTAssertNil(
      ContentReportTarget(
        thread: thread,
        post: reportPost(id: 999, floor: 1)
      )
    )
    XCTAssertNil(
      ContentReportTarget(
        thread: thread,
        parentPostID: 102,
        comment: reportComment(id: 103, parentPostID: 999)
      )
    )
    XCTAssertNil(
      ContentReportTarget(
        thread: thread,
        parentPostID: 102,
        comment: reportComment(id: 103, parentPostID: 102, visibility: .hidden)
      )
    )
  }

  func testSignedOutCoordinatorNeverResolvesReportPage() async throws {
    let vault = ContentReportVaultSpy(session: nil)
    let service = ContentReportServiceSpy()
    let presentation = ExternalWebPresentationModel()
    let coordinator = ContentReportCoordinator(
      vault: vault,
      service: service,
      presentation: presentation,
      observesAccountSessionChanges: false,
      observesPresentationChanges: false
    )

    try await waitForReportTest { coordinator.state == .signedOut }
    coordinator.request(try XCTUnwrap(reportTarget()), scopeID: reportUUID(10))

    XCTAssertNil(coordinator.pendingTarget)
    let requestedPostIDs = await service.requestedPostIDs()
    XCTAssertEqual(requestedPostIDs, [])
    XCTAssertNil(presentation.page)
  }

  func testConfirmedRequestOpensOnlyCanonicalServiceURLForStableLease() async throws {
    let session = reportSession(revision: reportUUID(1))
    let vault = ContentReportVaultSpy(session: session)
    let service = ContentReportServiceSpy(url: try reportURL(postID: 101))
    let presentation = ExternalWebPresentationModel()
    let coordinator = ContentReportCoordinator(
      vault: vault,
      service: service,
      presentation: presentation,
      observesAccountSessionChanges: false,
      observesPresentationChanges: false
    )
    try await waitForReportTest { coordinator.state == .ready }

    let target = try XCTUnwrap(reportTarget())
    coordinator.request(target, scopeID: reportUUID(11))
    XCTAssertEqual(coordinator.pendingTarget, target)
    coordinator.confirmPendingRequest()

    let expectedURL = try reportURL(postID: 101)
    try await waitForReportTest { presentation.page?.url == expectedURL }
    let requestedPostIDs = await service.requestedPostIDs()
    XCTAssertEqual(requestedPostIDs, [101])
    XCTAssertEqual(presentation.page?.url, expectedURL)
  }

  func testAccountRotationDuringPreflightRejectsLateURL() async throws {
    let oldSession = reportSession(revision: reportUUID(2))
    let newSession = reportSession(revision: reportUUID(3))
    let vault = ContentReportVaultSpy(session: oldSession)
    let service = ContentReportServiceSpy(
      url: try reportURL(postID: 101),
      suspends: true
    )
    let presentation = ExternalWebPresentationModel()
    let coordinator = ContentReportCoordinator(
      vault: vault,
      service: service,
      presentation: presentation,
      observesAccountSessionChanges: false,
      observesPresentationChanges: false
    )
    try await waitForReportTest { coordinator.state == .ready }

    coordinator.request(try XCTUnwrap(reportTarget()), scopeID: reportUUID(12))
    coordinator.confirmPendingRequest()
    try await waitForReportTest { await service.requestedPostIDs() == [101] }
    await vault.setSession(newSession)
    await service.release()

    try await waitForReportTest { coordinator.errorMessage != nil }
    XCTAssertNil(presentation.page)
    XCTAssertEqual(coordinator.errorMessage, "当前账户已变化，未打开举报页面。")
  }

  func testScopeInvalidationDuringPreflightRejectsLateURL() async throws {
    let scopeID = reportUUID(19)
    let session = reportSession(revision: reportUUID(9))
    let vault = ContentReportVaultSpy(session: session)
    let service = ContentReportServiceSpy(
      url: try reportURL(postID: 101),
      suspends: true
    )
    let presentation = ExternalWebPresentationModel()
    let coordinator = ContentReportCoordinator(
      vault: vault,
      service: service,
      presentation: presentation,
      observesAccountSessionChanges: false,
      observesPresentationChanges: false
    )
    try await waitForReportTest { coordinator.state == .ready }
    coordinator.request(try XCTUnwrap(reportTarget()), scopeID: scopeID)
    coordinator.confirmPendingRequest()
    try await waitForReportTest { await service.requestedPostIDs() == [101] }

    coordinator.invalidate(scopeID: scopeID)
    await service.release()
    try await Task.sleep(nanoseconds: 20_000_000)

    XCTAssertNil(presentation.page)
    XCTAssertTrue(coordinator.isAvailable)
  }

  func testAccountChangeDismissesPresentedReportPage() async throws {
    let session = reportSession(revision: reportUUID(5))
    let vault = ContentReportVaultSpy(session: session)
    let service = ContentReportServiceSpy(url: try reportURL(postID: 101))
    let presentation = ExternalWebPresentationModel()
    let coordinator = ContentReportCoordinator(
      vault: vault,
      service: service,
      presentation: presentation,
      observesAccountSessionChanges: false,
      observesPresentationChanges: false
    )
    try await waitForReportTest { coordinator.state == .ready }
    coordinator.request(try XCTUnwrap(reportTarget()), scopeID: reportUUID(13))
    coordinator.confirmPendingRequest()
    try await waitForReportTest { presentation.page != nil }

    coordinator.accountSessionDidChange()

    XCTAssertNil(presentation.page)
    try await waitForReportTest { coordinator.state == .ready }
  }

  func testScopeInvalidationCancelsPendingAndDismissesOnlyOwnedPage() async throws {
    let scopeID = reportUUID(15)
    let session = reportSession(revision: reportUUID(6))
    let vault = ContentReportVaultSpy(session: session)
    let service = ContentReportServiceSpy(url: try reportURL(postID: 101))
    let presentation = ExternalWebPresentationModel()
    let coordinator = ContentReportCoordinator(
      vault: vault,
      service: service,
      presentation: presentation,
      observesAccountSessionChanges: false,
      observesPresentationChanges: false
    )
    try await waitForReportTest { coordinator.state == .ready }

    coordinator.request(try XCTUnwrap(reportTarget()), scopeID: scopeID)
    coordinator.invalidate(scopeID: scopeID)
    XCTAssertNil(coordinator.pendingTarget)

    coordinator.request(try XCTUnwrap(reportTarget()), scopeID: scopeID)
    coordinator.confirmPendingRequest()
    try await waitForReportTest { presentation.page != nil }
    coordinator.invalidate(scopeID: scopeID)
    XCTAssertNil(presentation.page)

    let unrelatedURL = try XCTUnwrap(URL(string: "https://example.com/unrelated"))
    XCTAssertTrue(presentation.requestPresentation(for: unrelatedURL))
    coordinator.invalidate(scopeID: reportUUID(16))
    XCTAssertEqual(presentation.page?.url, unrelatedURL)
  }

  func testNormalBrowserDismissalRestoresReportAvailability() async throws {
    let scopeID = reportUUID(18)
    let session = reportSession(revision: reportUUID(8))
    let vault = ContentReportVaultSpy(session: session)
    let service = ContentReportServiceSpy(url: try reportURL(postID: 101))
    let presentation = ExternalWebPresentationModel()
    let coordinator = ContentReportCoordinator(
      vault: vault,
      service: service,
      presentation: presentation,
      observesAccountSessionChanges: false
    )
    try await waitForReportTest { coordinator.state == .ready }
    coordinator.request(try XCTUnwrap(reportTarget()), scopeID: scopeID)
    coordinator.confirmPendingRequest()
    try await waitForReportTest { coordinator.isPresentingReportPage }
    let pageID = try XCTUnwrap(presentation.page?.id)

    presentation.dismiss(id: pageID)

    try await waitForReportTest { coordinator.isAvailable }
    coordinator.request(try XCTUnwrap(reportTarget()), scopeID: scopeID)
    XCTAssertNotNil(coordinator.pendingTarget)
  }

  func testOccupiedBrowserDoesNotSilentlyAcceptDifferentReportPage() async throws {
    let session = reportSession(revision: reportUUID(4))
    let vault = ContentReportVaultSpy(session: session)
    let service = ContentReportServiceSpy(url: try reportURL(postID: 101))
    let presentation = ExternalWebPresentationModel()
    XCTAssertTrue(
      presentation.requestPresentation(
        for: try XCTUnwrap(URL(string: "https://example.com/already-open"))
      )
    )
    let coordinator = ContentReportCoordinator(
      vault: vault,
      service: service,
      presentation: presentation,
      observesAccountSessionChanges: false,
      observesPresentationChanges: false
    )
    try await waitForReportTest {
      coordinator.state == .ready || coordinator.state == .signedOut
    }

    XCTAssertFalse(coordinator.isAvailable)
    coordinator.request(try XCTUnwrap(reportTarget()), scopeID: reportUUID(14))
    XCTAssertNil(coordinator.pendingTarget)
    let requestedPostIDs = await service.requestedPostIDs()
    XCTAssertEqual(requestedPostIDs, [])
  }

  func testAppBoundaryRejectsAServiceURLForAnotherPost() async throws {
    let session = reportSession(revision: reportUUID(7))
    let vault = ContentReportVaultSpy(session: session)
    let service = ContentReportServiceSpy(url: try reportURL(postID: 999))
    let presentation = ExternalWebPresentationModel()
    let coordinator = ContentReportCoordinator(
      vault: vault,
      service: service,
      presentation: presentation,
      observesAccountSessionChanges: false,
      observesPresentationChanges: false
    )
    try await waitForReportTest { coordinator.state == .ready }

    coordinator.request(try XCTUnwrap(reportTarget()), scopeID: reportUUID(17))
    coordinator.confirmPendingRequest()

    try await waitForReportTest { coordinator.errorMessage != nil }
    XCTAssertNil(presentation.page)
    XCTAssertEqual(coordinator.errorMessage, "贴吧返回了无法验证的举报页面地址。")
  }

  func testBrowserAccountDisclosureIsExplicit() {
    let message = ContentReportDisclosure.confirmationMessage
    XCTAssertTrue(message.contains("Keychain"))
    XCTAssertTrue(message.contains("另一个百度账号"))
    XCTAssertTrue(message.contains("核对账号"))
    XCTAssertTrue(message.contains("提交后"))
  }
}

private actor ContentReportVaultSpy: AccountVault {
  private var session: StoredAccountSession?

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func accountSummaries() async throws -> [AccountSummary] { [] }
  func activeSession() async throws -> StoredAccountSession? { session }
  func upsert(_ session: StoredAccountSession) async throws { self.session = session }
  func switchActive(to userID: Int64) async throws {}
  func remove(userID: Int64) async throws { session = nil }
  func removeAll() async throws { session = nil }
  func setSession(_ session: StoredAccountSession?) { self.session = session }
}

private actor ContentReportServiceSpy: ContentReportService {
  private let url: URL?
  private let suspends: Bool
  private var requests = [Int64]()
  private var continuations = [CheckedContinuation<Void, Never>]()

  init(url: URL? = nil, suspends: Bool = false) {
    self.url = url
    self.suspends = suspends
  }

  func reportPageURL(postID: Int64) async throws -> URL {
    requests.append(postID)
    if suspends {
      await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
          continuations.append(continuation)
        }
      } onCancel: {
        Task { await self.release() }
      }
    }
    guard let url else { throw BrowseError.unavailable("测试服务不可用") }
    return url
  }

  func requestedPostIDs() -> [Int64] { requests }

  func release() {
    let pending = continuations
    continuations.removeAll()
    pending.forEach { $0.resume() }
  }
}

private func reportTarget() -> ContentReportTarget? {
  ContentReportTarget(thread: reportThread(), post: reportPost(id: 101, floor: 1))
}

private func reportThread() -> BrowseThread {
  BrowseThread(
    id: 100,
    forumID: 10,
    forumName: "swift",
    title: "Report target",
    excerpt: "",
    authorName: "author",
    replyCount: 2,
    viewCount: 3,
    createdAt: nil,
    lastReplyAt: nil,
    contents: [],
    firstPostID: 101
  )
}

private func reportPost(
  id: Int64,
  floor: Int,
  visibility: LocalContentVisibility = .visible
) -> BrowsePost {
  BrowsePost(
    id: id,
    threadID: 100,
    floor: floor,
    authorID: 1,
    authorName: "author",
    authorPortraitURL: nil,
    createdAt: nil,
    nestedReplyCount: 0,
    isThreadAuthor: floor == 1,
    contents: [],
    localVisibility: visibility
  )
}

private func reportComment(
  id: Int64,
  parentPostID: Int64,
  visibility: LocalContentVisibility = .visible
) -> BrowseComment {
  BrowseComment(
    id: id,
    authorID: 2,
    authorName: "commenter",
    authorPortraitURL: nil,
    createdAt: nil,
    contents: [],
    localVisibility: visibility,
    threadID: 100,
    parentPostID: parentPostID
  )
}

private func reportSession(revision: UUID) -> StoredAccountSession {
  StoredAccountSession(
    id: 42,
    username: "tester",
    displayName: "Tester",
    portrait: "",
    bduss: String(repeating: "b", count: AccountCredentialFormat.bdussLength),
    stoken: String(repeating: "s", count: AccountCredentialFormat.stokenLength),
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 1),
    sessionRevision: revision
  )
}

private func reportURL(postID: Int64) throws -> URL {
  try XCTUnwrap(
    URL(
      string:
        "https://tieba.baidu.com/tpl/wise-bawu-core/report?type=2&post_id=\(postID)&from=threadPost&noshare=1&loadingSignal=1"
    )
  )
}

private func reportUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}

@MainActor
private func waitForReportTest(
  timeoutNanoseconds: UInt64 = 2_000_000_000,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
  while !(await condition()) {
    if ContinuousClock.now >= deadline {
      XCTFail("Timed out waiting for report state")
      return
    }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
