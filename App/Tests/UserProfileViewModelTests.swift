import XCTest

@testable import TiebaPlusPlus

@MainActor
final class UserProfileViewModelTests: XCTestCase {
  func testLoadsAnonymousProfileAndPublicThreads() async throws {
    let service = UserProfileServiceStub(
      profile: .fixture,
      pages: [
        1: UserThreadPageData(
          threads: [.fixture(id: 10)],
          currentPage: 1,
          hasMore: true,
          isHidden: false
        )
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile { viewModel.state == .loaded }

    XCTAssertEqual(viewModel.profile?.id, 7)
    XCTAssertEqual(viewModel.profile?.preferredName, "测试用户")
    XCTAssertEqual(viewModel.threads.map(\.id), [10])
    XCTAssertFalse(viewModel.isActivityHidden)
    let profileRequests = await service.profileRequestSnapshot()
    let threadRequests = await service.threadRequestSnapshot()
    XCTAssertEqual(profileRequests, [7])
    XCTAssertEqual(threadRequests, [UserThreadRequest(userID: 7, page: 1)])
  }

  func testPaginationMergesUniqueThreadsAndStopsOnRepeatedPage() async throws {
    let service = UserProfileServiceStub(
      profile: .fixture,
      pages: [
        1: UserThreadPageData(
          threads: [.fixture(id: 10)],
          currentPage: 1,
          hasMore: true,
          isHidden: false
        ),
        2: UserThreadPageData(
          threads: [.fixture(id: 10), .fixture(id: 11)],
          currentPage: 2,
          hasMore: true,
          isHidden: false
        ),
        3: UserThreadPageData(
          threads: [.fixture(id: 11)],
          currentPage: 3,
          hasMore: true,
          isHidden: false
        ),
      ]
    )
    let viewModel = UserProfileViewModel(userID: 7, service: service)

    viewModel.loadIfNeeded()
    try await waitForProfile { viewModel.state == .loaded }
    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await waitForProfile { viewModel.threads.map(\.id) == [10, 11] }

    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    try await waitForProfile { await service.threadRequestCount() == 3 && !viewModel.isLoadingMore }
    viewModel.loadMoreIfNeeded(current: try XCTUnwrap(viewModel.threads.last))
    await Task.yield()

    XCTAssertEqual(viewModel.threads.map(\.id), [10, 11])
    let requestCount = await service.threadRequestCount()
    XCTAssertEqual(requestCount, 3)
  }
}

private struct UserThreadRequest: Equatable, Sendable {
  let userID: Int64
  let page: Int
}

private enum UserProfileStubError: Error {
  case missingPage
}

private actor UserProfileServiceStub: UserProfileService {
  let profile: BrowseUserProfile
  let pages: [Int: UserThreadPageData]
  private var profileRequests: [Int64] = []
  private var threadRequests: [UserThreadRequest] = []

  init(profile: BrowseUserProfile, pages: [Int: UserThreadPageData]) {
    self.profile = profile
    self.pages = pages
  }

  func userProfile(userID: Int64) async throws -> BrowseUserProfile {
    profileRequests.append(userID)
    return profile
  }

  func userThreads(userID: Int64, page: Int, pageSize: Int) async throws
    -> UserThreadPageData
  {
    threadRequests.append(UserThreadRequest(userID: userID, page: page))
    guard let response = pages[page] else { throw UserProfileStubError.missingPage }
    return response
  }

  func profileRequestSnapshot() -> [Int64] { profileRequests }
  func threadRequestSnapshot() -> [UserThreadRequest] { threadRequests }
  func threadRequestCount() -> Int { threadRequests.count }
}

extension BrowseUserProfile {
  fileprivate static let fixture = BrowseUserProfile(
    id: 7,
    tiebaUID: 70,
    username: "fixture-user",
    displayName: "测试用户",
    portraitURL: nil,
    growthLevel: 8,
    gender: .female,
    ipLocation: "上海",
    badges: ["测试印记"],
    biography: "公开简介",
    tiebaAge: "10.0",
    threadCount: 3,
    postCount: 20,
    followerCount: 100,
    followingCount: 10,
    followedForumCount: 5,
    totalAgreeCount: 500,
    isModerator: false,
    isVIP: true,
    isVerifiedCreator: false,
    isBlocked: false
  )
}

extension BrowseThread {
  fileprivate static func fixture(id: Int64) -> BrowseThread {
    BrowseThread(
      id: id,
      forumID: 42,
      forumName: "swift",
      title: "thread-\(id)",
      excerpt: "excerpt-\(id)",
      authorName: "测试用户",
      replyCount: 2,
      viewCount: 10,
      createdAt: nil,
      lastReplyAt: nil,
      contents: [.text("content")]
    )
  }
}

@MainActor
private func waitForProfile(
  timeout: TimeInterval = 2,
  condition: @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else { throw UserProfileStubError.missingPage }
    try await Task.sleep(nanoseconds: 10_000_000)
  }
}
