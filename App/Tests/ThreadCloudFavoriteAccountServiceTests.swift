import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class ThreadCloudFavoriteAccountServiceTests: XCTestCase {
  func testTargetAndSnapshotRejectInvalidValuesAndNormalizeForumName() throws {
    XCTAssertNil(ThreadCloudFavoriteTarget(forumID: 0, forumName: "swift", threadID: 9))
    XCTAssertNil(ThreadCloudFavoriteTarget(forumID: 8, forumName: "", threadID: 9))
    XCTAssertNil(ThreadCloudFavoriteTarget(forumID: 8, forumName: " \t ", threadID: 9))
    XCTAssertNil(ThreadCloudFavoriteTarget(forumID: 8, forumName: "swift\nforum", threadID: 9))
    XCTAssertNil(
      ThreadCloudFavoriteTarget(
        forumID: 8,
        forumName: String(repeating: "a", count: 101),
        threadID: 9
      )
    )
    XCTAssertNil(ThreadCloudFavoriteTarget(forumID: 8, forumName: "swift", threadID: 0))

    let target = try XCTUnwrap(
      ThreadCloudFavoriteTarget(forumID: 8, forumName: "  e\u{301}  ", threadID: 9)
    )
    XCTAssertEqual(target.forumName, "\u{e9}")

    XCTAssertNil(ThreadCloudFavoriteSnapshot(markedPostID: 0))
    XCTAssertNil(ThreadCloudFavoriteSnapshot(markedPostID: -1))
    XCTAssertFalse(try XCTUnwrap(ThreadCloudFavoriteSnapshot(markedPostID: nil)).isFavorited)
    let snapshot = try XCTUnwrap(ThreadCloudFavoriteSnapshot(markedPostID: 10))
    XCTAssertTrue(snapshot.isFavorited)
    XCTAssertEqual(snapshot.markedPostID, 10)
  }

  func testReadRejectsMissingOrInvalidAccountBeforeCoreRequest() async throws {
    let spy = ThreadCloudFavoriteClientSpy(
      readState: state(markedPostID: 91)
    )
    let service = TiebaCoreAccountService(client: spy)
    let target = try favoriteTarget()

    let legacyMessage = await browseErrorMessage {
      try await service.threadCloudFavorite(
        session: session(stoken: nil),
        target: target
      )
    }
    XCTAssertEqual(
      legacyMessage,
      "\u{6b64}\u{8d26}\u{6237}\u{9700}\u{8981}\u{91cd}\u{65b0}\u{767b}\u{5f55}\u{ff0c}\u{624d}\u{80fd}\u{5b89}\u{5168}\u{8bfb}\u{53d6}\u{4e3b}\u{9898}\u{6536}\u{85cf}\u{72b6}\u{6001}\u{3002}"
    )

    let invalidUserMessage = await browseErrorMessage {
      try await service.threadCloudFavorite(
        session: session(userID: 0),
        target: target
      )
    }
    XCTAssertEqual(invalidUserMessage, legacyMessage)
    let readRequestCount = await spy.readRequestCount()
    XCTAssertEqual(readRequestCount, 0)
  }

  func testFullSessionReadMapsExactTargetAndCredentialShape() async throws {
    let spy = ThreadCloudFavoriteClientSpy(
      readState: state(markedPostID: 91)
    )
    let service = TiebaCoreAccountService(client: spy)
    let target = try favoriteTarget()
    let storedSession = session(cookieName: .bdussBFESS)

    let result = try await service.threadCloudFavorite(
      session: storedSession,
      target: target
    )

    XCTAssertEqual(result.userID, 7)
    XCTAssertEqual(result.target, target)
    XCTAssertEqual(result.snapshot.markedPostID, 91)
    XCTAssertTrue(result.snapshot.isFavorited)
    let requests = await spy.readRequests()
    let request = try XCTUnwrap(requests.only)
    XCTAssertEqual(request.userID, 7)
    XCTAssertEqual(request.forumID, 42)
    XCTAssertEqual(request.threadID, 84)
    XCTAssertEqual(request.bdussBytes, 192)
    XCTAssertEqual(request.stokenBytes, 64)
    XCTAssertEqual(request.cookieName, .bdussBFESS)
  }

  func testReadRejectsEveryReturnedIdentityAndMarkerMismatch() async throws {
    let target = try favoriteTarget()
    let mismatches = [
      state(userID: 8, markedPostID: 91),
      state(forumID: 43, markedPostID: 91),
      state(threadID: 85, markedPostID: 91),
      state(markedPostID: 0),
    ]

    for mismatch in mismatches {
      let spy = ThreadCloudFavoriteClientSpy(readState: mismatch)
      let service = TiebaCoreAccountService(client: spy)
      let message = await browseErrorMessage {
        try await service.threadCloudFavorite(session: session(), target: target)
      }
      XCTAssertEqual(
        message,
        "\u{8d34}\u{5427}\u{8fd4}\u{56de}\u{4e86}\u{4e0d}\u{5339}\u{914d}\u{7684}\u{4e3b}\u{9898}\u{6536}\u{85cf}\u{72b6}\u{6001}\u{ff0c}\u{8bf7}\u{91cd}\u{65b0}\u{52a0}\u{8f7d}\u{540e}\u{518d}\u{8bd5}\u{3002}"
      )
      let readRequestCount = await spy.readRequestCount()
      XCTAssertEqual(readRequestCount, 1)
    }
  }

  func testWriteRequiresFullSessionAndRejectsInvalidMarkerBeforeCoreRequest() async throws {
    let spy = ThreadCloudFavoriteClientSpy(
      writeState: state(markedPostID: 91)
    )
    let service = TiebaCoreAccountService(client: spy)
    let target = try favoriteTarget()

    let invalidMarkerMessage = await browseErrorMessage {
      try await service.setThreadCloudFavorite(
        session: session(),
        target: target,
        markedPostID: 0
      )
    }
    XCTAssertEqual(invalidMarkerMessage, "\u{6536}\u{85cf}\u{697c}\u{5c42}\u{6807}\u{8bc6}\u{65e0}\u{6548}\u{3002}")

    let legacyMessage = await browseErrorMessage {
      try await service.setThreadCloudFavorite(
        session: session(stoken: nil),
        target: target,
        markedPostID: 91
      )
    }
    XCTAssertEqual(
      legacyMessage,
      "\u{6b64}\u{8d26}\u{6237}\u{9700}\u{8981}\u{91cd}\u{65b0}\u{767b}\u{5f55}\u{ff0c}\u{624d}\u{80fd}\u{5b89}\u{5168}\u{66f4}\u{65b0}\u{4e3b}\u{9898}\u{6536}\u{85cf}\u{3002}"
    )
    let writeRequestCount = await spy.writeRequestCount()
    XCTAssertEqual(writeRequestCount, 0)
  }

  func testWriteMapsAddAndRemoveMarkersExactly() async throws {
    let target = try favoriteTarget()
    let addSpy = ThreadCloudFavoriteClientSpy(
      writeState: state(markedPostID: 91)
    )
    let addService = TiebaCoreAccountService(client: addSpy)

    let added = try await addService.setThreadCloudFavorite(
      session: session(cookieName: .bdussBFESS),
      target: target,
      markedPostID: 91
    )
    XCTAssertEqual(added.snapshot.markedPostID, 91)
    XCTAssertTrue(added.snapshot.isFavorited)
    let addRequests = await addSpy.writeRequests()
    let addRequest = try XCTUnwrap(addRequests.only)
    XCTAssertEqual(addRequest.markedPostID, 91)
    XCTAssertEqual(addRequest.cookieName, .bdussBFESS)

    let removeSpy = ThreadCloudFavoriteClientSpy(
      writeState: state(markedPostID: nil)
    )
    let removeService = TiebaCoreAccountService(client: removeSpy)
    let removed = try await removeService.setThreadCloudFavorite(
      session: session(),
      target: target,
      markedPostID: nil
    )
    XCTAssertNil(removed.snapshot.markedPostID)
    XCTAssertFalse(removed.snapshot.isFavorited)
    let removeRequests = await removeSpy.writeRequests()
    let removeRequest = try XCTUnwrap(removeRequests.only)
    XCTAssertNil(removeRequest.markedPostID)
  }

  func testMutationRejectsIdentityOrDesiredMarkerMismatch() async throws {
    let target = try favoriteTarget()
    let mismatches = [
      state(userID: 8, markedPostID: 91),
      state(forumID: 43, markedPostID: 91),
      state(threadID: 85, markedPostID: 91),
      state(markedPostID: 92),
      state(markedPostID: 0),
    ]

    for mismatch in mismatches {
      let spy = ThreadCloudFavoriteClientSpy(writeState: mismatch)
      let service = TiebaCoreAccountService(client: spy)
      let message = await browseErrorMessage {
        try await service.setThreadCloudFavorite(
          session: session(),
          target: target,
          markedPostID: 91
        )
      }
      XCTAssertNotNil(message)
      let writeRequestCount = await spy.writeRequestCount()
      XCTAssertEqual(writeRequestCount, 1)
    }
  }

  func testConcurrentIdenticalWritesShareOneCoreTask() async throws {
    let spy = ThreadCloudFavoriteClientSpy(
      writeState: state(markedPostID: 91),
      suspendsWrite: true
    )
    let service = TiebaCoreAccountService(client: spy)
    let target = try favoriteTarget()
    let storedSession = session()

    let first = Task {
      try await service.setThreadCloudFavorite(
        session: storedSession,
        target: target,
        markedPostID: 91
      )
    }
    guard await waitForThreadCloudFavoriteTest({ await spy.writeRequestCount() == 1 }) else {
      await cleanUpSuspendedWrite(spy, tasks: [first])
      XCTFail("Timed out waiting for the first write")
      return
    }
    let second = Task {
      try await service.setThreadCloudFavorite(
        session: storedSession,
        target: target,
        markedPostID: 91
      )
    }
    for _ in 0..<50 { await Task.yield() }
    let requestCountBeforeRelease = await spy.writeRequestCount()
    XCTAssertEqual(requestCountBeforeRelease, 1)

    await spy.releaseWrite()
    let firstResult = try await first.value
    let secondResult = try await second.value
    XCTAssertEqual(firstResult, secondResult)
    XCTAssertEqual(firstResult.snapshot.markedPostID, 91)
    let finalWriteRequestCount = await spy.writeRequestCount()
    let finalReadRequestCount = await spy.readRequestCount()
    XCTAssertEqual(finalWriteRequestCount, 1)
    XCTAssertEqual(finalReadRequestCount, 0)
  }

  func testConflictingMarkerOnlyRereadsAndRejectsMismatchedAuthoritativeState() async throws {
    let spy = ThreadCloudFavoriteClientSpy(
      readState: state(markedPostID: 91),
      writeState: state(markedPostID: 91),
      suspendsWrite: true
    )
    let service = TiebaCoreAccountService(client: spy)
    let target = try favoriteTarget()
    let storedSession = session()

    let add = Task {
      try await service.setThreadCloudFavorite(
        session: storedSession,
        target: target,
        markedPostID: 91
      )
    }
    guard await waitForThreadCloudFavoriteTest({ await spy.writeRequestCount() == 1 }) else {
      await cleanUpSuspendedWrite(spy, tasks: [add])
      XCTFail("Timed out waiting for the first write")
      return
    }
    let remove = Task {
      try await service.setThreadCloudFavorite(
        session: storedSession,
        target: target,
        markedPostID: nil
      )
    }
    guard await waitForThreadCloudFavoriteTest({
      await service.threadCloudFavoriteWriteConflictWaiterCount() == 1
    }) else {
      await cleanUpSuspendedWrite(spy, tasks: [add, remove])
      XCTFail("Timed out waiting for the conflicting write")
      return
    }
    let writeRequestCountBeforeRelease = await spy.writeRequestCount()
    let readRequestCountBeforeRelease = await spy.readRequestCount()
    XCTAssertEqual(writeRequestCountBeforeRelease, 1)
    XCTAssertEqual(readRequestCountBeforeRelease, 0)

    await spy.releaseWrite()
    let addResult = try await add.value
    let removeMessage = await browseErrorMessage { try await remove.value }
    let finalWriteRequestCount = await spy.writeRequestCount()
    let finalReadRequestCount = await spy.readRequestCount()
    let finalConflictWaiterCount = await service.threadCloudFavoriteWriteConflictWaiterCount()
    XCTAssertEqual(addResult.snapshot.markedPostID, 91)
    XCTAssertEqual(
      removeMessage,
      "先前的云端收藏操作已结束，已重新读取当前状态；请确认后再操作。"
    )
    XCTAssertEqual(finalWriteRequestCount, 1)
    XCTAssertEqual(finalReadRequestCount, 1)
    XCTAssertEqual(finalConflictWaiterCount, 0)
  }

  func testRotatedSessionNeverCoalescesWithOlderWrite() async throws {
    let spy = ThreadCloudFavoriteClientSpy(
      readState: state(markedPostID: 91),
      writeState: state(markedPostID: 91),
      suspendsWrite: true
    )
    let service = TiebaCoreAccountService(client: spy)
    let target = try favoriteTarget()
    let firstRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000071")
    )
    let secondRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000072")
    )

    let first = Task {
      try await service.setThreadCloudFavorite(
        session: session(sessionRevision: firstRevision),
        target: target,
        markedPostID: 91
      )
    }
    guard await waitForThreadCloudFavoriteTest({ await spy.writeRequestCount() == 1 }) else {
      await cleanUpSuspendedWrite(spy, tasks: [first])
      XCTFail("Timed out waiting for the first write")
      return
    }
    let rotated = Task {
      try await service.setThreadCloudFavorite(
        session: session(sessionRevision: secondRevision),
        target: target,
        markedPostID: 91
      )
    }
    guard await waitForThreadCloudFavoriteTest({
      await service.threadCloudFavoriteWriteConflictWaiterCount() == 1
    }) else {
      await cleanUpSuspendedWrite(spy, tasks: [first, rotated])
      XCTFail("Timed out waiting for the conflicting write")
      return
    }
    await spy.releaseWrite()

    let firstResult = try await first.value
    let rotatedResult = try await rotated.value
    let finalWriteRequestCount = await spy.writeRequestCount()
    let finalReadRequestCount = await spy.readRequestCount()
    XCTAssertEqual(firstResult.snapshot.markedPostID, 91)
    XCTAssertEqual(rotatedResult.snapshot.markedPostID, 91)
    XCTAssertEqual(finalWriteRequestCount, 1)
    XCTAssertEqual(finalReadRequestCount, 1)
  }

  func testCredentialChangesNeverCoalesceWithinTheSameSessionRevision() async throws {
    let revision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000073")
    )
    let original = session(sessionRevision: revision)
    let rotations: [ThreadCloudFavoriteCredentialRotation] = [
      ThreadCloudFavoriteCredentialRotation(
        name: "BDUSS",
        session: session(
          bduss: String(repeating: "c", count: 192),
          sessionRevision: revision
        ),
        changesBDUSS: true,
        changesSTOKEN: false,
        changesCookieName: false
      ),
      ThreadCloudFavoriteCredentialRotation(
        name: "STOKEN",
        session: session(
          stoken: String(repeating: "t", count: 64),
          sessionRevision: revision
        ),
        changesBDUSS: false,
        changesSTOKEN: true,
        changesCookieName: false
      ),
      ThreadCloudFavoriteCredentialRotation(
        name: "cookie name",
        session: session(cookieName: .bdussBFESS, sessionRevision: revision),
        changesBDUSS: false,
        changesSTOKEN: false,
        changesCookieName: true
      ),
    ]

    for rotation in rotations {
      XCTAssertEqual(rotation.session.id, original.id, rotation.name)
      XCTAssertEqual(rotation.session.sessionRevision, original.sessionRevision, rotation.name)
      let spy = ThreadCloudFavoriteClientSpy(
        readState: state(markedPostID: 91),
        writeState: state(markedPostID: 91),
        suspendsWrite: true
      )
      let service = TiebaCoreAccountService(client: spy)
      let target = try favoriteTarget()
      let first = Task {
        try await service.setThreadCloudFavorite(
          session: original,
          target: target,
          markedPostID: 91
        )
      }
      guard await waitForThreadCloudFavoriteTest({ await spy.writeRequestCount() == 1 }) else {
        await cleanUpSuspendedWrite(spy, tasks: [first])
        XCTFail("Timed out waiting for the first write for \(rotation.name)")
        return
      }

      let rotated = Task {
        try await service.setThreadCloudFavorite(
          session: rotation.session,
          target: target,
          markedPostID: 91
        )
      }
      guard await waitForThreadCloudFavoriteTest({
        await service.threadCloudFavoriteWriteConflictWaiterCount() == 1
      }) else {
        await cleanUpSuspendedWrite(spy, tasks: [first, rotated])
        XCTFail("Timed out waiting for the \(rotation.name) conflict")
        return
      }

      let writesBeforeRelease = await spy.writeRequestCount()
      let readsBeforeRelease = await spy.readRequestCount()
      XCTAssertEqual(writesBeforeRelease, 1, rotation.name)
      XCTAssertEqual(readsBeforeRelease, 0, rotation.name)
      await spy.releaseWrite()

      let firstResult = try await first.value
      let rotatedResult = try await rotated.value
      XCTAssertEqual(firstResult.snapshot.markedPostID, 91, rotation.name)
      XCTAssertEqual(rotatedResult.snapshot.markedPostID, 91, rotation.name)

      let writes = await spy.writeRequests()
      let reads = await spy.readRequests()
      let write = try XCTUnwrap(writes.only, rotation.name)
      let read = try XCTUnwrap(reads.only, rotation.name)
      let originalSTOKEN = try XCTUnwrap(original.stoken, rotation.name)
      let rotatedSTOKEN = try XCTUnwrap(rotation.session.stoken, rotation.name)
      XCTAssertEqual(write.userID, read.userID, rotation.name)
      XCTAssertEqual(write.forumID, read.forumID, rotation.name)
      XCTAssertEqual(write.threadID, read.threadID, rotation.name)
      XCTAssertEqual(write.bdussBytes, read.bdussBytes, rotation.name)
      XCTAssertEqual(write.stokenBytes, read.stokenBytes, rotation.name)
      XCTAssertEqual(
        write.bdussFingerprint,
        credentialFingerprint(original.bduss),
        rotation.name
      )
      XCTAssertEqual(
        write.stokenFingerprint,
        credentialFingerprint(originalSTOKEN),
        rotation.name
      )
      XCTAssertEqual(
        read.bdussFingerprint,
        credentialFingerprint(rotation.session.bduss),
        rotation.name
      )
      XCTAssertEqual(
        read.stokenFingerprint,
        credentialFingerprint(rotatedSTOKEN),
        rotation.name
      )
      XCTAssertEqual(read.cookieName.rawValue, rotation.session.bdussCookieName.rawValue)
      assertFingerprintChange(
        write.bdussFingerprint,
        read.bdussFingerprint,
        expected: rotation.changesBDUSS,
        message: rotation.name
      )
      assertFingerprintChange(
        write.stokenFingerprint,
        read.stokenFingerprint,
        expected: rotation.changesSTOKEN,
        message: rotation.name
      )
      if rotation.changesCookieName {
        XCTAssertNotEqual(write.cookieName, read.cookieName, rotation.name)
      } else {
        XCTAssertEqual(write.cookieName, read.cookieName, rotation.name)
      }
      XCTAssertEqual(
        rotation.changesCookieName,
        write.cookieName != read.cookieName,
        rotation.name
      )
      let finalConflictWaiterCount =
        await service.threadCloudFavoriteWriteConflictWaiterCount()
      XCTAssertEqual(finalConflictWaiterCount, 0, rotation.name)
    }
  }

  func testCancellationAfterWriteStartsDoesNotDiscardConfirmedResult() async throws {
    let spy = ThreadCloudFavoriteClientSpy(
      writeState: state(markedPostID: 91),
      suspendsWrite: true
    )
    let service = TiebaCoreAccountService(client: spy)
    let target = try favoriteTarget()
    let write = Task {
      try await service.setThreadCloudFavorite(
        session: session(),
        target: target,
        markedPostID: 91
      )
    }
    guard await waitForThreadCloudFavoriteTest({ await spy.writeRequestCount() == 1 }) else {
      await cleanUpSuspendedWrite(spy, tasks: [write])
      XCTFail("Timed out waiting for the write")
      return
    }

    write.cancel()
    await spy.releaseWrite()
    let result = try await write.value

    XCTAssertEqual(result.snapshot.markedPostID, 91)
    let writeRequestCount = await spy.writeRequestCount()
    XCTAssertEqual(writeRequestCount, 1)
  }

  func testCancellationAndServerErrorsAreMappedWithoutLeakingMessages() async throws {
    let target = try favoriteTarget()
    let cancellationSpy = ThreadCloudFavoriteClientSpy(readFailure: .cancellation)
    let cancellationService = TiebaCoreAccountService(client: cancellationSpy)
    do {
      _ = try await cancellationService.threadCloudFavorite(
        session: session(),
        target: target
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }

    let serverSpy = ThreadCloudFavoriteClientSpy(
      readFailure: .core(.server(code: 401, message: "secret-server-message"))
    )
    let serverService = TiebaCoreAccountService(client: serverSpy)
    let message = await browseErrorMessage {
      try await serverService.threadCloudFavorite(session: session(), target: target)
    }
    XCTAssertEqual(message, "\u{8d26}\u{6237}\u{8bf7}\u{6c42}\u{5931}\u{8d25}\u{ff08}\u{9519}\u{8bef}\u{7801} 401\u{ff09}\u{3002}")
    XCTAssertFalse(message?.contains("secret-server-message") ?? true)

    let writeCancellationSpy = ThreadCloudFavoriteClientSpy(
      writeFailure: .cancellation
    )
    let writeCancellationService = TiebaCoreAccountService(client: writeCancellationSpy)
    do {
      _ = try await writeCancellationService.setThreadCloudFavorite(
        session: session(),
        target: target,
        markedPostID: 91
      )
      XCTFail("Expected cancellation")
    } catch is CancellationError {
    } catch {
      XCTFail("Expected CancellationError, got \(error)")
    }

    let writeServerSpy = ThreadCloudFavoriteClientSpy(
      writeFailure: .core(.server(code: 500, message: "secret-write-message"))
    )
    let writeServerService = TiebaCoreAccountService(client: writeServerSpy)
    let writeMessage = await browseErrorMessage {
      try await writeServerService.setThreadCloudFavorite(
        session: session(),
        target: target,
        markedPostID: 91
      )
    }
    XCTAssertEqual(writeMessage, "\u{8d26}\u{6237}\u{8bf7}\u{6c42}\u{5931}\u{8d25}\u{ff08}\u{9519}\u{8bef}\u{7801} 500\u{ff09}\u{3002}")
    XCTAssertFalse(writeMessage?.contains("secret-write-message") ?? true)
  }
}

private struct ThreadCloudFavoriteClientRequest: Equatable, Sendable {
  let userID: Int64
  let forumID: Int64
  let threadID: Int64
  let markedPostID: Int64?
  let bdussBytes: Int
  let stokenBytes: Int
  let bdussFingerprint: Int
  let stokenFingerprint: Int
  let cookieName: TiebaBDUSSCookieName
}

private struct ThreadCloudFavoriteCredentialRotation: Sendable {
  let name: String
  let session: StoredAccountSession
  let changesBDUSS: Bool
  let changesSTOKEN: Bool
  let changesCookieName: Bool
}

private enum ThreadCloudFavoriteSpyFailure: Sendable {
  case none
  case cancellation
  case core(TiebaClientError)
}

private enum ThreadCloudFavoriteSpyError: Error, Sendable {
  case unexpectedCall
}

private actor ThreadCloudFavoriteClientSpy: TiebaAuthenticatedAccountClient {
  private let readState: TiebaThreadCloudFavoriteState?
  private let writeState: TiebaThreadCloudFavoriteState?
  private let readFailure: ThreadCloudFavoriteSpyFailure
  private let writeFailure: ThreadCloudFavoriteSpyFailure
  private let suspendsWrite: Bool
  private var recordedReads: [ThreadCloudFavoriteClientRequest] = []
  private var recordedWrites: [ThreadCloudFavoriteClientRequest] = []
  private var writeIsReleased = false
  private var writeWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    readState: TiebaThreadCloudFavoriteState? = nil,
    writeState: TiebaThreadCloudFavoriteState? = nil,
    readFailure: ThreadCloudFavoriteSpyFailure = .none,
    writeFailure: ThreadCloudFavoriteSpyFailure = .none,
    suspendsWrite: Bool = false
  ) {
    self.readState = readState
    self.writeState = writeState
    self.readFailure = readFailure
    self.writeFailure = writeFailure
    self.suspendsWrite = suspendsWrite
  }

  func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    throw ThreadCloudFavoriteSpyError.unexpectedCall
  }

  func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) async throws -> TiebaFollowedForumPage {
    throw ThreadCloudFavoriteSpyError.unexpectedCall
  }

  func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    throw ThreadCloudFavoriteSpyError.unexpectedCall
  }

  func getForumAccountState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw ThreadCloudFavoriteSpyError.unexpectedCall
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    throw ThreadCloudFavoriteSpyError.unexpectedCall
  }

  func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    throw ThreadCloudFavoriteSpyError.unexpectedCall
  }

  func getThreadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) async throws -> TiebaThreadCloudFavoriteState {
    recordedReads.append(
      request(
        credential: credential,
        userID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        markedPostID: nil
      )
    )
    try throwFailure(readFailure)
    guard let readState else { throw ThreadCloudFavoriteSpyError.unexpectedCall }
    return readState
  }

  func setThreadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    markedPostID: Int64?
  ) async throws -> TiebaThreadCloudFavoriteState {
    recordedWrites.append(
      request(
        credential: credential,
        userID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        markedPostID: markedPostID
      )
    )
    if suspendsWrite, !writeIsReleased {
      await withCheckedContinuation { writeWaiters.append($0) }
    }
    try throwFailure(writeFailure)
    guard let writeState else { throw ThreadCloudFavoriteSpyError.unexpectedCall }
    return writeState
  }

  func readRequests() -> [ThreadCloudFavoriteClientRequest] { recordedReads }
  func writeRequests() -> [ThreadCloudFavoriteClientRequest] { recordedWrites }
  func readRequestCount() -> Int { recordedReads.count }
  func writeRequestCount() -> Int { recordedWrites.count }

  func releaseWrite() {
    writeIsReleased = true
    let waiters = writeWaiters
    writeWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  private func request(
    credential: TiebaSessionCredential,
    userID: Int64,
    forumID: Int64,
    threadID: Int64,
    markedPostID: Int64?
  ) -> ThreadCloudFavoriteClientRequest {
    ThreadCloudFavoriteClientRequest(
      userID: userID,
      forumID: forumID,
      threadID: threadID,
      markedPostID: markedPostID,
      bdussBytes: credential.bduss.utf8.count,
      stokenBytes: credential.stoken.utf8.count,
      bdussFingerprint: credentialFingerprint(credential.bduss),
      stokenFingerprint: credentialFingerprint(credential.stoken),
      cookieName: credential.bdussCookieName
    )
  }

  private func throwFailure(_ failure: ThreadCloudFavoriteSpyFailure) throws {
    switch failure {
    case .none:
      break
    case .cancellation:
      throw CancellationError()
    case .core(let error):
      throw error
    }
  }
}

private extension Array {
  var only: Element? { count == 1 ? self[0] : nil }
}

private func favoriteTarget() throws -> ThreadCloudFavoriteTarget {
  try XCTUnwrap(
    ThreadCloudFavoriteTarget(forumID: 42, forumName: "  swift  ", threadID: 84)
  )
}

private func state(
  userID: Int64 = 7,
  forumID: Int64 = 42,
  threadID: Int64 = 84,
  markedPostID: Int64?
) -> TiebaThreadCloudFavoriteState {
  TiebaThreadCloudFavoriteState(
    userID: userID,
    forumID: forumID,
    threadID: threadID,
    markedPostID: markedPostID
  )
}

private func session(
  userID: Int64 = 7,
  bduss: String = String(repeating: "b", count: 192),
  stoken: String? = String(repeating: "s", count: 64),
  cookieName: AccountBDUSSCookieName = .bduss,
  sessionRevision: UUID = UUID()
) -> StoredAccountSession {
  StoredAccountSession(
    id: userID,
    username: "tester",
    displayName: "Tester",
    portrait: "portrait",
    bduss: bduss,
    stoken: stoken,
    bdussCookieName: cookieName,
    createdAt: Date(timeIntervalSince1970: 1),
    updatedAt: Date(timeIntervalSince1970: 1),
    sessionRevision: sessionRevision
  )
}

private func credentialFingerprint(_ credential: String) -> Int {
  var hasher = Hasher()
  hasher.combine(credential)
  return hasher.finalize()
}

private func assertFingerprintChange(
  _ original: Int,
  _ rotated: Int,
  expected: Bool,
  message: String,
  file: StaticString = #filePath,
  line: UInt = #line
) {
  if expected {
    XCTAssertNotEqual(original, rotated, message, file: file, line: line)
  } else {
    XCTAssertEqual(original, rotated, message, file: file, line: line)
  }
}

private func browseErrorMessage<T>(
  _ operation: () async throws -> T
) async -> String? {
  do {
    _ = try await operation()
    XCTFail("Expected BrowseError")
    return nil
  } catch let error as BrowseError {
    return error.errorDescription
  } catch {
    XCTFail("Expected BrowseError, got \(error)")
    return nil
  }
}

private func waitForThreadCloudFavoriteTest(
  _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
  for _ in 0..<1_000 {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return false
}

private func cleanUpSuspendedWrite(
  _ spy: ThreadCloudFavoriteClientSpy,
  tasks: [Task<ThreadCloudFavoriteData, Error>]
) async {
  tasks.forEach { $0.cancel() }
  await spy.releaseWrite()
  for task in tasks {
    _ = await task.result
  }
}
