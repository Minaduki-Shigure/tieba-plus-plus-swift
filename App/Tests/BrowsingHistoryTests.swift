import Foundation
import XCTest

@testable import TiebaPlusPlus

final class BrowsingHistoryTests: XCTestCase {
  func testArchivePersistsAcrossStoreInstances() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let visitedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let firstStore = FileBrowsingHistoryStore(fileURL: location.fileURL)
    let authorAvatarURL = try XCTUnwrap(
      URL(string: "https://himg.bdimg.com/sys/portraitn/item/history-author")
    )

    try await firstStore.record(
      .thread(
        ThreadHistorySnapshot(
          threadID: 42,
          forumID: 7,
          forumName: "swift",
          title: "A persisted thread",
          excerpt: "excerpt",
          authorName: "author",
          authorUsername: "author-account",
          authorAvatarURL: authorAvatarURL
        )
      ),
      at: visitedAt
    )
    try await firstStore.setRecordingEnabled(false)

    let secondStore = FileBrowsingHistoryStore(fileURL: location.fileURL)
    let entries = try await secondStore.entries(kind: nil)
    let recordingEnabled = try await secondStore.isRecordingEnabled()

    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entry.lastVisitedAt, visitedAt)
    XCTAssertEqual(entry.visitCount, 1)
    XCTAssertEqual(entry.id, "thread:42")
    XCTAssertFalse(recordingEnabled)
    guard case .thread(let snapshot) = entry.target else {
      return XCTFail("Expected a thread history entry")
    }
    XCTAssertEqual(snapshot.browseThread.id, 42)
    XCTAssertEqual(snapshot.browseThread.forumName, "swift")
    XCTAssertEqual(snapshot.authorUsername, "author-account")
    XCTAssertEqual(snapshot.browseThread.authorUsername, "author-account")
    XCTAssertEqual(snapshot.authorAvatarURL, authorAvatarURL)
    XCTAssertEqual(snapshot.browseThread.authorAvatarURL, authorAvatarURL)

    let archive = try String(contentsOf: location.fileURL, encoding: .utf8)
    XCTAssertTrue(archive.contains("\"schemaVersion\":1"))
  }

  func testLegacyThreadSnapshotWithoutUsernameStillDecodes() throws {
    let data = Data(
      #"{"threadID":42,"title":"legacy","authorName":"legacy author"}"#.utf8
    )

    let snapshot = try JSONDecoder().decode(ThreadHistorySnapshot.self, from: data)

    XCTAssertEqual(snapshot.authorName, "legacy author")
    XCTAssertEqual(snapshot.authorUsername, "")
    XCTAssertNil(snapshot.authorAvatarURL)
    XCTAssertEqual(snapshot.browseThread.authorUsername, "")
    XCTAssertNil(snapshot.browseThread.authorAvatarURL)
  }

  func testThreadSnapshotDefaultsToMappedThreadAvatar() throws {
    let authorAvatarURL = try XCTUnwrap(
      URL(string: "https://himg.bdimg.com/sys/portraitn/item/thread-author")
    )
    let thread = BrowseThread(
      id: 42,
      forumID: 7,
      forumName: "swift",
      title: "Thread",
      excerpt: "Excerpt",
      authorName: "Author",
      replyCount: 3,
      viewCount: 10,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [],
      authorAvatarURL: authorAvatarURL
    )

    let snapshot = ThreadHistorySnapshot(thread: thread)
    let explicitlySuppressed = ThreadHistorySnapshot(
      thread: thread,
      resolvedAuthorAvatarURL: nil
    )
    let hidden = ThreadHistorySnapshot(thread: thread.withLocalVisibility(.hidden))
    let placeholder = ThreadHistorySnapshot(thread: thread.withLocalVisibility(.placeholder))

    XCTAssertEqual(snapshot.authorAvatarURL, authorAvatarURL)
    XCTAssertEqual(snapshot.browseThread.authorAvatarURL, authorAvatarURL)
    XCTAssertNil(explicitlySuppressed.authorAvatarURL)
    XCTAssertNil(explicitlySuppressed.browseThread.authorAvatarURL)
    XCTAssertNil(hidden.authorAvatarURL)
    XCTAssertNil(placeholder.authorAvatarURL)
  }

  func testThreadRecordConvenienceDistinguishesInheritedAndResolvedAvatar() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let authorAvatarURL = try XCTUnwrap(
      URL(string: "https://himg.bdimg.com/sys/portraitn/item/record-author")
    )
    let thread = BrowseThread(
      id: 43,
      forumID: 7,
      forumName: "swift",
      title: "Thread",
      excerpt: "Excerpt",
      authorName: "Author",
      replyCount: 3,
      viewCount: 10,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [],
      authorAvatarURL: authorAvatarURL
    )
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)

    try await store.record(thread: thread, at: Date(timeIntervalSince1970: 10))
    var entries = try await store.entries(kind: .thread)
    guard case .thread(let inherited) = try XCTUnwrap(entries.first).target else {
      return XCTFail("Expected a thread history entry")
    }
    XCTAssertEqual(inherited.authorAvatarURL, authorAvatarURL)

    try await store.record(
      thread: thread,
      resolvedAuthorAvatarURL: nil,
      at: Date(timeIntervalSince1970: 20)
    )
    entries = try await store.entries(kind: .thread)
    guard case .thread(let suppressed) = try XCTUnwrap(entries.first).target else {
      return XCTFail("Expected a thread history entry")
    }
    XCTAssertNil(suppressed.authorAvatarURL)
  }

  func testMigratesAndRemovesLegacyRecentForumsBeforeClear() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let suiteName = "BrowsingHistoryTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set("swift\nios", forKey: FileBrowsingHistoryStore.legacyRecentForumsKey)
    let store = FileBrowsingHistoryStore(
      fileURL: location.fileURL,
      legacyDefaults: .suite(suiteName)
    )

    let migrated = try await store.entries(kind: .forum)

    XCTAssertEqual(migrated.map(\.id), ["forum:swift", "forum:ios"])
    XCTAssertNil(defaults.object(forKey: FileBrowsingHistoryStore.legacyRecentForumsKey))

    try await store.deleteAll(kind: nil)
    let cleared = try await store.entries(kind: nil)
    XCTAssertTrue(cleared.isEmpty)

    defaults.set("legacy", forKey: FileBrowsingHistoryStore.legacyRecentForumsKey)
    try await store.deleteAll(kind: nil)
    XCTAssertNil(defaults.object(forKey: FileBrowsingHistoryStore.legacyRecentForumsKey))
  }

  func testUpsertDeduplicatesAndRefreshesMetadata() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)

    try await store.record(
      .forum(ForumHistorySnapshot(forumID: 1, name: " Swift ", displayName: "Old name")),
      at: Date(timeIntervalSince1970: 100)
    )
    try await store.record(
      .forum(ForumHistorySnapshot(forumID: 2, name: "swift", displayName: "New name")),
      at: Date(timeIntervalSince1970: 200)
    )

    let entries = try await store.entries(kind: .forum)
    let entry = try XCTUnwrap(entries.first)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entry.id, "forum:swift")
    XCTAssertEqual(entry.visitCount, 2)
    XCTAssertEqual(entry.lastVisitedAt, Date(timeIntervalSince1970: 200))
    guard case .forum(let forum) = entry.target else {
      return XCTFail("Expected a forum history entry")
    }
    XCTAssertEqual(forum.forumID, 2)
    XCTAssertEqual(forum.displayName, "New name")
  }

  func testConcurrentRecordsAreSerializedWithoutLosingVisits() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)

    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 1...12 {
        group.addTask {
          try await store.record(
            .thread(ThreadHistorySnapshot(threadID: 88, title: "thread")),
            at: Date(timeIntervalSince1970: TimeInterval(index))
          )
        }
      }
      try await group.waitForAll()
    }

    let entries = try await FileBrowsingHistoryStore(fileURL: location.fileURL)
      .entries(kind: .thread)
    XCTAssertEqual(entries.count, 1)
    XCTAssertEqual(entries.first?.visitCount, 12)
  }

  func testCorruptedArchiveReturnsExplicitErrorAndIsNotOverwritten() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let damagedData = Data("{not valid json".utf8)
    try damagedData.write(to: location.fileURL)
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)

    do {
      _ = try await store.entries(kind: nil)
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? BrowsingHistoryStoreError, .corruptedArchive)
    }

    do {
      try await store.record(
        .forum(ForumHistorySnapshot(name: "swift")),
        at: Date(timeIntervalSince1970: 100)
      )
      XCTFail("Expected corruptedArchive")
    } catch {
      XCTAssertEqual(error as? BrowsingHistoryStoreError, .corruptedArchive)
    }
    XCTAssertEqual(try Data(contentsOf: location.fileURL), damagedData)
  }

  func testUnsupportedArchiveVersionIsReportedBeforePayloadDecoding() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    try Data("{\"schemaVersion\":2}".utf8).write(to: location.fileURL)
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)

    do {
      _ = try await store.entries(kind: nil)
      XCTFail("Expected unsupportedSchemaVersion")
    } catch {
      XCTAssertEqual(error as? BrowsingHistoryStoreError, .unsupportedSchemaVersion(2))
    }
  }

  func testMaximumEntryCountIsAppliedIndependentlyToEachKind() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(
      fileURL: location.fileURL,
      maximumEntriesPerKind: 2
    )

    for index in 1...3 {
      try await store.record(
        .thread(ThreadHistorySnapshot(threadID: Int64(index), title: "thread-\(index)")),
        at: Date(timeIntervalSince1970: TimeInterval(index))
      )
      try await store.record(
        .forum(ForumHistorySnapshot(forumID: Int64(index), name: "forum-\(index)")),
        at: Date(timeIntervalSince1970: TimeInterval(index + 10))
      )
    }

    let threads = try await store.entries(kind: .thread)
    let forums = try await store.entries(kind: .forum)
    let allEntries = try await store.entries(kind: nil)

    XCTAssertEqual(threads.map(\.id), ["thread:3", "thread:2"])
    XCTAssertEqual(forums.map(\.id), ["forum:forum-3", "forum:forum-2"])
    XCTAssertEqual(allEntries.count, 4)
  }

  func testRecordingSwitchSingleDeleteAndClear() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)

    try await store.setRecordingEnabled(false)
    try await store.record(
      .thread(ThreadHistorySnapshot(threadID: 1, title: "ignored")),
      at: Date(timeIntervalSince1970: 1)
    )
    var entries = try await store.entries(kind: nil)
    XCTAssertTrue(entries.isEmpty)

    try await store.setRecordingEnabled(true)
    try await store.record(
      .thread(ThreadHistorySnapshot(threadID: 1, title: "thread")),
      at: Date(timeIntervalSince1970: 2)
    )
    try await store.record(
      .forum(ForumHistorySnapshot(name: "swift")),
      at: Date(timeIntervalSince1970: 3)
    )

    try await store.delete(id: "thread:1")
    entries = try await store.entries(kind: nil)
    XCTAssertEqual(entries.map(\.id), ["forum:swift"])

    try await store.deleteAll(kind: nil)
    entries = try await store.entries(kind: nil)
    let recordingEnabled = try await store.isRecordingEnabled()
    XCTAssertTrue(entries.isEmpty)
    XCTAssertTrue(recordingEnabled)
  }

  func testProgressUpdatePreservesVisitCountAndResumeState() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)
    let authorAvatarURL = try XCTUnwrap(
      URL(string: "https://himg.bdimg.com/sys/portraitn/item/progress-author")
    )
    try await store.record(
      .thread(
        ThreadHistorySnapshot(
          threadID: 12,
          title: "thread",
          authorUsername: "author-account",
          authorAvatarURL: authorAvatarURL
        )
      ),
      at: Date(timeIntervalSince1970: 10)
    )

    try await store.updateThreadProgress(
      threadID: 12,
      postID: 99,
      floor: 18,
      options: ThreadBrowseOptions(sort: .descending, onlyThreadAuthor: true),
      at: Date(timeIntervalSince1970: 20)
    )

    let threadEntries = try await store.entries(kind: .thread)
    let entry = try XCTUnwrap(threadEntries.first)
    XCTAssertEqual(entry.visitCount, 1)
    XCTAssertEqual(entry.lastVisitedAt, Date(timeIntervalSince1970: 20))
    guard case .thread(let thread) = entry.target else {
      return XCTFail("Expected a thread history entry")
    }
    XCTAssertEqual(thread.lastPostID, 99)
    XCTAssertEqual(thread.lastFloor, 18)
    XCTAssertEqual(thread.browseOptions.sort, .descending)
    XCTAssertTrue(thread.browseOptions.onlyThreadAuthor)
    XCTAssertEqual(thread.authorUsername, "author-account")
    XCTAssertEqual(thread.authorAvatarURL, authorAvatarURL)
  }

  func testHotProgressPersistsModeWithoutAnUnstableResumePosition() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)
    try await store.record(
      .thread(ThreadHistorySnapshot(threadID: 13, title: "hot thread")),
      at: Date(timeIntervalSince1970: 10)
    )

    try await store.updateThreadProgress(
      threadID: 13,
      postID: 100,
      floor: 0,
      options: ThreadBrowseOptions(sort: .hot, onlyThreadAuthor: false),
      at: Date(timeIntervalSince1970: 20)
    )

    let entries = try await store.entries(kind: .thread)
    let entry = try XCTUnwrap(entries.first)
    guard case .thread(let thread) = entry.target else {
      return XCTFail("Expected a thread history entry")
    }
    XCTAssertEqual(thread.browseOptions.sort, .hot)
    XCTAssertNil(thread.lastPostID)
    XCTAssertNil(thread.lastFloor)
  }

  func testOptionUpdatePersistsWithoutNewProgressAndRejectsStaleWrite() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)
    let authorAvatarURL = try XCTUnwrap(
      URL(string: "https://himg.bdimg.com/sys/portraitn/item/options-author")
    )
    try await store.record(
      .thread(
        ThreadHistorySnapshot(
          threadID: 14,
          title: "options",
          authorAvatarURL: authorAvatarURL,
          lastPostID: 140,
          lastFloor: 14
        )
      ),
      at: Date(timeIntervalSince1970: 10)
    )

    let newestOptions = ThreadBrowseOptions(sort: .descending, onlyThreadAuthor: true)
    try await store.updateThreadOptions(
      threadID: 14,
      options: newestOptions,
      at: Date(timeIntervalSince1970: 30)
    )
    try await store.updateThreadOptions(
      threadID: 14,
      options: ThreadBrowseOptions(sort: .ascending),
      at: Date(timeIntervalSince1970: 20)
    )

    let entries = try await store.entries(kind: .thread)
    let entry = try XCTUnwrap(entries.first)
    guard case .thread(let thread) = entry.target else {
      return XCTFail("Expected a thread history entry")
    }
    XCTAssertEqual(thread.browseOptions, newestOptions)
    XCTAssertEqual(thread.lastPostID, 140)
    XCTAssertEqual(thread.lastFloor, 14)
    XCTAssertEqual(thread.authorAvatarURL, authorAvatarURL)
    XCTAssertEqual(entry.lastVisitedAt, Date(timeIntervalSince1970: 30))
  }

  func testFavoriteOpenOverrideCanBecomeSharedHistoryMode() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)
    let snapshot = ThreadHistorySnapshot(
      threadID: 15,
      title: "favorite override",
      browseOptions: ThreadBrowseOptions(sort: .ascending, onlyThreadAuthor: false),
      lastPostID: 150,
      lastFloor: 15
    )
    try await store.record(.thread(snapshot), at: Date(timeIntervalSince1970: 10))
    let effectiveSnapshot = FavoriteThreadOpenOverrides(
      onlyThreadAuthor: true,
      descending: true
    ).applying(to: snapshot)

    try await store.updateThreadOptions(
      threadID: snapshot.threadID,
      options: effectiveSnapshot.browseOptions,
      at: Date(timeIntervalSince1970: 20)
    )

    let entries = try await store.entries(kind: .thread)
    let entry = try XCTUnwrap(entries.first)
    guard case .thread(let persisted) = entry.target else {
      return XCTFail("Expected a thread history entry")
    }
    XCTAssertEqual(
      persisted.browseOptions,
      ThreadBrowseOptions(sort: .descending, onlyThreadAuthor: true)
    )
    XCTAssertEqual(persisted.lastPostID, 150)
    XCTAssertEqual(persisted.lastFloor, 15)
  }

  @MainActor
  func testViewModelGroupsTodayAndEarlierForSelectedKind() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let store = FileBrowsingHistoryStore(fileURL: location.fileURL)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let now = Date(timeIntervalSince1970: 1_704_110_400)

    try await store.record(
      .thread(ThreadHistorySnapshot(threadID: 1, title: "earlier")),
      at: now.addingTimeInterval(-86_400)
    )
    try await store.record(
      .thread(ThreadHistorySnapshot(threadID: 2, title: "today")),
      at: now.addingTimeInterval(-60)
    )
    try await store.record(
      .forum(ForumHistorySnapshot(name: "swift")),
      at: now
    )

    let viewModel = BrowsingHistoryViewModel(repository: store)
    viewModel.loadIfNeeded()
    try await waitUntil { viewModel.state == .loaded }
    let sections = viewModel.sections(now: now, calendar: calendar)

    XCTAssertEqual(sections.today.map(\.id), ["thread:2"])
    XCTAssertEqual(sections.earlier.map(\.id), ["thread:1"])
    XCTAssertEqual(viewModel.forumEntries.map(\.id), ["forum:swift"])

    viewModel.selectedKind = .forum
    let threads = viewModel.sections(kind: .thread, now: now, calendar: calendar)
    let forums = viewModel.sections(kind: .forum, now: now, calendar: calendar)
    XCTAssertEqual(threads.today.map(\.id), ["thread:2"])
    XCTAssertEqual(threads.earlier.map(\.id), ["thread:1"])
    XCTAssertEqual(forums.today.map(\.id), ["forum:swift"])
    XCTAssertTrue(forums.earlier.isEmpty)
    XCTAssertEqual(viewModel.visibleEntries, viewModel.entries(for: .forum))
  }

  @MainActor
  func testDeleteSurvivesNavigationAndOnlyRemovesTheRequestedIdentity() async throws {
    let thread = historyEntry(.thread(ThreadHistorySnapshot(threadID: 42, title: "Thread")))
    let forum = historyEntry(.forum(ForumHistorySnapshot(name: "42")))
    let repository = ControlledHistoryRepository(entries: [thread, forum])
    let model = BrowsingHistoryViewModel(repository: repository)
    model.activate()
    try await waitUntil { model.state == .loaded }
    await repository.setHoldsMutations(true)

    model.delete(thread)
    try await waitUntil { await repository.mutationCount == 1 }
    model.selectedKind = .forum
    model.cancel()
    let refresh = Task { await model.refresh() }
    let released = await repository.releaseMutation(1)
    XCTAssertTrue(released)
    try await waitUntil { !model.isMutating }
    await refresh.value

    XCTAssertFalse(model.isActive)
    XCTAssertTrue(model.entries(for: .thread).isEmpty)
    XCTAssertEqual(model.entries(for: .forum), [forum])
    XCTAssertNil(model.operationError)
    let mutations = await repository.mutations
    XCTAssertEqual(mutations, [.delete("thread:42")])
  }

  @MainActor
  func testClearQueuesBehindDeleteAndReplacesBothProjections() async throws {
    let thread = historyEntry(.thread(ThreadHistorySnapshot(threadID: 42, title: "Thread")))
    let forum = historyEntry(.forum(ForumHistorySnapshot(name: "swift")))
    let repository = ControlledHistoryRepository(entries: [thread, forum])
    let model = BrowsingHistoryViewModel(repository: repository)
    await model.refresh()
    await repository.setHoldsMutations(true)

    model.delete(thread)
    model.selectedKind = .forum
    model.clearAll()
    try await waitUntil { await repository.mutationCount == 1 }
    let firstReleased = await repository.releaseMutation(1)
    XCTAssertTrue(firstReleased)
    try await waitUntil { await repository.mutationCount == 2 }
    let secondReleased = await repository.releaseMutation(2)
    XCTAssertTrue(secondReleased)
    try await waitUntil { !model.isMutating }

    XCTAssertTrue(model.entries(for: .thread).isEmpty)
    XCTAssertTrue(model.entries(for: .forum).isEmpty)
    XCTAssertEqual(model.state, .loaded)
    XCTAssertTrue(model.recordingEnabled)
    let mutations = await repository.mutations
    XCTAssertEqual(mutations, [.delete("thread:42"), .clear(nil)])
  }

  @MainActor
  func testRefreshFailurePreservesBothKindsAndCanRetry() async throws {
    let thread = historyEntry(.thread(ThreadHistorySnapshot(threadID: 1, title: "Thread")))
    let forum = historyEntry(.forum(ForumHistorySnapshot(name: "swift")))
    let repository = ControlledHistoryRepository(entries: [thread, forum])
    let model = BrowsingHistoryViewModel(repository: repository)
    await model.refresh()
    await repository.failNextRead()
    model.selectedKind = .forum

    await model.refresh()

    XCTAssertEqual(model.entries(for: .thread), [thread])
    XCTAssertEqual(model.entries(for: .forum), [forum])
    XCTAssertEqual(model.state, .failed(BrowsingHistoryStoreError.readFailed.localizedDescription))
    XCTAssertEqual(model.operationError, BrowsingHistoryStoreError.readFailed.localizedDescription)
    model.dismissOperationError()
    await model.refresh()
    XCTAssertEqual(model.state, .loaded)
    XCTAssertNil(model.operationError)
  }

  @MainActor
  func testCancelledReadCannotPublishOrClearTheReplacementRead() async throws {
    let old = historyEntry(.thread(ThreadHistorySnapshot(threadID: 1, title: "Old")))
    let current = historyEntry(.forum(ForumHistorySnapshot(name: "current")))
    let repository = ControlledHistoryRepository(entries: [old])
    await repository.setHoldsReads(true)
    let model = BrowsingHistoryViewModel(repository: repository)
    let oldRefresh = Task { await model.refresh() }
    try await waitUntil { await repository.readCount == 1 }
    model.cancel()
    await repository.replaceEntries([current])
    model.activate()
    try await waitUntil { await repository.readCount == 2 }

    let oldReleased = await repository.releaseRead(1)
    XCTAssertTrue(oldReleased)
    await oldRefresh.value
    XCTAssertTrue(model.entries.isEmpty)
    XCTAssertEqual(model.state, .loading)
    var joined = false
    let joinedRefresh = Task {
      joined = true
      await model.refresh()
    }
    try await waitUntil { joined }
    let readCount = await repository.readCount
    XCTAssertEqual(readCount, 2)
    let currentReleased = await repository.releaseRead(2)
    XCTAssertTrue(currentReleased)
    try await waitUntil { model.state == .loaded }
    await joinedRefresh.value
    XCTAssertEqual(model.entries, [current])
    XCTAssertTrue(model.isActive)
  }

  @MainActor
  func testReadStartedBeforeDeleteCannotRestoreDeletedContent() async throws {
    let thread = historyEntry(.thread(ThreadHistorySnapshot(threadID: 1, title: "Thread")))
    let forum = historyEntry(.forum(ForumHistorySnapshot(name: "swift")))
    let repository = ControlledHistoryRepository(entries: [thread, forum])
    let model = BrowsingHistoryViewModel(repository: repository)
    await model.refresh()
    await repository.setHoldsReads(true)
    let oldRefresh = Task { await model.refresh() }
    try await waitUntil { await repository.readCount == 2 }
    await repository.setHoldsReads(false)

    model.delete(thread)
    try await waitUntil { !model.isMutating }
    XCTAssertEqual(model.entries, [forum])
    let oldReleased = await repository.releaseRead(2)
    XCTAssertTrue(oldReleased)
    await oldRefresh.value
    XCTAssertEqual(model.entries, [forum])
    XCTAssertNil(model.operationError)
  }

  @MainActor
  func testEarlierRecordingFailureDoesNotUndoTheLatestRequestedPreference() async throws {
    let repository = ControlledHistoryRepository(entries: [])
    let model = BrowsingHistoryViewModel(repository: repository)
    await model.refresh()
    await repository.setHoldsMutations(true)
    model.setRecordingEnabled(false)
    model.setRecordingEnabled(true)
    try await waitUntil { await repository.mutationCount == 1 }
    XCTAssertTrue(model.recordingEnabled)
    model.cancel()

    let firstReleased = await repository.releaseMutation(1, error: .writeFailed)
    XCTAssertTrue(firstReleased)
    try await waitUntil { await repository.mutationCount == 2 }
    XCTAssertTrue(model.recordingEnabled)
    let secondReleased = await repository.releaseMutation(2)
    XCTAssertTrue(secondReleased)
    try await waitUntil { !model.isMutating }

    XCTAssertTrue(model.recordingEnabled)
    XCTAssertEqual(model.operationError, BrowsingHistoryStoreError.writeFailed.localizedDescription)
    let persistedPreference = try await repository.isRecordingEnabled()
    XCTAssertTrue(persistedPreference)
    let mutations = await repository.mutations
    XCTAssertEqual(mutations, [.recording(false), .recording(true)])
  }

  @MainActor
  func testDeleteFailureRetainsSnapshotAndAllowsASecondAttempt() async throws {
    let thread = historyEntry(.thread(ThreadHistorySnapshot(threadID: 1, title: "Thread")))
    let repository = ControlledHistoryRepository(entries: [thread])
    let model = BrowsingHistoryViewModel(repository: repository)
    await model.refresh()
    await repository.setHoldsMutations(true)
    model.delete(thread)
    try await waitUntil { await repository.mutationCount == 1 }
    let released = await repository.releaseMutation(1, error: .writeFailed)
    XCTAssertTrue(released)
    try await waitUntil { !model.isMutating }

    XCTAssertEqual(model.entries, [thread])
    XCTAssertEqual(model.operationError, BrowsingHistoryStoreError.writeFailed.localizedDescription)
    await repository.setHoldsMutations(false)
    model.delete(thread)
    try await waitUntil { !model.isMutating }
    XCTAssertTrue(model.entries.isEmpty)
    XCTAssertNil(model.operationError)
  }

  @MainActor
  func testReturningFromAVisitRefreshesOrderWithStableRecordIdentities() async throws {
    let location = try HistoryTestLocation()
    defer { location.remove() }
    let repository = FileBrowsingHistoryStore(fileURL: location.fileURL)
    let first = BrowsingHistoryTarget.thread(ThreadHistorySnapshot(threadID: 1, title: "First"))
    let second = BrowsingHistoryTarget.thread(ThreadHistorySnapshot(threadID: 2, title: "Second"))
    try await repository.record(first, at: Date(timeIntervalSince1970: 10))
    try await repository.record(second, at: Date(timeIntervalSince1970: 20))
    let model = BrowsingHistoryViewModel(repository: repository)
    model.activate()
    try await waitUntil { model.state == .loaded }
    XCTAssertEqual(model.entries.map(\.id), ["thread:2", "thread:1"])
    model.cancel()
    try await repository.record(first, at: Date(timeIntervalSince1970: 30))
    model.activate()
    try await waitUntil { model.entries.first?.id == "thread:1" }

    XCTAssertEqual(model.entries.map(\.id), ["thread:1", "thread:2"])
    XCTAssertEqual(model.entries.first?.visitCount, 2)
  }
}

private func historyEntry(_ target: BrowsingHistoryTarget) -> BrowsingHistoryEntry {
  BrowsingHistoryEntry(
    target: target, lastVisitedAt: Date(timeIntervalSince1970: 10), visitCount: 1)
}

private actor ControlledHistoryRepository: BrowsingHistoryRepository {
  enum Mutation: Equatable, Sendable {
    case delete(String)
    case clear(BrowsingHistoryKind?)
    case recording(Bool)
  }

  private var storedEntries: [BrowsingHistoryEntry]
  private var recordingEnabled = true
  private var holdsReads = false
  private var holdsMutations = false
  private var nextReadFails = false
  private(set) var readCount = 0
  private(set) var mutations: [Mutation] = []
  private var pendingReads:
    [Int: (CheckedContinuation<[BrowsingHistoryEntry], any Error>, [BrowsingHistoryEntry])] = [:]
  private var pendingMutations: [Int: CheckedContinuation<Void, any Error>] = [:]

  init(entries: [BrowsingHistoryEntry]) { storedEntries = entries }

  var mutationCount: Int { mutations.count }

  func setHoldsReads(_ value: Bool) { holdsReads = value }
  func setHoldsMutations(_ value: Bool) { holdsMutations = value }
  func replaceEntries(_ value: [BrowsingHistoryEntry]) { storedEntries = value }
  func failNextRead() { nextReadFails = true }

  func entries(kind: BrowsingHistoryKind?) async throws -> [BrowsingHistoryEntry] {
    readCount += 1
    let request = readCount
    if nextReadFails {
      nextReadFails = false
      throw BrowsingHistoryStoreError.readFailed
    }
    let snapshot = storedEntries.filter { kind == nil || $0.kind == kind }
    guard holdsReads else { return snapshot }
    // Deliberately ignore cancellation to exercise generation protection.
    return try await withCheckedThrowingContinuation { continuation in
      pendingReads[request] = (continuation, snapshot)
      Task {
        try? await Task.sleep(for: .seconds(2))
        expireRead(request)
      }
    }
  }

  func releaseRead(_ request: Int) -> Bool {
    guard let (continuation, snapshot) = pendingReads.removeValue(forKey: request) else {
      return false
    }
    continuation.resume(returning: snapshot)
    return true
  }

  private func expireRead(_ request: Int) {
    pendingReads.removeValue(forKey: request)?.0.resume(throwing: HistoryWaitTimeout())
  }

  func isRecordingEnabled() async throws -> Bool { recordingEnabled }

  func setRecordingEnabled(_ enabled: Bool) async throws {
    try await perform(.recording(enabled))
    recordingEnabled = enabled
  }

  func delete(id: String) async throws {
    try await perform(.delete(id))
    storedEntries.removeAll { $0.id == id }
  }

  func deleteAll(kind: BrowsingHistoryKind?) async throws {
    try await perform(.clear(kind))
    storedEntries.removeAll { kind == nil || $0.kind == kind }
  }

  private func perform(_ mutation: Mutation) async throws {
    mutations.append(mutation)
    let request = mutations.count
    if holdsMutations {
      try await withCheckedThrowingContinuation { continuation in
        pendingMutations[request] = continuation
        Task {
          try? await Task.sleep(for: .seconds(2))
          pendingMutations.removeValue(forKey: request)?.resume(throwing: HistoryWaitTimeout())
        }
      }
    }
    try Task.checkCancellation()
  }

  func releaseMutation(_ request: Int, error: BrowsingHistoryStoreError? = nil) -> Bool {
    guard let continuation = pendingMutations.removeValue(forKey: request) else { return false }
    if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume()
    }
    return true
  }

  func record(_ target: BrowsingHistoryTarget, at date: Date) async throws {}
  func updateThreadProgress(
    threadID: Int64, postID: Int64, floor: Int, options: ThreadBrowseOptions, at date: Date
  ) async throws {}
  func updateThreadOptions(
    threadID: Int64, options: ThreadBrowseOptions, at date: Date
  ) async throws {}
}

private struct HistoryTestLocation {
  let directoryURL: URL
  let fileURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    fileURL = directoryURL.appendingPathComponent("browsing-history.json")
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

private struct HistoryWaitTimeout: Error {}

@MainActor
private func waitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw HistoryWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
