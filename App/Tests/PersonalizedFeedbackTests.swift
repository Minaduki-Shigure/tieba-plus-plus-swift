import Foundation
import SwiftUI
import TiebaCore
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class PersonalizedFeedbackTests: XCTestCase {
  func testFeedbackActionAvailabilityRequiresVisibleAccountContentWithReasons() {
    XCTAssertEqual(
      PersonalizedFeedbackActionAvailability(
        isContentVisible: true,
        usesAccountPersona: true,
        feedbackReasonCount: 1,
        isSubmitting: false
      ),
      .available
    )

    for unavailable in [
      PersonalizedFeedbackActionAvailability(
        isContentVisible: false,
        usesAccountPersona: true,
        feedbackReasonCount: 1,
        isSubmitting: false
      ),
      PersonalizedFeedbackActionAvailability(
        isContentVisible: true,
        usesAccountPersona: false,
        feedbackReasonCount: 1,
        isSubmitting: false
      ),
      PersonalizedFeedbackActionAvailability(
        isContentVisible: true,
        usesAccountPersona: true,
        feedbackReasonCount: 0,
        isSubmitting: false
      ),
    ] {
      XCTAssertEqual(unavailable, .unavailable)
      XCTAssertNil(unavailable.presentation)
    }
  }

  func testFeedbackActionRemainsVisibleButDisabledWhileSubmitting() {
    let available = PersonalizedFeedbackActionAvailability(
      isContentVisible: true,
      usesAccountPersona: true,
      feedbackReasonCount: 2,
      isSubmitting: false
    )
    let submitting = PersonalizedFeedbackActionAvailability(
      isContentVisible: true,
      usesAccountPersona: true,
      feedbackReasonCount: 2,
      isSubmitting: true
    )

    XCTAssertEqual(
      available.presentation,
      PersonalizedFeedbackActionPresentation(
        title: "不感兴趣",
        systemImage: "hand.thumbsdown",
        accessibilityLabel: "减少此类推荐",
        isEnabled: true
      )
    )
    XCTAssertEqual(
      submitting.presentation,
      PersonalizedFeedbackActionPresentation(
        title: "提交中",
        systemImage: "hourglass",
        accessibilityLabel: "正在提交推荐反馈",
        isEnabled: false
      )
    )
  }

  @MainActor
  func testFeedbackFooterStaysWithinTheRowWidth() {
    let widths: [CGFloat] = [320, 390, 768]
    for width in widths {
      let host = UIHostingController(
        rootView: PersonalizedFeedbackFooter(
          threadID: 42,
          state: .available,
          action: {}
        )
        .environment(\.dynamicTypeSize, .large)
      )

      let size = host.sizeThatFits(in: CGSize(width: width, height: 1_000))

      XCTAssertLessThanOrEqual(size.width, width + 0.5)
      XCTAssertEqual(size.height, 44, accuracy: 0.5)
    }
  }

  func testSubmissionBindsReasonsToTheCurrentThreadAndPreservesServerOrder() throws {
    let item = feedbackItem()
    let submission = try XCTUnwrap(
      PersonalizedFeedbackSubmission(
        item: item,
        selectedReasonIDs: [7, 2],
        clickTimeMilliseconds: 1_723_456_789_012
      )
    )

    XCTAssertEqual(submission.threadID, 123)
    XCTAssertEqual(submission.forumID, 42)
    XCTAssertEqual(submission.reasons.map(\.id), [2, 7])
    XCTAssertEqual(submission.reasons.map(\.extra), ["opaque-a", "opaque-b"])
    XCTAssertEqual(submission.clickTimeMilliseconds, 1_723_456_789_012)

    XCTAssertNil(
      PersonalizedFeedbackSubmission(
        item: item,
        selectedReasonIDs: [],
        clickTimeMilliseconds: 1
      )
    )
    XCTAssertNil(
      PersonalizedFeedbackSubmission(
        item: item,
        selectedReasonIDs: [999],
        clickTimeMilliseconds: 1
      )
    )
    XCTAssertNil(
      PersonalizedFeedbackSubmission(
        item: item,
        selectedReasonIDs: [2],
        clickTimeMilliseconds: 0
      )
    )
  }

  func testCoreServiceRequiresFullCredentialsAndForwardsBoundOpaqueReasons() async throws {
    let client = PersonalizedFeedbackClientSpy()
    let service = TiebaCorePersonalizedFeedbackService(client: client)
    let submission = try XCTUnwrap(
      PersonalizedFeedbackSubmission(
        item: feedbackItem(),
        selectedReasonIDs: [2, 7],
        clickTimeMilliseconds: 1_723_456_789_012
      )
    )

    try await service.submitPersonalizedFeedback(
      session: session(),
      submission: submission
    )
    let snapshot = await client.snapshot()
    XCTAssertEqual(snapshot.requests.count, 1)
    let request = try XCTUnwrap(snapshot.requests.first)
    XCTAssertEqual(request.expectedUserID, 7)
    XCTAssertEqual(request.bdussBytes, 192)
    XCTAssertEqual(request.stokenBytes, 64)
    XCTAssertEqual(request.cookieName, .bdussBFESS)
    XCTAssertEqual(request.submission.threadID, 123)
    XCTAssertEqual(request.submission.forumID, 42)
    XCTAssertEqual(request.submission.reasonIDs, [2, 7])
    XCTAssertEqual(request.submission.reasonExtras, ["opaque-a", "opaque-b"])
    XCTAssertEqual(request.submission.clickTimeMilliseconds, 1_723_456_789_012)

    do {
      try await service.submitPersonalizedFeedback(
        session: session(stoken: nil),
        submission: submission
      )
      XCTFail("Expected legacy credentials to be rejected")
    } catch let error as PersonalizedFeedbackSubmissionError {
      XCTAssertEqual(error, .fullCredentialsRequired)
    }
    let finalSnapshot = await client.snapshot()
    XCTAssertEqual(finalSnapshot.requests.count, 1)
  }

  func testCoreServiceSeparatesUnknownOutcomeFromKnownSanitizedFailure() async throws {
    let submission = try XCTUnwrap(
      PersonalizedFeedbackSubmission(
        item: feedbackItem(),
        selectedReasonIDs: [2],
        clickTimeMilliseconds: 1
      )
    )
    let unknownService = TiebaCorePersonalizedFeedbackService(
      client: PersonalizedFeedbackClientSpy(error: .personalizedFeedbackOutcomeUnknown)
    )
    do {
      try await unknownService.submitPersonalizedFeedback(
        session: session(),
        submission: submission
      )
      XCTFail("Expected an unknown feedback outcome")
    } catch let error as PersonalizedFeedbackSubmissionError {
      XCTAssertEqual(error, .outcomeUnknown)
    }

    let secret = "server leaked stoken=" + String(repeating: "s", count: 64)
    let rejectedService = TiebaCorePersonalizedFeedbackService(
      client: PersonalizedFeedbackClientSpy(error: .server(code: 340_006, message: secret))
    )
    do {
      try await rejectedService.submitPersonalizedFeedback(
        session: session(),
        submission: submission
      )
      XCTFail("Expected a sanitized server rejection")
    } catch let error as PersonalizedFeedbackSubmissionError {
      XCTAssertEqual(error, .unavailable("账户请求失败（错误码 340006）。"))
      XCTAssertFalse(error.localizedDescription.contains(secret))
    }
  }

  private func feedbackItem() -> PersonalizedFeedItem {
    PersonalizedFeedItem(
      thread: BrowseThread(
        id: 123,
        forumID: 42,
        forumName: "swift",
        title: "Thread",
        excerpt: "Excerpt",
        authorName: "Author",
        replyCount: 3,
        viewCount: 10,
        createdAt: nil,
        lastReplyAt: nil,
        contents: [.text("Content")]
      ),
      feedbackReasons: [
        PersonalizedFeedbackReason(id: 2, title: "Reason A", extra: "opaque-a"),
        PersonalizedFeedbackReason(id: 7, title: "Reason B", extra: "opaque-b"),
        PersonalizedFeedbackReason(id: 2, title: "Duplicate", extra: "wrong"),
      ]
    )
  }

  private func session(stoken: String? = String(repeating: "s", count: 64))
    -> StoredAccountSession
  {
    StoredAccountSession(
      id: 7,
      username: "account",
      displayName: "Account",
      portrait: "portrait",
      bduss: String(repeating: "b", count: 192),
      stoken: stoken,
      bdussCookieName: .bdussBFESS,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1),
      sessionRevision: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    )
  }
}

private struct PersonalizedFeedbackClientRequest: Sendable {
  let expectedUserID: Int64
  let bdussBytes: Int
  let stokenBytes: Int
  let cookieName: TiebaBDUSSCookieName
  let submission: TiebaPersonalizedFeedbackSubmission
}

private actor PersonalizedFeedbackClientSpy: TiebaPersonalizedFeedbackClient {
  struct Snapshot: Sendable {
    let requests: [PersonalizedFeedbackClientRequest]
  }

  private let error: TiebaClientError?
  private var requests: [PersonalizedFeedbackClientRequest] = []

  init(error: TiebaClientError? = nil) {
    self.error = error
  }

  func submitPersonalizedFeedback(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaPersonalizedFeedbackSubmission
  ) async throws {
    requests.append(
      PersonalizedFeedbackClientRequest(
        expectedUserID: expectedUserID,
        bdussBytes: credential.bduss.utf8.count,
        stokenBytes: credential.stoken.utf8.count,
        cookieName: credential.bdussCookieName,
        submission: submission
      )
    )
    if let error { throw error }
  }

  func snapshot() -> Snapshot {
    Snapshot(requests: requests)
  }
}
