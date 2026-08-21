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
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: newThreadDraftUUID(3),
        sessionRevision: newThreadDraftUUID(4)
      )
    )
    let attachments = [newThreadDraftAttachment(2), newThreadDraftAttachment(1)]
    let draft = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: "标题",
        content: "  第一行\nCafe\u{301}\t末尾  ",
        attachments: attachments,
        disposition: .imageConfirmed(
          reference: reference,
          receipt: receipt
        ),
        updatedAt: Date(timeIntervalSince1970: 100)
      )
    )

    try await store.save(draft)
    let restored = try await store.draft(for: key)
    XCTAssertEqual(restored, draft)
    XCTAssertEqual(restored?.attachments, attachments)
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

  func testImageOnlyDraftRoundTripsWithNineAttachmentsInStableOrder() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileNewThreadDraftStore(fileURL: location.file)
    let key = try XCTUnwrap(
      NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())
    )
    let attachments = (1...ComposerImageDraftPolicy.maximumAttachmentCount).reversed().map {
      newThreadDraftAttachment(UInt8($0))
    }
    let draft = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: nil,
        content: "",
        attachments: attachments,
        updatedAt: Date(timeIntervalSince1970: 100)
      )
    )

    try await store.save(draft)
    let restored = try await store.draft(for: key)

    XCTAssertEqual(restored, draft)
    XCTAssertEqual(restored?.attachments, attachments)
  }

  func testSchemaV1DraftMigratesToEmptyAttachmentsAndRewritesAsV3OnSave() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileNewThreadDraftStore(fileURL: location.file)
    let key = try XCTUnwrap(
      NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())
    )
    let draft = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: "旧草稿",
        content: "旧正文",
        updatedAt: Date(timeIntervalSince1970: 100)
      )
    )
    try await store.save(draft)

    var legacyArchive = try newThreadDraftArchiveObject(at: location.file)
    legacyArchive["schemaVersion"] = 1
    var legacyDrafts = try XCTUnwrap(legacyArchive["drafts"] as? [[String: Any]])
    legacyDrafts[0].removeValue(forKey: "attachments")
    legacyDrafts[0].removeValue(forKey: "imageWatermark")
    legacyArchive["drafts"] = legacyDrafts
    try writeNewThreadDraftArchive(legacyArchive, to: location.file)

    let restored = try await store.draft(for: key)
    let migrated = try XCTUnwrap(restored)
    XCTAssertEqual(migrated.attachments, [])
    XCTAssertEqual(migrated.content, draft.content)
    try await store.save(migrated)

    let rewritten = try newThreadDraftArchiveObject(at: location.file)
    XCTAssertEqual(rewritten["schemaVersion"] as? Int, FileNewThreadDraftStore.schemaVersion)
    let rewrittenDrafts = try XCTUnwrap(rewritten["drafts"] as? [[String: Any]])
    XCTAssertEqual((rewrittenDrafts[0]["attachments"] as? [Any])?.count, 0)
  }

  func testSchemaV2AttachmentDraftMigratesAndRewritesAsV3OnSave() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileNewThreadDraftStore(fileURL: location.file)
    let key = try XCTUnwrap(NewThreadDraftKey(userID: 9, target: newThreadDraftTarget()))
    let attachments = [newThreadDraftAttachment(2), newThreadDraftAttachment(1)]
    let draft = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: nil,
        content: "正文",
        attachments: attachments,
        updatedAt: Date(timeIntervalSince1970: 100)
      )
    )
    try await store.save(draft)
    var legacyArchive = try newThreadDraftArchiveObject(at: location.file)
    legacyArchive["schemaVersion"] = 2
    var legacyDrafts = try XCTUnwrap(legacyArchive["drafts"] as? [[String: Any]])
    legacyDrafts[0].removeValue(forKey: "imageWatermark")
    legacyArchive["drafts"] = legacyDrafts
    try writeNewThreadDraftArchive(legacyArchive, to: location.file)

    let restored = try await store.draft(for: key)
    XCTAssertEqual(restored, draft)
    XCTAssertEqual(restored?.attachments, attachments)
    try await store.save(try XCTUnwrap(restored))
    let rewritten = try newThreadDraftArchiveObject(at: location.file)
    XCTAssertEqual(rewritten["schemaVersion"] as? Int, 3)
    let rewrittenDrafts = try XCTUnwrap(rewritten["drafts"] as? [[String: Any]])
    XCTAssertEqual((rewrittenDrafts[0]["attachments"] as? [Any])?.count, 2)
  }

  func testSchemaV3RejectsNoncanonicalWatermarkWithoutAttachments() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileNewThreadDraftStore(fileURL: location.file)
    let key = try XCTUnwrap(NewThreadDraftKey(userID: 9, target: newThreadDraftTarget()))
    try await store.save(
      try XCTUnwrap(
        NewThreadDraft(key: key, title: nil, content: "正文")
      )
    )
    var archive = try newThreadDraftArchiveObject(at: location.file)
    var drafts = try XCTUnwrap(archive["drafts"] as? [[String: Any]])
    drafts[0]["imageWatermark"] = "1"
    archive["drafts"] = drafts
    try writeNewThreadDraftArchive(archive, to: location.file)
    let original = try Data(contentsOf: location.file)

    await XCTAssertThrowsNewThreadDraftError(try await store.draft(for: key)) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: location.file), original)
  }

  func testSchemaV2CannotSmuggleImageDispositions() async throws {
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: newThreadDraftUUID(20),
        sessionRevision: newThreadDraftUUID(21)
      )
    )
    let receipt = try XCTUnwrap(NewThreadReceipt(threadID: 70, firstPostID: 700))
    let dispositions: [NewThreadDraftDisposition] = [
      .imagePreparationPending(reference: reference),
      .imagePipeline(reference: reference),
      .imageAcceptedAwaitingVisibility(reference: reference, receipt: receipt),
      .imageConfirmed(reference: reference, receipt: receipt),
    ]

    for disposition in dispositions {
      let location = try makeNewThreadDraftTestLocation()
      defer { try? FileManager.default.removeItem(at: location.directory) }
      let store = FileNewThreadDraftStore(fileURL: location.file)
      let key = try XCTUnwrap(
        NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())
      )
      try await store.save(
        try XCTUnwrap(
          NewThreadDraft(
            key: key,
            title: nil,
            content: "",
            attachments: [newThreadDraftAttachment(1)],
            disposition: disposition
          )
        )
      )
      var downgraded = try newThreadDraftArchiveObject(at: location.file)
      downgraded["schemaVersion"] = 2
      var downgradedDrafts = try XCTUnwrap(downgraded["drafts"] as? [[String: Any]])
      downgradedDrafts[0].removeValue(forKey: "imageWatermark")
      downgraded["drafts"] = downgradedDrafts
      try writeNewThreadDraftArchive(downgraded, to: location.file)
      let original = try Data(contentsOf: location.file)

      await XCTAssertThrowsNewThreadDraftError(try await store.draft(for: key)) { error in
        XCTAssertEqual(error as? NewThreadDraftStoreError, .corruptedArchive)
      }
      XCTAssertEqual(try Data(contentsOf: location.file), original)
    }
  }

  func testSchemaV3RejectsDuplicateOverlimitAndInvalidAttachmentMetadata() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileNewThreadDraftStore(fileURL: location.file)
    let key = try XCTUnwrap(
      NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())
    )
    let draft = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: nil,
        content: "正文",
        attachments: [newThreadDraftAttachment(1)]
      )
    )
    try await store.save(draft)
    let validObjects = try (1...10).map {
      try newThreadDraftAttachmentObject(newThreadDraftAttachment(UInt8($0)))
    }
    var invalidMetadata = validObjects[0]
    invalidMetadata["sha256"] = "not-a-sha256"
    var invalidFilename = validObjects[0]
    invalidFilename["relativePrivateFilename"] = "../outside.jpg"
    let malformedAttachmentSets: [[Any]] = [
      [validObjects[0], validObjects[0]],
      validObjects.prefix(10).map { $0 as Any },
      [invalidMetadata],
      [invalidFilename],
    ]

    for attachments in malformedAttachmentSets {
      var archive = try newThreadDraftArchiveObject(at: location.file)
      var drafts = try XCTUnwrap(archive["drafts"] as? [[String: Any]])
      drafts[0]["attachments"] = attachments
      archive["drafts"] = drafts
      try writeNewThreadDraftArchive(archive, to: location.file)

      await XCTAssertThrowsNewThreadDraftError(try await store.draft(for: key)) { error in
        XCTAssertEqual(error as? NewThreadDraftStoreError, .corruptedArchive)
      }
    }
  }

  func testSchemaV1CannotSmuggleAttachmentsThroughMigration() async throws {
    let location = try makeNewThreadDraftTestLocation()
    defer { try? FileManager.default.removeItem(at: location.directory) }
    let store = FileNewThreadDraftStore(fileURL: location.file)
    let key = try XCTUnwrap(
      NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())
    )
    try await store.save(
      try XCTUnwrap(
        NewThreadDraft(
          key: key,
          title: nil,
          content: "正文",
          attachments: [newThreadDraftAttachment(1)]
        )
      )
    )
    var downgraded = try newThreadDraftArchiveObject(at: location.file)
    downgraded["schemaVersion"] = 1
    try writeNewThreadDraftArchive(downgraded, to: location.file)
    let original = try Data(contentsOf: location.file)

    await XCTAssertThrowsNewThreadDraftError(try await store.draft(for: key)) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: location.file), original)
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
    let original = Data("{\"schemaVersion\":4,\"drafts\":[]}".utf8)
    try original.write(to: location.file)
    let store = FileNewThreadDraftStore(fileURL: location.file)
    let key = NewThreadDraftKey(userID: 9, target: newThreadDraftTarget())!

    await XCTAssertThrowsNewThreadDraftError(try await store.draft(for: key)) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .unsupportedSchemaVersion(4))
    }
    await XCTAssertThrowsNewThreadDraftError(
      try await store.save(NewThreadDraft(key: key, title: nil, content: "new")!)
    ) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .unsupportedSchemaVersion(4))
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

private func newThreadDraftAttachment(_ value: UInt8) -> ComposerImageAttachment {
  ComposerImageAttachment(
    id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, value)),
    sha256: String(repeating: String(format: "%02x", value), count: 32),
    byteCount: Int64(100 + Int(value)),
    pixelWidth: 20,
    pixelHeight: 10,
    quality: .standard
  )!
}

private func newThreadDraftUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, value))
}

private func newThreadDraftArchiveObject(at url: URL) throws -> [String: Any] {
  try XCTUnwrap(
    JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
  )
}

private func newThreadDraftAttachmentObject(
  _ attachment: ComposerImageAttachment
) throws -> [String: Any] {
  try XCTUnwrap(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(attachment)) as? [String: Any]
  )
}

private func writeNewThreadDraftArchive(_ object: [String: Any], to url: URL) throws {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
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
