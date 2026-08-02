import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ForumInformationViewModelTests: XCTestCase {
  @MainActor
  func testTabsLoadIndependentlyAndCacheSuccessfulResponses() async throws {
    let service = ForumInformationStub()
    await service.enqueueOverview(.value(Fixtures.overview))
    await service.enqueueRules(.value(Fixtures.rules))
    await service.enqueueModerators(.value(Fixtures.roles))
    let viewModel = ForumInformationViewModel(forumID: 100, service: service)

    await viewModel.load(.overview)
    await viewModel.load(.rules)
    await viewModel.load(.moderators)
    await viewModel.load(.overview)

    guard case .loaded(let overview) = viewModel.overview else {
      return XCTFail("Expected overview to load")
    }
    guard case .loaded(let rules) = viewModel.rules else {
      return XCTFail("Expected rules to load")
    }
    guard case .loaded(let roles) = viewModel.moderatorRoles else {
      return XCTFail("Expected moderators to load")
    }
    XCTAssertEqual(overview, Fixtures.overview)
    XCTAssertEqual(rules, Fixtures.rules)
    XCTAssertEqual(roles, Fixtures.roles)
    let counts = await service.requestCounts()
    XCTAssertEqual(counts, RequestCounts(overview: 1, rules: 1, moderators: 1))
  }

  @MainActor
  func testFailedTabCanRetryWithoutReloadingOtherTabs() async throws {
    let service = ForumInformationStub()
    await service.enqueueRules(.failure(StubFailure(message: "rules unavailable")))
    await service.enqueueRules(.value(Fixtures.rules))
    let viewModel = ForumInformationViewModel(forumID: 100, service: service)

    await viewModel.load(.rules)
    guard case .failed(let message) = viewModel.rules else {
      return XCTFail("Expected the first request to fail")
    }
    XCTAssertEqual(message, "rules unavailable")

    await viewModel.load(.rules)
    guard case .loaded(let rules) = viewModel.rules else {
      return XCTFail("Expected retry to succeed")
    }
    XCTAssertEqual(rules, Fixtures.rules)
    let counts = await service.requestCounts()
    XCTAssertEqual(counts, RequestCounts(overview: 0, rules: 2, moderators: 0))
  }

  @MainActor
  func testReloadFetchesARecentlyLoadedTabAgain() async throws {
    let service = ForumInformationStub()
    let updated = BrowseForumOverview(
      forum: Fixtures.forum,
      introduction: "updated introduction",
      originalAvatarURL: Fixtures.overview.originalAvatarURL
    )
    await service.enqueueOverview(.value(Fixtures.overview))
    await service.enqueueOverview(.value(updated))
    let viewModel = ForumInformationViewModel(forumID: 100, service: service)

    await viewModel.load(.overview)
    await viewModel.reload(.overview)

    guard case .loaded(let overview) = viewModel.overview else {
      return XCTFail("Expected refreshed overview")
    }
    XCTAssertEqual(overview, updated)
    let counts = await service.requestCounts()
    XCTAssertEqual(counts.overview, 2)
  }

  @MainActor
  func testInvalidForumIDDoesNotReachService() async throws {
    let service = ForumInformationStub()
    let viewModel = ForumInformationViewModel(forumID: 0, service: service)

    await viewModel.load(.overview)
    await viewModel.load(.rules)
    await viewModel.load(.moderators)

    let counts = await service.requestCounts()
    XCTAssertEqual(counts, RequestCounts(overview: 0, rules: 0, moderators: 0))
  }
}

private struct RequestCounts: Equatable, Sendable {
  let overview: Int
  let rules: Int
  let moderators: Int
}

private struct StubFailure: LocalizedError, Sendable {
  let message: String

  var errorDescription: String? { message }
}

private enum Stub<Value: Sendable>: Sendable {
  case value(Value)
  case failure(StubFailure)

  func get() throws -> Value {
    switch self {
    case .value(let value):
      value
    case .failure(let error):
      throw error
    }
  }
}

private actor ForumInformationStub: ForumInformationService {
  private var overviewStubs: [Stub<BrowseForumOverview>] = []
  private var rulesStubs: [Stub<BrowseForumRules>] = []
  private var moderatorStubs: [Stub<[BrowseForumModeratorRole]>] = []
  private var overviewRequests = 0
  private var rulesRequests = 0
  private var moderatorRequests = 0

  func enqueueOverview(_ stub: Stub<BrowseForumOverview>) {
    overviewStubs.append(stub)
  }

  func enqueueRules(_ stub: Stub<BrowseForumRules>) {
    rulesStubs.append(stub)
  }

  func enqueueModerators(_ stub: Stub<[BrowseForumModeratorRole]>) {
    moderatorStubs.append(stub)
  }

  func forumOverview(forumID: Int64) async throws -> BrowseForumOverview {
    overviewRequests += 1
    guard !overviewStubs.isEmpty else { throw StubFailure(message: "unexpected overview") }
    return try overviewStubs.removeFirst().get()
  }

  func forumModeratorRoles(forumID: Int64) async throws -> [BrowseForumModeratorRole] {
    moderatorRequests += 1
    guard !moderatorStubs.isEmpty else {
      throw StubFailure(message: "unexpected moderators")
    }
    return try moderatorStubs.removeFirst().get()
  }

  func forumRules(forumID: Int64) async throws -> BrowseForumRules {
    rulesRequests += 1
    guard !rulesStubs.isEmpty else { throw StubFailure(message: "unexpected rules") }
    return try rulesStubs.removeFirst().get()
  }

  func requestCounts() -> RequestCounts {
    RequestCounts(
      overview: overviewRequests,
      rules: rulesRequests,
      moderators: moderatorRequests
    )
  }
}

private enum Fixtures {
  static let forum = BrowseForum(
    id: 100,
    name: "Swift",
    category: "科技",
    subcategory: "编程",
    memberCount: 1_000,
    threadCount: 200,
    postCount: 3_000,
    avatarURL: URL(string: "https://example.com/forum.png"),
    slogan: "Swift forum",
    hasModerators: true,
    hasRules: true,
    featuredClassifications: []
  )

  static let overview = BrowseForumOverview(
    forum: forum,
    introduction: "forum introduction",
    originalAvatarURL: URL(string: "https://example.com/forum-original.png")
  )

  static let moderator = BrowseForumModerator(
    id: 7,
    username: "moderator",
    displayName: "Moderator",
    portraitURL: URL(string: "https://example.com/moderator.png"),
    level: 12,
    roleName: "吧主"
  )

  static let roles = [
    BrowseForumModeratorRole(id: 0, name: "吧主", moderators: [moderator])
  ]

  static let rules = BrowseForumRules(
    title: "Swift 吧规",
    preface: "Please read first",
    rules: [BrowseForumRule(id: 0, title: "Rule one", contents: [.text("Be kind")])],
    publishTime: "2026-08-02",
    author: moderator
  )
}
