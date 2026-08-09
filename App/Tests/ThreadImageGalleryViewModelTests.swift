import Combine
import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ThreadImageGalleryViewModelTests: XCTestCase {
  func testLocalOccurrencesAreImmediateAndBootstrapUsesImageOrdinalNotContentOffset() async throws {
    let local = [
      GalleryFixtures.local(1),
      GalleryFixtures.local(2, contentOffset: 8, imageOrdinal: 2),
    ]
    let remote = [
      GalleryFixtures.remote(1, pictureID: "picture-1", postID: 101),
      GalleryFixtures.remote(2, pictureID: "picture-2", postID: 102),
    ]
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page(remote, totalCount: 2))
    ])

    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: local,
      selectedID: local[1].id,
      service: service
    )

    XCTAssertEqual(viewModel.occurrences, local)
    XCTAssertEqual(viewModel.selectedID, local[1].id)
    XCTAssertEqual(viewModel.selectedURL, local[1].url)
    XCTAssertEqual(viewModel.totalCount, 2)

    try await galleryWaitUntil { await service.requestCount() == 1 }
    await viewModel.waitForCurrentLoads()
    let requests = await service.requestSnapshot()
    XCTAssertEqual(requests.map(\.direction), [.bootstrap])
    XCTAssertEqual(requests.first?.anchorIndex, 2)
  }

  func testBootstrapAtomicallyReplacesUniqueSelectionAndKeepsRepeatedPictureOccurrences() async {
    let local = [GalleryFixtures.local(1), GalleryFixtures.local(2)]
    let repeatedAtFive = GalleryFixtures.remote(5, pictureID: "repeated", postID: 50)
    let repeatedAtSeven = GalleryFixtures.remote(7, pictureID: "repeated", postID: 50)
    let selectedRemote = GalleryFixtures.remote(6, pictureID: "picture-2", postID: 102)
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page(
        [repeatedAtSeven, selectedRemote, repeatedAtFive],
        totalCount: 7
      ))
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: local,
      selectedID: local[1].id,
      service: service
    )
    var publishedStates: [ThreadPictureGalleryState] = []
    let stateObservation = viewModel.$galleryState.dropFirst().sink {
      publishedStates.append($0)
    }

    await viewModel.waitForCurrentLoads()

    XCTAssertEqual(publishedStates.count, 1)
    XCTAssertTrue(publishedStates.allSatisfy { state in
      guard let selectedID = state.selectedID else { return state.occurrences.isEmpty }
      return state.occurrences.contains(where: { $0.id == selectedID })
    })
    XCTAssertTrue(publishedStates.allSatisfy {
      $0.localToRemoteIDMigrations[local[1].id] == $0.selectedID
    })
    XCTAssertEqual(viewModel.selectedID, selectedRemote.id)
    XCTAssertEqual(viewModel.selectedURL, selectedRemote.url)
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [local[1].id: selectedRemote.id]
    )
    XCTAssertTrue(viewModel.occurrences.contains(repeatedAtFive))
    XCTAssertTrue(viewModel.occurrences.contains(repeatedAtSeven))
    XCTAssertNotEqual(repeatedAtFive.id, repeatedAtSeven.id)
    XCTAssertEqual(viewModel.occurrences.compactMap(\.overallIndex), [5, 6, 7])
    XCTAssertEqual(viewModel.totalCount, 7)
    withExtendedLifetime(stateObservation) {}
  }

  func testAmbiguousBootstrapMatchKeepsEntireLocalSnapshotAndSelection() async {
    let local = [GalleryFixtures.local(1), GalleryFixtures.local(2)]
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([
        GalleryFixtures.remote(4, pictureID: "picture-2", postID: 102),
        GalleryFixtures.remote(5, pictureID: "picture-2", postID: 102),
      ], totalCount: 10))
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: local,
      selectedID: local[1].id,
      service: service
    )

    await viewModel.waitForCurrentLoads()

    XCTAssertEqual(viewModel.occurrences, local)
    XCTAssertEqual(viewModel.selectedID, local[1].id)
    XCTAssertEqual(viewModel.selectedURL, local[1].url)
    XCTAssertEqual(viewModel.totalCount, local.count)
    XCTAssertTrue(viewModel.galleryState.localToRemoteIDMigrations.isEmpty)
    XCTAssertFalse(viewModel.canLoadPrevious)
    XCTAssertFalse(viewModel.canLoadNext)
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 1)
  }

  func testAmbiguousLocalBootstrapMatchKeepsEntireLocalSnapshotAndSelection() async {
    let first = GalleryFixtures.local(
      1,
      pictureID: "repeated",
      postID: 50,
      contentOffset: 0
    )
    let selected = GalleryFixtures.local(
      2,
      pictureID: "repeated",
      postID: 50,
      contentOffset: 1
    )
    let remote = GalleryFixtures.remote(4, pictureID: "repeated", postID: 50)
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([remote], totalCount: 10))
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [first, selected],
      selectedID: selected.id,
      service: service
    )

    await viewModel.waitForCurrentLoads()

    XCTAssertEqual(viewModel.occurrences, [first, selected])
    XCTAssertEqual(viewModel.selectedID, selected.id)
    XCTAssertEqual(viewModel.totalCount, 2)
    XCTAssertTrue(viewModel.galleryState.localToRemoteIDMigrations.isEmpty)
    XCTAssertFalse(viewModel.canLoadPrevious)
    XCTAssertFalse(viewModel.canLoadNext)
  }

  func testBootstrapFailureRetainsLocalSnapshotAndCanRetry() async throws {
    let local = [GalleryFixtures.local(1), GalleryFixtures.local(2)]
    let retryPage = GalleryFixtures.page([
      GalleryFixtures.remote(4, pictureID: "before", postID: 40),
      GalleryFixtures.remote(5, pictureID: "picture-2", postID: 102),
      GalleryFixtures.remote(6, pictureID: "after", postID: 60),
    ], totalCount: 10)
    let service = ScriptedThreadPictureGalleryService([
      .failure(GalleryStubFailure(message: "bootstrap failed")),
      .value(retryPage),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: local,
      selectedID: local[1].id,
      service: service
    )

    try await galleryWaitUntil { viewModel.bootstrapError == "bootstrap failed" }
    XCTAssertEqual(viewModel.occurrences, local)
    XCTAssertEqual(viewModel.selectedID, local[1].id)

    viewModel.retryBootstrap()
    await viewModel.waitForCurrentLoads()

    XCTAssertNil(viewModel.bootstrapError)
    XCTAssertEqual(viewModel.selectedID, retryPage.occurrences[1].id)
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 2)
  }

  func testPrependAndAppendKeepSelectedOccurrenceAndURLStable() async {
    let local = GalleryFixtures.local(2)
    let five = GalleryFixtures.remote(5, pictureID: "five", postID: 50)
    let six = GalleryFixtures.remote(6, pictureID: local.pictureID, postID: local.postID)
    let seven = GalleryFixtures.remote(7, pictureID: "seven", postID: 70)
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([five, six, seven], totalCount: 9)),
      .value(GalleryFixtures.page([
        GalleryFixtures.remote(3, pictureID: "three", postID: 30),
        GalleryFixtures.remote(4, pictureID: "four", postID: 40),
        five,
      ], totalCount: 9)),
      .value(GalleryFixtures.page([
        seven,
        GalleryFixtures.remote(8, pictureID: "eight", postID: 80),
        GalleryFixtures.remote(9, pictureID: "nine", postID: 90),
      ], totalCount: 9)),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [local],
      selectedID: local.id,
      service: service
    )

    await viewModel.waitForCurrentLoads()
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [local.id: six.id]
    )
    viewModel.select(five.id)
    let previousSelectedID = viewModel.selectedID
    let previousSelectedURL = viewModel.selectedURL
    await viewModel.waitForCurrentLoads()

    XCTAssertEqual(viewModel.selectedID, previousSelectedID)
    XCTAssertEqual(viewModel.selectedURL, previousSelectedURL)
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [local.id: six.id]
    )
    XCTAssertEqual(viewModel.selectedIndex, 2)
    XCTAssertEqual(viewModel.occurrences.compactMap(\.overallIndex), [3, 4, 5, 6, 7])

    viewModel.select(seven.id)
    let nextSelectedID = viewModel.selectedID
    let nextSelectedURL = viewModel.selectedURL
    await viewModel.waitForCurrentLoads()

    XCTAssertEqual(viewModel.selectedID, nextSelectedID)
    XCTAssertEqual(viewModel.selectedURL, nextSelectedURL)
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [local.id: six.id]
    )
    XCTAssertEqual(viewModel.occurrences.compactMap(\.overallIndex), [3, 4, 5, 6, 7, 8, 9])
  }

  func testLaterPageReconcilesASelectedLocalPlaceholderAtomically() async {
    let firstLocal = GalleryFixtures.local(1)
    let laterLocal = GalleryFixtures.local(2)
    let firstRemote = GalleryFixtures.remote(
      1,
      pictureID: firstLocal.pictureID,
      postID: firstLocal.postID
    )
    let middleRemote = GalleryFixtures.remote(2, pictureID: "middle", postID: 200)
    let laterRemote = GalleryFixtures.remote(
      3,
      pictureID: laterLocal.pictureID,
      postID: laterLocal.postID
    )
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([firstRemote, middleRemote], totalCount: 3)),
      .value(GalleryFixtures.page([middleRemote, laterRemote], totalCount: 3)),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [firstLocal, laterLocal],
      selectedID: firstLocal.id,
      service: service
    )

    await viewModel.waitForCurrentLoads()
    XCTAssertTrue(viewModel.occurrences.contains(laterLocal))
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [firstLocal.id: firstRemote.id]
    )

    viewModel.select(laterLocal.id)
    await viewModel.waitForCurrentLoads()

    XCTAssertEqual(viewModel.selectedID, laterRemote.id)
    XCTAssertEqual(viewModel.selectedURL, laterRemote.url)
    XCTAssertEqual(viewModel.selectedDisplayIndex, 3)
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [
        firstLocal.id: firstRemote.id,
        laterLocal.id: laterRemote.id,
      ]
    )
    XCTAssertFalse(viewModel.occurrences.contains(laterLocal))
    XCTAssertEqual(viewModel.occurrences.filter { $0.pictureID == laterLocal.pictureID }.count, 1)
  }

  func testContinuationRejectsARegressedTotalCount() async {
    let local = GalleryFixtures.local(2)
    let five = GalleryFixtures.remote(5, pictureID: "five", postID: 50)
    let six = GalleryFixtures.remote(6, pictureID: local.pictureID, postID: local.postID)
    let seven = GalleryFixtures.remote(7, pictureID: "seven", postID: 70)
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([five, six, seven], totalCount: 100)),
      .value(GalleryFixtures.page([
        seven,
        GalleryFixtures.remote(8, pictureID: "eight", postID: 80),
      ], totalCount: 20)),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [local],
      selectedID: local.id,
      service: service
    )

    await viewModel.waitForCurrentLoads()
    viewModel.select(seven.id)
    await viewModel.waitForCurrentLoads()

    XCTAssertEqual(viewModel.totalCount, 100)
    XCTAssertFalse(viewModel.occurrences.contains(where: { $0.overallIndex == 8 }))
    XCTAssertFalse(viewModel.canLoadNext)
  }

  func testContinuationAcceptsANewlyIncreasedTotalCount() async {
    let local = GalleryFixtures.local(2)
    let five = GalleryFixtures.remote(5, pictureID: "five", postID: 50)
    let six = GalleryFixtures.remote(6, pictureID: local.pictureID, postID: local.postID)
    let seven = GalleryFixtures.remote(7, pictureID: "seven", postID: 70)
    let eight = GalleryFixtures.remote(8, pictureID: "eight", postID: 80)
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([five, six, seven], totalCount: 8)),
      .value(GalleryFixtures.page([seven, eight], totalCount: 9)),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [local],
      selectedID: local.id,
      service: service
    )

    await viewModel.waitForCurrentLoads()
    viewModel.select(seven.id)
    await viewModel.waitForCurrentLoads()

    XCTAssertEqual(viewModel.totalCount, 9)
    XCTAssertTrue(viewModel.occurrences.contains(eight))
    XCTAssertTrue(viewModel.canLoadNext)
  }

  func testDirectionsCoalesceIndependentlyAndFailedDirectionCanRetry() async throws {
    let local = GalleryFixtures.local(2)
    let five = GalleryFixtures.remote(5, pictureID: "five", postID: 50)
    let six = GalleryFixtures.remote(6, pictureID: local.pictureID, postID: local.postID)
    let seven = GalleryFixtures.remote(7, pictureID: "seven", postID: 70)
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([five, six, seven], totalCount: 10)),
      .suspended(1),
      .suspended(2),
      .value(GalleryFixtures.page([
        GalleryFixtures.remote(3, pictureID: "three", postID: 30),
        GalleryFixtures.remote(4, pictureID: "four", postID: 40),
      ], totalCount: 10)),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [local],
      selectedID: local.id,
      service: service
    )
    await viewModel.waitForCurrentLoads()

    viewModel.select(five.id)
    try await galleryWaitUntil { await service.requestCount() == 2 }
    viewModel.loadIfNeeded()
    viewModel.loadIfNeeded()
    await Task.yield()
    let coalescedRequestCount = await service.requestCount()
    XCTAssertEqual(coalescedRequestCount, 2)

    viewModel.select(seven.id)
    try await galleryWaitUntil { await service.requestCount() == 3 }
    XCTAssertTrue(viewModel.isLoadingPrevious)
    XCTAssertTrue(viewModel.isLoadingNext)

    let resumedNext = await service.resume(
      id: 2,
      returning: GalleryFixtures.page([
        seven,
        GalleryFixtures.remote(8, pictureID: "eight", postID: 80),
        GalleryFixtures.remote(9, pictureID: "nine", postID: 90),
        GalleryFixtures.remote(10, pictureID: "ten", postID: 100),
      ], totalCount: 10)
    )
    XCTAssertTrue(resumedNext)
    try await galleryWaitUntil { !viewModel.isLoadingNext }
    XCTAssertTrue(viewModel.isLoadingPrevious)

    let failedPrevious = await service.fail(
      id: 1,
      with: GalleryStubFailure(message: "previous failed")
    )
    XCTAssertTrue(failedPrevious)
    try await galleryWaitUntil { viewModel.previousError == "previous failed" }
    XCTAssertFalse(viewModel.isLoadingPrevious)
    XCTAssertTrue(viewModel.occurrences.contains(where: { $0.overallIndex == 10 }))
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [local.id: six.id]
    )

    viewModel.retryPrevious()
    await viewModel.waitForCurrentLoads()
    XCTAssertNil(viewModel.previousError)
    XCTAssertTrue(viewModel.occurrences.contains(where: { $0.overallIndex == 3 }))
    let requestSnapshot = await service.requestSnapshot()
    let directions = requestSnapshot.map(\.direction)
    XCTAssertEqual(directions, [
      .bootstrap, .previous, .next, .previous,
    ])
  }

  func testSingleLoadedOccurrenceCanStartBothDirections() async throws {
    let local = GalleryFixtures.local(1)
    let selectedRemote = GalleryFixtures.remote(
      5,
      pictureID: local.pictureID,
      postID: local.postID
    )
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([selectedRemote], totalCount: 10)),
      .suspended(1),
      .suspended(2),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [local],
      selectedID: local.id,
      service: service
    )

    try await galleryWaitUntil { await service.requestCount() == 3 }
    let directions = await service.requestSnapshot().map(\.direction)
    XCTAssertEqual(directions.first, .bootstrap)
    let continuationDirections = Array(directions.dropFirst())
    XCTAssertEqual(continuationDirections.count, 2)
    XCTAssertTrue(continuationDirections.contains(.previous))
    XCTAssertTrue(continuationDirections.contains(.next))
    XCTAssertTrue(viewModel.isLoadingPrevious)
    XCTAssertTrue(viewModel.isLoadingNext)
    let resumedFirst = await service.resume(
      id: 1,
      returning: GalleryFixtures.page([], totalCount: 10)
    )
    let resumedSecond = await service.resume(
      id: 2,
      returning: GalleryFixtures.page([], totalCount: 10)
    )
    XCTAssertTrue(resumedFirst)
    XCTAssertTrue(resumedSecond)
    await viewModel.waitForCurrentLoads()
    viewModel.cancel()
  }

  func testEmptyAndDuplicateOnlyPagesStopTheirDirectionWithoutCrashing() async {
    let local = GalleryFixtures.local(2)
    let five = GalleryFixtures.remote(5, pictureID: "five", postID: 50)
    let six = GalleryFixtures.remote(6, pictureID: local.pictureID, postID: local.postID)
    let seven = GalleryFixtures.remote(7, pictureID: "seven", postID: 70)
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([five, six, seven], totalCount: 10)),
      .value(GalleryFixtures.page([], totalCount: 10)),
      .value(GalleryFixtures.page([seven, seven], totalCount: 10)),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [local],
      selectedID: local.id,
      service: service
    )
    await viewModel.waitForCurrentLoads()

    viewModel.select(five.id)
    await viewModel.waitForCurrentLoads()
    XCTAssertFalse(viewModel.canLoadPrevious)
    XCTAssertEqual(viewModel.occurrences.compactMap(\.overallIndex), [5, 6, 7])

    viewModel.select(seven.id)
    await viewModel.waitForCurrentLoads()
    XCTAssertFalse(viewModel.canLoadNext)
    XCTAssertEqual(viewModel.occurrences.compactMap(\.overallIndex), [5, 6, 7])
  }

  func testInvalidOverallIndicesAndRegressedTotalAreRejected() async {
    let local = GalleryFixtures.local(2)
    let five = GalleryFixtures.remote(5, pictureID: "five", postID: 50)
    let six = GalleryFixtures.remote(6, pictureID: local.pictureID, postID: local.postID)
    let seven = GalleryFixtures.remote(7, pictureID: "seven", postID: 70)
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([five, six, seven], totalCount: 10)),
      .value(GalleryFixtures.page([
        GalleryFixtures.remote(0, pictureID: "zero", postID: 1),
        GalleryFixtures.remote(11, pictureID: "eleven", postID: 11),
      ], totalCount: 10)),
      .value(GalleryFixtures.page([
        GalleryFixtures.remote(8, pictureID: "eight", postID: 80)
      ], totalCount: 4)),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [local],
      selectedID: local.id,
      service: service
    )
    await viewModel.waitForCurrentLoads()

    viewModel.select(five.id)
    await viewModel.waitForCurrentLoads()
    XCTAssertFalse(viewModel.canLoadPrevious)
    XCTAssertEqual(viewModel.totalCount, 10)

    viewModel.select(seven.id)
    await viewModel.waitForCurrentLoads()
    XCTAssertFalse(viewModel.canLoadNext)
    XCTAssertEqual(viewModel.totalCount, 10)
    XCTAssertEqual(viewModel.occurrences.compactMap(\.overallIndex), [5, 6, 7])
  }

  func testContextChangeRejectsLateBootstrapResponse() async throws {
    let oldLocal = GalleryFixtures.local(1)
    let newLocal = GalleryFixtures.local(3, postID: 303)
    let newRemote = GalleryFixtures.remote(
      1,
      pictureID: newLocal.pictureID,
      postID: newLocal.postID
    )
    let service = ScriptedThreadPictureGalleryService([
      .suspended(1),
      .value(GalleryFixtures.page([newRemote], totalCount: 1)),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(threadID: 1),
      localOccurrences: [oldLocal],
      selectedID: oldLocal.id,
      service: service
    )
    try await galleryWaitUntil { await service.requestCount() == 1 }

    viewModel.updateContext(
      GalleryFixtures.context(threadID: 2),
      localOccurrences: [newLocal],
      selectedID: newLocal.id
    )
    XCTAssertTrue(viewModel.galleryState.localToRemoteIDMigrations.isEmpty)
    try await galleryWaitUntil { await service.requestCount() == 2 }
    await viewModel.waitForCurrentLoads()
    XCTAssertEqual(viewModel.context.threadID, 2)
    XCTAssertEqual(viewModel.selectedID, newRemote.id)
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [newLocal.id: newRemote.id]
    )

    let resumedOldContext = await service.resume(
      id: 1,
      returning: GalleryFixtures.page([
        GalleryFixtures.remote(1, pictureID: oldLocal.pictureID, postID: oldLocal.postID)
      ], totalCount: 1)
    )
    XCTAssertTrue(resumedOldContext)
    await Task.yield()
    XCTAssertEqual(viewModel.context.threadID, 2)
    XCTAssertEqual(viewModel.occurrences, [newRemote])
    XCTAssertEqual(viewModel.selectedID, newRemote.id)
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [newLocal.id: newRemote.id]
    )
  }

  func testDisablingRemoteLoadingCancelsWorkRestoresOnlyLocalAndCanReenable() async throws {
    let local = GalleryFixtures.local(1)
    let remote = GalleryFixtures.remote(1, pictureID: local.pictureID, postID: local.postID)
    let service = ScriptedThreadPictureGalleryService([
      .suspended(1),
      .value(GalleryFixtures.page([remote], totalCount: 1)),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [local],
      selectedID: local.id,
      service: service
    )
    try await galleryWaitUntil { await service.requestCount() == 1 }

    viewModel.setRemoteLoadingEnabled(false)
    XCTAssertFalse(viewModel.isRemoteLoadingEnabled)
    XCTAssertEqual(viewModel.occurrences, [local])
    XCTAssertEqual(viewModel.selectedID, local.id)
    XCTAssertTrue(viewModel.galleryState.localToRemoteIDMigrations.isEmpty)
    XCTAssertFalse(viewModel.isBootstrapping)

    let resumedDisabledRequest = await service.resume(
      id: 1,
      returning: GalleryFixtures.page([remote], totalCount: 1)
    )
    XCTAssertTrue(resumedDisabledRequest)
    await Task.yield()
    XCTAssertEqual(viewModel.occurrences, [local])

    viewModel.setRemoteLoadingEnabled(true)
    XCTAssertEqual(viewModel.occurrences, [local])
    XCTAssertTrue(viewModel.galleryState.localToRemoteIDMigrations.isEmpty)
    await viewModel.waitForCurrentLoads()
    XCTAssertTrue(viewModel.isRemoteLoadingEnabled)
    XCTAssertEqual(viewModel.occurrences, [remote])
    XCTAssertEqual(viewModel.selectedID, remote.id)
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [local.id: remote.id]
    )
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 2)

    viewModel.setRemoteLoadingEnabled(false)
    XCTAssertEqual(viewModel.occurrences, [local])
    XCTAssertEqual(viewModel.selectedID, local.id)
    XCTAssertTrue(viewModel.galleryState.localToRemoteIDMigrations.isEmpty)
  }

  func testRemoteResetDoesNotInferALocalSelectionFromAnUnmappedRepeatedPair() async {
    let firstLocal = GalleryFixtures.local(
      1,
      pictureID: "repeated",
      postID: 50,
      contentOffset: 0
    )
    let fallbackLocal = GalleryFixtures.local(2)
    let firstRemote = GalleryFixtures.remote(1, pictureID: "repeated", postID: 50)
    let repeatedRemote = GalleryFixtures.remote(2, pictureID: "repeated", postID: 50)
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([firstRemote], totalCount: 2)),
      .value(GalleryFixtures.page([firstRemote, repeatedRemote], totalCount: 2)),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [firstLocal, fallbackLocal],
      selectedID: firstLocal.id,
      service: service
    )

    await viewModel.waitForCurrentLoads()
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [firstLocal.id: firstRemote.id]
    )

    viewModel.select(fallbackLocal.id)
    await viewModel.waitForCurrentLoads()
    XCTAssertTrue(viewModel.occurrences.contains(repeatedRemote))
    viewModel.select(repeatedRemote.id)

    viewModel.setRemoteLoadingEnabled(false)

    XCTAssertEqual(viewModel.occurrences, [firstLocal, fallbackLocal])
    XCTAssertEqual(viewModel.selectedID, fallbackLocal.id)
    XCTAssertTrue(viewModel.galleryState.localToRemoteIDMigrations.isEmpty)
  }

  func testContextResetClearsCommittedMigrationsBeforeReplacementBootstrap() async throws {
    let oldLocal = GalleryFixtures.local(1)
    let oldRemote = GalleryFixtures.remote(
      1,
      pictureID: oldLocal.pictureID,
      postID: oldLocal.postID
    )
    let newLocal = GalleryFixtures.local(2, postID: 202)
    let newRemote = GalleryFixtures.remote(
      1,
      pictureID: newLocal.pictureID,
      postID: newLocal.postID
    )
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([oldRemote], totalCount: 1)),
      .suspended(1),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(threadID: 1),
      localOccurrences: [oldLocal],
      selectedID: oldLocal.id,
      service: service
    )
    await viewModel.waitForCurrentLoads()
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [oldLocal.id: oldRemote.id]
    )

    viewModel.updateContext(
      GalleryFixtures.context(threadID: 2),
      localOccurrences: [newLocal],
      selectedID: newLocal.id
    )
    try await galleryWaitUntil { await service.requestCount() == 2 }

    XCTAssertEqual(viewModel.occurrences, [newLocal])
    XCTAssertEqual(viewModel.selectedID, newLocal.id)
    XCTAssertTrue(viewModel.galleryState.localToRemoteIDMigrations.isEmpty)

    let resumed = await service.resume(
      id: 1,
      returning: GalleryFixtures.page([newRemote], totalCount: 1)
    )
    XCTAssertTrue(resumed)
    await viewModel.waitForCurrentLoads()
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [newLocal.id: newRemote.id]
    )
  }

  func testLocalSnapshotResetClearsCommittedMigrationsInTheSameContext() async throws {
    let oldLocal = GalleryFixtures.local(1)
    let oldRemote = GalleryFixtures.remote(
      1,
      pictureID: oldLocal.pictureID,
      postID: oldLocal.postID
    )
    let newLocal = GalleryFixtures.local(2)
    let newRemote = GalleryFixtures.remote(
      1,
      pictureID: newLocal.pictureID,
      postID: newLocal.postID
    )
    let service = ScriptedThreadPictureGalleryService([
      .value(GalleryFixtures.page([oldRemote], totalCount: 1)),
      .suspended(1),
    ])
    let context = GalleryFixtures.context()
    let viewModel = ThreadImageGalleryViewModel(
      context: context,
      localOccurrences: [oldLocal],
      selectedID: oldLocal.id,
      service: service
    )
    await viewModel.waitForCurrentLoads()
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [oldLocal.id: oldRemote.id]
    )

    viewModel.updateContext(
      context,
      localOccurrences: [newLocal],
      selectedID: newLocal.id
    )
    try await galleryWaitUntil { await service.requestCount() == 2 }

    XCTAssertEqual(viewModel.occurrences, [newLocal])
    XCTAssertEqual(viewModel.selectedID, newLocal.id)
    XCTAssertTrue(viewModel.galleryState.localToRemoteIDMigrations.isEmpty)

    let resumed = await service.resume(
      id: 1,
      returning: GalleryFixtures.page([newRemote], totalCount: 1)
    )
    XCTAssertTrue(resumed)
    await viewModel.waitForCurrentLoads()
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [newLocal.id: newRemote.id]
    )
  }

  func testCancelRejectsLateResponseAndLoadIfNeededStartsFreshBootstrap() async throws {
    let local = GalleryFixtures.local(1)
    let remote = GalleryFixtures.remote(1, pictureID: local.pictureID, postID: local.postID)
    let service = ScriptedThreadPictureGalleryService([
      .suspended(1),
      .value(GalleryFixtures.page([remote], totalCount: 1)),
    ])
    let viewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [local],
      selectedID: local.id,
      service: service
    )
    try await galleryWaitUntil { await service.requestCount() == 1 }

    viewModel.cancel()
    XCTAssertFalse(viewModel.isBootstrapping)
    XCTAssertEqual(viewModel.occurrences, [local])
    viewModel.loadIfNeeded()
    try await galleryWaitUntil { await service.requestCount() == 2 }
    await viewModel.waitForCurrentLoads()
    XCTAssertEqual(viewModel.selectedID, remote.id)
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [local.id: remote.id]
    )

    let resumedCanceledRequest = await service.resume(
      id: 1,
      returning: GalleryFixtures.page([
        GalleryFixtures.remote(2, pictureID: local.pictureID, postID: local.postID)
      ], totalCount: 2)
    )
    XCTAssertTrue(resumedCanceledRequest)
    await Task.yield()
    XCTAssertEqual(viewModel.occurrences, [remote])
    XCTAssertEqual(viewModel.selectedID, remote.id)
    XCTAssertEqual(
      viewModel.galleryState.localToRemoteIDMigrations,
      [local.id: remote.id]
    )
  }

  func testEmptyLocalGalleryAndDisabledModeNeverRequestOrIndexEmptyCollection() async {
    let service = ScriptedThreadPictureGalleryService()
    let emptyViewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [],
      selectedID: .local(postID: 1, contentOffset: 0),
      service: service
    )
    emptyViewModel.loadIfNeeded()
    emptyViewModel.select(nil)

    let local = GalleryFixtures.local(1)
    let disabledViewModel = ThreadImageGalleryViewModel(
      context: GalleryFixtures.context(),
      localOccurrences: [local],
      selectedID: local.id,
      isRemoteLoadingEnabled: false,
      service: service
    )
    disabledViewModel.loadIfNeeded()

    await Task.yield()
    XCTAssertTrue(emptyViewModel.occurrences.isEmpty)
    XCTAssertNil(emptyViewModel.selectedID)
    XCTAssertEqual(disabledViewModel.occurrences, [local])
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

  func testViewerContextRevisionChangesOnlyAtHardIdentityBoundaries() async {
    let service = ScriptedThreadPictureGalleryService()
    let local = [GalleryFixtures.local(1), GalleryFixtures.local(2)]
    let firstContext = ThreadPictureGalleryContext(
      forumID: 0,
      forumName: "",
      threadID: 1
    )
    let secondContext = ThreadPictureGalleryContext(
      forumID: 0,
      forumName: "",
      threadID: 2
    )
    let viewModel = ThreadImageGalleryViewModel(
      context: firstContext,
      localOccurrences: local,
      selectedID: local[0].id,
      isRemoteLoadingEnabled: false,
      service: service
    )

    XCTAssertEqual(viewModel.galleryState.viewerContextRevision, 0)
    viewModel.select(local[1].id)
    XCTAssertEqual(viewModel.galleryState.viewerContextRevision, 0)

    viewModel.setRemoteLoadingEnabled(true)
    XCTAssertEqual(viewModel.galleryState.viewerContextRevision, 0)
    viewModel.setRemoteLoadingEnabled(false)
    XCTAssertEqual(viewModel.galleryState.viewerContextRevision, 1)

    viewModel.updateContext(
      secondContext,
      localOccurrences: local,
      selectedID: local[1].id
    )
    XCTAssertEqual(viewModel.galleryState.viewerContextRevision, 2)
    XCTAssertEqual(viewModel.occurrences.map(\.id), local.map(\.id))
    let requestCount = await service.requestCount()
    XCTAssertEqual(requestCount, 0)
  }

}

private struct GalleryStubFailure: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private enum ThreadPictureGalleryStub: Sendable {
  case value(ThreadPicturePage)
  case failure(GalleryStubFailure)
  case suspended(Int)
}

private actor ScriptedThreadPictureGalleryService: ThreadPictureGalleryService {
  private var stubs: [ThreadPictureGalleryStub]
  private var requests: [ThreadPicturePageRequest] = []
  private var pending: [Int: CheckedContinuation<ThreadPicturePage, any Error>] = [:]

  init(_ stubs: [ThreadPictureGalleryStub] = []) {
    self.stubs = stubs
  }

  func picturePage(for request: ThreadPicturePageRequest) async throws -> ThreadPicturePage {
    requests.append(request)
    guard !stubs.isEmpty else {
      throw GalleryStubFailure(message: "unexpected gallery request")
    }
    switch stubs.removeFirst() {
    case .value(let page):
      return page
    case .failure(let error):
      throw error
    case .suspended(let identifier):
      return try await withCheckedThrowingContinuation { continuation in
        pending[identifier] = continuation
      }
    }
  }

  func requestCount() -> Int { requests.count }
  func requestSnapshot() -> [ThreadPicturePageRequest] { requests }

  func resume(id: Int, returning page: ThreadPicturePage) -> Bool {
    guard let continuation = pending.removeValue(forKey: id) else { return false }
    continuation.resume(returning: page)
    return true
  }

  func fail(id: Int, with error: GalleryStubFailure) -> Bool {
    guard let continuation = pending.removeValue(forKey: id) else { return false }
    continuation.resume(throwing: error)
    return true
  }
}

private enum GalleryFixtures {
  static func context(threadID: Int64 = 1000) -> ThreadPictureGalleryContext {
    ThreadPictureGalleryContext(
      forumID: 42,
      forumName: "swift",
      threadID: threadID
    )
  }

  static func local(
    _ number: Int,
    pictureID: String? = nil,
    postID: Int64? = nil,
    contentOffset: Int? = nil,
    imageOrdinal: Int? = nil
  ) -> ThreadPictureOccurrence {
    ThreadPictureOccurrence(
      localURL: URL(string: "https://example.com/local-\(number).jpg")!,
      pictureID: pictureID ?? "picture-\(number)",
      postID: postID ?? Int64(100 + number),
      contentOffset: contentOffset ?? (number - 1),
      imageOrdinal: imageOrdinal
    )
  }

  static func remote(
    _ overallIndex: Int,
    pictureID: String,
    postID: Int64 = 100
  ) -> ThreadPictureOccurrence {
    ThreadPictureOccurrence(
      remoteURL: URL(string: "https://example.com/remote-\(overallIndex).jpg")!,
      pictureID: pictureID,
      postID: postID,
      overallIndex: overallIndex
    )
  }

  static func page(
    _ occurrences: [ThreadPictureOccurrence],
    totalCount: Int
  ) -> ThreadPicturePage {
    ThreadPicturePage(occurrences: occurrences, totalCount: totalCount)
  }
}

private struct GalleryWaitTimeout: Error {}

@MainActor
private func galleryWaitUntil(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw GalleryWaitTimeout() }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
