import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ContentFilterBatchTests: XCTestCase {
  func testBatchSplitsMixedWhitespaceAndDeduplicatesCanonicalKeywordsInOrder() throws {
    let patterns = try ContentFilterKeywordInputPolicy.validatedPatterns(
      " \t广告\r\n推广  广告\u{3000}cafe\u{301}\u{00A0}café\n SPAM spam ",
      matchMode: .literal,
      inputMode: .batch
    )

    XCTAssertEqual(patterns, ["广告", "推广", "café", "SPAM", "spam"])
  }

  func testSinglePhrasesAndRegularExpressionsAreNeverSplit() throws {
    XCTAssertEqual(
      try ContentFilterKeywordInputPolicy.validatedPatterns(
        "  广告 推广  ", matchMode: .literal, inputMode: .single
      ),
      ["广告 推广"]
    )
    for inputMode in ContentFilterKeywordInputMode.allCases {
      XCTAssertEqual(
        try ContentFilterKeywordInputPolicy.validatedPatterns(
          "^广告 推广$", matchMode: .regularExpression, inputMode: inputMode
        ),
        ["^广告 推广$"]
      )
    }
  }

  func testBatchRejectsEmptyOversizedWordsAndOversizedInput() throws {
    XCTAssertThrowsError(
      try ContentFilterKeywordInputPolicy.validatedPatterns(
        " \t\r\n\u{3000}", matchMode: .literal, inputMode: .batch
      )
    ) { XCTAssertEqual($0 as? ContentFilterKeywordPatternError, .empty) }
    XCTAssertThrowsError(
      try ContentFilterKeywordInputPolicy.validatedPatterns(
        "valid " + String(repeating: "字", count: SafeContentFilterRegex.maximumPatternCharacters + 1),
        matchMode: .literal, inputMode: .batch
      )
    ) { XCTAssertEqual($0 as? ContentFilterKeywordPatternError, .tooLong) }
    XCTAssertThrowsError(
      try ContentFilterKeywordInputPolicy.validatedPatterns(
        String(repeating: " ", count: ContentFilterKeywordInputPolicy.maximumInputBytes + 1),
        matchMode: .literal, inputMode: .batch
      )
    ) { XCTAssertEqual($0 as? ContentFilterKeywordInputError, .inputTooLarge) }
  }

  func testBatchCountLimitAppliesAfterDeduplication() throws {
    let limit = FileContentFilterStore.defaultMaximumRules
    let words = (0..<limit).map { "word\($0)" }
    XCTAssertEqual(
      try ContentFilterKeywordInputPolicy.validatedPatterns(
        (words + words).joined(separator: " "), matchMode: .literal, inputMode: .batch
      ),
      words
    )
    XCTAssertThrowsError(
      try ContentFilterKeywordInputPolicy.validatedPatterns(
        (words + ["extra"]).joined(separator: " "), matchMode: .literal, inputMode: .batch
      )
    ) { XCTAssertEqual($0 as? ContentFilterStoreError, .tooManyRules) }
  }

  func testPreviewCountsOnlyNewRulesAndChecksCapacityAcrossBothLists() throws {
    let existing: [ContentFilterRule] = [
      .keyword("广告", list: .block),
      .keyword("推广", list: .allow),
      try .regularExpression("促销", list: .block),
    ]
    let preview = try ContentFilterKeywordInputPolicy.batchPreview(
      " 广告 广告 推广 促销 ", list: .block, existingRules: existing, maximumRules: 5
    )
    XCTAssertEqual(preview.newKeywords, ["推广", "促销"])
    XCTAssertEqual(preview.existingCount, 1)
    XCTAssertThrowsError(
      try ContentFilterKeywordInputPolicy.batchPreview(
        "广告 推广 促销", list: .block, existingRules: existing, maximumRules: 4
      )
    ) { XCTAssertEqual($0 as? ContentFilterStoreError, .tooManyRules) }
    let allDuplicates = try ContentFilterKeywordInputPolicy.batchPreview(
      "广告 广告", list: .block, existingRules: existing, maximumRules: 3
    )
    XCTAssertTrue(allDuplicates.newKeywords.isEmpty)
    XCTAssertEqual(allDuplicates.existingCount, 1)
    let allow = try ContentFilterKeywordInputPolicy.batchPreview(
      "广告 推广", list: .allow, existingRules: existing, maximumRules: 4
    )
    XCTAssertEqual(allow.newKeywords, ["广告"])
    XCTAssertEqual(allow.existingCount, 1)
  }

  func testBatchRulesMatchEitherKeywordWithPerFieldAllowListPriority() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = FileContentFilterStore(fileURL: fileURL)
    let block = try ContentFilterKeywordInputPolicy.validatedPatterns(
      "广告 推广", matchMode: .literal, inputMode: .batch
    )
    let allow = try ContentFilterKeywordInputPolicy.validatedPatterns(
      "可信广告 官方推广", matchMode: .literal, inputMode: .batch
    )
    try await store.add(block.map { .keyword($0, list: .block) })
    try await store.add(allow.map { .keyword($0, list: .allow) })
    let snapshot = try await FileContentFilterStore(fileURL: fileURL).snapshot()

    XCTAssertEqual(snapshot.visibility(for: thread("这里有广告")), .placeholder)
    XCTAssertEqual(snapshot.visibility(for: thread("这里有推广")), .placeholder)
    XCTAssertEqual(snapshot.visibility(for: thread("普通内容")), .visible)
    XCTAssertEqual(snapshot.visibility(for: thread("可信广告")), .visible)
    XCTAssertEqual(snapshot.visibility(for: thread("官方推广")), .visible)
    XCTAssertEqual(snapshot.visibility(for: thread("可信广告", excerpt: "另有推广")), .placeholder)
  }

  func testBatchPreservesExistingPhraseRulesAndSkipsDuplicatesWithoutReplacingIdentity() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = FileContentFilterStore(fileURL: fileURL, maximumRules: 4)
    let phrase = try await store.add(
      .keyword("广告 推广", list: .block, createdAt: Date(timeIntervalSince1970: 1))
    )
    let existing = try await store.add(
      .keyword("广告", list: .block, createdAt: Date(timeIntervalSince1970: 2))
    )
    let added = try await store.add([
      .keyword(" 广告 ", list: .block),
      .keyword("  推广  ", list: .block, createdAt: Date(timeIntervalSince1970: 3)),
      .keyword("推广", list: .block),
      .keyword("广告", list: .allow, createdAt: Date(timeIntervalSince1970: 4)),
    ])
    XCTAssertEqual(added.map(\.keyword), ["推广", "广告"])
    XCTAssertEqual(added.map(\.list), [.block, .allow])
    let snapshot = try await store.snapshot()
    XCTAssertEqual(snapshot.rules.count, 4)
    XCTAssertTrue(snapshot.rules.contains(existing))
    XCTAssertTrue(snapshot.rules.contains(phrase))
    let reloaded = try await FileContentFilterStore(fileURL: fileURL).snapshot()
    XCTAssertEqual(reloaded, snapshot)

    let archive = try Data(contentsOf: fileURL)
    let noChanges = try await store.add([.keyword("广告", list: .block)])
    XCTAssertTrue(noChanges.isEmpty)
    XCTAssertEqual(try Data(contentsOf: fileURL), archive)
    do {
      _ = try await store.add(.keyword("广告", list: .block))
      XCTFail("Single-rule input must continue to reject duplicates")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .duplicateRule)
    }
  }

  func testBatchValidationAndCapacityFailuresLeaveArchiveAndSnapshotUntouched() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = FileContentFilterStore(fileURL: fileURL, maximumRules: 2)
    try await store.add(
      .keyword("existing", list: .allow, createdAt: Date(timeIntervalSince1970: 1))
    )
    let original = try Data(contentsOf: fileURL)
    let originalSnapshot = try await store.snapshot()
    let cases: [([ContentFilterRule], ContentFilterStoreError)] = [
      ([.keyword("valid", list: .block), .keyword(" ", list: .block)], .invalidRule),
      ([.keyword("first", list: .block), .keyword("second", list: .block)], .tooManyRules),
      ([.keyword("valid", list: .block), .user(id: 0, name: "", list: .block)], .invalidRule),
    ]
    for (rules, expectedError) in cases {
      do {
        try await store.add(rules)
        XCTFail("Expected the entire batch to fail")
      } catch let error as ContentFilterStoreError {
        XCTAssertEqual(error, expectedError)
      }
      XCTAssertEqual(try Data(contentsOf: fileURL), original)
      let snapshot = try await store.snapshot()
      XCTAssertEqual(snapshot, originalSnapshot)
    }
  }

  func testBatchRegularExpressionLimitAndArchiveSizeFailureAreAtomic() async throws {
    let fileURL = temporaryFileURL()
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
    let store = FileContentFilterStore(
      fileURL: fileURL, maximumRegularExpressionRules: 1, maximumArchiveBytes: 1_024
    )
    try await store.add(
      .keyword("existing", list: .block, createdAt: Date(timeIntervalSince1970: 1))
    )
    let original = try Data(contentsOf: fileURL)
    let originalSnapshot = try await store.snapshot()
    do {
      try await store.add([
        .keyword("valid", list: .block),
        try .regularExpression("^first$", list: .block),
        try .regularExpression("^second$", list: .allow),
      ])
      XCTFail("Expected a regex capacity failure")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .tooManyRegularExpressions)
    }
    do {
      try await store.add((0..<10).map { .keyword("word\($0)", list: .block) })
      XCTFail("Expected an encoded archive size failure")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .archiveTooLarge)
    }
    XCTAssertEqual(try Data(contentsOf: fileURL), original)
    let snapshot = try await store.snapshot()
    XCTAssertEqual(snapshot, originalSnapshot)
  }

  func testBatchWriteFailureDoesNotPublishPartialRulesAndCanBeRetried() async throws {
    let directory = temporaryFileURL().deletingLastPathComponent()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let obstruction = directory.appendingPathComponent("not-a-directory")
    let original = Data("preserve this file".utf8)
    try original.write(to: obstruction)
    let fileURL = obstruction.appendingPathComponent("filters.json")
    let store = FileContentFilterStore(fileURL: fileURL)
    let rules: [ContentFilterRule] = [
      .keyword("first", list: .block, createdAt: Date(timeIntervalSince1970: 1)),
      .keyword("second", list: .block, createdAt: Date(timeIntervalSince1970: 2)),
    ]
    do {
      try await store.add(rules)
      XCTFail("Expected an actual filesystem write failure")
    } catch let error as ContentFilterStoreError {
      XCTAssertEqual(error, .writeFailed)
    }
    let failedSnapshot = try await store.snapshot()
    XCTAssertEqual(failedSnapshot, .empty)
    XCTAssertEqual(try Data(contentsOf: obstruction), original)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

    try FileManager.default.removeItem(at: obstruction)
    let retried = try await store.add(rules)
    XCTAssertEqual(retried, rules)
    let reloaded = try await FileContentFilterStore(fileURL: fileURL).snapshot()
    XCTAssertEqual(Set(reloaded.rules), Set(rules))
  }

  private func thread(_ title: String, excerpt: String = "ordinary") -> BrowseThread {
    BrowseThread(
      id: 1, forumID: 2, forumName: "swift", title: title, excerpt: excerpt,
      authorName: "Author", replyCount: 0, viewCount: 0, createdAt: nil, lastReplyAt: nil,
      contents: []
    )
  }

  private func temporaryFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("TiebaPlusPlus-ContentFilterBatchTests-\(UUID().uuidString)")
      .appendingPathComponent("content-filters.json")
  }
}
