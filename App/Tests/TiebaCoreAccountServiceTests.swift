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
      credential: AccountCredentials(bduss: String(repeating: "b", count: 192))
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
    XCTAssertEqual(snapshot.validationCredentialByteCounts, [192])
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
    credentialComponent: String = "b"
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: 7,
      username: "account",
      displayName: "Account",
      portrait: "portrait-token",
      bduss: String(repeating: credentialComponent, count: 192),
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

private struct ThreadAgreementClientRequest: Equatable, Sendable {
  let credentialByteCount: Int
  let expectedUserID: Int64
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let firstPostID: Int64
  let desiredState: Bool?
}

private struct AccountClientSnapshot: Sendable {
  let validationCredentialByteCounts: [Int]
  let membershipRequests: [AccountClientRequest]
  let accountStateRequests: [AccountClientRequest]
  let mutationRequests: [AccountClientRequest]
  let checkInRequests: [AccountClientRequest]
  let threadAgreementRequests: [ThreadAgreementClientRequest]
  let threadAgreementMutationRequests: [ThreadAgreementClientRequest]
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
  private let membership: TiebaForumMembership?
  private let accountState: TiebaForumAccountState?
  private let mutation: TiebaForumMembership?
  private let mutationError: TiebaClientError?
  private let checkIn: TiebaForumAccountState?
  private let checkInError: TiebaClientError?
  private let threadAgreement: TiebaThreadAgreement?
  private let threadAgreementMutation: TiebaThreadAgreement?
  private let suspendsMutation: Bool
  private let suspendsCheckIn: Bool
  private let suspendsThreadAgreementMutation: Bool
  private var validationCredentialByteCounts: [Int] = []
  private var membershipRequests: [AccountClientRequest] = []
  private var accountStateRequests: [AccountClientRequest] = []
  private var mutationRequests: [AccountClientRequest] = []
  private var checkInRequests: [AccountClientRequest] = []
  private var threadAgreementRequests: [ThreadAgreementClientRequest] = []
  private var threadAgreementMutationRequests: [ThreadAgreementClientRequest] = []
  private var mutationIsReleased = false
  private var mutationWaiters: [CheckedContinuation<Void, Never>] = []
  private var checkInIsReleased = false
  private var checkInWaiters: [CheckedContinuation<Void, Never>] = []
  private var threadAgreementMutationIsReleased = false
  private var threadAgreementMutationWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    validation: TiebaAuthenticatedAccount? = nil,
    membership: TiebaForumMembership? = nil,
    accountState: TiebaForumAccountState? = nil,
    mutation: TiebaForumMembership? = nil,
    mutationError: TiebaClientError? = nil,
    checkIn: TiebaForumAccountState? = nil,
    checkInError: TiebaClientError? = nil,
    threadAgreement: TiebaThreadAgreement? = nil,
    threadAgreementMutation: TiebaThreadAgreement? = nil,
    suspendsMutation: Bool = false,
    suspendsCheckIn: Bool = false,
    suspendsThreadAgreementMutation: Bool = false
  ) {
    self.validation = validation
    self.membership = membership
    self.accountState = accountState
    self.mutation = mutation
    self.mutationError = mutationError
    self.checkIn = checkIn
    self.checkInError = checkInError
    self.threadAgreement = threadAgreement
    self.threadAgreementMutation = threadAgreementMutation
    self.suspendsMutation = suspendsMutation
    self.suspendsCheckIn = suspendsCheckIn
    self.suspendsThreadAgreementMutation = suspendsThreadAgreementMutation
  }

  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    validationCredentialByteCounts.append(credential.bduss.utf8.count)
    guard let validation else { throw AccountClientSpyError.unexpectedCall }
    return validation
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

  func mutationRequestCount() -> Int { mutationRequests.count }
  func checkInRequestCount() -> Int { checkInRequests.count }
  func threadAgreementMutationRequestCount() -> Int {
    threadAgreementMutationRequests.count
  }

  func snapshot() -> AccountClientSnapshot {
    AccountClientSnapshot(
      validationCredentialByteCounts: validationCredentialByteCounts,
      membershipRequests: membershipRequests,
      accountStateRequests: accountStateRequests,
      mutationRequests: mutationRequests,
      checkInRequests: checkInRequests,
      threadAgreementRequests: threadAgreementRequests,
      threadAgreementMutationRequests: threadAgreementMutationRequests
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
