import XCTest

@testable import TiebaPlusPlus

final class ThreadCloudFavoriteFloorPresentationTests: XCTestCase {
  func testReadyStateOffersExactAddUpdateAndRemoveActions() throws {
    let target = try XCTUnwrap(makeTarget(threadID: 40))
    let post = makePost(id: 401, threadID: target.threadID, floor: 6)
    let position = try XCTUnwrap(
      ThreadCloudFavoritePosition(post: post, threadID: target.threadID)
    )

    XCTAssertEqual(
      presentation(post: post, target: target, state: .ready(snapshot(nil))),
      ThreadCloudFavoriteFloorPresentation(
        post: post,
        target: target,
        entryTarget: target,
        state: .ready(snapshot(nil)),
        isPureReadingMode: false
      )
    )
    XCTAssertEqual(
      presentation(post: post, target: target, state: .ready(snapshot(nil))).action,
      .add(target: target, position: position, previous: snapshot(nil))
    )

    let otherMarker = snapshot(499)
    let update = presentation(post: post, target: target, state: .ready(otherMarker))
    XCTAssertFalse(update.isCurrentPosition)
    XCTAssertEqual(
      update.action,
      .update(target: target, position: position, previous: otherMarker)
    )

    let current = presentation(post: post, target: target, state: .ready(snapshot(post.id)))
    XCTAssertTrue(current.isCurrentPosition)
    XCTAssertEqual(
      current.action,
      .remove(target: target, previous: snapshot(post.id))
    )
  }

  func testTransientAndFailedStatesRetainOnlyConfirmedMarkerWithoutOfferingAction() throws {
    let target = try XCTUnwrap(makeTarget(threadID: 41))
    let post = makePost(id: 411, threadID: target.threadID, floor: 7)
    let current = snapshot(post.id)
    let other = snapshot(499)

    let statesWithCurrentMarker: [ThreadCloudFavoriteEntryState] = [
      .loading(previous: current),
      .mutating(previous: current, requestedMarkedPostID: 499),
      .failed(previous: current, message: "unavailable"),
    ]
    for state in statesWithCurrentMarker {
      let value = presentation(post: post, target: target, state: state)
      XCTAssertTrue(value.isCurrentPosition)
      XCTAssertNil(value.action)
    }

    let statesWithoutCurrentMarker: [ThreadCloudFavoriteEntryState] = [
      .unknown,
      .signedOut,
      .loading(previous: nil),
      .loading(previous: other),
      .mutating(previous: other, requestedMarkedPostID: post.id),
      .failed(previous: nil, message: "unavailable"),
      .failed(previous: other, message: "unavailable"),
    ]
    for state in statesWithoutCurrentMarker {
      let value = presentation(post: post, target: target, state: state)
      XCTAssertFalse(value.isCurrentPosition)
      XCTAssertNil(value.action)
    }
  }

  func testPureReadingKeepsExactMarkerReadOnly() throws {
    let target = try XCTUnwrap(makeTarget(threadID: 42))
    let post = makePost(id: 421, threadID: target.threadID, floor: 8)

    let current = presentation(
      post: post,
      target: target,
      state: .ready(snapshot(post.id)),
      isPureReadingMode: true
    )
    XCTAssertTrue(current.isCurrentPosition)
    XCTAssertNil(current.action)

    for markedPostID in [nil, 499] as [Int64?] {
      let value = presentation(
        post: post,
        target: target,
        state: .ready(snapshot(markedPostID)),
        isPureReadingMode: true
      )
      XCTAssertFalse(value.isCurrentPosition)
      XCTAssertNil(value.action)
    }
  }

  func testPresentationFailsClosedForTargetIdentityAndPostVisibility() throws {
    let target = try XCTUnwrap(makeTarget(threadID: 43))
    let differentEntryTarget = try XCTUnwrap(
      ThreadCloudFavoriteTarget(
        forumID: target.forumID + 1,
        forumName: "Other",
        threadID: target.threadID
      )
    )
    let post = makePost(id: 431, threadID: target.threadID, floor: 9)
    let state = ThreadCloudFavoriteEntryState.ready(snapshot(post.id))

    let mismatchedEntry = ThreadCloudFavoriteFloorPresentation(
      post: post,
      target: target,
      entryTarget: differentEntryTarget,
      state: state,
      isPureReadingMode: false
    )
    XCTAssertFalse(mismatchedEntry.isCurrentPosition)
    XCTAssertNil(mismatchedEntry.action)

    let invalidPosts = [
      makePost(id: post.id, threadID: target.threadID + 1, floor: post.floor),
      makePost(id: 0, threadID: target.threadID, floor: post.floor),
      makePost(id: post.id, threadID: target.threadID, floor: 0),
      post.withLocalVisibility(.placeholder),
      post.withLocalVisibility(.hidden),
    ]
    for invalidPost in invalidPosts {
      let value = presentation(post: invalidPost, target: target, state: state)
      XCTAssertFalse(value.isCurrentPosition)
      XCTAssertNil(value.action)
    }
  }

  func testMarkerUsesExactPostIDRatherThanFloorNumber() throws {
    let target = try XCTUnwrap(makeTarget(threadID: 44))
    let marked = makePost(id: 441, threadID: target.threadID, floor: 10)
    let duplicateFloor = makePost(id: 442, threadID: target.threadID, floor: 10)

    let value = presentation(
      post: duplicateFloor,
      target: target,
      state: .ready(snapshot(marked.id))
    )

    XCTAssertFalse(value.isCurrentPosition)
    XCTAssertEqual(
      value.action,
      .update(
        target: target,
        position: try XCTUnwrap(
          ThreadCloudFavoritePosition(post: duplicateFloor, threadID: target.threadID)
        ),
        previous: snapshot(marked.id)
      )
    )
  }

  func testFloorMenuCopyNamesTheExactConfirmedOperation() throws {
    let target = try XCTUnwrap(makeTarget(threadID: 45))
    let post = makePost(id: 451, threadID: target.threadID, floor: 11)
    let position = try XCTUnwrap(
      ThreadCloudFavoritePosition(post: post, threadID: target.threadID)
    )

    let add = ThreadCloudFavoritePendingAction.add(
      target: target,
      position: position,
      previous: snapshot(nil)
    )
    let update = ThreadCloudFavoritePendingAction.update(
      target: target,
      position: position,
      previous: snapshot(499)
    )
    let remove = ThreadCloudFavoritePendingAction.remove(
      target: target,
      previous: snapshot(post.id)
    )

    XCTAssertEqual(add.floorMenuTitle, "收藏到第 11 楼")
    XCTAssertEqual(add.floorMenuSystemImage, "star")
    XCTAssertEqual(update.floorMenuTitle, "更新云收藏到第 11 楼")
    XCTAssertEqual(update.floorMenuSystemImage, "bookmark.circle")
    XCTAssertEqual(remove.floorMenuTitle, "移除云端收藏")
    XCTAssertEqual(remove.floorMenuSystemImage, "trash")
  }

  func testAdmissionRequiresCurrentReadySnapshotAndExactRetainedPost() throws {
    let target = try XCTUnwrap(makeTarget(threadID: 46))
    let post = makePost(id: 461, threadID: target.threadID, floor: 12)
    let position = try XCTUnwrap(
      ThreadCloudFavoritePosition(post: post, threadID: target.threadID)
    )
    let add = ThreadCloudFavoritePendingAction.add(
      target: target,
      position: position,
      previous: snapshot(nil)
    )
    let update = ThreadCloudFavoritePendingAction.update(
      target: target,
      position: position,
      previous: snapshot(499)
    )
    let remove = ThreadCloudFavoritePendingAction.remove(
      target: target,
      previous: snapshot(post.id)
    )

    XCTAssertTrue(
      ThreadCloudFavoriteActionAdmissionPolicy.admits(
        add,
        target: target,
        state: .ready(snapshot(nil)),
        retainedPost: post
      )
    )
    XCTAssertTrue(
      ThreadCloudFavoriteActionAdmissionPolicy.admits(
        update,
        target: target,
        state: .ready(snapshot(499)),
        retainedPost: post
      )
    )
    XCTAssertTrue(
      ThreadCloudFavoriteActionAdmissionPolicy.admits(
        remove,
        target: target,
        state: .ready(snapshot(post.id)),
        retainedPost: nil
      )
    )

    XCTAssertFalse(
      ThreadCloudFavoriteActionAdmissionPolicy.admits(
        add,
        target: target,
        state: .loading(previous: snapshot(nil)),
        retainedPost: post
      )
    )
    XCTAssertFalse(
      ThreadCloudFavoriteActionAdmissionPolicy.admits(
        add,
        target: target,
        state: .ready(snapshot(499)),
        retainedPost: post
      )
    )
    XCTAssertFalse(
      ThreadCloudFavoriteActionAdmissionPolicy.admits(
        update,
        target: target,
        state: .ready(snapshot(post.id)),
        retainedPost: post
      )
    )
    XCTAssertFalse(
      ThreadCloudFavoriteActionAdmissionPolicy.admits(
        update,
        target: target,
        state: .ready(snapshot(498)),
        retainedPost: post
      )
    )
    XCTAssertFalse(
      ThreadCloudFavoriteActionAdmissionPolicy.admits(
        remove,
        target: target,
        state: .ready(snapshot(post.id + 1)),
        retainedPost: nil
      )
    )
    XCTAssertFalse(
      ThreadCloudFavoriteActionAdmissionPolicy.admits(
        remove,
        target: target,
        state: .ready(snapshot(nil)),
        retainedPost: nil
      )
    )
  }

  func testAdmissionRejectsStaleTargetAndAlteredPostIdentity() throws {
    let target = try XCTUnwrap(makeTarget(threadID: 47))
    let otherTarget = try XCTUnwrap(makeTarget(threadID: 48))
    let post = makePost(id: 471, threadID: target.threadID, floor: 13)
    let position = try XCTUnwrap(
      ThreadCloudFavoritePosition(post: post, threadID: target.threadID)
    )
    let action = ThreadCloudFavoritePendingAction.add(
      target: target,
      position: position,
      previous: snapshot(nil)
    )
    let state = ThreadCloudFavoriteEntryState.ready(snapshot(nil))

    let invalidPosts: [BrowsePost?] = [
      nil,
      makePost(id: post.id, threadID: target.threadID + 1, floor: post.floor),
      makePost(id: post.id, threadID: target.threadID, floor: post.floor + 1),
      makePost(id: post.id + 1, threadID: target.threadID, floor: post.floor),
      post.withLocalVisibility(.placeholder),
      post.withLocalVisibility(.hidden),
    ]
    for invalidPost in invalidPosts {
      XCTAssertFalse(
        ThreadCloudFavoriteActionAdmissionPolicy.admits(
          action,
          target: target,
          state: state,
          retainedPost: invalidPost
        )
      )
    }

    XCTAssertFalse(
      ThreadCloudFavoriteActionAdmissionPolicy.admits(
        action,
        target: otherTarget,
        state: state,
        retainedPost: post
      )
    )
  }

  private func presentation(
    post: BrowsePost,
    target: ThreadCloudFavoriteTarget,
    state: ThreadCloudFavoriteEntryState,
    isPureReadingMode: Bool = false
  ) -> ThreadCloudFavoriteFloorPresentation {
    ThreadCloudFavoriteFloorPresentation(
      post: post,
      target: target,
      entryTarget: target,
      state: state,
      isPureReadingMode: isPureReadingMode
    )
  }

  private func makeTarget(threadID: Int64) -> ThreadCloudFavoriteTarget? {
    ThreadCloudFavoriteTarget(forumID: 4, forumName: "Swift", threadID: threadID)
  }

  private func snapshot(_ markedPostID: Int64?) -> ThreadCloudFavoriteSnapshot {
    ThreadCloudFavoriteSnapshot(markedPostID: markedPostID)!
  }

  private func makePost(id: Int64, threadID: Int64, floor: Int) -> BrowsePost {
    BrowsePost(
      id: id,
      threadID: threadID,
      floor: floor,
      authorID: 1,
      authorName: "Tester",
      authorPortraitURL: nil,
      createdAt: nil,
      nestedReplyCount: 0,
      isThreadAuthor: false,
      contents: [.text("post")]
    )
  }
}
