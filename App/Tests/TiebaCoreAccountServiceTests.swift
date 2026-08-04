import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class TiebaCoreAccountServiceTests: XCTestCase {
  func testValidationAndMembershipMapCoreResponsesWithoutChangingAccountIdentity() async throws {
    let client = AccountClientSpy(
      validation: TiebaAuthenticatedAccount(
        userID: 7,
        username: "validated-user",
        portrait: "portrait-token"
      ),
      membership: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    )
    let service = TiebaCoreAccountService(client: client)

    let account = try await service.validate(
      credential: AccountCredentials(
        bduss: String(repeating: "b", count: 192),
        stoken: String(repeating: "s", count: 64),
        bdussCookieName: .bdussBFESS
      )
    )
    let membership = try await service.forumMembership(
      session: session(),
      forumID: 42,
      forumName: "swift"
    )

    XCTAssertEqual(account.userID, 7)
    XCTAssertEqual(account.username, "validated-user")
    XCTAssertEqual(account.portrait, "portrait-token")
    XCTAssertEqual(
      membership,
      ForumMembershipData(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    )
    let snapshot = await client.snapshot()
    XCTAssertEqual(
      snapshot.validationSessionShapes,
      [SessionCredentialShape(bdussBytes: 192, stokenBytes: 64, cookieName: .bdussBFESS)]
    )
    XCTAssertEqual(
      snapshot.membershipRequests,
      [
        AccountClientRequest(
          credentialByteCount: 192,
          expectedUserID: 7,
          forumID: 42,
          forumName: "swift",
          desiredState: nil
        )
      ]
    )
  }

  func testCloudFavoritesRequireFullCredentialsAndMapServerMetadata() async throws {
    let coreFavorite = TiebaCloudFavorite(
      id: 123,
      title: "A stored thread",
      forumName: "swift",
      author: TiebaCloudFavoriteAuthor(
        userID: 8,
        username: "author",
        displayName: "Author",
        portrait: "portrait"
      ),
      isDeleted: false,
      lastTimestamp: 1_700_000_000,
      threadType: 0,
      status: 0,
      maximumPostID: 999,
      minimumPostID: 100,
      markedPostID: 456,
      markStatus: 1,
      postNumber: 88,
      postNumberMessage: "88",
      updateCount: 3
    )
    let client = AccountClientSpy(
      cloudFavorites: TiebaCloudFavoritePage(
        requestedUserID: 7,
        favorites: [coreFavorite],
        offset: 30,
        pageSize: 30,
        hasMore: true
      )
    )
    let service = TiebaCoreAccountService(client: client)

    let page = try await service.cloudFavorites(
      session: session(),
      offset: 30,
      pageSize: 30
    )

    XCTAssertEqual(page.userID, 7)
    XCTAssertEqual(page.nextOffset, 60)
    XCTAssertTrue(page.hasMore)
    let item = try XCTUnwrap(page.items.first)
    XCTAssertEqual(item.id, 123)
    XCTAssertEqual(item.authorName, "Author")
    XCTAssertEqual(item.markPostID, 456)
    XCTAssertEqual(item.latestPostID, 999)
    XCTAssertEqual(item.latestFloor, 88)
    XCTAssertTrue(item.hasUpdates)
    XCTAssertEqual(item.updatedAt, Date(timeIntervalSince1970: 1_700_000_000))
    let snapshot = await client.snapshot()
    let requests = snapshot.cloudFavoriteRequests
    XCTAssertEqual(
      requests,
      [
        CloudFavoriteClientRequest(
          userID: 7,
          offset: 30,
          pageSize: 30,
          bdussBytes: 192,
          stokenBytes: 64,
          cookieName: .bduss
        )
      ]
    )
  }

  func testLegacySessionCannotStartCloudFavoritesRequest() async throws {
    let client = AccountClientSpy()
    let service = TiebaCoreAccountService(client: client)
    let legacySession = session(stokenComponent: nil)

    do {
      _ = try await service.cloudFavorites(
        session: legacySession,
        offset: 0,
        pageSize: 30
      )
      XCTFail("Expected a re-login requirement")
    } catch let error as BrowseError {
      XCTAssertEqual(error.errorDescription, "此账户需要重新登录，才能安全读取贴吧收藏。")
    }
    let snapshot = await client.snapshot()
    let requests = snapshot.cloudFavoriteRequests
    XCTAssertTrue(requests.isEmpty)
  }

  func testForumAccountStateMapsCheckInWithoutExposingCredentials() async throws {
    let client = AccountClientSpy(
      accountState: signedCoreState(days: 6, rank: 12)
    )
    let service = TiebaCoreAccountService(client: client)

    let state = try await service.forumAccountState(
      session: session(),
      forumID: 42,
      forumName: "swift"
    )

    XCTAssertEqual(state.membership.userID, 7)
    XCTAssertEqual(state.membership.forumID, 42)
    XCTAssertEqual(state.checkIn?.isCheckedIn, true)
    XCTAssertEqual(state.checkIn?.consecutiveDays, 6)
    XCTAssertEqual(state.checkIn?.rank, 12)
    XCTAssertEqual(
      Set(Mirror(reflecting: state).children.compactMap(\.label)),
      ["membership", "checkIn"]
    )
    let snapshot = await client.snapshot()
    XCTAssertEqual(snapshot.accountStateRequests.count, 1)
    XCTAssertEqual(snapshot.accountStateRequests.first?.credentialByteCount, 192)
  }

  func testThreadAgreementReadAndWritePassIdentityAndMapAuthoritativeResponses() async throws {
    let client = AccountClientSpy(
      threadAgreement: TiebaThreadAgreement(
        userID: 7,
        forumID: 42,
        threadID: 123,
        firstPostID: 456,
        isAgreed: false,
        agreeScore: 17
      ),
      threadAgreementMutation: TiebaThreadAgreement(
        userID: 7,
        forumID: 42,
        threadID: 123,
        firstPostID: 456,
        isAgreed: true,
        agreeScore: -3
      )
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()

    let current = try await service.threadAgreement(
      session: storedSession,
      forumID: 42,
      forumName: "swift",
      threadID: 123,
      firstPostID: 456
    )
    let updated = try await service.setThreadAgreed(
      session: storedSession,
      forumID: 42,
      forumName: "  swift  ",
      threadID: 123,
      firstPostID: 456,
      isAgreed: true
    )

    XCTAssertEqual(
      current,
      ThreadAgreementData(
        userID: 7,
        forumID: 42,
        threadID: 123,
        firstPostID: 456,
        isAgreed: false,
        agreeScore: 17
      )
    )
    XCTAssertEqual(
      updated,
      ThreadAgreementData(
        userID: 7,
        forumID: 42,
        threadID: 123,
        firstPostID: 456,
        isAgreed: true,
        agreeScore: 0
      )
    )
    let snapshot = await client.snapshot()
    XCTAssertEqual(
      snapshot.threadAgreementRequests,
      [
        ThreadAgreementClientRequest(
          credentialByteCount: 192,
          expectedUserID: 7,
          forumID: 42,
          forumName: "swift",
          threadID: 123,
          firstPostID: 456,
          desiredState: nil
        )
      ]
    )
    XCTAssertEqual(
      snapshot.threadAgreementMutationRequests,
      [
        ThreadAgreementClientRequest(
          credentialByteCount: 192,
          expectedUserID: 7,
          forumID: 42,
          forumName: "swift",
          threadID: 123,
          firstPostID: 456,
          desiredState: true
        )
      ]
    )
  }

  func testConcurrentIdenticalThreadAgreementWritesShareOneCoreTask() async throws {
    let client = AccountClientSpy(
      threadAgreementMutation: coreThreadAgreement(isAgreed: true, score: 18),
      suspendsThreadAgreementMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()

    let first = Task {
      try await service.setThreadAgreed(
        session: storedSession,
        forumID: 42,
        forumName: "  swift  ",
        threadID: 123,
        firstPostID: 456,
        isAgreed: true
      )
    }
    try await waitForAccountServiceTest {
      await client.threadAgreementMutationRequestCount() == 1
    }
    let second = Task {
      try await service.setThreadAgreed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        threadID: 123,
        firstPostID: 456,
        isAgreed: true
      )
    }
    for _ in 0..<50 { await Task.yield() }

    let requestCountBeforeRelease = await client.threadAgreementMutationRequestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await client.releaseThreadAgreementMutation()
    let firstResult = try await first.value
    let secondResult = try await second.value

    XCTAssertEqual(firstResult, secondResult)
    XCTAssertTrue(firstResult.isAgreed)
    XCTAssertEqual(firstResult.agreeScore, 18)
    let finalRequestCount = await client.threadAgreementMutationRequestCount()
    XCTAssertEqual(finalRequestCount, 1)
  }

  func testOppositeThreadAgreementTargetWaitsThenReturnsSettledConflictWithoutSecondWrite()
    async throws
  {
    let client = AccountClientSpy(
      threadAgreementMutation: coreThreadAgreement(isAgreed: true, score: 18),
      suspendsThreadAgreementMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()
    let first = Task {
      try await service.setThreadAgreed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        threadID: 123,
        firstPostID: 456,
        isAgreed: true
      )
    }
    try await waitForAccountServiceTest {
      await client.threadAgreementMutationRequestCount() == 1
    }

    let conflictProbe = AccountServiceCompletionProbe()
    let conflict = Task { () -> String? in
      await conflictProbe.markStarted()
      do {
        _ = try await service.setThreadAgreed(
          session: storedSession,
          forumID: 42,
          forumName: "swift",
          threadID: 123,
          firstPostID: 456,
          isAgreed: false
        )
        await conflictProbe.markCompleted()
        return nil
      } catch {
        await conflictProbe.markCompleted()
        return (error as? BrowseError)?.errorDescription
      }
    }
    try await waitForAccountServiceTest { await conflictProbe.hasStarted() }
    try await waitForAccountServiceTest {
      await service.threadAgreementWriteConflictWaiterCount() == 1
    }

    let requestCountBeforeRelease = await client.threadAgreementMutationRequestCount()
    let completedBeforeRelease = await conflictProbe.hasCompleted()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    XCTAssertFalse(completedBeforeRelease)
    await client.releaseThreadAgreementMutation()
    let firstResult = try await first.value
    try await waitForAccountServiceTest { await conflictProbe.hasCompleted() }
    let conflictMessage = await conflict.value

    XCTAssertTrue(firstResult.isAgreed)
    XCTAssertEqual(
      conflictMessage,
      "先前的主题点赞操作已结束，请重新读取当前状态。"
    )
    let finalRequestCount = await client.threadAgreementMutationRequestCount()
    let finalConflictWaiterCount = await service.threadAgreementWriteConflictWaiterCount()
    XCTAssertEqual(finalRequestCount, 1)
    XCTAssertEqual(finalConflictWaiterCount, 0)
  }

  func testRotatedThreadAgreementSessionOrChangedCredentialNeverCoalesces() async throws {
    let client = AccountClientSpy(
      threadAgreementMutation: coreThreadAgreement(isAgreed: true, score: 18),
      suspendsThreadAgreementMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let originalRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000031")
    )
    let rotatedRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000032")
    )
    let original = session(sessionRevision: originalRevision, credentialComponent: "b")
    let rotated = session(sessionRevision: rotatedRevision, credentialComponent: "b")
    let changedCredential = session(sessionRevision: originalRevision, credentialComponent: "c")
    let first = Task {
      try await service.setThreadAgreed(
        session: original,
        forumID: 42,
        forumName: "swift",
        threadID: 123,
        firstPostID: 456,
        isAgreed: true
      )
    }
    try await waitForAccountServiceTest {
      await client.threadAgreementMutationRequestCount() == 1
    }

    let rotatedConflict = Task { () -> String? in
      do {
        _ = try await service.setThreadAgreed(
          session: rotated,
          forumID: 42,
          forumName: "swift",
          threadID: 123,
          firstPostID: 456,
          isAgreed: true
        )
        return nil
      } catch {
        return (error as? BrowseError)?.errorDescription
      }
    }
    let credentialConflict = Task { () -> String? in
      do {
        _ = try await service.setThreadAgreed(
          session: changedCredential,
          forumID: 42,
          forumName: "swift",
          threadID: 123,
          firstPostID: 456,
          isAgreed: true
        )
        return nil
      } catch {
        return (error as? BrowseError)?.errorDescription
      }
    }
    try await waitForAccountServiceTest {
      await service.threadAgreementWriteConflictWaiterCount() == 2
    }

    let requestCountBeforeRelease = await client.threadAgreementMutationRequestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await client.releaseThreadAgreementMutation()
    _ = try await first.value
    let rotatedMessage = await rotatedConflict.value
    let credentialMessage = await credentialConflict.value

    XCTAssertEqual(
      rotatedMessage,
      "先前的主题点赞操作已结束，请重新读取当前状态。"
    )
    XCTAssertEqual(
      credentialMessage,
      "先前的主题点赞操作已结束，请重新读取当前状态。"
    )
    let finalRequestCount = await client.threadAgreementMutationRequestCount()
    let finalConflictWaiterCount = await service.threadAgreementWriteConflictWaiterCount()
    XCTAssertEqual(finalRequestCount, 1)
    XCTAssertEqual(finalConflictWaiterCount, 0)
  }

  func testThreadAgreementWritesForDifferentThreadsRunInParallel() async throws {
    let client = AccountClientSpy(
      threadAgreementMutation: coreThreadAgreement(isAgreed: true, score: 18),
      suspendsThreadAgreementMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()
    let first = Task {
      try await service.setThreadAgreed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        threadID: 123,
        firstPostID: 456,
        isAgreed: true
      )
    }
    let second = Task {
      try await service.setThreadAgreed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        threadID: 124,
        firstPostID: 457,
        isAgreed: true
      )
    }
    try await waitForAccountServiceTest {
      await client.threadAgreementMutationRequestCount() == 2
    }

    let conflictWaiterCount = await service.threadAgreementWriteConflictWaiterCount()
    XCTAssertEqual(conflictWaiterCount, 0)
    let snapshotBeforeRelease = await client.snapshot()
    XCTAssertEqual(
      Set(snapshotBeforeRelease.threadAgreementMutationRequests.map(\.threadID)),
      Set<Int64>([123, 124])
    )
    XCTAssertEqual(
      Set(snapshotBeforeRelease.threadAgreementMutationRequests.map(\.firstPostID)),
      Set<Int64>([456, 457])
    )
    await client.releaseThreadAgreementMutation()
    _ = try await first.value
    _ = try await second.value

    let finalRequestCount = await client.threadAgreementMutationRequestCount()
    XCTAssertEqual(finalRequestCount, 2)
  }

  func testConcurrentIdenticalForumWritesShareOneCoreTask() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      ),
      suspendsMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()

    let first = Task {
      try await service.setForumFollowed(
        session: storedSession,
        forumID: 42,
        forumName: "  swift  ",
        isFollowed: true
      )
    }
    try await waitForAccountServiceTest { await client.mutationRequestCount() == 1 }

    let second = Task {
      try await service.setForumFollowed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    }
    for _ in 0..<50 { await Task.yield() }

    let requestCountBeforeRelease = await client.mutationRequestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await client.releaseMutation()
    let firstResult = try await first.value
    let secondResult = try await second.value

    XCTAssertEqual(firstResult, secondResult)
    XCTAssertTrue(firstResult.isFollowed)
    let finalRequestCount = await client.mutationRequestCount()
    XCTAssertEqual(finalRequestCount, 1)
  }

  func testOppositeForumWriteWaitsForFirstWriteBeforeReturningSettledConflict() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      ),
      suspendsMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()
    let first = Task {
      try await service.setForumFollowed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    }
    try await waitForAccountServiceTest { await client.mutationRequestCount() == 1 }

    let conflictProbe = AccountServiceCompletionProbe()
    let conflict = Task { () -> String? in
      await conflictProbe.markStarted()
      do {
        _ = try await service.setForumFollowed(
          session: storedSession,
          forumID: 42,
          forumName: "swift",
          isFollowed: false
        )
        await conflictProbe.markCompleted()
        return nil
      } catch {
        await conflictProbe.markCompleted()
        return (error as? BrowseError)?.errorDescription
      }
    }
    try await waitForAccountServiceTest { await conflictProbe.hasStarted() }
    try await waitForAccountServiceTest {
      await service.forumWriteConflictWaiterCount() == 1
    }

    let requestCountBeforeRelease = await client.mutationRequestCount()
    let completedBeforeRelease = await conflictProbe.hasCompleted()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    XCTAssertFalse(completedBeforeRelease)
    await client.releaseMutation()
    let firstResult = try await first.value
    try await waitForAccountServiceTest { await conflictProbe.hasCompleted() }
    let conflictMessage = await conflict.value

    XCTAssertTrue(firstResult.isFollowed)
    XCTAssertEqual(
      conflictMessage,
      "先前的贴吧账户操作已结束，请重新读取当前状态。"
    )
    let finalRequestCount = await client.mutationRequestCount()
    let finalConflictWaiterCount = await service.forumWriteConflictWaiterCount()
    XCTAssertEqual(finalRequestCount, 1)
    XCTAssertEqual(finalConflictWaiterCount, 0)
  }

  func testConflictAlsoWaitsForAFailedWriteBeforeReturningSettledError() async throws {
    let client = AccountClientSpy(
      mutationError: .server(code: 500, message: "failed"),
      suspendsMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()
    let first = Task { () -> String? in
      do {
        _ = try await service.setForumFollowed(
          session: storedSession,
          forumID: 42,
          forumName: "swift",
          isFollowed: true
        )
        return nil
      } catch {
        return (error as? BrowseError)?.errorDescription
      }
    }
    try await waitForAccountServiceTest { await client.mutationRequestCount() == 1 }

    let conflictProbe = AccountServiceCompletionProbe()
    let conflict = Task { () -> String? in
      await conflictProbe.markStarted()
      do {
        _ = try await service.setForumFollowed(
          session: storedSession,
          forumID: 42,
          forumName: "swift",
          isFollowed: false
        )
        await conflictProbe.markCompleted()
        return nil
      } catch {
        await conflictProbe.markCompleted()
        return (error as? BrowseError)?.errorDescription
      }
    }
    try await waitForAccountServiceTest {
      await service.forumWriteConflictWaiterCount() == 1
    }
    let completedBeforeRelease = await conflictProbe.hasCompleted()
    XCTAssertFalse(completedBeforeRelease)

    await client.releaseMutation()
    let firstMessage = await first.value
    try await waitForAccountServiceTest { await conflictProbe.hasCompleted() }
    let conflictMessage = await conflict.value

    XCTAssertEqual(firstMessage, "账户请求失败（错误码 500）。")
    XCTAssertEqual(
      conflictMessage,
      "先前的贴吧账户操作已结束，请重新读取当前状态。"
    )
    let finalRequestCount = await client.mutationRequestCount()
    let finalConflictWaiterCount = await service.forumWriteConflictWaiterCount()
    XCTAssertEqual(finalRequestCount, 1)
    XCTAssertEqual(finalConflictWaiterCount, 0)
  }

  func testRotatedSessionWaitsForOlderCredentialWriteThenReturnsSettledConflict() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      ),
      suspendsMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let oldRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000021")
    )
    let rotatedRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000022")
    )
    let oldSession = session(
      updatedAt: 1,
      sessionRevision: oldRevision,
      credentialComponent: "b"
    )
    let rotatedSession = session(
      updatedAt: 1,
      sessionRevision: rotatedRevision,
      credentialComponent: "c"
    )
    let first = Task {
      try await service.setForumFollowed(
        session: oldSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    }
    try await waitForAccountServiceTest { await client.mutationRequestCount() == 1 }

    let conflictProbe = AccountServiceCompletionProbe()
    let conflict = Task { () -> String? in
      await conflictProbe.markStarted()
      do {
        _ = try await service.setForumFollowed(
          session: rotatedSession,
          forumID: 42,
          forumName: "swift",
          isFollowed: true
        )
        await conflictProbe.markCompleted()
        return nil
      } catch {
        await conflictProbe.markCompleted()
        return (error as? BrowseError)?.errorDescription
      }
    }
    try await waitForAccountServiceTest { await conflictProbe.hasStarted() }
    try await waitForAccountServiceTest {
      await service.forumWriteConflictWaiterCount() == 1
    }

    let requestCountBeforeRelease = await client.mutationRequestCount()
    let completedBeforeRelease = await conflictProbe.hasCompleted()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    XCTAssertFalse(completedBeforeRelease)
    await client.releaseMutation()
    _ = try await first.value
    try await waitForAccountServiceTest { await conflictProbe.hasCompleted() }
    let conflictMessage = await conflict.value
    XCTAssertEqual(
      conflictMessage,
      "先前的贴吧账户操作已结束，请重新读取当前状态。"
    )
  }

  func testSameRevisionDifferentCredentialOrForumNameNeverCoalesces() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      ),
      suspendsMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let revision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000023")
    )
    let original = session(sessionRevision: revision, credentialComponent: "b")
    let changedCredential = session(sessionRevision: revision, credentialComponent: "c")
    let first = Task {
      try await service.setForumFollowed(
        session: original,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    }
    try await waitForAccountServiceTest { await client.mutationRequestCount() == 1 }

    let credentialProbe = AccountServiceCompletionProbe()
    let changedCredentialConflict = Task { () -> String? in
      await credentialProbe.markStarted()
      do {
        _ = try await service.setForumFollowed(
          session: changedCredential,
          forumID: 42,
          forumName: "swift",
          isFollowed: true
        )
        await credentialProbe.markCompleted()
        return nil
      } catch {
        await credentialProbe.markCompleted()
        return (error as? BrowseError)?.errorDescription
      }
    }
    let forumNameProbe = AccountServiceCompletionProbe()
    let changedForumNameConflict = Task { () -> String? in
      await forumNameProbe.markStarted()
      do {
        _ = try await service.setForumFollowed(
          session: original,
          forumID: 42,
          forumName: "different-forum-name",
          isFollowed: true
        )
        await forumNameProbe.markCompleted()
        return nil
      } catch {
        await forumNameProbe.markCompleted()
        return (error as? BrowseError)?.errorDescription
      }
    }
    try await waitForAccountServiceTest {
      let credentialStarted = await credentialProbe.hasStarted()
      let forumNameStarted = await forumNameProbe.hasStarted()
      return credentialStarted && forumNameStarted
    }
    try await waitForAccountServiceTest {
      await service.forumWriteConflictWaiterCount() == 2
    }

    let requestCountBeforeRelease = await client.mutationRequestCount()
    let credentialCompletedBeforeRelease = await credentialProbe.hasCompleted()
    let forumNameCompletedBeforeRelease = await forumNameProbe.hasCompleted()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    XCTAssertFalse(credentialCompletedBeforeRelease)
    XCTAssertFalse(forumNameCompletedBeforeRelease)
    await client.releaseMutation()
    _ = try await first.value
    try await waitForAccountServiceTest {
      let credentialCompleted = await credentialProbe.hasCompleted()
      let forumNameCompleted = await forumNameProbe.hasCompleted()
      return credentialCompleted && forumNameCompleted
    }
    let credentialConflictMessage = await changedCredentialConflict.value
    let forumNameConflictMessage = await changedForumNameConflict.value
    XCTAssertEqual(
      credentialConflictMessage,
      "先前的贴吧账户操作已结束，请重新读取当前状态。"
    )
    XCTAssertEqual(
      forumNameConflictMessage,
      "先前的贴吧账户操作已结束，请重新读取当前状态。"
    )
  }

  func testCancellationAfterForumWriteStartsDoesNotDiscardConfirmedResult() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      ),
      suspendsMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()
    let write = Task {
      try await service.setForumFollowed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    }
    try await waitForAccountServiceTest { await client.mutationRequestCount() == 1 }

    write.cancel()
    await client.releaseMutation()
    let result = try await write.value

    XCTAssertTrue(result.isFollowed)
    let requestCount = await client.mutationRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testConcurrentIdenticalCheckInsShareOneCoreTask() async throws {
    let client = AccountClientSpy(
      checkIn: signedCoreState(days: 5, rank: 11),
      suspendsCheckIn: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()

    let first = Task {
      try await service.checkInToForum(
        session: storedSession,
        forumID: 42,
        forumName: "swift"
      )
    }
    try await waitForAccountServiceTest { await client.checkInRequestCount() == 1 }
    let second = Task {
      try await service.checkInToForum(
        session: storedSession,
        forumID: 42,
        forumName: "swift"
      )
    }
    for _ in 0..<50 { await Task.yield() }

    let requestCountBeforeRelease = await client.checkInRequestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await client.releaseCheckIn()
    let firstResult = try await first.value
    let secondResult = try await second.value

    XCTAssertEqual(firstResult, secondResult)
    XCTAssertEqual(firstResult.checkIn?.consecutiveDays, 5)
    let finalRequestCount = await client.checkInRequestCount()
    XCTAssertEqual(finalRequestCount, 1)
  }

  func testCheckInWaitsForFollowWriteBeforeReturningSettledConflict() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      ),
      checkIn: signedCoreState(days: 5, rank: 11),
      suspendsMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()
    let follow = Task {
      try await service.setForumFollowed(
        session: storedSession,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
    }
    try await waitForAccountServiceTest { await client.mutationRequestCount() == 1 }

    let conflictProbe = AccountServiceCompletionProbe()
    let conflict = Task { () -> String? in
      await conflictProbe.markStarted()
      do {
        _ = try await service.checkInToForum(
          session: storedSession,
          forumID: 42,
          forumName: "swift"
        )
        await conflictProbe.markCompleted()
        return nil
      } catch {
        await conflictProbe.markCompleted()
        return (error as? BrowseError)?.errorDescription
      }
    }
    try await waitForAccountServiceTest { await conflictProbe.hasStarted() }
    try await waitForAccountServiceTest {
      await service.forumWriteConflictWaiterCount() == 1
    }

    let checkInRequestCount = await client.checkInRequestCount()
    let completedBeforeRelease = await conflictProbe.hasCompleted()
    XCTAssertEqual(checkInRequestCount, 0)
    XCTAssertFalse(completedBeforeRelease)
    await client.releaseMutation()
    _ = try await follow.value
    try await waitForAccountServiceTest { await conflictProbe.hasCompleted() }
    let conflictMessage = await conflict.value
    XCTAssertEqual(
      conflictMessage,
      "先前的贴吧账户操作已结束，请重新读取当前状态。"
    )
    let finalCheckInRequestCount = await client.checkInRequestCount()
    XCTAssertEqual(finalCheckInRequestCount, 0)
  }

  func testRotatedSessionWaitsForOlderCheckInThenReturnsSettledConflict() async throws {
    let client = AccountClientSpy(
      checkIn: signedCoreState(days: 5, rank: 11),
      suspendsCheckIn: true
    )
    let service = TiebaCoreAccountService(client: client)
    let oldRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000024")
    )
    let rotatedRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000025")
    )
    let oldSession = session(
      updatedAt: 1,
      sessionRevision: oldRevision,
      credentialComponent: "b"
    )
    let rotatedSession = session(
      updatedAt: 1,
      sessionRevision: rotatedRevision,
      credentialComponent: "c"
    )
    let first = Task {
      try await service.checkInToForum(
        session: oldSession,
        forumID: 42,
        forumName: "swift"
      )
    }
    try await waitForAccountServiceTest { await client.checkInRequestCount() == 1 }

    let conflictProbe = AccountServiceCompletionProbe()
    let conflict = Task { () -> String? in
      await conflictProbe.markStarted()
      do {
        _ = try await service.checkInToForum(
          session: rotatedSession,
          forumID: 42,
          forumName: "swift"
        )
        await conflictProbe.markCompleted()
        return nil
      } catch {
        await conflictProbe.markCompleted()
        return (error as? BrowseError)?.errorDescription
      }
    }
    try await waitForAccountServiceTest { await conflictProbe.hasStarted() }
    try await waitForAccountServiceTest {
      await service.forumWriteConflictWaiterCount() == 1
    }

    let requestCountBeforeRelease = await client.checkInRequestCount()
    let completedBeforeRelease = await conflictProbe.hasCompleted()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    XCTAssertFalse(completedBeforeRelease)
    await client.releaseCheckIn()
    _ = try await first.value
    try await waitForAccountServiceTest { await conflictProbe.hasCompleted() }
    let conflictMessage = await conflict.value
    XCTAssertEqual(
      conflictMessage,
      "先前的贴吧账户操作已结束，请重新读取当前状态。"
    )
    let finalRequestCount = await client.checkInRequestCount()
    XCTAssertEqual(finalRequestCount, 1)
  }

  func testCancellationAfterCheckInStartsDoesNotDiscardConfirmedResult() async throws {
    let client = AccountClientSpy(
      checkIn: signedCoreState(days: 5, rank: 11),
      suspendsCheckIn: true
    )
    let service = TiebaCoreAccountService(client: client)
    let storedSession = session()
    let write = Task {
      try await service.checkInToForum(
        session: storedSession,
        forumID: 42,
        forumName: "swift"
      )
    }
    try await waitForAccountServiceTest { await client.checkInRequestCount() == 1 }

    write.cancel()
    await client.releaseCheckIn()
    let result = try await write.value

    XCTAssertEqual(result.checkIn?.isCheckedIn, true)
    let requestCount = await client.checkInRequestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testForumWritePassesExpectedIdentityAndMapsAuthoritativeResult() async throws {
    let client = AccountClientSpy(
      mutation: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "Swift 语言",
        isFollowed: false
      )
    )
    let service = TiebaCoreAccountService(client: client)

    let membership = try await service.setForumFollowed(
      session: session(),
      forumID: 42,
      forumName: "swift",
      isFollowed: false
    )

    XCTAssertEqual(
      membership,
      ForumMembershipData(
        userID: 7,
        forumID: 42,
        forumName: "Swift 语言",
        isFollowed: false
      )
    )
    let snapshot = await client.snapshot()
    let requests = snapshot.mutationRequests
    XCTAssertEqual(
      requests,
      [
        AccountClientRequest(
          credentialByteCount: 192,
          expectedUserID: 7,
          forumID: 42,
          forumName: "swift",
          desiredState: false
        )
      ]
    )
  }

  func testContentAgreementBatchMapsAllObjectKindsAndKeepsOnlyDescriptorIntersection()
    async throws
  {
    let topic = ContentAgreementTarget(
      kind: .topic,
      forumID: 42,
      forumName: "swift",
      threadID: 123,
      objectID: 456
    )!
    let post = ContentAgreementTarget(
      kind: .post,
      forumID: 42,
      forumName: "swift",
      threadID: 123,
      objectID: 457
    )!
    let subpost = ContentAgreementTarget(
      kind: .subpost,
      forumID: 42,
      forumName: "swift",
      threadID: 123,
      parentPostID: 457,
      objectID: 789
    )!
    let corePage = TiebaAgreementPage(
      userID: 7,
      forumID: 42,
      threadID: 123,
      agreements: [
        coreAgreement(target: .thread(firstPostID: 456), isAgreed: true, score: 10),
        coreAgreement(target: .post(postID: 457), isAgreed: false, score: 4),
        coreAgreement(
          target: .subpost(parentPostID: 457, subpostID: 789),
          isAgreed: true,
          score: -3
        ),
        coreAgreement(target: .post(postID: 999), isAgreed: true, score: 99),
      ],
      pagination: TiebaPagination(
        pageSize: 30,
        currentPage: 1,
        totalPages: 1,
        totalCount: 4,
        hasMore: false,
        hasPrevious: false
      )
    )
    let client = AccountClientSpy(agreementPage: corePage)
    let service = TiebaCoreAccountService(client: client)
    let request = ContentAgreementPostPageRequest(
      forumID: 42,
      forumName: "swift",
      threadID: 123,
      page: 1,
      pageSize: 30,
      options: ThreadBrowseOptions(sort: .hot, onlyThreadAuthor: true),
      location: .pageCursor(457),
      includesSubposts: true,
      subpostsSortedByAgree: true,
      subpostPageSize: 4
    )!
    let descriptor = ContentAgreementReadDescriptor(
      request: .postPage(request),
      expectedTargets: [topic, post, subpost]
    )!

    let page = try await service.contentAgreements(session: session(), descriptor: descriptor)

    XCTAssertEqual(Set(page.agreements.map(\.target)), Set([topic, post, subpost]))
    XCTAssertEqual(page.agreements.first(where: { $0.target == subpost })?.snapshot.agreeScore, 0)
    let snapshot = await client.snapshot()
    XCTAssertEqual(
      snapshot.agreementPostPageRequests,
      [
        ContentAgreementPostPageClientRequest(
          credentialByteCount: 192,
          expectedUserID: 7,
          forumID: 42,
          threadID: 123,
          page: 1,
          pageSize: 30,
          sort: .hot,
          onlyThreadAuthor: true,
          location: .pageCursor(457),
          includeSubposts: true,
          subpostsSortedByAgree: true,
          subpostPageSize: 4
        )
      ]
    )
    XCTAssertTrue(snapshot.agreementSubpostPageRequests.isEmpty)
  }

  func testContentAgreementSubpostBatchMapsRequestAndKeepsOnlyDescriptorIntersection()
    async throws
  {
    let parent = ContentAgreementTarget(
      kind: .post,
      forumID: 42,
      forumName: "swift",
      threadID: 123,
      objectID: 457
    )!
    let subpost = ContentAgreementTarget(
      kind: .subpost,
      forumID: 42,
      forumName: "swift",
      threadID: 123,
      parentPostID: 457,
      objectID: 789
    )!
    let corePage = TiebaAgreementPage(
      userID: 7,
      forumID: 42,
      threadID: 123,
      agreements: [
        coreAgreement(target: .post(postID: 457), isAgreed: false, score: 4),
        coreAgreement(
          target: .subpost(parentPostID: 457, subpostID: 789),
          isAgreed: true,
          score: 8
        ),
        coreAgreement(
          target: .subpost(parentPostID: 457, subpostID: 790),
          isAgreed: true,
          score: 99
        ),
      ],
      pagination: TiebaPagination(
        pageSize: 20,
        currentPage: 3,
        totalPages: 4,
        totalCount: 3,
        hasMore: true,
        hasPrevious: true
      )
    )
    let client = AccountClientSpy(agreementPage: corePage)
    let service = TiebaCoreAccountService(client: client)
    let request = ContentAgreementSubpostPageRequest(
      forumID: 42,
      forumName: "swift",
      threadID: 123,
      parentPostID: 457,
      aroundSubpostID: 789,
      page: 3
    )!
    let descriptor = ContentAgreementReadDescriptor(
      request: .subpostPage(request),
      expectedTargets: [parent, subpost]
    )!

    let page = try await service.contentAgreements(session: session(), descriptor: descriptor)

    XCTAssertEqual(Set(page.agreements.map(\.target)), Set([parent, subpost]))
    XCTAssertEqual(page.agreements.first(where: { $0.target == subpost })?.snapshot.agreeScore, 8)
    let snapshot = await client.snapshot()
    XCTAssertTrue(snapshot.agreementPostPageRequests.isEmpty)
    XCTAssertEqual(
      snapshot.agreementSubpostPageRequests,
      [
        ContentAgreementSubpostPageClientRequest(
          credentialByteCount: 192,
          expectedUserID: 7,
          forumID: 42,
          threadID: 123,
          parentPostID: 457,
          aroundSubpostID: 789,
          page: 3
        )
      ]
    )
  }

  func testContentAgreementSingleReadAndWriteMapEveryObjectTargetExactly() async throws {
    let mappings: [(ContentAgreementTarget, TiebaAgreementTarget)] = [
      (
        ContentAgreementTarget(
          kind: .topic,
          forumID: 42,
          forumName: "swift",
          threadID: 123,
          objectID: 456
        )!,
        .thread(firstPostID: 456)
      ),
      (
        ContentAgreementTarget(
          kind: .post,
          forumID: 42,
          forumName: "swift",
          threadID: 123,
          objectID: 457
        )!,
        .post(postID: 457)
      ),
      (
        ContentAgreementTarget(
          kind: .subpost,
          forumID: 42,
          forumName: "swift",
          threadID: 123,
          parentPostID: 457,
          objectID: 789
        )!,
        .subpost(parentPostID: 457, subpostID: 789)
      ),
    ]

    for (target, coreTarget) in mappings {
      let response = coreAgreement(target: coreTarget, isAgreed: true, score: 8)
      let client = AccountClientSpy(
        agreement: response,
        agreementMutation: response
      )
      let service = TiebaCoreAccountService(client: client)

      let current = try await service.contentAgreement(session: session(), target: target)
      let updated = try await service.setContentAgreed(
        session: session(),
        target: target,
        isAgreed: true
      )

      XCTAssertEqual(current.target, target)
      XCTAssertEqual(updated.target, target)
      let snapshot = await client.snapshot()
      XCTAssertEqual(snapshot.agreementRequests.map(\.target), [coreTarget])
      XCTAssertEqual(snapshot.agreementMutationRequests.map(\.target), [coreTarget])
      XCTAssertEqual(snapshot.agreementMutationRequests.map(\.desiredState), [true])
    }
  }

  func testContentAgreementCoordinatorDoesNotCoalesceSameUserAcrossSessionRevisions()
    async throws
  {
    let firstRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000041")
    )
    let secondRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000042")
    )
    let firstSession = session(sessionRevision: firstRevision)
    let secondSession = session(sessionRevision: secondRevision)
    let target = ContentAgreementTarget(
      kind: .post,
      forumID: 42,
      forumName: "swift",
      threadID: 123,
      objectID: 457
    )!
    let client = AccountClientSpy(
      agreementMutation: coreAgreement(
        target: .post(postID: 457),
        isAgreed: true,
        score: 8
      ),
      suspendsAgreementMutation: true
    )
    let service = TiebaCoreAccountService(client: client)
    let first = Task {
      try await service.setContentAgreed(
        session: firstSession,
        target: target,
        isAgreed: true
      )
    }
    try await waitForAccountServiceTest {
      await client.agreementMutationRequestCount() == 1
    }
    let second = Task { () -> String? in
      do {
        _ = try await service.setContentAgreed(
          session: secondSession,
          target: target,
          isAgreed: true
        )
        return nil
      } catch {
        return (error as? BrowseError)?.errorDescription
      }
    }
    try await waitForAccountServiceTest {
      await service.contentAgreementWriteConflictWaiterCount() == 1
    }

    let requestCountBeforeRelease = await client.agreementMutationRequestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)
    await client.releaseAgreementMutation()
    _ = try await first.value
    let conflict = await second.value

    XCTAssertEqual(conflict, "先前的内容点赞操作已结束，请重新读取当前状态。")
    let finalRequestCount = await client.agreementMutationRequestCount()
    let finalWaiterCount = await service.contentAgreementWriteConflictWaiterCount()
    XCTAssertEqual(finalRequestCount, 1)
    XCTAssertEqual(finalWaiterCount, 0)
  }

  func testServerErrorDoesNotExposeResponseMessage() throws {
    let secret = String(repeating: "b", count: 192)
    let error = TiebaCoreAccountService.accountError(
      TiebaClientError.server(code: 1, message: "request bdusstoken=\(secret)")
    )

    let message = try XCTUnwrap(error.errorDescription)
    XCTAssertEqual(message, "账户请求失败（错误码 1）。")
    XCTAssertFalse(message.contains(secret))
    XCTAssertFalse(message.contains("bdusstoken"))
  }

  func testUnknownErrorDoesNotExposeLocalizedDescription() throws {
    let secret = "sensitive diagnostic"
    let error = TiebaCoreAccountService.accountError(SensitiveAccountError(message: secret))

    let message = try XCTUnwrap(error.errorDescription)
    XCTAssertEqual(message, "账户请求失败，请稍后重试。")
    XCTAssertFalse(message.contains(secret))
  }

  func testAccountErrorUsesOnlyFixedMessagesAndNumericStatus() throws {
    let cases: [(TiebaClientError, String)] = [
      (.invalidArgument("secret"), "账户请求参数无效。"),
      (.invalidEndpoint, "无法建立安全的账户请求。"),
      (.network(code: -1009), "网络连接失败，请检查网络后重试。"),
      (.transportFailure, "网络响应异常，请稍后重试。"),
      (.invalidHTTPResponse, "网络响应异常，请稍后重试。"),
      (.httpStatus(503), "贴吧服务暂时不可用（HTTP 503）。"),
      (.responseTooLarge(maximumBytes: 65_536), "贴吧返回的数据过大，请稍后重试。"),
      (.invalidProtobuf, "贴吧返回了无法识别的数据，接口可能已经更新。"),
      (.invalidJSON, "贴吧返回了无法识别的数据，接口可能已经更新。"),
      (
        .invalidAuthenticatedResponse,
        "账户凭据与贴吧响应不一致，请重新登录后再试。"
      ),
      (.forumNotFollowed, "请先关注该贴吧后再签到。"),
      (.forumCheckInUnavailable, "该贴吧当前无法签到。"),
    ]

    for (source, expected) in cases {
      XCTAssertEqual(
        TiebaCoreAccountService.accountError(source).errorDescription,
        expected
      )
    }
  }

  func testForumMutationServerErrorIsSanitizedByService() async throws {
    let secret = String(repeating: "t", count: 26)
    let client = AccountClientSpy(
      mutationError: .server(code: 340006, message: "invalid tbs=\(secret)")
    )
    let service = TiebaCoreAccountService(client: client)

    do {
      _ = try await service.setForumFollowed(
        session: session(),
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      )
      XCTFail("Expected a sanitized server error")
    } catch let error as BrowseError {
      let message = try XCTUnwrap(error.errorDescription)
      XCTAssertEqual(message, "账户请求失败（错误码 340006）。")
      XCTAssertFalse(message.contains(secret))
      XCTAssertFalse(message.contains("tbs"))
    } catch {
      XCTFail("Unexpected error type: \(type(of: error))")
    }
  }

  private func session(
    updatedAt: TimeInterval = 1,
    sessionRevision: UUID = UUID(),
    credentialComponent: String = "b",
    stokenComponent: String? = "s"
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: 7,
      username: "account",
      displayName: "Account",
      portrait: "portrait-token",
      bduss: String(repeating: credentialComponent, count: 192),
      stoken: stokenComponent.map { String(repeating: $0, count: 64) },
      bdussCookieName: .bduss,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: updatedAt),
      sessionRevision: sessionRevision
    )
  }

  private func signedCoreState(days: Int, rank: Int) -> TiebaForumAccountState {
    TiebaForumAccountState(
      membership: TiebaForumMembership(
        userID: 7,
        forumID: 42,
        forumName: "swift",
        isFollowed: true
      ),
      checkIn: TiebaForumCheckIn(
        isCheckedIn: true,
        consecutiveDays: days,
        rank: rank
      )
    )
  }

  private func coreThreadAgreement(
    isAgreed: Bool,
    score: Int,
    threadID: Int64 = 123,
    firstPostID: Int64 = 456
  ) -> TiebaThreadAgreement {
    TiebaThreadAgreement(
      userID: 7,
      forumID: 42,
      threadID: threadID,
      firstPostID: firstPostID,
      isAgreed: isAgreed,
      agreeScore: score
    )
  }

  private func coreAgreement(
    target: TiebaAgreementTarget,
    isAgreed: Bool,
    score: Int
  ) -> TiebaAgreementState {
    TiebaAgreementState(
      userID: 7,
      forumID: 42,
      threadID: 123,
      target: target,
      isAgreed: isAgreed,
      agreeScore: score
    )
  }
}

private struct SensitiveAccountError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

private struct AccountClientRequest: Equatable, Sendable {
  let credentialByteCount: Int
  let expectedUserID: Int64
  let forumID: Int64
  let forumName: String
  let desiredState: Bool?
}

private struct SessionCredentialShape: Equatable, Sendable {
  let bdussBytes: Int
  let stokenBytes: Int
  let cookieName: TiebaBDUSSCookieName
}

private struct CloudFavoriteClientRequest: Equatable, Sendable {
  let userID: Int64
  let offset: Int
  let pageSize: Int
  let bdussBytes: Int
  let stokenBytes: Int
  let cookieName: TiebaBDUSSCookieName
}

private struct ThreadAgreementClientRequest: Equatable, Sendable {
  let credentialByteCount: Int
  let expectedUserID: Int64
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let firstPostID: Int64
  let desiredState: Bool?
}

private struct ContentAgreementClientRequest: Equatable, Sendable {
  let credentialByteCount: Int
  let expectedUserID: Int64
  let forumID: Int64
  let forumName: String?
  let threadID: Int64
  let target: TiebaAgreementTarget
  let desiredState: Bool?
}

private struct ContentAgreementPostPageClientRequest: Equatable, Sendable {
  let credentialByteCount: Int
  let expectedUserID: Int64
  let forumID: Int64
  let threadID: Int64
  let page: Int
  let pageSize: Int
  let sort: TiebaPostSort
  let onlyThreadAuthor: Bool
  let location: TiebaPostLocation?
  let includeSubposts: Bool
  let subpostsSortedByAgree: Bool
  let subpostPageSize: Int
}

private struct ContentAgreementSubpostPageClientRequest: Equatable, Sendable {
  let credentialByteCount: Int
  let expectedUserID: Int64
  let forumID: Int64
  let threadID: Int64
  let parentPostID: Int64
  let aroundSubpostID: Int64?
  let page: Int
}

private struct AccountClientSnapshot: Sendable {
  let validationCredentialByteCounts: [Int]
  let validationSessionShapes: [SessionCredentialShape]
  let cloudFavoriteRequests: [CloudFavoriteClientRequest]
  let membershipRequests: [AccountClientRequest]
  let accountStateRequests: [AccountClientRequest]
  let mutationRequests: [AccountClientRequest]
  let checkInRequests: [AccountClientRequest]
  let threadAgreementRequests: [ThreadAgreementClientRequest]
  let threadAgreementMutationRequests: [ThreadAgreementClientRequest]
  let agreementRequests: [ContentAgreementClientRequest]
  let agreementMutationRequests: [ContentAgreementClientRequest]
  let agreementPostPageRequests: [ContentAgreementPostPageClientRequest]
  let agreementSubpostPageRequests: [ContentAgreementSubpostPageClientRequest]
}

private enum AccountClientSpyError: Error, Sendable {
  case unexpectedCall
}

private actor AccountServiceCompletionProbe {
  private var started = false
  private var completed = false

  func markStarted() { started = true }
  func markCompleted() { completed = true }
  func hasStarted() -> Bool { started }
  func hasCompleted() -> Bool { completed }
}

private actor AccountClientSpy: TiebaAuthenticatedAccountClient {
  private let validation: TiebaAuthenticatedAccount?
  private let cloudFavorites: TiebaCloudFavoritePage?
  private let membership: TiebaForumMembership?
  private let accountState: TiebaForumAccountState?
  private let mutation: TiebaForumMembership?
  private let mutationError: TiebaClientError?
  private let checkIn: TiebaForumAccountState?
  private let checkInError: TiebaClientError?
  private let threadAgreement: TiebaThreadAgreement?
  private let threadAgreementMutation: TiebaThreadAgreement?
  private let agreement: TiebaAgreementState?
  private let agreementPage: TiebaAgreementPage?
  private let agreementMutation: TiebaAgreementState?
  private let suspendsMutation: Bool
  private let suspendsCheckIn: Bool
  private let suspendsThreadAgreementMutation: Bool
  private let suspendsAgreementMutation: Bool
  private var validationCredentialByteCounts: [Int] = []
  private var validationSessionShapes: [SessionCredentialShape] = []
  private var cloudFavoriteRequests: [CloudFavoriteClientRequest] = []
  private var membershipRequests: [AccountClientRequest] = []
  private var accountStateRequests: [AccountClientRequest] = []
  private var mutationRequests: [AccountClientRequest] = []
  private var checkInRequests: [AccountClientRequest] = []
  private var threadAgreementRequests: [ThreadAgreementClientRequest] = []
  private var threadAgreementMutationRequests: [ThreadAgreementClientRequest] = []
  private var agreementRequests: [ContentAgreementClientRequest] = []
  private var agreementMutationRequests: [ContentAgreementClientRequest] = []
  private var agreementPostPageRequests: [ContentAgreementPostPageClientRequest] = []
  private var agreementSubpostPageRequests: [ContentAgreementSubpostPageClientRequest] = []
  private var mutationIsReleased = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
  private var checkInIsReleased = false
  private var checkInWaiters: [CheckedContinuation<Void, Never>] = []
  private var threadAgreementMutationIsReleased = false
  private var threadAgreementMutationWaiters: [CheckedContinuation<Void, Never>] = []
  private var agreementMutationIsReleased = false
  private var agreementMutationWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    validation: TiebaAuthenticatedAccount? = nil,
    cloudFavorites: TiebaCloudFavoritePage? = nil,
    membership: TiebaForumMembership? = nil,
    accountState: TiebaForumAccountState? = nil,
    mutation: TiebaForumMembership? = nil,
    mutationError: TiebaClientError? = nil,
    checkIn: TiebaForumAccountState? = nil,
    checkInError: TiebaClientError? = nil,
    threadAgreement: TiebaThreadAgreement? = nil,
    threadAgreementMutation: TiebaThreadAgreement? = nil,
    agreement: TiebaAgreementState? = nil,
    agreementPage: TiebaAgreementPage? = nil,
    agreementMutation: TiebaAgreementState? = nil,
    suspendsMutation: Bool = false,
    suspendsCheckIn: Bool = false,
    suspendsThreadAgreementMutation: Bool = false,
    suspendsAgreementMutation: Bool = false
  ) {
    self.validation = validation
    self.cloudFavorites = cloudFavorites
    self.membership = membership
    self.accountState = accountState
    self.mutation = mutation
    self.mutationError = mutationError
    self.checkIn = checkIn
    self.checkInError = checkInError
    self.threadAgreement = threadAgreement
    self.threadAgreementMutation = threadAgreementMutation
    self.agreement = agreement
    self.agreementPage = agreementPage
    self.agreementMutation = agreementMutation
    self.suspendsMutation = suspendsMutation
    self.suspendsCheckIn = suspendsCheckIn
    self.suspendsThreadAgreementMutation = suspendsThreadAgreementMutation
    self.suspendsAgreementMutation = suspendsAgreementMutation
  }

  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    validationCredentialByteCounts.append(credential.bduss.utf8.count)
    guard let validation else { throw AccountClientSpyError.unexpectedCall }
    return validation
  }

  func validateSession(
    credential: TiebaSessionCredential
  ) async throws -> TiebaAuthenticatedAccount {
    validationSessionShapes.append(
      SessionCredentialShape(
        bdussBytes: credential.bduss.utf8.count,
        stokenBytes: credential.stoken.utf8.count,
        cookieName: credential.bdussCookieName
      )
    )
    guard let validation else { throw AccountClientSpyError.unexpectedCall }
    return validation
  }

  func getCloudFavorites(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    offset: Int,
    pageSize: Int
  ) async throws -> TiebaCloudFavoritePage {
    cloudFavoriteRequests.append(
      CloudFavoriteClientRequest(
        userID: expectedUserID,
        offset: offset,
        pageSize: pageSize,
        bdussBytes: credential.bduss.utf8.count,
        stokenBytes: credential.stoken.utf8.count,
        cookieName: credential.bdussCookieName
      )
    )
    guard let cloudFavorites else { throw AccountClientSpyError.unexpectedCall }
    return cloudFavorites
  }

  func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage {
    throw AccountClientSpyError.unexpectedCall
  }

  func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    membershipRequests.append(
      AccountClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        desiredState: nil
      )
    )
    guard let membership else { throw AccountClientSpyError.unexpectedCall }
    return membership
  }

  func getForumAccountState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    accountStateRequests.append(
      AccountClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        desiredState: nil
      )
    )
    guard let accountState else { throw AccountClientSpyError.unexpectedCall }
    return accountState
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    mutationRequests.append(
      AccountClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        desiredState: isFollowed
      )
    )
    if suspendsMutation, !mutationIsReleased {
      await withCheckedContinuation { mutationWaiters.append($0) }
    }
    if let mutationError { throw mutationError }
    guard let mutation else { throw AccountClientSpyError.unexpectedCall }
    return mutation
  }

  func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    checkInRequests.append(
      AccountClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        desiredState: nil
      )
    )
    if suspendsCheckIn, !checkInIsReleased {
      await withCheckedContinuation { checkInWaiters.append($0) }
    }
    if let checkInError { throw checkInError }
    guard let checkIn else { throw AccountClientSpyError.unexpectedCall }
    return checkIn
  }

  func getThreadAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64
  ) async throws -> TiebaThreadAgreement {
    threadAgreementRequests.append(
      ThreadAgreementClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        firstPostID: firstPostID,
        desiredState: nil
      )
    )
    guard let threadAgreement else { throw AccountClientSpyError.unexpectedCall }
    return threadAgreement
  }

  func setThreadAgreementState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool
  ) async throws -> TiebaThreadAgreement {
    threadAgreementMutationRequests.append(
      ThreadAgreementClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        firstPostID: firstPostID,
        desiredState: isAgreed
      )
    )
    if suspendsThreadAgreementMutation, !threadAgreementMutationIsReleased {
      await withCheckedContinuation { threadAgreementMutationWaiters.append($0) }
    }
    guard let threadAgreementMutation else { throw AccountClientSpyError.unexpectedCall }
    return threadAgreementMutation
  }

  func getAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaAgreementTarget
  ) async throws -> TiebaAgreementState {
    agreementRequests.append(
      ContentAgreementClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: nil,
        threadID: threadID,
        target: target,
        desiredState: nil
      )
    )
    guard let agreement else { throw AccountClientSpyError.unexpectedCall }
    return agreement
  }

  func getAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    page: Int,
    pageSize: Int,
    sort: TiebaPostSort,
    onlyThreadAuthor: Bool,
    location: TiebaPostLocation?,
    includeSubposts: Bool,
    subpostsSortedByAgree: Bool,
    subpostPageSize: Int
  ) async throws -> TiebaAgreementPage {
    agreementPostPageRequests.append(
      ContentAgreementPostPageClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        page: page,
        pageSize: pageSize,
        sort: sort,
        onlyThreadAuthor: onlyThreadAuthor,
        location: location,
        includeSubposts: includeSubposts,
        subpostsSortedByAgree: subpostsSortedByAgree,
        subpostPageSize: subpostPageSize
      )
    )
    guard let agreementPage else { throw AccountClientSpyError.unexpectedCall }
    return agreementPage
  }

  func getSubpostAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    parentPostID: Int64,
    aroundSubpostID: Int64?,
    page: Int
  ) async throws -> TiebaAgreementPage {
    agreementSubpostPageRequests.append(
      ContentAgreementSubpostPageClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        parentPostID: parentPostID,
        aroundSubpostID: aroundSubpostID,
        page: page
      )
    )
    guard let agreementPage else { throw AccountClientSpyError.unexpectedCall }
    return agreementPage
  }

  func setAgreementState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaAgreementTarget,
    isAgreed: Bool
  ) async throws -> TiebaAgreementState {
    agreementMutationRequests.append(
      ContentAgreementClientRequest(
        credentialByteCount: credential.bduss.utf8.count,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: target,
        desiredState: isAgreed
      )
    )
    if suspendsAgreementMutation, !agreementMutationIsReleased {
      await withCheckedContinuation { agreementMutationWaiters.append($0) }
    }
    guard let agreementMutation else { throw AccountClientSpyError.unexpectedCall }
    return agreementMutation
  }

  func releaseMutation() {
    mutationIsReleased = true
    let waiters = mutationWaiters
    mutationWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func releaseCheckIn() {
    checkInIsReleased = true
    let waiters = checkInWaiters
    checkInWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func releaseThreadAgreementMutation() {
    threadAgreementMutationIsReleased = true
    let waiters = threadAgreementMutationWaiters
    threadAgreementMutationWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func releaseAgreementMutation() {
    agreementMutationIsReleased = true
    let waiters = agreementMutationWaiters
    agreementMutationWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  func mutationRequestCount() -> Int { mutationRequests.count }
  func checkInRequestCount() -> Int { checkInRequests.count }
  func threadAgreementMutationRequestCount() -> Int {
    threadAgreementMutationRequests.count
  }
  func agreementMutationRequestCount() -> Int { agreementMutationRequests.count }

  func snapshot() -> AccountClientSnapshot {
    AccountClientSnapshot(
      validationCredentialByteCounts: validationCredentialByteCounts,
      validationSessionShapes: validationSessionShapes,
      cloudFavoriteRequests: cloudFavoriteRequests,
      membershipRequests: membershipRequests,
      accountStateRequests: accountStateRequests,
      mutationRequests: mutationRequests,
      checkInRequests: checkInRequests,
      threadAgreementRequests: threadAgreementRequests,
      threadAgreementMutationRequests: threadAgreementMutationRequests,
      agreementRequests: agreementRequests,
      agreementMutationRequests: agreementMutationRequests,
      agreementPostPageRequests: agreementPostPageRequests,
      agreementSubpostPageRequests: agreementSubpostPageRequests
    )
  }
}

private func waitForAccountServiceTest(
  timeout: TimeInterval = 2,
  condition: () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw AccountClientSpyError.unexpectedCall }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
