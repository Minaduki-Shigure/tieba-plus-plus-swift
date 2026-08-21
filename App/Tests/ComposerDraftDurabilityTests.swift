import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ComposerDraftDurabilityTests: XCTestCase {
  func testNewThreadStagedSyncFailurePreservesPreviousArchive() async throws {
    let location = composerDraftDurabilityLocation(prefix: "new-thread-staged-sync")
    defer { try? FileManager.default.removeItem(at: location.root) }
    let key = try XCTUnwrap(
      NewThreadDraftKey(userID: 9, target: composerDraftNewThreadTarget())
    )
    let original = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: "original",
        content: "original body",
        updatedAt: Date(timeIntervalSince1970: 100)
      )
    )
    try await FileNewThreadDraftStore(fileURL: location.file).save(original)
    let originalBytes = try Data(contentsOf: location.file)
    let failingStore = FileNewThreadDraftStore(
      fileURL: location.file,
      beforeDurabilitySync: { checkpoint in
        if checkpoint == .stagedFile { throw ComposerDraftDurabilityTestFailure.injected }
      }
    )

    await composerDraftXCTAssertThrowsError(
      try await failingStore.save(
        try XCTUnwrap(
          NewThreadDraft(
            key: key,
            title: "replacement",
            content: "replacement body",
            updatedAt: Date(timeIntervalSince1970: 200)
          )
        )
      )
    ) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .writeFailed)
    }

    XCTAssertEqual(try Data(contentsOf: location.file), originalBytes)
    let retainedDraft = try await FileNewThreadDraftStore(fileURL: location.file).draft(for: key)
    XCTAssertEqual(retainedDraft, original)
    try composerDraftAssertNoStagedFiles(in: location.parent)
  }

  func testReplyStagedSyncFailurePreservesPreviousArchive() async throws {
    let location = composerDraftDurabilityLocation(prefix: "reply-staged-sync")
    defer { try? FileManager.default.removeItem(at: location.root) }
    let key = try XCTUnwrap(
      TextReplyDraftKey(userID: 9, target: composerDraftReplyTarget())
    )
    let original = try XCTUnwrap(
      TextReplyDraft(
        key: key,
        content: "original reply",
        updatedAt: Date(timeIntervalSince1970: 100)
      )
    )
    try await FileTextReplyDraftStore(fileURL: location.file).save(original)
    let originalBytes = try Data(contentsOf: location.file)
    let failingStore = FileTextReplyDraftStore(
      fileURL: location.file,
      beforeDurabilitySync: { checkpoint in
        if checkpoint == .stagedFile { throw ComposerDraftDurabilityTestFailure.injected }
      }
    )

    await composerDraftXCTAssertThrowsError(
      try await failingStore.save(
        try XCTUnwrap(
          TextReplyDraft(
            key: key,
            content: "replacement reply",
            updatedAt: Date(timeIntervalSince1970: 200)
          )
        )
      )
    ) { error in
      XCTAssertEqual(error as? TextReplyDraftStoreError, .writeFailed)
    }

    XCTAssertEqual(try Data(contentsOf: location.file), originalBytes)
    let retainedDraft = try await FileTextReplyDraftStore(fileURL: location.file).draft(for: key)
    XCTAssertEqual(retainedDraft, original)
    try composerDraftAssertNoStagedFiles(in: location.parent)
  }

  func testNewThreadParentSyncFailurePublishesButStillReportsWriteFailure() async throws {
    let location = composerDraftDurabilityLocation(prefix: "new-thread-parent-sync")
    defer { try? FileManager.default.removeItem(at: location.root) }
    let key = try XCTUnwrap(
      NewThreadDraftKey(userID: 9, target: composerDraftNewThreadTarget())
    )
    let original = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: nil,
        content: "original",
        updatedAt: Date(timeIntervalSince1970: 100)
      )
    )
    let replacement = try XCTUnwrap(
      NewThreadDraft(
        key: key,
        title: "replacement",
        content: "replacement",
        updatedAt: Date(timeIntervalSince1970: 200)
      )
    )
    try await FileNewThreadDraftStore(fileURL: location.file).save(original)
    let failingStore = FileNewThreadDraftStore(
      fileURL: location.file,
      beforeDurabilitySync: { checkpoint in
        if checkpoint == .parentDirectory {
          throw ComposerDraftDurabilityTestFailure.injected
        }
      }
    )

    await composerDraftXCTAssertThrowsError(try await failingStore.save(replacement)) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .writeFailed)
    }

    let publishedDraft = try await FileNewThreadDraftStore(fileURL: location.file).draft(for: key)
    XCTAssertEqual(publishedDraft, replacement)
    try composerDraftAssertNoStagedFiles(in: location.parent)
  }

  func testReplyParentSyncFailurePublishesButStillReportsWriteFailure() async throws {
    let location = composerDraftDurabilityLocation(prefix: "reply-parent-sync")
    defer { try? FileManager.default.removeItem(at: location.root) }
    let key = try XCTUnwrap(
      TextReplyDraftKey(userID: 9, target: composerDraftReplyTarget())
    )
    let original = try XCTUnwrap(
      TextReplyDraft(
        key: key,
        content: "original",
        updatedAt: Date(timeIntervalSince1970: 100)
      )
    )
    let replacement = try XCTUnwrap(
      TextReplyDraft(
        key: key,
        content: "replacement",
        updatedAt: Date(timeIntervalSince1970: 200)
      )
    )
    try await FileTextReplyDraftStore(fileURL: location.file).save(original)
    let failingStore = FileTextReplyDraftStore(
      fileURL: location.file,
      beforeDurabilitySync: { checkpoint in
        if checkpoint == .parentDirectory {
          throw ComposerDraftDurabilityTestFailure.injected
        }
      }
    )

    await composerDraftXCTAssertThrowsError(try await failingStore.save(replacement)) { error in
      XCTAssertEqual(error as? TextReplyDraftStoreError, .writeFailed)
    }

    let publishedDraft = try await FileTextReplyDraftStore(fileURL: location.file).draft(for: key)
    XCTAssertEqual(publishedDraft, replacement)
    try composerDraftAssertNoStagedFiles(in: location.parent)
  }

  func testReplyRejectsReplacedStagedBytesWithoutPublishingThem() async throws {
    let location = composerDraftDurabilityLocation(prefix: "reply-replaced-staged")
    defer { try? FileManager.default.removeItem(at: location.root) }
    let key = try XCTUnwrap(
      TextReplyDraftKey(userID: 9, target: composerDraftReplyTarget())
    )
    let original = try XCTUnwrap(
      TextReplyDraft(
        key: key,
        content: "original",
        updatedAt: Date(timeIntervalSince1970: 100)
      )
    )
    try await FileTextReplyDraftStore(fileURL: location.file).save(original)
    let originalBytes = try Data(contentsOf: location.file)
    let failingStore = FileTextReplyDraftStore(
      fileURL: location.file,
      prepareStagedFile: { stagedURL in
        try Data("replaced staged bytes".utf8).write(to: stagedURL, options: .atomic)
      }
    )

    await composerDraftXCTAssertThrowsError(
      try await failingStore.save(
        try XCTUnwrap(
          TextReplyDraft(
            key: key,
            content: "replacement",
            updatedAt: Date(timeIntervalSince1970: 200)
          )
        )
      )
    ) { error in
      XCTAssertEqual(error as? TextReplyDraftStoreError, .writeFailed)
    }

    XCTAssertEqual(try Data(contentsOf: location.file), originalBytes)
    try composerDraftAssertNoStagedFiles(in: location.parent)
  }

  func testBothStoresReachDurabilityCheckpointsInOrder() async throws {
    let newThreadLocation = composerDraftDurabilityLocation(prefix: "new-thread-order")
    let replyLocation = composerDraftDurabilityLocation(prefix: "reply-order")
    defer {
      try? FileManager.default.removeItem(at: newThreadLocation.root)
      try? FileManager.default.removeItem(at: replyLocation.root)
    }
    let recorder = ComposerDraftDurabilityRecorder()
    let newThreadStore = FileNewThreadDraftStore(
      fileURL: newThreadLocation.file,
      beforeDurabilitySync: recorder.record
    )
    let replyStore = FileTextReplyDraftStore(
      fileURL: replyLocation.file,
      beforeDurabilitySync: recorder.record
    )

    try await newThreadStore.save(
      try XCTUnwrap(
        NewThreadDraft(
          key: try XCTUnwrap(
            NewThreadDraftKey(userID: 9, target: composerDraftNewThreadTarget())
          ),
          title: nil,
          content: "new thread"
        )
      )
    )
    try await replyStore.save(
      try XCTUnwrap(
        TextReplyDraft(
          key: try XCTUnwrap(
            TextReplyDraftKey(userID: 9, target: composerDraftReplyTarget())
          ),
          content: "reply"
        )
      )
    )

    XCTAssertEqual(
      recorder.snapshot(),
      [.stagedFile, .parentDirectory, .stagedFile, .parentDirectory]
    )
  }

  func testSymlinkedParentIsRejectedWithoutWritingThroughIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "composer-draft-symlink-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: root) }
    let realParent = root.appendingPathComponent("real", isDirectory: true)
    let linkedParent = root.appendingPathComponent("linked", isDirectory: true)
    try FileManager.default.createDirectory(at: realParent, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: linkedParent, withDestinationURL: realParent)
    let store = FileNewThreadDraftStore(
      fileURL: linkedParent.appendingPathComponent("drafts.json", isDirectory: false)
    )
    let key = try XCTUnwrap(
      NewThreadDraftKey(userID: 9, target: composerDraftNewThreadTarget())
    )

    await composerDraftXCTAssertThrowsError(
      try await store.save(
        try XCTUnwrap(NewThreadDraft(key: key, title: nil, content: "must not escape"))
      )
    ) { error in
      XCTAssertEqual(error as? NewThreadDraftStoreError, .writeFailed)
    }

    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: realParent.appendingPathComponent("drafts.json").path
      )
    )
  }
}

private enum ComposerDraftDurabilityTestFailure: Error, Sendable {
  case injected
}

private final class ComposerDraftDurabilityRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var checkpoints: [ComposerDraftDurabilityCheckpoint] = []

  func record(_ checkpoint: ComposerDraftDurabilityCheckpoint) {
    lock.lock()
    checkpoints.append(checkpoint)
    lock.unlock()
  }

  func snapshot() -> [ComposerDraftDurabilityCheckpoint] {
    lock.lock()
    defer { lock.unlock() }
    return checkpoints
  }
}

private func composerDraftDurabilityLocation(
  prefix: String
) -> (root: URL, parent: URL, file: URL) {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "\(prefix)-\(UUID().uuidString)",
    isDirectory: true
  )
  let parent = root.appendingPathComponent("store", isDirectory: true)
  return (
    root,
    parent,
    parent.appendingPathComponent("drafts.json", isDirectory: false)
  )
}

private func composerDraftNewThreadTarget() -> NewThreadTarget {
  NewThreadTarget(forumID: 7, forumName: "swift")!
}

private func composerDraftReplyTarget() -> TextReplyTarget {
  TextReplyTarget(
    forumID: 7,
    forumName: "swift",
    threadID: 70,
    firstPostID: 700,
    destination: .thread(firstPostID: 700)
  )!
}

private func composerDraftAssertNoStagedFiles(in directoryURL: URL) throws {
  let filenames = try FileManager.default.contentsOfDirectory(atPath: directoryURL.path)
  XCTAssertFalse(filenames.contains(where: { $0.hasSuffix(".staged") }))
}

private func composerDraftXCTAssertThrowsError<T: Sendable>(
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
