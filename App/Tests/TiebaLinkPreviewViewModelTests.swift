import Foundation
import XCTest

@testable import TiebaPlusPlus

final class TiebaLinkPreviewViewModelTests: XCTestCase {
  func testPastedLinkPolicyEnforcesValueCountBoundary() {
    let forumURL = "https://tieba.baidu.com/f?kw=Swift"
    let acceptedValues = [forumURL] + Array(repeating: "", count: 7)

    XCTAssertEqual(
      PastedTiebaLinkPolicy.target(from: acceptedValues),
      .forum("Swift")
    )
    XCTAssertNil(
      PastedTiebaLinkPolicy.target(from: acceptedValues + [""])
    )
    XCTAssertNil(PastedTiebaLinkPolicy.target(from: []))
  }

  func testPastedLinkPolicyEnforcesTotalUTF8ByteBoundary() {
    let forumURL = "https://tieba.baidu.com/f?kw=Swift"
    let remainingByteCount =
      PastedTiebaLinkPolicy.maximumTotalUTF8ByteCount - forumURL.utf8.count
    let boundaryPadding = String(repeating: "x", count: remainingByteCount)

    XCTAssertEqual(
      PastedTiebaLinkPolicy.target(from: [forumURL, boundaryPadding]),
      .forum("Swift")
    )
    XCTAssertNil(
      PastedTiebaLinkPolicy.target(from: [forumURL, boundaryPadding + "x"])
    )
  }

  func testPastedLinkPolicyAcceptsOneUniqueTargetAndRejectsAmbiguity() {
    let forumURL = "https://tieba.baidu.com/f?kw=Swift"
    let sameForumURL = "tieba-plus-plus://forum/Swift"
    let threadURL = "https://tieba.baidu.com/p/123"

    XCTAssertEqual(
      PastedTiebaLinkPolicy.target(
        from: ["unsupported text", forumURL, sameForumURL]
      ),
      .forum("Swift")
    )
    XCTAssertNil(
      PastedTiebaLinkPolicy.target(from: [forumURL, threadURL])
    )
    XCTAssertNil(
      PastedTiebaLinkPolicy.target(from: ["unsupported text"])
    )
  }

  func testThreadFallbackPreservesOnlyAuthorAndPostLocation() {
    let route = TiebaThreadRoute(
      threadID: 456,
      onlyThreadAuthor: true,
      postID: 789
    )

    let snapshot = TiebaLinkPreviewSnapshot.fallback(target: .thread(route))

    XCTAssertEqual(snapshot.target, .thread(route))
    XCTAssertEqual(snapshot.title, "帖子 456")
    XCTAssertEqual(snapshot.subtitle, "贴吧帖子 · 只看楼主 · 定位到回复 789")
    XCTAssertFalse(snapshot.isDetailed)
  }

  @MainActor
  func testForegroundSuccessOnlyEnrichesDisplayAndPreservesIdentityAndTarget() async throws {
    let service = ScriptedTiebaLinkPreviewService()
    await service.enqueue(.suspended(1))
    let viewModel = TiebaLinkPreviewViewModel(service: service)
    let target = TiebaLinkTarget.thread(
      TiebaThreadRoute(threadID: 100, onlyThreadAuthor: true, postID: 200)
    )
    viewModel.sceneActivityDidChange(isActive: true)

    let previewID = viewModel.present(target: target)
    try await previewWaitUntil { await service.requestCount() == 1 }

    XCTAssertEqual(viewModel.preview?.id, previewID)
    XCTAssertEqual(viewModel.preview?.target, target)
    XCTAssertEqual(
      viewModel.preview?.subtitle,
      "贴吧帖子 · 只看楼主 · 定位到回复 200"
    )
    XCTAssertFalse(viewModel.preview?.isDetailed ?? true)
    assertPreviewState(viewModel.state, is: .loading)

    let didResume = await service.resume(
      id: 1,
      returning: TiebaLinkPreviewMetadata(
        title: "读取后的标题",
        subtitle: "读取后的吧名与作者"
      )
    )
    XCTAssertTrue(didResume)
    try await previewWaitUntil { viewModel.preview?.isDetailed == true }

    XCTAssertEqual(viewModel.preview?.id, previewID)
    XCTAssertEqual(viewModel.preview?.target, target)
    XCTAssertEqual(viewModel.preview?.title, "读取后的标题")
    XCTAssertEqual(viewModel.preview?.subtitle, "读取后的吧名与作者")
    assertPreviewState(viewModel.state, is: .loaded)
  }

  @MainActor
  func testFailureRetainsFallbackAndTargetCanStillBeConsumed() async throws {
    let service = ScriptedTiebaLinkPreviewService()
    await service.enqueue(.failure)
    let viewModel = TiebaLinkPreviewViewModel(service: service)
    let target = TiebaLinkTarget.forum("Swift")
    viewModel.sceneActivityDidChange(isActive: true)

    let previewID = viewModel.present(target: target)
    try await previewWaitUntil { isPreviewFailure(viewModel.state) }

    XCTAssertEqual(viewModel.preview?.id, previewID)
    XCTAssertEqual(viewModel.preview?.target, target)
    XCTAssertEqual(viewModel.preview?.title, "Swift吧")
    XCTAssertFalse(viewModel.preview?.isDetailed ?? true)
    XCTAssertEqual(
      viewModel.consumeTargetForOpening(expectedID: previewID),
      target
    )
    XCTAssertNil(viewModel.preview)
  }

  @MainActor
  func testFailureCanBeRetriedWithoutReplacingPreviewIdentity() async throws {
    let service = ScriptedTiebaLinkPreviewService()
    await service.enqueue(.failure)
    await service.enqueue(
      .value(
        TiebaLinkPreviewMetadata(
          title: "重试成功",
          subtitle: "Swift吧"
        )
      )
    )
    let viewModel = TiebaLinkPreviewViewModel(service: service)
    let target = TiebaLinkTarget.forum("Swift")
    viewModel.sceneActivityDidChange(isActive: true)

    let previewID = viewModel.present(target: target)
    try await previewWaitUntil { isPreviewFailure(viewModel.state) }
    viewModel.retry(expectedID: previewID)
    try await previewWaitUntil { viewModel.preview?.isDetailed == true }

    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [target, target])
    XCTAssertEqual(viewModel.preview?.id, previewID)
    XCTAssertEqual(viewModel.preview?.target, target)
    XCTAssertEqual(viewModel.preview?.title, "重试成功")
    assertPreviewState(viewModel.state, is: .loaded)
  }

  @MainActor
  func testUnrequestedServiceCancellationBecomesRetryableFailure() async throws {
    let service = ScriptedTiebaLinkPreviewService()
    await service.enqueue(.cancellation)
    let viewModel = TiebaLinkPreviewViewModel(service: service)
    viewModel.sceneActivityDidChange(isActive: true)

    let previewID = viewModel.present(target: .forum("Cancelled"))
    try await previewWaitUntil { isPreviewFailure(viewModel.state) }

    XCTAssertEqual(viewModel.preview?.id, previewID)
    XCTAssertEqual(viewModel.preview?.title, "Cancelled吧")
    XCTAssertFalse(viewModel.preview?.isDetailed ?? true)
  }

  @MainActor
  func testConsecutivePastesRejectUncooperativeLateFirstResponse() async throws {
    let service = ScriptedTiebaLinkPreviewService()
    await service.enqueue(.suspended(1))
    await service.enqueue(.suspended(2))
    let viewModel = TiebaLinkPreviewViewModel(service: service)
    let firstTarget = TiebaLinkTarget.forum("First")
    let secondTarget = TiebaLinkTarget.thread(TiebaThreadRoute(threadID: 222))
    viewModel.sceneActivityDidChange(isActive: true)

    _ = viewModel.present(target: firstTarget)
    try await previewWaitUntil { await service.requestCount() == 1 }
    let secondID = viewModel.present(target: secondTarget)
    try await previewWaitUntil { await service.requestCount() == 2 }

    let didResumeSecond = await service.resume(
      id: 2,
      returning: TiebaLinkPreviewMetadata(
        title: "Second detail",
        subtitle: "Second subtitle"
      )
    )
    XCTAssertTrue(didResumeSecond)
    try await previewWaitUntil { viewModel.preview?.title == "Second detail" }

    let didResumeFirst = await service.resume(
      id: 1,
      returning: TiebaLinkPreviewMetadata(
        title: "Late first detail",
        subtitle: "Must be ignored"
      )
    )
    XCTAssertTrue(didResumeFirst)
    try await previewWaitUntil { await service.completionCount() == 2 }
    await previewDrainMainActor()

    XCTAssertEqual(viewModel.preview?.id, secondID)
    XCTAssertEqual(viewModel.preview?.target, secondTarget)
    XCTAssertEqual(viewModel.preview?.title, "Second detail")
  }

  @MainActor
  func testDismissRejectsUncooperativeLateResponseWithoutRepopulation() async throws {
    let service = ScriptedTiebaLinkPreviewService()
    await service.enqueue(.suspended(1))
    let viewModel = TiebaLinkPreviewViewModel(service: service)
    viewModel.sceneActivityDidChange(isActive: true)

    let previewID = viewModel.present(target: .forum("Dismissed"))
    try await previewWaitUntil { await service.requestCount() == 1 }
    viewModel.dismiss(expectedID: previewID)

    let didResume = await service.resume(
      id: 1,
      returning: TiebaLinkPreviewMetadata(
        title: "Late detail",
        subtitle: "Must not repopulate"
      )
    )
    XCTAssertTrue(didResume)
    try await previewWaitUntil { await service.completionCount() == 1 }
    await previewDrainMainActor()

    XCTAssertNil(viewModel.preview)
    assertPreviewState(viewModel.state, is: .idle)
  }

  @MainActor
  func testBackgroundRejectsLateResponseAndForegroundStartsFreshLoad() async throws {
    let service = ScriptedTiebaLinkPreviewService()
    await service.enqueue(.suspended(1))
    await service.enqueue(.suspended(2))
    let viewModel = TiebaLinkPreviewViewModel(service: service)
    let target = TiebaLinkTarget.forum("Lifecycle")
    viewModel.sceneActivityDidChange(isActive: true)

    let previewID = viewModel.present(target: target)
    try await previewWaitUntil { await service.requestCount() == 1 }
    viewModel.sceneActivityDidChange(isActive: false)

    let didResumeBackground = await service.resume(
      id: 1,
      returning: TiebaLinkPreviewMetadata(
        title: "Background late detail",
        subtitle: "Must be ignored"
      )
    )
    XCTAssertTrue(didResumeBackground)
    try await previewWaitUntil { await service.completionCount() == 1 }
    await previewDrainMainActor()

    XCTAssertEqual(viewModel.preview?.id, previewID)
    XCTAssertEqual(viewModel.preview?.target, target)
    XCTAssertEqual(viewModel.preview?.title, "Lifecycle吧")
    XCTAssertFalse(viewModel.preview?.isDetailed ?? true)
    assertPreviewState(viewModel.state, is: .idle)

    viewModel.sceneActivityDidChange(isActive: true)
    try await previewWaitUntil { await service.requestCount() == 2 }
    let didResumeForeground = await service.resume(
      id: 2,
      returning: TiebaLinkPreviewMetadata(
        title: "Foreground detail",
        subtitle: "Fresh response"
      )
    )
    XCTAssertTrue(didResumeForeground)
    try await previewWaitUntil { viewModel.preview?.title == "Foreground detail" }

    XCTAssertEqual(viewModel.preview?.id, previewID)
    XCTAssertEqual(viewModel.preview?.target, target)
    assertPreviewState(viewModel.state, is: .loaded)
  }

  @MainActor
  func testInactivePresentationDefersRequestUntilForeground() async throws {
    let service = ScriptedTiebaLinkPreviewService()
    await service.enqueue(
      .value(
        TiebaLinkPreviewMetadata(
          title: "Foreground detail",
          subtitle: "Loaded after activation"
        )
      )
    )
    let viewModel = TiebaLinkPreviewViewModel(service: service)

    let previewID = viewModel.present(target: .forum("Deferred"))
    await previewDrainMainActor()

    XCTAssertEqual(viewModel.preview?.id, previewID)
    XCTAssertEqual(viewModel.preview?.title, "Deferred吧")
    assertPreviewState(viewModel.state, is: .idle)
    let inactiveRequestCount = await service.requestCount()
    XCTAssertEqual(inactiveRequestCount, 0)

    viewModel.sceneActivityDidChange(isActive: true)
    try await previewWaitUntil { viewModel.preview?.isDetailed == true }

    XCTAssertEqual(viewModel.preview?.id, previewID)
    XCTAssertEqual(viewModel.preview?.title, "Foreground detail")
    let activeRequestCount = await service.requestCount()
    XCTAssertEqual(activeRequestCount, 1)
  }

  @MainActor
  func testConsumeTargetIsOneShotAndClearsPresentation() {
    let service = ScriptedTiebaLinkPreviewService()
    let viewModel = TiebaLinkPreviewViewModel(service: service)
    let target = TiebaLinkTarget.thread(
      TiebaThreadRoute(threadID: 333, onlyThreadAuthor: true, postID: 444)
    )
    let previewID = viewModel.present(target: target)

    XCTAssertNil(
      viewModel.consumeTargetForOpening(expectedID: UUID())
    )
    XCTAssertEqual(viewModel.preview?.id, previewID)
    XCTAssertEqual(
      viewModel.consumeTargetForOpening(expectedID: previewID),
      target
    )
    XCTAssertNil(viewModel.consumeTargetForOpening(expectedID: previewID))
    XCTAssertNil(viewModel.preview)
    assertPreviewState(viewModel.state, is: .idle)
  }

  @MainActor
  func testStaleSheetCallbacksCannotDismissRetryOrOpenReplacement() async {
    let service = ScriptedTiebaLinkPreviewService()
    let viewModel = TiebaLinkPreviewViewModel(service: service)
    let firstID = viewModel.present(target: .forum("First"))
    let replacement = TiebaLinkTarget.user(777)
    let replacementID = viewModel.present(target: replacement)

    viewModel.retry(expectedID: firstID)
    viewModel.dismiss(expectedID: firstID)

    XCTAssertNil(viewModel.consumeTargetForOpening(expectedID: firstID))
    XCTAssertEqual(viewModel.preview?.id, replacementID)
    XCTAssertEqual(viewModel.preview?.target, replacement)
    let requests = await service.requestSnapshot()
    XCTAssertTrue(requests.isEmpty)
  }

  @MainActor
  func testUserTargetNeverRequestsPreviewMetadata() async {
    let service = ScriptedTiebaLinkPreviewService()
    let viewModel = TiebaLinkPreviewViewModel(service: service)
    let target = TiebaLinkTarget.user(555)
    viewModel.sceneActivityDidChange(isActive: true)

    let previewID = viewModel.present(target: target)
    viewModel.retry(expectedID: previewID)
    viewModel.sceneActivityDidChange(isActive: false)
    viewModel.sceneActivityDidChange(isActive: true)
    await previewDrainMainActor()

    XCTAssertEqual(viewModel.preview?.id, previewID)
    XCTAssertEqual(viewModel.preview?.target, target)
    XCTAssertEqual(viewModel.preview?.title, "用户 555")
    XCTAssertFalse(viewModel.preview?.isDetailed ?? true)
    assertPreviewState(viewModel.state, is: .loaded)
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests, [])
  }
}

private enum TiebaLinkPreviewStub: Sendable {
  case value(TiebaLinkPreviewMetadata?)
  case failure
  case cancellation
  case suspended(Int)
}

private struct TiebaLinkPreviewStubFailure: Error, Sendable {}

private actor ScriptedTiebaLinkPreviewService: TiebaLinkPreviewService {
  private var stubs: [TiebaLinkPreviewStub] = []
  private var requests: [TiebaLinkTarget] = []
  private var completedRequests = 0
  private var continuations: [
    Int: CheckedContinuation<TiebaLinkPreviewMetadata?, any Error>
  ] = [:]

  func enqueue(_ stub: TiebaLinkPreviewStub) {
    stubs.append(stub)
  }

  func preview(for target: TiebaLinkTarget) async throws -> TiebaLinkPreviewMetadata? {
    requests.append(target)
    defer { completedRequests += 1 }
    guard !stubs.isEmpty else { throw TiebaLinkPreviewStubFailure() }

    switch stubs.removeFirst() {
    case .value(let metadata):
      return metadata
    case .failure:
      throw TiebaLinkPreviewStubFailure()
    case .cancellation:
      throw CancellationError()
    case .suspended(let identifier):
      // Deliberately ignore task cancellation. Tests resume this continuation
      // later to model an uncooperative transport returning a stale response.
      return try await withCheckedThrowingContinuation { continuation in
        continuations[identifier] = continuation
      }
    }
  }

  func resume(id: Int, returning metadata: TiebaLinkPreviewMetadata?) -> Bool {
    guard let continuation = continuations.removeValue(forKey: id) else { return false }
    continuation.resume(returning: metadata)
    return true
  }

  func requestSnapshot() -> [TiebaLinkTarget] { requests }
  func requestCount() -> Int { requests.count }
  func completionCount() -> Int { completedRequests }
}

private enum ExpectedPreviewState {
  case idle
  case loading
  case loaded
}

private func assertPreviewState(
  _ state: LoadState,
  is expected: ExpectedPreviewState,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  switch (state, expected) {
  case (.idle, .idle), (.loading, .loading), (.loaded, .loaded):
    break
  default:
    XCTFail("Unexpected preview state: \(state)", file: file, line: line)
  }
}

private func isPreviewFailure(_ state: LoadState) -> Bool {
  if case .failed = state { return true }
  return false
}

private struct TiebaLinkPreviewWaitTimeout: Error {}

@MainActor
private func previewWaitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw TiebaLinkPreviewWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}

@MainActor
private func previewDrainMainActor() async {
  for _ in 0..<20 {
    await Task<Never, Never>.yield()
  }
}
