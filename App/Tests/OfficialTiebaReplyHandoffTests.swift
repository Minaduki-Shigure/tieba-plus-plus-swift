import Foundation
import SwiftUI
import XCTest

@testable import TiebaPlusPlus

final class OfficialTiebaReplyHandoffTests: XCTestCase {
  func testThreadReplyUsesCompleteTiebaLiteDispatchTemplate() throws {
    let handoff = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(destination: .thread(firstPostID: 700))
      )
    )

    XCTAssertEqual(handoff.threadID, 42)
    XCTAssertEqual(handoff.destination, .thread)
    XCTAssertFalse(handoff.isNestedReply)
    XCTAssertEqual(
      handoff.url.absoluteString,
      "com.baidu.tieba://unidispatch/pb?obj_locate=pb_reply"
        + "&obj_source=wise&obj_name=index&obj_param2=chrome&has_token=0"
        + "&qd=scheme&refer=tieba.baidu.com&wise_sample_id=3000232_2-99999_9"
        + "&fr=bpush&tid=42"
    )
    XCTAssertEqual(
      TiebaLink.target(from: handoff.url),
      .thread(TiebaThreadRoute(threadID: 42))
    )
  }

  func testFloorReplyUsesCompleteParentAnchorTemplate() throws {
    let handoff = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(destination: .post(postID: 701))
      )
    )

    XCTAssertEqual(handoff.destination, .parentPost(701))
    XCTAssertFalse(handoff.isNestedReply)
    XCTAssertEqual(
      handoff.url.absoluteString,
      "com.baidu.tieba://unidispatch/pb?obj_locate=comment_lzl_cut_guide"
        + "&obj_source=wise&obj_name=index&obj_param2=chrome&has_token=0"
        + "&qd=scheme&refer=tieba.baidu.com&wise_sample_id=3000232_2"
        + "&hightlight_anchor_pid=701&is_anchor_to_comment=1"
        + "&comment_sort_type=0&fr=bpush&tid=42"
    )
    XCTAssertEqual(
      TiebaLink.target(from: handoff.url),
      .thread(TiebaThreadRoute(threadID: 42, postID: 701))
    )
  }

  func testNestedReplyDeliberatelyDegradesToItsParentFloor() throws {
    let floor = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(destination: .post(postID: 701))
      )
    )
    let nested = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(
          destination: .subpost(parentPostID: 701, subpostID: 702)
        )
      )
    )

    XCTAssertEqual(nested.destination, .parentPost(701))
    XCTAssertTrue(nested.isNestedReply)
    XCTAssertEqual(nested.url, floor.url)
    XCTAssertFalse(nested.url.absoluteString.contains("702"))
  }

  func testDispatchContainsOnlyFixedPublicRoutingFields() throws {
    let targets = [
      try target(destination: .thread(firstPostID: 700)),
      try target(destination: .post(postID: 701)),
      try target(destination: .subpost(parentPostID: 701, subpostID: 702)),
    ]
    let forbiddenNames: Set<String> = [
      "bduss", "stoken", "tbs", "uid", "cuid", "forum_id", "kw", "content",
      "text", "subpost_id",
    ]

    for target in targets {
      let handoff = try XCTUnwrap(OfficialTiebaReplyHandoff(target: target))
      let components = try XCTUnwrap(
        URLComponents(url: handoff.url, resolvingAgainstBaseURL: false)
      )
      let queryItems = components.queryItems ?? []

      XCTAssertEqual(components.scheme, "com.baidu.tieba")
      XCTAssertEqual(components.host, "unidispatch")
      XCTAssertEqual(components.path, "/pb")
      XCTAssertNil(components.user)
      XCTAssertNil(components.password)
      XCTAssertNil(components.port)
      XCTAssertNil(components.fragment)
      XCTAssertEqual(Set(queryItems.map(\.name)).count, queryItems.count)
      XCTAssertTrue(queryItems.allSatisfy { $0.value?.isEmpty == false })
      XCTAssertTrue(
        forbiddenNames.isDisjoint(with: Set(queryItems.map(\.name)))
      )
      XCTAssertFalse(handoff.url.absoluteString.contains("secret-forum"))
      XCTAssertFalse(handoff.url.absoluteString.contains("draft-marker"))
      XCTAssertFalse(handoff.url.absoluteString.contains("credential-marker"))
    }
  }

  func testOpenGateRejectsOverlapAndStaleCompletion() throws {
    let handoff = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(destination: .thread(firstPostID: 700))
      )
    )
    let lifecycleID = uuid(1)
    let requestID = uuid(2)
    var gate = OfficialTiebaReplyHandoffOpenGate()

    let request = try XCTUnwrap(
      gate.begin(handoff: handoff, lifecycleID: lifecycleID, id: requestID)
    )
    XCTAssertTrue(gate.isOpening)
    XCTAssertEqual(gate.pendingRequest, request)
    XCTAssertNil(gate.begin(handoff: handoff, lifecycleID: lifecycleID, id: uuid(3)))

    let stale = OfficialTiebaReplyHandoffOpenRequest(
      id: requestID,
      lifecycleID: uuid(4),
      handoff: handoff
    )
    XCTAssertNil(gate.complete(stale, accepted: true))
    XCTAssertTrue(gate.isOpening)
    XCTAssertEqual(gate.complete(request, accepted: true), .accepted)
    XCTAssertFalse(gate.isOpening)
    XCTAssertNil(gate.complete(request, accepted: true))
  }

  func testOpenGateCancellationInvalidatesLateCompletion() throws {
    let handoff = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(destination: .post(postID: 701))
      )
    )
    var gate = OfficialTiebaReplyHandoffOpenGate()
    let request = try XCTUnwrap(
      gate.begin(handoff: handoff, lifecycleID: uuid(5), id: uuid(6))
    )

    gate.cancel()

    XCTAssertFalse(gate.isOpening)
    XCTAssertNil(gate.pendingRequest)
    XCTAssertNil(gate.complete(request, accepted: false))
  }

  func testLifecycleDeactivationCancelsBothLateOpenOutcomes() throws {
    let handoff = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(destination: .post(postID: 701))
      )
    )
    var lifecycle = ReplyComposerLifecycleGate()
    let lifecycleID = lifecycle.beginAppearance()
    var acceptedGate = OfficialTiebaReplyHandoffOpenGate()
    var unavailableGate = OfficialTiebaReplyHandoffOpenGate()
    let acceptedRequest = try XCTUnwrap(
      acceptedGate.begin(handoff: handoff, lifecycleID: lifecycleID, id: uuid(9))
    )
    let unavailableRequest = try XCTUnwrap(
      unavailableGate.begin(handoff: handoff, lifecycleID: lifecycleID, id: uuid(10))
    )

    XCTAssertEqual(lifecycle.scheduleDeactivation(), lifecycleID)
    acceptedGate.cancel()
    unavailableGate.cancel()

    XCTAssertFalse(lifecycle.isActive)
    XCTAssertNil(acceptedGate.complete(acceptedRequest, accepted: true))
    XCTAssertNil(unavailableGate.complete(unavailableRequest, accepted: false))
  }

  func testOpenGateMapsRejectedSystemDispatchToUnavailable() throws {
    let handoff = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(destination: .thread(firstPostID: 700))
      )
    )
    var gate = OfficialTiebaReplyHandoffOpenGate()
    let request = try XCTUnwrap(
      gate.begin(handoff: handoff, lifecycleID: uuid(7), id: uuid(8))
    )

    XCTAssertEqual(gate.complete(request, accepted: false), .unavailable)
    XCTAssertFalse(gate.isOpening)
  }

  func testDisclosureRequiresNestedReplyReselection() throws {
    let floor = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(destination: .post(postID: 701))
      )
    )
    let nested = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(
          destination: .subpost(parentPostID: 701, subpostID: 702)
        )
      )
    )

    XCTAssertFalse(
      OfficialTiebaReplyHandoffCopy.disclosureMessage(for: floor)
        .contains("重新选择具体回复")
    )
    XCTAssertTrue(
      OfficialTiebaReplyHandoffCopy.disclosureMessage(for: floor)
        .contains("本地草稿不会传递")
    )
    XCTAssertTrue(
      OfficialTiebaReplyHandoffCopy.disclosureMessage(for: nested)
        .contains("重新选择具体回复")
    )
    XCTAssertTrue(
      OfficialTiebaReplyHandoffCopy.disclosureMessage(for: nested)
        .contains("本地草稿不会传递")
    )
  }

  @MainActor
  func testSystemDispatchForwardsExactlyOneURLAndHandledOutcome() async throws {
    let handoff = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(destination: .post(postID: 701))
      )
    )
    let request = OfficialTiebaReplyHandoffOpenRequest(
      id: uuid(11),
      lifecycleID: uuid(12),
      handoff: handoff
    )
    var openedURLs: [URL] = []
    let openURL = OpenURLAction { url in
      openedURLs.append(url)
      return .handled
    }
    let completed = expectation(description: "system handoff accepted")
    var received: (OfficialTiebaReplyHandoffOpenRequest, Bool)?

    OfficialTiebaReplyHandoffSystemDispatch.open(request, using: openURL) {
      received = ($0, $1)
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: 1)

    XCTAssertEqual(openedURLs, [handoff.url])
    XCTAssertEqual(received?.0, request)
    XCTAssertEqual(received?.1, true)
  }

  @MainActor
  func testSystemDispatchMapsDiscardedActionWithoutFallbackOrRetry() async throws {
    let handoff = try XCTUnwrap(
      OfficialTiebaReplyHandoff(
        target: try target(destination: .thread(firstPostID: 700))
      )
    )
    let request = OfficialTiebaReplyHandoffOpenRequest(
      id: uuid(13),
      lifecycleID: uuid(14),
      handoff: handoff
    )
    var openedURLs: [URL] = []
    let openURL = OpenURLAction { url in
      openedURLs.append(url)
      return .discarded
    }
    let completed = expectation(description: "system handoff rejected")
    var accepted: Bool?

    OfficialTiebaReplyHandoffSystemDispatch.open(request, using: openURL) {
      accepted = $1
      completed.fulfill()
    }
    await fulfillment(of: [completed], timeout: 1)

    XCTAssertEqual(openedURLs, [handoff.url])
    XCTAssertEqual(accepted, false)
  }

  private func target(
    destination: TextReplyTarget.Destination
  ) throws -> TextReplyTarget {
    try XCTUnwrap(
      TextReplyTarget(
        forumID: 7,
        forumName: "secret-forum&content=draft-marker&bduss=credential-marker",
        threadID: 42,
        firstPostID: 700,
        destination: destination
      )
    )
  }

  private func uuid(_ byte: UInt8) -> UUID {
    UUID(
      uuid: (
        byte, 0, 0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0,
        0, 0, 0, 0
      )
    )
  }
}
