import XCTest

@testable import TiebaPlusPlus

final class NewThreadDraftStoreTests: XCTestCase {
  func testRoundTripPreservesTitleContentDispositionAndStorageAttributes() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileNewThreadDraftStore(fileURL: location.file)
    let key = try XCTUnwrap(
      NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())
    )
    let receipt = try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    let draft = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: "标题",
        content: "  第一行\nCafe\u{301}\t末尾  ",
        disposition: .confirmed(
          submissionID: UUID(),
          receipt: receipt
        ),
        updatedAt: Date(timeIntervalSince1970: 100)
      )
    )

    try await store.save(draft)
    let restored = try await store.draft(for: key)
    XCTAssertEqual(restored, draft)
    let values = try location.file.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
#if os(iOS) && !targetEnvironment(simulator)
    let attributes = try FileManager.default.attributesOfItem(atPath: location.file.path)
    XCTAssertEqual(
      attributes[.protectionKey] as? FileProtectionType,
      .completeUntilFirstUserAuthentication
    )
#endif
  }

  func testDraftsAreIsolatedByAccountAndExactForumTarget() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileNewThreadDraftStore(fileURL: location.file)
    let primary = newThreadDraftTarget()
    let alternate = try XCTUnwrap(NewThreadTarget(forumID: 7, forumName: "swift-alt"))
    let keys = [
      try XCTUnwrap(NewThreadDraftKey(userID: 9, target: primary)),
      try XCTUnwrap(NewThreadDraftKey(userID: 10, target: primary)),
      try XCTUnwrap(NewThreadDraftKey(userID: 9, target: alternate)),
    ]

    for (index, key) in keys.enumerated() {
      try await store.save(
        try XCTUnwrap(
          NewThreadDraft(
            key: key,
            title: "title-\(index)",
            content: "content-\(index)",
            updatedAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
          )
        )
      )
    }

    for (index, key) in keys.enumerated() {
      let restored = try await store.draft(for: key)
      XCTAssertEqual(restored?.title, "title-\(index)")
      XCTAssertEqual(restored?.content, "content-\(index)")
    }
  }

  func testCapacityEvictsOldestWithoutCrossKeyOverwrite() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileNewThreadDraftStore(fileURL: location.file, maximumDrafts: 2)
    let target = newThreadDraftTarget()
    let keys = (1...3).map { NewThreadDraftKey(userID: Int64($0), target: target)! }

    for (index, key) in keys.enumerated() {
      try await store.save(
        NewThreadDraft(
          key: key,
          title: nil,
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
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
      at: location.directory,
      withIntermediateDirectories: true
    )
    let original = Data("not-json".utf8)
    try original.write(to: location.file)
    let store = FileNewThreadDraftStore(fileURL: location.file)
    let key = NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())!

    await XCTAssertThrowsNewThreadDraftError(try await store.draft(for: key)) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .corruptedArchive)
    }
    await XCTAssertThrowsNewThreadDraftError(
      try await store.save(NewThreadDraft(key: key, title: nil, content: "new")!)
    ) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: location.file), original)
  }

  func testFutureArchiveFailsClosedAndIsNotOverwritten() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    try FileManager.default.createDirectory(
      at: location.directory,
      withIntermediateDirectories: true
    )
    let original = Data("{\"schemaVersion\":2,\"drafts\":[]}".utf8)
    try original.write(to: location.file)
    let store = FileNewThreadDraftStore(fileURL: location.file)
    let key = NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())!

    await XCTAssertThrowsNewThreadDraftError(try await store.draft(for: key)) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .unsupportedSchemaVersion(2))
    }
    await XCTAssertThrowsNewThreadDraftError(
      try await store.save(NewThreadDraft(key: key, title: nil, content: "new")!)
    ) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .unsupportedSchemaVersion(2))
    }
    XCTAssertEqual(try Data(contentsOf: location.file), original)
  }

  func testArchiveByteLimitIsEnforcedBeforeCommit() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileNewThreadDraftStore(
      fileURL: location.file,
      maximumArchiveBytes: 1_024
    )
    let key = NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())!
    let draft = NewThreadDraft(
      key: key,
      title: nil,
      content: String(repeating: "a", count: 2_000)
    )!

    await XCTAssertThrowsNewThreadDraftError(try await store.save(draft)) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .archiveTooLarge)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: location.file.path))
  }

  func testStagedMetadataFailureLeavesPreviousArchiveUnchanged() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())!
    let original = NewThreadDraft(
      key: key,
      title: "原标题",
      content: "原正文",
      updatedAt: Date(timeIntervalSince1970: 100)
    )!
    let initialStore = FileNewThreadDraftStore(fileURL: location.file)
    try await initialStore.save(original)
    let originalBytes = try Data(contentsOf: location.file)
    let failingStore = FileNewThreadDraftStore(
      fileURL: location.file,
      prepareStagedFile: { _ in throw NewThreadDraftTestFailure.injected }
    )

    await XCTAssertThrowsNewThreadDraftError(
      try await failingStore.save(
        NewThreadDraft(key: key, title: "新标题", content: "新正文")!
      )
    ) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .writeFailed)
    }

    XCTAssertEqual(try Data(contentsOf: location.file), originalBytes)
    let restored = try await FileNewThreadDraftStore(fileURL: location.file).draft(for: key)
    XCTAssertEqual(restored, original)
  }

  func testStagedMetadataFailureIsNotHiddenWhenArchiveBytesAlreadyMatch() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let key = NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())!
    let original = NewThreadDraft(
      key: key,
      title: "相同标题",
      content: "相同正文",
      updatedAt: Date(timeIntervalSince1970: 100)
    )!
    try await FileNewThreadDraftStore(fileURL: location.file).save(original)
    let originalBytes = try Data(contentsOf: location.file)
    let failingStore = FileNewThreadDraftStore(
      fileURL: location.file,
      prepareStagedFile: { _ in throw NewThreadDraftTestFailure.injected }
    )

    await XCTAssertThrowsNewThreadDraftError(try await failingStore.save(original)) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .writeFailed)
    }

    XCTAssertEqual(try Data(contentsOf: location.file), originalBytes)
  }
}

private enum NewThreadDraftTestFailure: Error, Sendable {
  case injected
}

private func makeNewThreadDraftTestLocation() throws -> (directory: URL, file: URL) {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("new-thread-drafts-\(UUID().uuidString)", isDirectory: true)
  return (
    directory,
    directory.appendingPathComponent("drafts.json", isDirectory: false)
  )
}

private func newThreadDraftTarget() -> NewThreadTarget {
  NewThreadTarget(forumID: 7, forumName: "swift")!
}

private func XCTAssertThrowsNewThreadDraftError<T: Sendable>(
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
