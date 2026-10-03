import Foundation
import SwiftProtobuf
import TiebaProto
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaOwnedContentDeletionTests: XCTestCase, @unchecked Sendable {
  private let userID: Int64 = 7_001
  private let forumID: Int64 = 8_001
  private let forumName = "swift"
  private let threadID: Int64 = 9_001
  private let firstPostID: Int64 = 10_001
  private let postID: Int64 = 10_002
  private let tbs = "0123456789abcdef0123456789"

  func testRequestFactoryUsesExactSelfOwnedThreadDeletionContract() throws {
    let request = try factory().deleteOwnedContent(
      credential: credential().bdussCredential,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .thread(firstPostID: firstPostID),
      tbs: tbs
    )
    let fields = try formFields(request)

    assertCommonWriteRequest(request, path: "/c/c/bawu/delthread")
    XCTAssertEqual(
      Set(fields.keys),
      [
        "BDUSS", "_client_version", "delete_my_thread", "fid", "is_frs_mask",
        "is_vipdel", "sign", "src", "tbs", "word", "z",
      ]
    )
    XCTAssertEqual(fields["BDUSS"], credential().bduss)
    XCTAssertEqual(fields["_client_version"], "12.41.7.1")
    XCTAssertEqual(fields["fid"], String(forumID))
    XCTAssertEqual(fields["word"], forumName)
    XCTAssertEqual(fields["z"], String(threadID))
    XCTAssertEqual(fields["tbs"], tbs)
    XCTAssertEqual(fields["src"], "1")
    XCTAssertEqual(fields["is_vipdel"], "0")
    XCTAssertEqual(fields["delete_my_thread"], "1")
    XCTAssertEqual(fields["is_frs_mask"], "0")
    XCTAssertEqual(fields["sign"], "c264f7b660f12e6068894b3feeeef47a")
    XCTAssertEqual(fields["sign"], signature(for: fields))
    XCTAssertNil(fields["pid"])
    XCTAssertNil(fields["delete_my_post"])
    XCTAssertNil(fields["stoken"])
  }

  func testRequestFactoryUsesExactSelfOwnedPostDeletionContract() throws {
    let request = try factory().deleteOwnedContent(
      credential: credential().bdussCredential,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .post(postID: postID),
      tbs: tbs
    )
    let fields = try formFields(request)

    assertCommonWriteRequest(request, path: "/c/c/bawu/delpost")
    XCTAssertEqual(
      Set(fields.keys),
      [
        "BDUSS", "_client_version", "delete_my_post", "fid", "is_vipdel", "isfloor",
        "pid", "sign", "src", "tbs", "word", "z",
      ]
    )
    XCTAssertEqual(fields["BDUSS"], credential().bduss)
    XCTAssertEqual(fields["_client_version"], "12.41.7.1")
    XCTAssertEqual(fields["fid"], String(forumID))
    XCTAssertEqual(fields["word"], forumName)
    XCTAssertEqual(fields["z"], String(threadID))
    XCTAssertEqual(fields["pid"], String(postID))
    XCTAssertEqual(fields["isfloor"], "0")
    XCTAssertEqual(fields["src"], "1")
    XCTAssertEqual(fields["is_vipdel"], "0")
    XCTAssertEqual(fields["delete_my_post"], "1")
    XCTAssertEqual(fields["tbs"], tbs)
    XCTAssertEqual(fields["sign"], "e5500175a3fec819b14dfc9daeb8c1e5")
    XCTAssertEqual(fields["sign"], signature(for: fields))
    XCTAssertNil(fields["delete_my_thread"])
    XCTAssertNil(fields["is_frs_mask"])
    XCTAssertNil(fields["stoken"])
  }

  func testThreadOwnerDeletionUsesTheOrdinaryPostManagementContract() throws {
    let request = try factory().deleteOwnedContent(
      credential: credential().bdussCredential,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: managedPostTarget,
      tbs: tbs
    )
    let fields = try formFields(request)

    assertCommonWriteRequest(request, path: "/c/c/bawu/delpost")
    XCTAssertEqual(Set(fields.keys), [
      "BDUSS", "_client_version", "delete_my_post", "fid", "is_vipdel", "isfloor",
      "pid", "sign", "src", "tbs", "word", "z",
    ])
    XCTAssertEqual(fields["fid"], String(forumID))
    XCTAssertEqual(fields["word"], forumName)
    XCTAssertEqual(fields["z"], String(threadID))
    XCTAssertEqual(fields["pid"], String(postID))
    XCTAssertEqual(fields["isfloor"], "0")
    XCTAssertEqual(fields["src"], "1")
    XCTAssertEqual(fields["is_vipdel"], "1")
    XCTAssertEqual(fields["delete_my_post"], "0")
    XCTAssertEqual(fields["tbs"], tbs)
    XCTAssertEqual(fields["sign"], signature(for: fields))
  }

  func testInvalidThreadOwnerTargetsFailBeforeAnyNetworkRequest() async throws {
    let targets: [TiebaOwnedContentDeletionTarget] = [
      .postInOwnedThread(postID: 0, postAuthorID: userID + 1, floor: 2),
      .postInOwnedThread(postID: -1, postAuthorID: userID + 1, floor: 2),
      .postInOwnedThread(postID: postID, postAuthorID: 0, floor: 2),
      .postInOwnedThread(postID: postID, postAuthorID: -1, floor: 2),
      .postInOwnedThread(postID: postID, postAuthorID: userID, floor: 2),
      .postInOwnedThread(postID: postID, postAuthorID: userID + 1, floor: 1),
      .postInOwnedThread(postID: postID, postAuthorID: userID + 1, floor: 0),
      .postInOwnedThread(postID: postID, postAuthorID: userID + 1, floor: -1),
    ]
    let transport = OwnedContentDeletionTransport(steps: [])
    let client = TiebaAuthenticatedClient(transport: transport)
    for target in targets {
      XCTAssertThrowsError(
        try factory().deleteOwnedContent(
          credential: credential().bdussCredential,
          expectedUserID: userID,
          forumID: forumID,
          forumName: forumName,
          threadID: threadID,
          target: target,
          tbs: tbs
        )
      )
      await assertError(.invalidArgument("Invalid thread-owner deletion target.")) {
        _ = try await self.deletePost(using: client, target: target)
      }
    }
    let snapshot = await transport.snapshot()
    XCTAssertTrue(snapshot.paths.isEmpty)
  }

  func testThreadOwnerPreflightBindsBothAuthorsAndTheExactOrdinaryFloor() throws {
    let context = try deletionContext(managedPostResponse(), target: managedPostTarget)
    XCTAssertEqual(context.userID, userID)
    XCTAssertEqual(context.target, managedPostTarget)
    XCTAssertEqual(context.tbs, tbs)
    // A located page may omit the first floor. In that case, verified thread metadata
    // provides authority; if the first floor is present it must agree with that metadata.
    var noFirstFloor = managedPostResponse()
    noFirstFloor.data.clearFirstFloorPost()
    XCTAssertNoThrow(try deletionContext(noFirstFloor, target: managedPostTarget))
    // Adding a management mode must not broaden the existing self-deletion contract.
    assertInvalidPreflight(managedPostResponse(), target: .post(postID: postID))

    for (_, response) in invalidManagedPostResponses() {
      assertInvalidPreflight(response, target: managedPostTarget)
    }
    assertInvalidPreflight(
      managedPostResponse(),
      target: .postInOwnedThread(postID: firstPostID, postAuthorID: userID + 1, floor: 2)
    )
    assertInvalidPreflight(
      managedPostResponse(),
      target: .postInOwnedThread(postID: postID, postAuthorID: userID + 1, floor: 3)
    )
  }

  func testUnverifiedThreadOwnerContextNeverDispatchesDeletion() async throws {
    for (name, response) in invalidManagedPostResponses() {
      let transport = OwnedContentDeletionTransport(steps: [
        .response(try response.serializedData())
      ])
      let client = TiebaAuthenticatedClient(transport: transport)
      await assertError(.invalidAuthenticatedResponse) {
        _ = try await self.deletePost(using: client, target: self.managedPostTarget)
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.paths, ["/c/f/pb/page"], name)
    }
  }

  func testThreadOwnerDeletionReturnsAnExactReceiptAndDoesNotReplayAcceptedTargets()
    async throws
  {
    let transport = OwnedContentDeletionTransport(steps: [
      .response(try managedPostResponse().serializedData()),
      .response(Data(#"{"error_code":0}"#.utf8)),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    let receipt = try await deletePost(using: client, target: managedPostTarget)
    XCTAssertEqual(receipt.userID, userID)
    XCTAssertEqual(receipt.forumID, forumID)
    XCTAssertEqual(receipt.threadID, threadID)
    XCTAssertEqual(receipt.target, managedPostTarget)
    let repeated = try await deletePost(using: client, target: managedPostTarget)
    XCTAssertEqual(repeated, receipt)

    for target in conflictingManagedPostTargets {
      await assertError(.ownedContentDeletionWriteConflict) {
        _ = try await self.deletePost(using: client, target: target)
      }
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])
    let write = try XCTUnwrap(snapshot.requests.last)
    let fields = try formFields(write)
    XCTAssertEqual(fields["pid"], String(postID))
    XCTAssertEqual(fields["is_vipdel"], "1")
    XCTAssertEqual(fields["delete_my_post"], "0")
  }

  func testThreadOwnerConcurrentMetadataConflictsCannotJoinOrReplayTheWrite() async throws {
    let transport = OwnedContentDeletionTransport(
      steps: [
        .response(try managedPostResponse().serializedData()),
        .response(Data(#"{"error_code":0}"#.utf8)),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task { try await self.deletePost(using: client, target: self.managedPostTarget) }
    guard await transport.waitUntilRequestCount(2) else {
      await transport.releaseBlockedRequest()
      first.cancel()
      _ = await first.result
      return XCTFail("Thread-owner deletion write did not dispatch")
    }
    for target in conflictingManagedPostTargets {
      await assertError(.ownedContentDeletionWriteConflict) {
        _ = try await self.deletePost(using: client, target: target)
      }
    }
    let equivalent = Task {
      try await self.deletePost(using: client, target: self.managedPostTarget)
    }
    await transport.releaseBlockedRequest()
    let receipt = try await first.value
    let repeated = try await equivalent.value
    XCTAssertEqual(receipt, repeated)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])
  }

  func testUnknownDeletionLocksTheSamePostAcrossOwnershipModesAndMetadata() async throws {
    for initialTarget in [managedPostTarget, .post(postID: postID)] {
      let response = initialTarget == managedPostTarget ? managedPostResponse() : pageResponse()
      let transport = OwnedContentDeletionTransport(steps: [
        .response(try response.serializedData()),
        .failure(.transportFailure),
      ])
      let client = TiebaAuthenticatedClient(transport: transport)
      await assertError(.ownedContentDeletionOutcomeUnknown) {
        _ = try await self.deletePost(using: client, target: initialTarget)
      }
      for target in [managedPostTarget] + conflictingManagedPostTargets {
        await assertError(.ownedContentDeletionOutcomeUnknown) {
          _ = try await self.deletePost(using: client, target: target)
        }
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])
    }
  }

  func testAcceptedSelfDeletionCannotBeReplayedAsThreadOwnerDeletion() async throws {
    let transport = OwnedContentDeletionTransport(steps: [
      .response(try pageResponse().serializedData()),
      .response(Data(#"{"error_code":0}"#.utf8)),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    _ = try await deletePost(using: client)
    await assertError(.ownedContentDeletionWriteConflict) {
      _ = try await self.deletePost(using: client, target: self.managedPostTarget)
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])
  }

  func testRequestFactoryRejectsUnboundIdentifiersAndMalformedTBS() throws {
    let factory = factory()
    XCTAssertThrowsError(
      try factory.deleteOwnedContent(
        credential: credential().bdussCredential,
        expectedUserID: 0,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: .post(postID: postID),
        tbs: tbs
      )
    )
    XCTAssertThrowsError(
      try factory.deleteOwnedContent(
        credential: credential().bdussCredential,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: .post(postID: 0),
        tbs: tbs
      )
    )
    XCTAssertThrowsError(
      try factory.deleteOwnedContent(
        credential: credential().bdussCredential,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: .thread(firstPostID: 0),
        tbs: tbs
      )
    )
    for malformedTBS in ["", "short", String(repeating: "A", count: 26)] {
      XCTAssertThrowsError(
        try factory.deleteOwnedContent(
          credential: credential().bdussCredential,
          expectedUserID: userID,
          forumID: forumID,
          forumName: forumName,
          threadID: threadID,
          target: .post(postID: postID),
          tbs: malformedTBS
        )
      )
    }
  }

  func testPreflightAcceptsOnlyTheSignedInAuthorsOwnTarget() throws {
    let response = pageResponse()
    let thread = try deletionContext(response, target: .thread(firstPostID: firstPostID))
    XCTAssertEqual(thread.userID, userID)
    XCTAssertEqual(thread.forumID, forumID)
    XCTAssertEqual(thread.threadID, threadID)
    XCTAssertEqual(thread.target, .thread(firstPostID: firstPostID))
    XCTAssertEqual(thread.tbs, tbs)

    let post = try deletionContext(response, target: .post(postID: postID))
    XCTAssertEqual(post.target, .post(postID: postID))

    var wrongThreadAuthor = response
    wrongThreadAuthor.data.thread.authorID = userID + 1
    assertInvalidPreflight(
      wrongThreadAuthor,
      target: .thread(firstPostID: firstPostID)
    )

    var wrongFirstPostAuthor = response
    wrongFirstPostAuthor.data.firstFloorPost.authorID = userID + 1
    assertInvalidPreflight(
      wrongFirstPostAuthor,
      target: .thread(firstPostID: firstPostID)
    )

    var wrongPostAuthor = response
    wrongPostAuthor.data.postList[0].authorID = userID + 1
    assertInvalidPreflight(wrongPostAuthor, target: .post(postID: postID))

    var mismatchedDeclaredAndEmbeddedAuthor = response
    mismatchedDeclaredAndEmbeddedAuthor.data.postList[0].author.id = userID + 1
    assertInvalidPreflight(
      mismatchedDeclaredAndEmbeddedAuthor,
      target: .post(postID: postID)
    )
  }

  func testClientStopsBeforeWriteWhenPreflightAuthorDoesNotMatch() async throws {
    var response = pageResponse()
    response.data.postList[0].authorID = userID + 1
    response.data.postList[0].author.id = userID + 1
    let transport = OwnedContentDeletionTransport(steps: [
      .response(try response.serializedData()),
    ])

    await assertError(.invalidAuthenticatedResponse) {
      _ = try await TiebaAuthenticatedClient(transport: transport).deleteOwnedContent(
        credential: self.credential(),
        expectedUserID: self.userID,
        forumID: self.forumID,
        forumName: self.forumName,
        threadID: self.threadID,
        target: .post(postID: self.postID)
      )
    }

    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page"])
    XCTAssertEqual(snapshot.maximumBodyBytes, [
      TiebaAuthenticatedClient.agreementPageResponseMaximumBytes
    ])
  }

  func testDeletionAcknowledgementClassifiesSuccessRejectionAndMalformedBodies() throws {
    for body in [
      #"{"error_code":0}"#,
      #"{"errno":"0"}"#,
      #"{"error":{"errno":0}}"#,
    ] {
      XCTAssertNoThrow(
        try TiebaAuthenticatedDecoder.checkOwnedContentDeletionAcknowledgement(
          from: Data(body.utf8)
        )
      )
    }

    XCTAssertThrowsError(
      try TiebaAuthenticatedDecoder.checkOwnedContentDeletionAcknowledgement(
        from: Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .server(code: 340_006, message: "denied"))
    }

    for body in [#"{}"#, #"[]"#, #"{"error_code":false}"#, #"{"error_code":0.5}"#] {
      XCTAssertThrowsError(
        try TiebaAuthenticatedDecoder.checkOwnedContentDeletionAcknowledgement(
          from: Data(body.utf8)
        )
      ) { error in
        XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
      }
    }
  }

  func testClientPreservesExplicitRejectionAndMapsUnverifiableACKToUnknown() async throws {
    let preflight = try pageResponse().serializedData()
    let rejectionTransport = OwnedContentDeletionTransport(steps: [
      .response(preflight),
      .response(Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)),
    ])
    await assertError(.server(code: 340_006, message: "denied")) {
      _ = try await self.deletePost(using: rejectionTransport)
    }
    let rejectionSnapshot = await rejectionTransport.snapshot()
    XCTAssertEqual(
      rejectionSnapshot.paths,
      ["/c/f/pb/page", "/c/c/bawu/delpost"]
    )

    for step in [
      OwnedContentDeletionStep.response(Data(#"{}"#.utf8)),
      .failure(.transportFailure),
    ] {
      let transport = OwnedContentDeletionTransport(steps: [.response(preflight), step])
      await assertError(.ownedContentDeletionOutcomeUnknown) {
        _ = try await self.deletePost(using: transport)
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])
      XCTAssertEqual(snapshot.paths.filter { $0 == "/c/c/bawu/delpost" }.count, 1)
    }
  }

  func testClientReturnsBoundReceiptAfterOneVerifiedWrite() async throws {
    let transport = OwnedContentDeletionTransport(steps: [
      .response(try pageResponse().serializedData()),
      .response(Data(#"{"error_code":0}"#.utf8)),
    ])
    let receipt = try await deletePost(using: transport)

    XCTAssertEqual(receipt.userID, userID)
    XCTAssertEqual(receipt.forumID, forumID)
    XCTAssertEqual(receipt.threadID, threadID)
    XCTAssertEqual(receipt.target, .post(postID: postID))
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])
    XCTAssertEqual(snapshot.maximumBodyBytes, [
      TiebaAuthenticatedClient.agreementPageResponseMaximumBytes,
      TiebaAuthenticatedClient.ownedContentDeletionWriteResponseMaximumBytes,
    ])
  }

  func testEquivalentConcurrentCallsShareOnePreflightAndWrite() async throws {
    let transport = OwnedContentDeletionTransport(
      steps: [
        .response(try pageResponse().serializedData()),
        .response(Data(#"{"error_code":0}"#.utf8)),
      ],
      blockedRequestIndex: 1
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task { try await self.deletePost(using: client) }
    let second = Task { try await self.deletePost(using: client) }

    guard await transport.waitUntilRequestCount(2) else {
      await transport.releaseBlockedRequest()
      first.cancel()
      second.cancel()
      _ = await first.result
      _ = await second.result
      return XCTFail("Deletion write did not dispatch")
    }
    await transport.releaseBlockedRequest()

    let firstReceipt = try await first.value
    let secondReceipt = try await second.value
    XCTAssertEqual(firstReceipt, secondReceipt)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])
  }

  func testUnknownTerminalPreventsAnyLaterRequestForTheSameTarget() async throws {
    let transport = OwnedContentDeletionTransport(steps: [
      .response(try pageResponse().serializedData()),
      .response(Data(#"{}"#.utf8)),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.ownedContentDeletionOutcomeUnknown) {
      _ = try await self.deletePost(using: client)
    }
    let firstSnapshot = await transport.snapshot()
    XCTAssertEqual(firstSnapshot.paths, ["/c/f/pb/page", "/c/c/bawu/delpost"])

    await assertError(.ownedContentDeletionOutcomeUnknown) {
      _ = try await client.deleteOwnedContent(
        credential: TiebaSessionCredential(
          bduss: String(repeating: "c", count: 192),
          stoken: String(repeating: "t", count: 64),
          bdussCookieName: .bdussBFESS
        ),
        expectedUserID: self.userID,
        forumID: self.forumID,
        forumName: self.forumName,
        threadID: self.threadID,
        target: .post(postID: self.postID)
      )
    }
    let secondSnapshot = await transport.snapshot()
    XCTAssertEqual(secondSnapshot.paths, firstSnapshot.paths)
    XCTAssertEqual(secondSnapshot.maximumBodyBytes, firstSnapshot.maximumBodyBytes)
  }

  func testExplicitServerRejectionDoesNotCreateTerminalAndCanPreflightAgain() async throws {
    let preflight = try pageResponse().serializedData()
    let transport = OwnedContentDeletionTransport(steps: [
      .response(preflight),
      .response(Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)),
      .response(preflight),
      .response(Data(#"{"error_code":0}"#.utf8)),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)

    await assertError(.server(code: 340_006, message: "denied")) {
      _ = try await self.deletePost(using: client)
    }
    let receipt = try await deletePost(using: client)

    XCTAssertEqual(receipt.target, .post(postID: postID))
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, [
      "/c/f/pb/page", "/c/c/bawu/delpost",
      "/c/f/pb/page", "/c/c/bawu/delpost",
    ])
  }

  func testNestedReplyRequestsFollowTheActualTiebaLiteChildPIDContract() throws {
    for (target, management) in [(subpostTarget, false), (managedSubpostTarget, true)] {
      let request = try factory().deleteOwnedContent(
        credential: credential().bdussCredential,
        expectedUserID: userID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: target,
        tbs: tbs
      )
      let fields = try formFields(request)
      assertCommonWriteRequest(request, path: "/c/c/bawu/delpost")
      XCTAssertEqual(
        Set(fields.keys),
        [
          "BDUSS", "_client_version", "delete_my_post", "fid", "is_vipdel", "isfloor",
          "pid", "sign", "src", "tbs", "word", "z",
        ])
      XCTAssertEqual(fields["pid"], String(subpostID))
      XCTAssertEqual(fields["fid"], String(forumID))
      XCTAssertEqual(fields["z"], String(threadID))
      XCTAssertEqual(fields["word"], forumName)
      XCTAssertEqual(fields["isfloor"], "0")
      XCTAssertEqual(fields["src"], "1")
      XCTAssertEqual(fields["is_vipdel"], management ? "1" : "0")
      XCTAssertEqual(fields["delete_my_post"], management ? "0" : "1")
      XCTAssertEqual(fields["tbs"], tbs)
      XCTAssertEqual(fields["sign"], signature(for: fields))
    }
  }

  func testMalformedNestedTargetsDoNotReadOrWrite() async throws {
    let targets: [TiebaOwnedContentDeletionTarget] = [
      .subpost(parentPostID: 0, subpostID: subpostID),
      .subpost(parentPostID: -1, subpostID: subpostID),
      .subpost(parentPostID: postID, subpostID: 0),
      .subpost(parentPostID: postID, subpostID: -1),
      .subpost(parentPostID: postID, subpostID: postID),
      .subpostInOwnedThread(
        parentPostID: 0, subpostID: subpostID, subpostAuthorID: userID + 1, floor: 2),
      .subpostInOwnedThread(
        parentPostID: postID, subpostID: 0, subpostAuthorID: userID + 1, floor: 2),
      .subpostInOwnedThread(
        parentPostID: postID, subpostID: postID, subpostAuthorID: userID + 1, floor: 2),
      .subpostInOwnedThread(
        parentPostID: postID, subpostID: subpostID, subpostAuthorID: 0, floor: 2),
      .subpostInOwnedThread(
        parentPostID: postID, subpostID: subpostID, subpostAuthorID: -1, floor: 2),
      .subpostInOwnedThread(
        parentPostID: postID, subpostID: subpostID, subpostAuthorID: userID, floor: 2),
      .subpostInOwnedThread(
        parentPostID: postID, subpostID: subpostID, subpostAuthorID: userID + 1, floor: 0),
      .subpostInOwnedThread(
        parentPostID: postID, subpostID: subpostID, subpostAuthorID: userID + 1, floor: -1),
    ]
    let transport = OwnedContentDeletionTransport(steps: [])
    let client = TiebaAuthenticatedClient(transport: transport)
    for target in targets {
      do {
        _ = try await deletePost(using: client, target: target)
        XCTFail("Expected malformed nested-reply target to fail")
      } catch TiebaClientError.invalidArgument {
      } catch {
        XCTFail("Unexpected error: \(error)")
      }
    }
    let snapshot = await transport.snapshot()
    XCTAssertTrue(snapshot.paths.isEmpty)
  }

  func testSelfNestedDeletionBindsTheChildNotTheParentOrThreadAuthor() async throws {
    for parentIsFirstFloor in [false, true] {
      var page = nestedParentResponse()
      page.data.thread.authorID = userID + 9
      page.data.thread.author.id = userID + 9
      page.data.firstFloorPost.authorID = userID + 9
      page.data.firstFloorPost.author.id = userID + 9
      let parentID = parentIsFirstFloor ? firstPostID : postID
      let target = TiebaOwnedContentDeletionTarget.subpost(
        parentPostID: parentID, subpostID: subpostID
      )
      let floor = nestedFloorResponse(parent: page, parentIsFirstFloor: parentIsFirstFloor)
      let transport = OwnedContentDeletionTransport(steps: [
        .response(try page.serializedData()),
        .response(try floor.serializedData()),
        .response(Data(#"{"error_code":0}"#.utf8)),
      ])
      let receipt = try await deletePost(
        using: TiebaAuthenticatedClient(transport: transport), target: target
      )
      XCTAssertEqual(receipt.target, target)
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/f/pb/floor", "/c/c/bawu/delpost"])
      let pageRead = try PbPageReqIdl(
        serializedBytes: deletionProtobufPayload(from: XCTUnwrap(snapshot.requests.first))
      )
      XCTAssertEqual(pageRead.data.pid, parentID)
      XCTAssertEqual(pageRead.data.withFloor, 0)
      XCTAssertEqual(pageRead.data.common.bduss, credential().bduss)
      let floorRead = try PbFloorReqIdl(
        serializedBytes: deletionProtobufPayload(from: snapshot.requests[1])
      )
      XCTAssertEqual(floorRead.data.kz, threadID)
      XCTAssertEqual(floorRead.data.pid, parentID)
      XCTAssertEqual(floorRead.data.spid, subpostID)
      XCTAssertEqual(floorRead.data.forumID, forumID)
      XCTAssertEqual(floorRead.data.common.bduss, credential().bduss)
      XCTAssertEqual(try formFields(snapshot.requests[2])["pid"], String(subpostID))
      XCTAssertEqual(
        snapshot.maximumBodyBytes,
        [
          TiebaAuthenticatedClient.agreementPageResponseMaximumBytes,
          TiebaAuthenticatedClient.subpostAgreementPageResponseMaximumBytes,
          TiebaAuthenticatedClient.ownedContentDeletionWriteResponseMaximumBytes,
        ])
    }
  }

  func testThreadOwnerCanDeleteNestedReplyInFirstOrAnotherAuthorsFloor() async throws {
    for parentIsFirstFloor in [false, true] {
      let page = nestedParentResponse()
      let target = TiebaOwnedContentDeletionTarget.subpostInOwnedThread(
        parentPostID: parentIsFirstFloor ? firstPostID : postID,
        subpostID: subpostID,
        subpostAuthorID: userID + 1,
        floor: parentIsFirstFloor ? 1 : 2
      )
      let transport = OwnedContentDeletionTransport(steps: [
        .response(try page.serializedData()),
        .response(
          try nestedFloorResponse(
            parent: page, management: true, parentIsFirstFloor: parentIsFirstFloor
          ).serializedData()),
        .response(Data(#"{"error_code":0}"#.utf8)),
      ])
      let receipt = try await deletePost(
        using: TiebaAuthenticatedClient(transport: transport), target: target
      )
      XCTAssertEqual(receipt.target, target)
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.paths.count, 3)
      XCTAssertEqual(try formFields(XCTUnwrap(snapshot.requests.last))["is_vipdel"], "1")
      XCTAssertEqual(try formFields(XCTUnwrap(snapshot.requests.last))["delete_my_post"], "0")
    }
  }

  func testUnverifiedNestedParentContextNeverRequestsChildOrDispatchesWrite() async throws {
    for (name, page) in invalidNestedParentResponses() {
      for target in [subpostTarget, managedSubpostTarget] {
        let transport = OwnedContentDeletionTransport(steps: [.response(try page.serializedData())])
        await assertError(.invalidAuthenticatedResponse) {
          _ = try await self.deletePost(
            using: TiebaAuthenticatedClient(transport: transport), target: target
          )
        }
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.paths, ["/c/f/pb/page"], name)
      }
    }
  }

  func testParentAuthorDoesNotGrantThreadOwnerAuthority() async throws {
    var page = nestedParentResponse()
    page.data.thread.authorID = userID + 9
    page.data.thread.author.id = userID + 9
    page.data.firstFloorPost.authorID = userID + 9
    page.data.firstFloorPost.author.id = userID + 9
    page.data.postList[0].authorID = userID
    page.data.postList[0].author.id = userID
    let transport = OwnedContentDeletionTransport(steps: [.response(try page.serializedData())])
    await assertError(.invalidAuthenticatedResponse) {
      _ = try await self.deletePost(
        using: TiebaAuthenticatedClient(transport: transport), target: self.managedSubpostTarget
      )
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page"])
  }

  func testManagedNestedDeletionRejectsChangedParentFloorAndChildMasqueradingAsFirstFloor()
    async throws
  {
    for target in [
      TiebaOwnedContentDeletionTarget.subpostInOwnedThread(
        parentPostID: postID, subpostID: subpostID, subpostAuthorID: userID + 1, floor: 3
      ),
      .subpost(parentPostID: postID, subpostID: firstPostID),
      .subpostInOwnedThread(
        parentPostID: postID, subpostID: firstPostID, subpostAuthorID: userID + 1, floor: 2
      ),
    ] {
      let transport = OwnedContentDeletionTransport(steps: [
        .response(try nestedParentResponse().serializedData())
      ])
      await assertError(.invalidAuthenticatedResponse) {
        _ = try await self.deletePost(
          using: TiebaAuthenticatedClient(transport: transport), target: target
        )
      }
      let snapshot = await transport.snapshot()
      XCTAssertEqual(snapshot.paths, ["/c/f/pb/page"])
    }
  }

  func testNestedChildPreflightRejectsMissingAmbiguousOrChangedIdentitiesBeforeWrite() async throws
  {
    for management in [false, true] {
      let target = management ? managedSubpostTarget : subpostTarget
      for (name, floor) in invalidNestedFloorResponses(management: management) {
        let transport = OwnedContentDeletionTransport(steps: [
          .response(try nestedParentResponse().serializedData()),
          .response(try floor.serializedData()),
        ])
        await assertError(.invalidAuthenticatedResponse) {
          _ = try await self.deletePost(
            using: TiebaAuthenticatedClient(transport: transport), target: target
          )
        }
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/f/pb/floor"], name)
      }
    }
  }

  func testNestedIdentityAllowsConsistentSingleAuthorRepresentationAndMissingOptionalTBS()
    throws
  {
    var page = nestedParentResponse()
    page.data.clearFirstFloorPost()
    page.data.thread.clearAuthor()
    page.data.postList[0].clearAuthor()
    let parent = try nestedParentContext(page, target: subpostTarget)
    var floor = nestedFloorResponse(parent: page)
    floor.data.clearAnti()
    floor.data.subpostList[0].authorID = 0
    let context = try TiebaAuthenticatedDecoder.ownedSubpostDeletionContext(
      from: floor, parent: parent)
    XCTAssertEqual(context.tbs, tbs)
    XCTAssertEqual(context.target, subpostTarget)
    floor.data.subpostList[0].authorID = userID
    floor.data.subpostList[0].clearAuthor()
    XCTAssertNoThrow(
      try TiebaAuthenticatedDecoder.ownedSubpostDeletionContext(from: floor, parent: parent))
  }

  func testNestedDeletionUsesFreshExactChildTBSWhenProvided() async throws {
    var floor = nestedFloorResponse()
    let freshTBS = "abcdef0123456789abcdef0123"
    floor.data.anti.tbs = freshTBS
    let transport = OwnedContentDeletionTransport(steps: [
      .response(try nestedParentResponse().serializedData()),
      .response(try floor.serializedData()),
      .response(Data(#"{"error_code":0}"#.utf8)),
    ])
    _ = try await deletePost(
      using: TiebaAuthenticatedClient(transport: transport), target: subpostTarget)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(try formFields(XCTUnwrap(snapshot.requests.last))["tbs"], freshTBS)
  }

  func testNestedFloorCanOmitRepeatedParentMetadataWithoutWeakeningChildOwnership() throws {
    for management in [false, true] {
      let target = management ? managedSubpostTarget : subpostTarget
      let parent = try nestedParentContext(nestedParentResponse(), target: target)
      var floor = nestedFloorResponse(management: management)
      floor.data.thread.firstPostID = 0
      floor.data.thread.authorID = 0
      floor.data.thread.clearAuthor()
      floor.data.post.authorID = 0
      floor.data.post.clearAuthor()
      let context = try TiebaAuthenticatedDecoder.ownedSubpostDeletionContext(from: floor, parent: parent)
      XCTAssertEqual(context.target, target)
      floor.data.subpostList[0].authorID = 0
      floor.data.subpostList[0].clearAuthor()
      XCTAssertThrowsError(try TiebaAuthenticatedDecoder.ownedSubpostDeletionContext(from: floor, parent: parent))
    }
  }

  func testUnknownNestedWriteCannotBeResentThroughChangedParentModeOrPostKind() async throws {
    for initialTarget in [subpostTarget, managedSubpostTarget] {
      for finalStep in [
        OwnedContentDeletionStep.failure(.transportFailure),
        .response(Data(#"{}"#.utf8)),
      ] {
        let transport = OwnedContentDeletionTransport(steps: [
          .response(try nestedParentResponse().serializedData()),
          .response(
            try nestedFloorResponse(management: initialTarget == managedSubpostTarget)
              .serializedData()),
          finalStep,
        ])
        let client = TiebaAuthenticatedClient(transport: transport)
        await assertError(.ownedContentDeletionOutcomeUnknown) {
          _ = try await self.deletePost(using: client, target: initialTarget)
        }
        for target in conflictingSubpostTargets + [subpostTarget, managedSubpostTarget] {
          await assertError(.ownedContentDeletionOutcomeUnknown) {
            _ = try await self.deletePost(using: client, target: target)
          }
        }
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/f/pb/floor", "/c/c/bawu/delpost"])
      }
    }
  }

  func testAcceptedNestedWriteReturnsReceiptWithoutResendAndRejectsRetargeting() async throws {
    let transport = OwnedContentDeletionTransport(steps: [
      .response(try nestedParentResponse().serializedData()),
      .response(try nestedFloorResponse().serializedData()),
      .response(Data(#"{"error_code":0}"#.utf8)),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    let receipt = try await deletePost(using: client, target: subpostTarget)
    let repeated = try await deletePost(using: client, target: subpostTarget)
    XCTAssertEqual(receipt, repeated)
    XCTAssertEqual(receipt.target, subpostTarget)
    for target in conflictingSubpostTargets + [managedSubpostTarget] {
      await assertError(.ownedContentDeletionWriteConflict) {
        _ = try await self.deletePost(using: client, target: target)
      }
    }
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/f/pb/floor", "/c/c/bawu/delpost"])
  }

  func testEquivalentConcurrentNestedCallsCoalesceAndMetadataChangesConflict() async throws {
    let transport = OwnedContentDeletionTransport(
      steps: [
        .response(try nestedParentResponse().serializedData()),
        .response(try nestedFloorResponse().serializedData()),
        .response(Data(#"{"error_code":0}"#.utf8)),
      ],
      blockedRequestIndex: 2
    )
    let client = TiebaAuthenticatedClient(transport: transport)
    let first = Task { try await self.deletePost(using: client, target: self.subpostTarget) }
    guard await transport.waitUntilRequestCount(3) else {
      await transport.releaseBlockedRequest()
      first.cancel()
      _ = await first.result
      return XCTFail("Nested deletion write did not dispatch")
    }
    let second = Task { try await self.deletePost(using: client, target: self.subpostTarget) }
    for target in conflictingSubpostTargets + [managedSubpostTarget] {
      await assertError(.ownedContentDeletionWriteConflict) {
        _ = try await self.deletePost(using: client, target: target)
      }
    }
    await transport.releaseBlockedRequest()
    let firstReceipt = try await first.value
    let secondReceipt = try await second.value
    XCTAssertEqual(firstReceipt, secondReceipt)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(snapshot.paths, ["/c/f/pb/page", "/c/f/pb/floor", "/c/c/bawu/delpost"])
  }

  func testNestedReadFailureRemainsRetryableWithoutBeingClassifiedAsDispatched() async throws {
    let page = try nestedParentResponse().serializedData()
    let transport = OwnedContentDeletionTransport(steps: [
      .response(page), .failure(.transportFailure),
      .response(page), .response(try nestedFloorResponse().serializedData()),
      .response(Data(#"{"error_code":0}"#.utf8)),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    await assertError(.transportFailure) {
      _ = try await self.deletePost(using: client, target: self.subpostTarget)
    }
    _ = try await deletePost(using: client, target: subpostTarget)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.paths,
      [
        "/c/f/pb/page", "/c/f/pb/floor",
        "/c/f/pb/page", "/c/f/pb/floor", "/c/c/bawu/delpost",
      ])
  }

  func testNestedExplicitWriteRejectionPreservesServerErrorAndRequiresFreshPreflightOnRetry()
    async throws
  {
    let page = try nestedParentResponse().serializedData()
    let floor = try nestedFloorResponse().serializedData()
    let transport = OwnedContentDeletionTransport(steps: [
      .response(page), .response(floor),
      .response(Data(#"{"error_code":340006,"error_msg":"denied"}"#.utf8)),
      .response(page), .response(floor), .response(Data(#"{"error_code":0}"#.utf8)),
    ])
    let client = TiebaAuthenticatedClient(transport: transport)
    await assertError(.server(code: 340_006, message: "denied")) {
      _ = try await self.deletePost(using: client, target: self.subpostTarget)
    }
    _ = try await deletePost(using: client, target: subpostTarget)
    let snapshot = await transport.snapshot()
    XCTAssertEqual(
      snapshot.paths,
      [
        "/c/f/pb/page", "/c/f/pb/floor", "/c/c/bawu/delpost",
        "/c/f/pb/page", "/c/f/pb/floor", "/c/c/bawu/delpost",
      ])
  }

  private var subpostID: Int64 { 10_003 }

  private var subpostTarget: TiebaOwnedContentDeletionTarget {
    .subpost(parentPostID: postID, subpostID: subpostID)
  }

  private var managedSubpostTarget: TiebaOwnedContentDeletionTarget {
    .subpostInOwnedThread(
      parentPostID: postID, subpostID: subpostID, subpostAuthorID: userID + 1, floor: 2
    )
  }

  private var conflictingSubpostTargets: [TiebaOwnedContentDeletionTarget] {
    [
      .subpost(parentPostID: firstPostID, subpostID: subpostID),
      .subpostInOwnedThread(
        parentPostID: firstPostID, subpostID: subpostID, subpostAuthorID: userID + 1, floor: 1
      ),
      .subpostInOwnedThread(
        parentPostID: postID, subpostID: subpostID, subpostAuthorID: userID + 2, floor: 2
      ),
      .subpostInOwnedThread(
        parentPostID: postID, subpostID: subpostID, subpostAuthorID: userID + 1, floor: 3
      ),
      .post(postID: subpostID),
      .postInOwnedThread(postID: subpostID, postAuthorID: userID + 1, floor: 2),
    ]
  }

  private func nestedParentResponse() -> PbPageResIdl {
    var page = pageResponse()
    page.data.postList[0].authorID = userID + 5
    page.data.postList[0].author.id = userID + 5
    return page
  }

  private func nestedFloorResponse(
    parent: PbPageResIdl? = nil,
    management: Bool = false,
    parentIsFirstFloor: Bool = false
  ) -> PbFloorResIdl {
    let page = parent ?? nestedParentResponse()
    var response = PbFloorResIdl()
    response.data.forum = page.data.forum
    response.data.thread = page.data.thread
    response.data.post = parentIsFirstFloor ? page.data.firstFloorPost : page.data.postList[0]
    response.data.page = page.data.page
    response.data.anti = page.data.anti
    var subpost = SubPostList()
    subpost.id = subpostID
    subpost.authorID = management ? userID + 1 : userID
    subpost.author.id = subpost.authorID
    subpost.floor = 1
    response.data.subpostList = [subpost]
    return response
  }

  private func nestedParentContext(
    _ response: PbPageResIdl,
    target: TiebaOwnedContentDeletionTarget
  ) throws -> TiebaSubpostDeletionParentContext {
    try TiebaAuthenticatedDecoder.subpostDeletionParentContext(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: target
    )
  }

  private func invalidNestedParentResponses() -> [(String, PbPageResIdl)] {
    let mutations: [(String, (inout PbPageResIdl) -> Void)] = [
      ("missing data", { $0.clearData() }),
      ("missing actor", { $0.data.clearUser() }),
      ("signed out", { $0.data.user.isLogin = 0 }),
      ("wrong actor", { $0.data.user.id = self.userID + 1 }),
      ("missing forum", { $0.data.clearForum() }),
      ("wrong forum", { $0.data.forum.id += 1 }),
      ("wrong forum name", { $0.data.forum.name = "other" }),
      ("missing thread", { $0.data.clearThread() }),
      ("wrong thread", { $0.data.thread.id += 1 }),
      ("wrong thread forum", { $0.data.thread.fid += 1 }),
      ("missing first PID", { $0.data.thread.firstPostID = 0 }),
      ("child masquerading as first PID", { $0.data.thread.firstPostID = self.subpostID }),
      ("conflicting thread author", { $0.data.thread.author.id += 1 }),
      (
        "unknown thread author",
        {
          $0.data.thread.authorID = 0
          $0.data.thread.clearAuthor()
        }
      ),
      (
        "wrong first post author",
        {
          $0.data.firstFloorPost.authorID += 1
          $0.data.firstFloorPost.author.id += 1
        }
      ),
      ("conflicting first post author", { $0.data.firstFloorPost.author.id += 1 }),
      (
        "invalid first record identity",
        {
          $0.data.firstFloorPost.id += 10
          $0.data.firstFloorPost.floor = 2
        }
      ),
      ("wrong first post thread", { $0.data.firstFloorPost.tid += 1 }),
      ("missing parent", { $0.data.postList = [] }),
      ("wrong parent", { $0.data.postList[0].id += 10 }),
      ("duplicate parent", { $0.data.postList.append($0.data.postList[0]) }),
      (
        "conflicting first post duplicate",
        {
          var duplicate = $0.data.firstFloorPost
          duplicate.author.id += 1
          $0.data.postList.append(duplicate)
        }
      ),
      ("wrong parent thread", { $0.data.postList[0].tid += 1 }),
      ("conflicting parent author", { $0.data.postList[0].author.id += 1 }),
      (
        "unknown parent author",
        {
          $0.data.postList[0].authorID = 0
          $0.data.postList[0].clearAuthor()
        }
      ),
      ("parent pretending first floor", { $0.data.postList[0].floor = 1 }),
      ("invalid parent floor", { $0.data.postList[0].floor = 0 }),
      (
        "child is an ordinary floor",
        {
          var ordinary = $0.data.postList[0]
          ordinary.id = self.subpostID
          ordinary.floor = 3
          $0.data.postList.append(ordinary)
        }
      ),
      ("missing page", { $0.data.clearPage() }),
      ("missing anti", { $0.data.clearAnti() }),
      ("invalid TBS", { $0.data.anti.tbs = "invalid" }),
    ]
    return mutations.map { name, mutation in
      var page = nestedParentResponse()
      mutation(&page)
      return (name, page)
    }
  }

  private func invalidNestedFloorResponses(management: Bool) -> [(String, PbFloorResIdl)] {
    let mutations: [(String, (inout PbFloorResIdl) -> Void)] = [
      ("missing data", { $0.clearData() }),
      ("missing forum", { $0.data.clearForum() }),
      ("wrong forum", { $0.data.forum.id += 1 }),
      ("wrong forum name", { $0.data.forum.name = "other" }),
      ("missing thread", { $0.data.clearThread() }),
      ("wrong thread", { $0.data.thread.id += 1 }),
      ("wrong thread forum", { $0.data.thread.fid += 1 }),
      ("wrong first PID", { $0.data.thread.firstPostID += 10 }),
      (
        "changed thread author",
        {
          $0.data.thread.authorID += 10
          $0.data.thread.author.id += 10
        }
      ),
      ("conflicting thread author", { $0.data.thread.author.id += 1 }),
      ("missing parent", { $0.data.clearPost() }),
      ("wrong parent", { $0.data.post.id += 10 }),
      ("wrong parent thread", { $0.data.post.tid += 1 }),
      ("changed parent floor", { $0.data.post.floor += 1 }),
      (
        "changed parent author",
        {
          $0.data.post.authorID += 10
          $0.data.post.author.id += 10
        }
      ),
      ("conflicting parent author", { $0.data.post.author.id += 1 }),
      ("missing page", { $0.data.clearPage() }),
      ("invalid TBS", { $0.data.anti.tbs = "invalid" }),
      ("missing child", { $0.data.subpostList = [] }),
      ("different child", { $0.data.subpostList[0].id += 10 }),
      ("duplicate child", { $0.data.subpostList.append($0.data.subpostList[0]) }),
      (
        "conflicting duplicate child",
        {
          var duplicate = $0.data.subpostList[0]
          duplicate.authorID += 10
          duplicate.author.id += 10
          $0.data.subpostList.append(duplicate)
        }
      ),
      ("parent masquerading as child", { $0.data.subpostList[0].id = self.postID }),
      ("first floor masquerading as child", { $0.data.subpostList[0].id = self.firstPostID }),
      (
        "changed child author",
        {
          $0.data.subpostList[0].authorID += 10
          $0.data.subpostList[0].author.id += 10
        }
      ),
      ("conflicting child author", { $0.data.subpostList[0].author.id += 1 }),
      (
        "unknown child author",
        {
          $0.data.subpostList[0].authorID = 0
          $0.data.subpostList[0].clearAuthor()
        }
      ),
      ("negative child author", { $0.data.subpostList[0].authorID = -1 }),
    ]
    return mutations.map { name, mutation in
      var floor = nestedFloorResponse(management: management)
      mutation(&floor)
      return (name, floor)
    }
  }

  private func deletionProtobufPayload(from request: URLRequest) throws -> Data {
    let body = try XCTUnwrap(request.httpBody)
    let prefix = Data(
      "---*_r1999\r\nContent-Disposition: form-data; name=\"data\"; filename=\"file\"\r\n\r\n".utf8
    )
    let suffix = Data("\r\n---*_r1999--\r\n".utf8)
    XCTAssertTrue(body.starts(with: prefix))
    XCTAssertTrue(body.suffix(suffix.count) == suffix)
    guard body.count >= prefix.count + suffix.count else { throw TiebaClientError.transportFailure }
    return body.subdata(in: prefix.count..<(body.count - suffix.count))
  }

  private func factory() -> TiebaAuthenticatedRequestFactory {
    TiebaAuthenticatedRequestFactory(configuration: .init())
  }

  private func credential() -> TiebaSessionCredential {
    TiebaSessionCredential(
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bduss
    )
  }

  private func pageResponse() -> PbPageResIdl {
    var signedInUser = User()
    signedInUser.isLogin = 1
    signedInUser.id = userID

    var author = User()
    author.id = userID

    var forum = SimpleForum()
    forum.id = forumID
    forum.name = forumName

    var thread = ThreadInfo()
    thread.id = threadID
    thread.fid = forumID
    thread.firstPostID = firstPostID
    thread.authorID = userID
    thread.author = author

    var firstPost = Post()
    firstPost.id = firstPostID
    firstPost.tid = threadID
    firstPost.floor = 1
    firstPost.authorID = userID
    firstPost.author = author

    var post = Post()
    post.id = postID
    post.tid = threadID
    post.floor = 2
    post.authorID = userID
    post.author = author

    var page = Page()
    page.pageSize = 2
    page.currentPage = 1
    page.totalPage = 1
    page.totalCount = 2

    var anti = Anti()
    anti.tbs = tbs

    var data = PbPageResIdl.DataRes()
    data.user = signedInUser
    data.forum = forum
    data.thread = thread
    data.firstFloorPost = firstPost
    data.postList = [post]
    data.page = page
    data.anti = anti

    var response = PbPageResIdl()
    response.data = data
    return response
  }

  private var managedPostTarget: TiebaOwnedContentDeletionTarget {
    .postInOwnedThread(postID: postID, postAuthorID: userID + 1, floor: 2)
  }

  private var conflictingManagedPostTargets: [TiebaOwnedContentDeletionTarget] {
    [
      .post(postID: postID),
      .postInOwnedThread(postID: postID, postAuthorID: userID + 2, floor: 2),
      .postInOwnedThread(postID: postID, postAuthorID: userID + 1, floor: 3),
    ]
  }

  private func managedPostResponse() -> PbPageResIdl {
    var response = pageResponse()
    response.data.postList[0].authorID = userID + 1
    response.data.postList[0].author.id = userID + 1
    return response
  }

  private func invalidManagedPostResponses() -> [(String, PbPageResIdl)] {
    let mutations: [(String, (inout PbPageResIdl) -> Void)] = [
      ("signed out", { $0.data.user.isLogin = 0 }),
      ("different actor", { $0.data.user.id = self.userID + 1 }),
      ("different forum", { $0.data.forum.id = self.forumID + 1 }),
      ("different forum name", { $0.data.forum.name = "different" }),
      ("different thread", { $0.data.thread.id = self.threadID + 1 }),
      ("different thread forum", { $0.data.thread.fid = self.forumID + 1 }),
      ("missing first post ID", { $0.data.thread.firstPostID = 0 }),
      ("target is first post", { $0.data.thread.firstPostID = self.postID }),
      ("different first floor ID", { $0.data.firstFloorPost.id = self.firstPostID + 2 }),
      ("invalid first floor number", { $0.data.firstFloorPost.floor = 2 }),
      ("different first floor thread", { $0.data.firstFloorPost.tid = self.threadID + 1 }),
      ("different first floor author", {
        $0.data.firstFloorPost.authorID = self.userID + 1
        $0.data.firstFloorPost.author.id = self.userID + 1
      }),
      ("conflicting first floor author", { $0.data.firstFloorPost.author.id = self.userID + 1 }),
      ("conflicting loaded first floor", {
        var firstPost = $0.data.firstFloorPost
        $0.data.clearFirstFloorPost()
        firstPost.authorID = self.userID + 1
        firstPost.author.id = self.userID + 1
        $0.data.postList.append(firstPost)
      }),
      ("noncanonical loaded first floor ID", {
        var firstPost = $0.data.firstFloorPost
        $0.data.clearFirstFloorPost()
        firstPost.id = self.firstPostID + 2
        $0.data.postList.append(firstPost)
      }),
      ("noncanonical loaded first floor number", {
        var firstPost = $0.data.firstFloorPost
        $0.data.clearFirstFloorPost()
        firstPost.floor = 2
        $0.data.postList.append(firstPost)
      }),
      ("different thread author", {
        $0.data.thread.authorID = self.userID + 1
        $0.data.thread.author.id = self.userID + 1
      }),
      ("conflicting thread author", { $0.data.thread.author.id = self.userID + 1 }),
      ("unknown thread author", {
        $0.data.thread.authorID = 0
        $0.data.thread.author.id = 0
      }),
      ("different post ID", { $0.data.postList[0].id = self.postID + 1 }),
      ("different post thread", { $0.data.postList[0].tid = self.threadID + 1 }),
      ("different post author", {
        $0.data.postList[0].authorID = self.userID + 2
        $0.data.postList[0].author.id = self.userID + 2
      }),
      ("conflicting post author", { $0.data.postList[0].author.id = self.userID + 2 }),
      ("unknown post author", {
        $0.data.postList[0].authorID = 0
        $0.data.postList[0].author.id = 0
      }),
      ("different floor", { $0.data.postList[0].floor = 3 }),
      ("first floor disguised as reply", { $0.data.postList[0].floor = 1 }),
      ("duplicate target post", { $0.data.postList.append($0.data.postList[0]) }),
      ("missing target post", { $0.data.postList = [] }),
      ("invalid TBS", { $0.data.anti.tbs = "invalid" }),
    ]
    return mutations.map { name, mutation in
      var response = managedPostResponse()
      mutation(&response)
      return (name, response)
    }
  }

  private func deletionContext(
    _ response: PbPageResIdl,
    target: TiebaOwnedContentDeletionTarget
  ) throws -> TiebaOwnedContentDeletionContext {
    try TiebaAuthenticatedDecoder.ownedContentDeletionContext(
      from: response,
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: target
    )
  }

  private func assertInvalidPreflight(
    _ response: PbPageResIdl,
    target: TiebaOwnedContentDeletionTarget,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertThrowsError(
      try deletionContext(response, target: target),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(
        error as? TiebaClientError,
        .invalidAuthenticatedResponse,
        file: file,
        line: line
      )
    }
  }

  private func assertCommonWriteRequest(
    _ request: URLRequest,
    path: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    XCTAssertEqual(request.url?.scheme, "https", file: file, line: line)
    XCTAssertEqual(request.url?.host, "tiebac.baidu.com", file: file, line: line)
    XCTAssertEqual(request.url?.path, path, file: file, line: line)
    XCTAssertEqual(request.httpMethod, "POST", file: file, line: line)
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData, file: file, line: line)
    XCTAssertFalse(request.httpShouldHandleCookies, file: file, line: line)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "User-Agent"),
      "bdtb for Android 12.41.7.1",
      file: file,
      line: line
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "ka=open", file: file, line: line)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded",
      file: file,
      line: line
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Accept"),
      "application/json",
      file: file,
      line: line
    )
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Accept-Encoding"),
      "gzip",
      file: file,
      line: line
    )
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), file: file, line: line)
    XCTAssertNil(request.value(forHTTPHeaderField: "client_user_token"), file: file, line: line)
  }

  private func signature(for fields: [String: String]) -> String {
    TiebaFormSigner.signature(
      for: fields.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
    )
  }

  private func formFields(_ request: URLRequest) throws -> [String: String] {
    let body = try XCTUnwrap(request.httpBody)
    var components = URLComponents()
    components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
      .replacingOccurrences(of: "+", with: "%20")
    let items = try XCTUnwrap(components.queryItems)
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
  }

  private func deletePost(
    using transport: OwnedContentDeletionTransport
  ) async throws -> TiebaOwnedContentDeletionReceipt {
    try await deletePost(using: TiebaAuthenticatedClient(transport: transport))
  }

  private func deletePost(
    using client: TiebaAuthenticatedClient,
    target: TiebaOwnedContentDeletionTarget? = nil
  ) async throws -> TiebaOwnedContentDeletionReceipt {
    try await client.deleteOwnedContent(
      credential: credential(),
      expectedUserID: userID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: target ?? .post(postID: postID)
    )
  }

  private func assertError(
    _ expected: TiebaClientError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected TiebaClientError")
    } catch let error as TiebaClientError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private enum OwnedContentDeletionStep: Sendable {
  case response(Data)
  case failure(TiebaClientError)
}

private struct OwnedContentDeletionTransportSnapshot: Sendable {
  let paths: [String]
  let maximumBodyBytes: [Int?]
  let requests: [URLRequest]
}

private actor OwnedContentDeletionTransport: TiebaTransport {
  private var steps: [OwnedContentDeletionStep]
  private var paths = [String]()
  private var maximumBodyBytes = [Int?]()
  private var requests = [URLRequest]()
  private let blockedRequestIndex: Int?
  private var blockedRequestContinuation: CheckedContinuation<Void, Never>?
  private var isBlockedRequestReleased = false

  init(
    steps: [OwnedContentDeletionStep],
    blockedRequestIndex: Int? = nil
  ) {
    self.steps = steps
    self.blockedRequestIndex = blockedRequestIndex
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    try await send(request, maximumBodyBytes: nil)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    let requestIndex = paths.count
    paths.append(request.url?.path ?? "")
    requests.append(request)
    self.maximumBodyBytes.append(maximumBodyBytes)
    if let blockedRequestIndex,
      requestIndex == blockedRequestIndex,
      !isBlockedRequestReleased
    {
      await withCheckedContinuation { continuation in
        blockedRequestContinuation = continuation
      }
    }
    guard !steps.isEmpty else { throw TiebaClientError.transportFailure }
    switch steps.removeFirst() {
    case .response(let body):
      return TiebaHTTPResponse(body: body, statusCode: 200)
    case .failure(let error):
      throw error
    }
  }

  func waitUntilRequestCount(
    _ expected: Int,
    timeout: Duration = .seconds(2)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
      if paths.count >= expected { return true }
      try? await Task.sleep(for: .milliseconds(1))
    }
    return false
  }

  func releaseBlockedRequest() {
    isBlockedRequestReleased = true
    blockedRequestContinuation?.resume()
    blockedRequestContinuation = nil
  }

  func snapshot() -> OwnedContentDeletionTransportSnapshot {
    OwnedContentDeletionTransportSnapshot(
      paths: paths,
      maximumBodyBytes: maximumBodyBytes,
      requests: requests
    )
  }
}
