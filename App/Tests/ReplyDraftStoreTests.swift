import XCTest

@testable import TiebaPlusPlus

final class ReplyDraftStoreTests: XCTestCase {
  func testRoundTripPreservesExactTextDispositionAndStorageAttributes() async throws {
    let location = try makeReplyDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileTextReplyDraftStore(fileURL: location.file)
    let target = draftTarget(destination: .post(postID: 701))
    let key = try XCTUnwrap(TextReplyDraftKey(userID: 9, target: target))
    let submissionID = UUID()
    let text = "  第一行\nCafe\u{301}\t末尾  "
    let draft = try XCTUnwrap(
      TextReplyDraft(
        key: key,
        content: text,
        disposition: .acceptedAwaitingVisibility(
          submissionID: submissionID,
          receipt: .subpost(parentPostID: 701, subpostID: 703)
        ),
        updatedAt: Date(timeIntervalSince1970: 100)
      )
    )

    try await store.save(draft)
    let restored = try await store.draft(for: key)

    XCTAssertEqual(restored, draft)
    XCTAssertEqual(restored?.content, text)
    let values = try location.file.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
#if os(iOS)
    let attributes = try FileManager.default.attributesOfItem(atPath: location.file.path)
    XCTAssertEqual(
      attributes[.protectionKey] as? FileProtectionType,
      .completeUntilFirstUserAuthentication
    )
#endif
  }

  func testDraftsAreIsolatedByUserAndExactTarget() async throws {
    let location = try makeReplyDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileTextReplyDraftStore(fileURL: location.file)
    let threadTarget = draftTarget()
    let postTarget = draftTarget(destination: .post(postID: 701))
    let keys = [
      try XCTUnwrap(TextReplyDraftKey(userID: 9, target: threadTarget)),
      try XCTUnwrap(TextReplyDraftKey(userID: 10, target: threadTarget)),
      try XCTUnwrap(TextReplyDraftKey(userID: 9, target: postTarget)),
    ]

    for (index, key) in keys.enumerated() {
      try await store.save(
        try XCTUnwrap(
          TextReplyDraft(
            key: key,
            content: "draft-\(index)",
            updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
          )
        )
      )
    }

    for (index, key) in keys.enumerated() {
      let restored = try await store.draft(for: key)
      XCTAssertEqual(restored?.content, "draft-\(index)")
    }
  }

  func testChallengeTombstoneWithEmptyContentRoundTrips() async throws {
    let location = try makeReplyDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileTextReplyDraftStore(fileURL: location.file)
    let key = try XCTUnwrap(TextReplyDraftKey(userID: 9, target: draftTarget()))
    let submissionID = UUID()
    let revision = UUID()
    let tombstone = try XCTUnwrap(
      TextReplyDraft(
        key: key,
        content: "",
        disposition: .challengeRequired(
          submissionID: submissionID,
          sessionRevision: revision
        )
      )
    )

    try await store.save(tombstone)
    let restored = try await store.draft(for: key)

    XCTAssertEqual(restored, tombstone)
    XCTAssertEqual(restored?.content, "")
  }

  func testCapacityEvictsOldestWithoutCrossKeyOverwrite() async throws {
    let location = try makeReplyDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileTextReplyDraftStore(fileURL: location.file, maximumDrafts: 2)
    let target = draftTarget()
    let keys = (1...3).map { userID in
      TextReplyDraftKey(userID: Int64(userID), target: target)!
    }

    for (index, key) in keys.enumerated() {
      try await store.save(
        TextReplyDraft(
          key: key,
          content: "draft-\(index)",
          updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
        )!
      )
    }

    let evicted = try await store.draft(for: keys[0])
    let firstRetained = try await store.draft(for: keys[1])
    let secondRetained = try await store.draft(for: keys[2])
    XCTAssertNil(evicted)
    XCTAssertEqual(firstRetained?.content, "draft-1")
    XCTAssertEqual(secondRetained?.content, "draft-2")
  }

  func testCorruptedArchiveFailsClosedAndIsNotOverwritten() async throws {
    let location = try makeReplyDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
      at: location.directory,
      withIntermediateDirectories: true
    )
    let original = Data("not-json".utf8)
    try original.write(to: location.file)
    let store = FileTextReplyDraftStore(fileURL: location.file)
    let key = TextReplyDraftKey(userID: 9, target: draftTarget())!

    await XCTAssertThrowsErrorAsync(try await store.draft(for: key)) { error in
      XCTAssertEqual(error as? TextReplyDraftStoreError, .corruptedArchive)
    }
    await XCTAssertThrowsErrorAsync(
      try await store.save(TextReplyDraft(key: key, content: "new")!)
    ) { error in
      XCTAssertEqual(error as? TextReplyDraftStoreError, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: location.file), original)
  }

  func testFutureArchiveFailsClosedAndIsNotOverwritten() async throws {
    let location = try makeReplyDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
      at: location.directory,
      withIntermediateDirectories: true
    )
    let original = Data("{\"schemaVersion\":2,\"drafts\":[]}".utf8)
    try original.write(to: location.file)
    let store = FileTextReplyDraftStore(fileURL: location.file)
    let key = TextReplyDraftKey(userID: 9, target: draftTarget())!

    await XCTAssertThrowsErrorAsync(try await store.draft(for: key)) { error in
      XCTAssertEqual(error as? TextReplyDraftStoreError, .unsupportedSchemaVersion(2))
    }
    await XCTAssertThrowsErrorAsync(
      try await store.save(TextReplyDraft(key: key, content: "new")!)
    ) { error in
      XCTAssertEqual(error as? TextReplyDraftStoreError, .unsupportedSchemaVersion(2))
    }
    XCTAssertEqual(try Data(contentsOf: location.file), original)
  }

  func testArchiveByteLimitIsEnforcedBeforeCommit() async throws {
    let location = try makeReplyDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileTextReplyDraftStore(
      fileURL: location.file,
      maximumArchiveBytes: 1_024
    )
    let key = TextReplyDraftKey(userID: 9, target: draftTarget())!
    let draft = TextReplyDraft(key: key, content: String(repeating: "a", count: 2_000))!

    await XCTAssertThrowsErrorAsync(try await store.save(draft)) { error in
      XCTAssertEqual(error as? TextReplyDraftStoreError, .archiveTooLarge)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: location.file.path))
  }
}

private func makeReplyDraftTestLocation() throws -> (directory: URL, file: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("reply-drafts-\(UUID().uuidString)", isDirectory: true)
  return (
    directory,
    directory.appendingPathComponent("drafts.json", isDirectory: false)
  )
}

private func draftTarget(
  destination: TextReplyTarget.Destination = .thread(firstPostID: 700)
) -> TextReplyTarget {
  TextReplyTarget(
    forumID: 7,
    forumName: "swift",
    threadID: 70,
    firstPostID: 700,
    destination: destination
  )!
}

private func XCTAssertThrowsErrorAsync<T>(
  _ expression: @autoclosure () async throws -> T,
  _ errorHandler: (Error) -> Void,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("Expected an error", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}
