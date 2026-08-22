import Foundation
import XCTest

@testable import TiebaPlusPlus

final class KeychainAccountVaultTests: XCTestCase {
  func testStoresSwitchesAndRemovesMultipleAccountsWithoutExposingSecretsInSummaries() async throws {
    let backend = InMemoryAccountVaultBackend()
    let vault = KeychainAccountVault(backend: backend)
    try await vault.upsert(session(userID: 1, name: "one", updatedAt: 10))
    try await vault.upsert(session(userID: 2, name: "two", updatedAt: 20))

    var summaries = try await vault.accountSummaries()
    XCTAssertEqual(summaries.map(\.id), [2, 1])
    XCTAssertEqual(summaries.first(where: { $0.isActive })?.id, 2)
    XCTAssertEqual(summaries.map(\.preferredName), ["two", "one"])
    XCTAssertTrue(summaries.allSatisfy { $0.hasFullCredentials })
    let archiveText = String(decoding: try XCTUnwrap(backend.snapshot()), as: UTF8.self)
    XCTAssertTrue(archiveText.contains("\"version\":3"))
    XCTAssertTrue(archiveText.lowercased().contains("stoken"))
    XCTAssertFalse(archiveText.lowercased().contains("tbs"))

    try await vault.switchActive(to: 1)
    let switchedSession = try await vault.activeSession()
    XCTAssertEqual(switchedSession?.id, 1)
    XCTAssertEqual(switchedSession?.bduss.count, 192)
    XCTAssertEqual(switchedSession?.stoken?.count, 64)
    XCTAssertEqual(switchedSession?.bdussCookieName, .bdussBFESS)
    XCTAssertNotNil(switchedSession?.credentials)

    try await vault.remove(userID: 1)
    summaries = try await vault.accountSummaries()
    XCTAssertEqual(summaries.map(\.id), [2])
    XCTAssertTrue(summaries[0].isActive)

    try await vault.remove(userID: 2)
    let removedSession = try await vault.activeSession()
    let removedSummaries = try await vault.accountSummaries()
    XCTAssertNil(removedSession)
    XCTAssertTrue(removedSummaries.isEmpty)
    XCTAssertNil(backend.snapshot())
  }

  func testExactSessionLookupReadsAnInactiveAccountWithoutChangingTheActiveAccount() async throws {
    let backend = InMemoryAccountVaultBackend()
    let vault = KeychainAccountVault(backend: backend)
    try await vault.upsert(session(userID: 1, name: "one"))
    try await vault.upsert(session(userID: 2, name: "two"))
    try await vault.switchActive(to: 1)
    let writeCount = backend.writeCount

    let inactive = try await vault.session(userID: 2)
    let missing = try await vault.session(userID: 3)
    let invalid = try await vault.session(userID: 0)
    let active = try await vault.activeSession()

    XCTAssertEqual(inactive?.id, 2)
    XCTAssertEqual(inactive?.username, "two")
    XCTAssertNil(missing)
    XCTAssertNil(invalid)
    XCTAssertEqual(active?.id, 1)
    XCTAssertEqual(backend.writeCount, writeCount)
  }

  func testUpsertPreservesOriginalCreationDate() async throws {
    let backend = InMemoryAccountVaultBackend()
    let vault = KeychainAccountVault(backend: backend)
    try await vault.upsert(session(userID: 1, name: "old", createdAt: 5, updatedAt: 10))
    try await vault.upsert(session(userID: 1, name: "new", createdAt: 20, updatedAt: 30))

    let storedAccount = try await vault.activeSession()
    let account = try XCTUnwrap(storedAccount)
    XCTAssertEqual(account.username, "new")
    XCTAssertEqual(account.createdAt, Date(timeIntervalSince1970: 5))
    XCTAssertEqual(account.updatedAt, Date(timeIntervalSince1970: 30))
  }

  func testClockRollbackCannotWriteAnUnreadableArchive() async throws {
    let backend = InMemoryAccountVaultBackend()
    let vault = KeychainAccountVault(backend: backend)
    try await vault.upsert(session(userID: 1, name: "future", createdAt: 100, updatedAt: 100))
    try await vault.upsert(session(userID: 1, name: "after-rollback", createdAt: 10, updatedAt: 10))

    let storedAccount = try await vault.activeSession()
    let account = try XCTUnwrap(storedAccount)
    XCTAssertEqual(account.username, "after-rollback")
    XCTAssertEqual(account.createdAt, Date(timeIntervalSince1970: 100))
    XCTAssertEqual(account.updatedAt, Date(timeIntervalSince1970: 100))
    let summaries = try await vault.accountSummaries()
    XCTAssertEqual(summaries.count, 1)
  }

  func testMigratesV1ArchiveOnceAndPersistsStableSessionRevision() async throws {
    let expectedRevision = try XCTUnwrap(
      UUID(uuidString: "11111111-2222-3333-4444-555555555555")
    )
    let unexpectedRevision = try XCTUnwrap(
      UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
    )
    let legacyArchive = LegacyAccountVaultArchive(
      activeUserID: 7,
      accounts: [
        LegacyStoredAccountSession(
          id: 7,
          username: "legacy",
          displayName: "Legacy Account",
          portrait: "portrait-7",
          bduss: String(repeating: "b", count: 192),
          createdAt: Date(timeIntervalSince1970: 5),
          updatedAt: Date(timeIntervalSince1970: 10)
        )
      ]
    )
    let backend = InMemoryAccountVaultBackend(initial: try JSONEncoder().encode(legacyArchive))
    let migrationGenerator = RevisionGeneratorSpy(revision: expectedRevision)
    let migratingVault = KeychainAccountVault(
      backend: backend,
      sessionRevisionGenerator: { migrationGenerator.next() }
    )

    let migratedSession = try await migratingVault.activeSession()
    let migrated = try XCTUnwrap(migratedSession)
    XCTAssertEqual(migrated.id, 7)
    XCTAssertEqual(migrated.sessionRevision, expectedRevision)
    XCTAssertNil(migrated.stoken)
    XCTAssertEqual(migrated.bdussCookieName, .bduss)
    XCTAssertNil(migrated.credentials)
    let migratedSummaries = try await migratingVault.accountSummaries()
    XCTAssertFalse(try XCTUnwrap(migratedSummaries.first).hasFullCredentials)
    XCTAssertEqual(migrated.createdAt, Date(timeIntervalSince1970: 5))
    XCTAssertEqual(migrated.updatedAt, Date(timeIntervalSince1970: 10))
    XCTAssertEqual(migrationGenerator.callCount, 1)
    XCTAssertEqual(backend.writeCount, 1)

    let migratedData = try XCTUnwrap(backend.snapshot())
    let migratedHeader = try JSONDecoder().decode(EncodedArchiveHeader.self, from: migratedData)
    XCTAssertEqual(migratedHeader.version, 3)

    let reopeningGenerator = RevisionGeneratorSpy(revision: unexpectedRevision)
    let reopenedVault = KeychainAccountVault(
      backend: backend,
      sessionRevisionGenerator: { reopeningGenerator.next() }
    )
    let reopenedSession = try await reopenedVault.activeSession()
    let reopened = try XCTUnwrap(reopenedSession)
    XCTAssertEqual(reopened.sessionRevision, expectedRevision)
    XCTAssertEqual(reopeningGenerator.callCount, 0)
    XCTAssertEqual(backend.writeCount, 1)
  }

  func testMigratesV2ArchivePreservingRevisionWithoutCallingGenerator() async throws {
    let expectedRevision = try XCTUnwrap(
      UUID(uuidString: "22222222-3333-4444-5555-666666666666")
    )
    let legacyArchive = LegacyAccountVaultArchiveV2(
      activeUserID: 8,
      accounts: [
        LegacyStoredAccountSessionV2(
          id: 8,
          username: "legacy-v2",
          displayName: "Legacy V2",
          portrait: "portrait-8",
          bduss: String(repeating: "b", count: 192),
          createdAt: Date(timeIntervalSince1970: 5),
          updatedAt: Date(timeIntervalSince1970: 10),
          sessionRevision: expectedRevision
        )
      ]
    )
    let backend = InMemoryAccountVaultBackend(initial: try JSONEncoder().encode(legacyArchive))
    let revisionGenerator = RevisionGeneratorSpy()
    let vault = KeychainAccountVault(
      backend: backend,
      sessionRevisionGenerator: { revisionGenerator.next() }
    )

    let migratedSession = try await vault.activeSession()
    let migrated = try XCTUnwrap(migratedSession)
    XCTAssertEqual(migrated.sessionRevision, expectedRevision)
    XCTAssertNil(migrated.stoken)
    XCTAssertEqual(migrated.bdussCookieName, .bduss)
    XCTAssertNil(migrated.credentials)
    XCTAssertEqual(revisionGenerator.callCount, 0)
    XCTAssertEqual(backend.writeCount, 1)
    let migratedData = try XCTUnwrap(backend.snapshot())
    XCTAssertEqual(
      try JSONDecoder().decode(EncodedArchiveHeader.self, from: migratedData).version,
      3
    )

    let reopened = KeychainAccountVault(
      backend: backend,
      sessionRevisionGenerator: { revisionGenerator.next() }
    )
    let reopenedSession = try await reopened.activeSession()
    XCTAssertEqual(reopenedSession?.sessionRevision, expectedRevision)
    XCTAssertEqual(revisionGenerator.callCount, 0)
    XCTAssertEqual(backend.writeCount, 1)
  }

  func testInvalidV1ArchiveIsNotOverwrittenDuringMigration() async throws {
    let invalidArchive = LegacyAccountVaultArchive(
      activeUserID: 7,
      accounts: [
        LegacyStoredAccountSession(
          id: 7,
          username: "legacy",
          displayName: "Legacy Account",
          portrait: "portrait-7",
          bduss: "short",
          createdAt: Date(timeIntervalSince1970: 5),
          updatedAt: Date(timeIntervalSince1970: 10)
        )
      ]
    )
    let originalData = try JSONEncoder().encode(invalidArchive)
    let backend = InMemoryAccountVaultBackend(initial: originalData)
    let revisionGenerator = RevisionGeneratorSpy()
    let vault = KeychainAccountVault(
      backend: backend,
      sessionRevisionGenerator: { revisionGenerator.next() }
    )

    await XCTAssertThrowsErrorAsync {
      _ = try await vault.activeSession()
    } verify: { error in
      XCTAssertEqual(error as? AccountVaultError, .invalidArchive)
    }
    XCTAssertEqual(backend.snapshot(), originalData)
    XCTAssertEqual(backend.writeCount, 0)
    XCTAssertEqual(revisionGenerator.callCount, 0)
  }

  func testInvalidV2ArchiveIsNotOverwrittenDuringMigration() async throws {
    let invalidArchive = LegacyAccountVaultArchiveV2(
      activeUserID: 8,
      accounts: [
        LegacyStoredAccountSessionV2(
          id: 8,
          username: "legacy-v2",
          displayName: "Legacy V2",
          portrait: "portrait-8",
          bduss: "short",
          createdAt: Date(timeIntervalSince1970: 5),
          updatedAt: Date(timeIntervalSince1970: 10),
          sessionRevision: UUID()
        )
      ]
    )
    let originalData = try JSONEncoder().encode(invalidArchive)
    let backend = InMemoryAccountVaultBackend(initial: originalData)
    let vault = KeychainAccountVault(backend: backend)

    await XCTAssertThrowsErrorAsync {
      _ = try await vault.activeSession()
    } verify: { error in
      XCTAssertEqual(error as? AccountVaultError, .invalidArchive)
    }
    XCTAssertEqual(backend.snapshot(), originalData)
    XCTAssertEqual(backend.writeCount, 0)
  }

  func testInvalidV3CredentialPairIsNotOverwritten() async throws {
    let invalidSession = StoredAccountSession(
      id: 9,
      username: "invalid-v3",
      displayName: "Invalid V3",
      portrait: "portrait-9",
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 63) + ";",
      bdussCookieName: .bduss,
      createdAt: Date(timeIntervalSince1970: 5),
      updatedAt: Date(timeIntervalSince1970: 10)
    )
    let archive = EncodedAccountVaultArchiveV3(
      activeUserID: invalidSession.id,
      accounts: [invalidSession]
    )
    let originalData = try JSONEncoder().encode(archive)
    let backend = InMemoryAccountVaultBackend(initial: originalData)
    let vault = KeychainAccountVault(backend: backend)

    await XCTAssertThrowsErrorAsync {
      _ = try await vault.activeSession()
    } verify: { error in
      XCTAssertEqual(error as? AccountVaultError, .invalidArchive)
    }
    XCTAssertEqual(backend.snapshot(), originalData)
    XCTAssertEqual(backend.writeCount, 0)
  }

  func testEveryExistingAccountUpsertRotatesRevisionWithoutChangingDateSemantics() async throws {
    let initialRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000001")
    )
    let sameTimestampRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000002")
    )
    let rollbackRevision = try XCTUnwrap(
      UUID(uuidString: "00000000-0000-0000-0000-000000000003")
    )
    let revisions = SessionRevisionSequence([sameTimestampRevision, rollbackRevision])
    let vault = KeychainAccountVault(
      backend: InMemoryAccountVaultBackend(),
      sessionRevisionGenerator: { revisions.next() }
    )

    try await vault.upsert(
      session(
        userID: 1,
        name: "original",
        createdAt: 5,
        updatedAt: 10,
        sessionRevision: initialRevision
      )
    )
    try await vault.upsert(
      session(
        userID: 1,
        name: "same-time",
        createdAt: 10,
        updatedAt: 10,
        sessionRevision: initialRevision
      )
    )

    var activeSession = try await vault.activeSession()
    var stored = try XCTUnwrap(activeSession)
    XCTAssertEqual(stored.sessionRevision, sameTimestampRevision)
    XCTAssertEqual(stored.createdAt, Date(timeIntervalSince1970: 5))
    XCTAssertEqual(stored.updatedAt, Date(timeIntervalSince1970: 10))

    try await vault.upsert(
      session(
        userID: 1,
        name: "clock-rollback",
        createdAt: 1,
        updatedAt: 1,
        sessionRevision: sameTimestampRevision
      )
    )

    activeSession = try await vault.activeSession()
    stored = try XCTUnwrap(activeSession)
    XCTAssertEqual(stored.username, "clock-rollback")
    XCTAssertEqual(stored.sessionRevision, rollbackRevision)
    XCTAssertEqual(stored.createdAt, Date(timeIntervalSince1970: 5))
    XCTAssertEqual(stored.updatedAt, Date(timeIntervalSince1970: 10))
  }

  func testExistingAccountUpsertReplacesCompletePairAndRotatesRevision() async throws {
    let replacementRevision = try XCTUnwrap(
      UUID(uuidString: "33333333-4444-5555-6666-777777777777")
    )
    let vault = KeychainAccountVault(
      backend: InMemoryAccountVaultBackend(),
      sessionRevisionGenerator: { replacementRevision }
    )
    let original = session(userID: 1, name: "original", createdAt: 5, updatedAt: 10)
    try await vault.upsert(original)
    let replacement = StoredAccountSession(
      id: 1,
      username: "replacement",
      displayName: "replacement",
      portrait: "replacement-portrait",
      bduss: String(repeating: "f", count: 192),
      stoken: String(repeating: "t", count: 64),
      bdussCookieName: .bduss,
      createdAt: Date(timeIntervalSince1970: 20),
      updatedAt: Date(timeIntervalSince1970: 30),
      sessionRevision: original.sessionRevision
    )

    try await vault.upsert(replacement)

    let activeSession = try await vault.activeSession()
    let stored = try XCTUnwrap(activeSession)
    XCTAssertEqual(stored.bduss, replacement.bduss)
    XCTAssertEqual(stored.stoken, replacement.stoken)
    XCTAssertEqual(stored.bdussCookieName, .bduss)
    XCTAssertEqual(stored.sessionRevision, replacementRevision)
    XCTAssertEqual(stored.createdAt, original.createdAt)
    XCTAssertEqual(stored.updatedAt, replacement.updatedAt)
  }

  func testMalformedAndFutureArchivesAreNeverOverwritten() async throws {
    let malformed = Data("not-json".utf8)
    let malformedBackend = InMemoryAccountVaultBackend(initial: malformed)
    let malformedVault = KeychainAccountVault(backend: malformedBackend)

    await XCTAssertThrowsErrorAsync {
      try await malformedVault.upsert(self.session(userID: 1, name: "one"))
    } verify: { error in
      XCTAssertEqual(error as? AccountVaultError, .invalidArchive)
    }
    XCTAssertEqual(malformedBackend.snapshot(), malformed)
    XCTAssertEqual(malformedBackend.writeCount, 0)

    let future = try JSONSerialization.data(
      withJSONObject: ["version": 4, "accounts": []]
    )
    let futureBackend = InMemoryAccountVaultBackend(initial: future)
    let futureVault = KeychainAccountVault(backend: futureBackend)
    await XCTAssertThrowsErrorAsync {
      try await futureVault.upsert(self.session(userID: 1, name: "one"))
    } verify: { error in
      XCTAssertEqual(error as? AccountVaultError, .futureArchive)
    }
    XCTAssertEqual(futureBackend.snapshot(), future)
    XCTAssertEqual(futureBackend.writeCount, 0)
  }

  func testExplicitResetRecoversFromMalformedArchive() async throws {
    let backend = InMemoryAccountVaultBackend(initial: Data("not-json".utf8))
    let vault = KeychainAccountVault(backend: backend)

    try await vault.removeAll()

    let summaries = try await vault.accountSummaries()
    XCTAssertTrue(summaries.isEmpty)
    XCTAssertNil(backend.snapshot())
  }

  func testAccountLimitRejectsNewAccountWithoutDeletingExistingSessions() async throws {
    let backend = InMemoryAccountVaultBackend()
    let vault = KeychainAccountVault(backend: backend)
    for userID in 1...KeychainAccountVault.maximumAccounts {
      try await vault.upsert(
        session(userID: Int64(userID), name: "user-\(userID)", updatedAt: userID)
      )
    }

    await XCTAssertThrowsErrorAsync {
      try await vault.upsert(self.session(userID: 99, name: "overflow", updatedAt: 99))
    } verify: { error in
      XCTAssertEqual(error as? AccountVaultError, .tooManyAccounts)
    }
    let summaries = try await vault.accountSummaries()
    XCTAssertEqual(summaries.count, 8)
  }

  func testRejectsStructurallyInvalidCredentialValuesWithoutWriting() async throws {
    let backend = InMemoryAccountVaultBackend()
    let vault = KeychainAccountVault(backend: backend)
    let invalid = StoredAccountSession(
      id: 1,
      username: "one",
      displayName: "one",
      portrait: "portrait",
      bduss: "short",
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )

    await XCTAssertThrowsErrorAsync {
      try await vault.upsert(invalid)
    } verify: { error in
      XCTAssertEqual(error as? AccountVaultError, .invalidArchive)
    }
    XCTAssertNil(backend.snapshot())

    let invalidSTOKEN = StoredAccountSession(
      id: 1,
      username: "one",
      displayName: "one",
      portrait: "portrait",
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 63) + ";",
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    await XCTAssertThrowsErrorAsync {
      try await vault.upsert(invalidSTOKEN)
    } verify: { error in
      XCTAssertEqual(error as? AccountVaultError, .invalidArchive)
    }
    XCTAssertNil(backend.snapshot())

    let legacyBFESSWithoutSTOKEN = StoredAccountSession(
      id: 1,
      username: "one",
      displayName: "one",
      portrait: "portrait",
      bduss: String(repeating: "b", count: 192),
      stoken: nil,
      bdussCookieName: .bdussBFESS,
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 1)
    )
    await XCTAssertThrowsErrorAsync {
      try await vault.upsert(legacyBFESSWithoutSTOKEN)
    } verify: { error in
      XCTAssertEqual(error as? AccountVaultError, .invalidArchive)
    }
    XCTAssertNil(backend.snapshot())
  }

  func testSensitiveSessionDescriptionsAndMirrorsAreRedacted() throws {
    let stored = session(userID: 7, name: "account")
    let credentials = try XCTUnwrap(stored.credentials)
    let stoken = try XCTUnwrap(stored.stoken)

    for output in [
      String(describing: credentials),
      String(reflecting: credentials),
      String(describing: stored),
      String(reflecting: stored),
    ] {
      XCTAssertFalse(output.contains(stored.bduss))
      XCTAssertFalse(output.contains(stoken))
    }
    XCTAssertEqual(Array(stored.customMirror.children).count, 2)
  }

  func testSummaryUsesStableFallbackForAccountsWithoutNames() {
    let summary = AccountSummary(
      id: 42,
      username: "  ",
      displayName: "\n",
      portraitURL: nil,
      isActive: true,
      hasFullCredentials: false,
      updatedAt: .distantPast
    )

    XCTAssertEqual(summary.preferredName, "用户 42")
  }

  private func session(
    userID: Int64,
    name: String,
    createdAt: Int = 1,
    updatedAt: Int = 1,
    sessionRevision: UUID = UUID()
  ) -> StoredAccountSession {
    StoredAccountSession(
      id: userID,
      username: name,
      displayName: name,
      portrait: "portrait-\(userID)",
      bduss: String(repeating: "b", count: 192),
      stoken: String(repeating: "s", count: 64),
      bdussCookieName: .bdussBFESS,
      createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
      updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt)),
      sessionRevision: sessionRevision
    )
  }
}

private struct LegacyAccountVaultArchive: Encodable {
  let version = 1
  let activeUserID: Int64?
  let accounts: [LegacyStoredAccountSession]
}

private struct EncodedArchiveHeader: Decodable {
  let version: Int
}

private struct EncodedAccountVaultArchiveV3: Encodable {
  let version = 3
  let activeUserID: Int64?
  let accounts: [StoredAccountSession]
}

private struct LegacyStoredAccountSession: Encodable {
  let id: Int64
  let username: String
  let displayName: String
  let portrait: String
  let bduss: String
  let createdAt: Date
  let updatedAt: Date
}

private struct LegacyAccountVaultArchiveV2: Encodable {
  let version = 2
  let activeUserID: Int64?
  let accounts: [LegacyStoredAccountSessionV2]
}

private struct LegacyStoredAccountSessionV2: Encodable {
  let id: Int64
  let username: String
  let displayName: String
  let portrait: String
  let bduss: String
  let createdAt: Date
  let updatedAt: Date
  let sessionRevision: UUID
}

private final class RevisionGeneratorSpy: @unchecked Sendable {
  private let lock = NSLock()
  private let revision: UUID
  private var calls = 0

  init(revision: UUID = UUID()) {
    self.revision = revision
  }

  var callCount: Int {
    lock.withLock { calls }
  }

  func next() -> UUID {
    lock.withLock {
      calls += 1
      return revision
    }
  }
}

private final class SessionRevisionSequence: @unchecked Sendable {
  private let lock = NSLock()
  private var revisions: [UUID]

  init(_ revisions: [UUID]) {
    self.revisions = revisions
  }

  func next() -> UUID {
    lock.withLock {
      precondition(!revisions.isEmpty)
      return revisions.removeFirst()
    }
  }
}

private final class InMemoryAccountVaultBackend: AccountVaultBackend, @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data?
  private(set) var writeCount = 0

  init(initial: Data? = nil) {
    self.data = initial
  }

  func read() throws -> Data? {
    lock.withLock { data }
  }

  func write(_ data: Data) throws {
    lock.withLock {
      self.data = data
      writeCount += 1
    }
  }

  func delete() throws {
    lock.withLock { data = nil }
  }

  func snapshot() -> Data? {
    lock.withLock { data }
  }
}

private func XCTAssertThrowsErrorAsync(
  _ expression: () async throws -> Void,
  verify: (any Error) -> Void
) async {
  do {
    try await expression()
    XCTFail("Expected error")
  } catch {
    verify(error)
  }
}
