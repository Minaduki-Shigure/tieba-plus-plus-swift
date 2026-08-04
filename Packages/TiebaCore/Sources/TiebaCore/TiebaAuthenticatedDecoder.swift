import CoreFoundation
import Foundation
import TiebaProto

struct TiebaForumMembershipContext:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let state: TiebaForumAccountState
  let tbs: String

  var membership: TiebaForumMembership { state.membership }

  var description: String { "TiebaForumMembershipContext(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["state": state], displayStyle: .struct)
  }
}

enum TiebaAuthenticatedDecoder {
  static func account(from body: Data) throws -> TiebaAuthenticatedAccount {
    let object = try responseObject(from: body)
    try checkServerError(object)
    guard
      let user = object["user"] as? [String: Any],
      let userID = int64(user["id"]),
      userID > 0,
      let username = string(user["name"]),
      let portrait = string(user["portrait"])
    else {
      throw TiebaClientError.invalidJSON
    }
    return TiebaAuthenticatedAccount(
      userID: userID,
      username: username,
      portrait: portrait
    )
  }

  static func followedForums(
    from body: Data,
    page: Int,
    pageSize: Int
  ) throws -> TiebaFollowedForumPage {
    let object = try responseObject(from: body)
    try checkServerError(object)

    var forums = [TiebaFollowedForum]()
    if let groups = object["forum_list"] as? [String: Any] {
      for key in ["non-gconforum", "gconforum"] {
        guard let entries = groups[key] as? [[String: Any]] else { continue }
        forums.append(contentsOf: entries.compactMap(followedForum))
      }
    }
    var seen = Set<Int64>()
    forums = forums.filter { seen.insert($0.id).inserted }
    let hasMore = bool(object["has_more"]) ?? false
    return TiebaFollowedForumPage(
      forums: forums,
      pagination: TiebaPagination(
        pageSize: pageSize,
        currentPage: page,
        totalPages: 0,
        totalCount: 0,
        hasMore: hasMore,
        hasPrevious: page > 1
      )
    )
  }

  static func forumMembership(
    from response: FrsPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) throws -> TiebaForumMembershipContext {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    guard
      response.hasData,
      response.data.hasUser,
      response.data.hasForum,
      response.data.hasAnti
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let expectedForumName = canonicalForumName(forumName)
    let responseForumName = canonicalForumName(response.data.forum.name)
    let followValue = response.data.forum.isLike
    let tbs = response.data.anti.tbs
    guard
      response.data.user.id == expectedUserID,
      response.data.forum.id == forumID,
      !expectedForumName.isEmpty,
      responseForumName == expectedForumName,
      followValue == 0 || followValue == 1,
      TiebaAuthenticatedRequestFactory.isValidTBS(tbs)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let membership = TiebaForumMembership(
      userID: expectedUserID,
      forumID: forumID,
      forumName: responseForumName,
      isFollowed: followValue == 1
    )

    return TiebaForumMembershipContext(
      state: TiebaForumAccountState(membership: membership, checkIn: nil),
      tbs: tbs
    )
  }

  static func forumAccountState(
    from response: FrsPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) throws -> TiebaForumMembershipContext {
    let context = try forumMembership(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName
    )
    let checkIn = try forumCheckInMetadata(
      from: response,
      expectedUserID: expectedUserID
    )
    return TiebaForumMembershipContext(
      state: TiebaForumAccountState(
        membership: context.membership,
        checkIn: checkIn
      ),
      tbs: context.tbs
    )
  }

  static func checkForumFollowWriteResponse(_ body: Data) throws {
    let object = try responseObject(from: body)
    try checkServerError(object)
  }

  static func forumCheckIn(from body: Data, expectedUserID: Int64) throws -> TiebaForumCheckIn {
    let object = try responseObject(from: body)
    try checkServerError(object)
    guard
      let userInfo = object["user_info"] as? [String: Any],
      let userID = int64(userInfo["user_id"]),
      let isCheckedIn = int64(userInfo["is_sign_in"]),
      let consecutiveDays = int64(userInfo["cont_sign_num"]),
      let rank = int64(userInfo["user_sign_rank"]),
      consecutiveDays >= 0,
      rank >= 0,
      let consecutiveDays = Int(exactly: consecutiveDays),
      let rank = Int(exactly: rank)
    else {
      throw TiebaClientError.invalidJSON
    }
    guard userID == expectedUserID, isCheckedIn == 1 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return TiebaForumCheckIn(
      isCheckedIn: true,
      consecutiveDays: consecutiveDays,
      rank: rank
    )
  }

  static func agreementPage(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) throws -> TiebaAgreementPage {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    guard
      expectedUserID > 0,
      forumID > 0,
      threadID > 0,
      response.hasData,
      response.data.hasUser,
      response.data.hasThread,
      response.data.hasForum,
      response.data.hasPage,
      response.data.user.isLogin == 1,
      response.data.user.id == expectedUserID,
      response.data.thread.id == threadID,
      response.data.forum.id == forumID,
      response.data.thread.fid == 0 || response.data.thread.fid == forumID
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let data = response.data
    var agreements = [TiebaAgreementState]()
    var seenTargets = Set<TiebaAgreementTarget>()

    let resolvedFirstPost = try resolvedFirstPost(data, threadID: threadID)
    let firstPostID = resolvedFirstPost.id
    try appendAgreement(
      agree: data.thread.hasAgree ? data.thread.agree : nil,
      target: .thread(firstPostID: firstPostID),
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      agreements: &agreements,
      seenTargets: &seenTargets
    )
    if let firstPost = resolvedFirstPost.post {
      try appendInlineSubposts(
        from: firstPost,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        agreements: &agreements,
        seenTargets: &seenTargets
      )
    }

    for post in data.postList {
      guard
        post.id > 0,
        post.floor >= 1,
        post.tid == 0 || post.tid == threadID
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      guard post.floor != 1 else { continue }
      try appendAgreement(
        agree: post.hasAgree ? post.agree : nil,
        target: .post(postID: post.id),
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        agreements: &agreements,
        seenTargets: &seenTargets
      )

      try appendInlineSubposts(
        from: post,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        agreements: &agreements,
        seenTargets: &seenTargets
      )
    }

    return TiebaAgreementPage(
      userID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      agreements: agreements,
      pagination: try pagination(data.page)
    )
  }

  static func agreement(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaAgreementTarget
  ) throws -> TiebaAgreementState {
    let page = try agreementPage(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
    let matches = page.agreements.filter { $0.target == target }
    guard matches.count == 1, let agreement = matches.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return agreement
  }

  static func subpostAgreementPage(
    from response: PbFloorResIdl,
    validatedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    parentPostID: Int64,
    requiredSubpostID: Int64? = nil
  ) throws -> TiebaAgreementPage {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    guard
      validatedUserID > 0,
      forumID > 0,
      threadID > 0,
      parentPostID > 0,
      response.hasData,
      response.data.hasForum,
      response.data.hasThread,
      response.data.hasPost,
      response.data.hasPage,
      response.data.forum.id == forumID,
      response.data.thread.id == threadID,
      response.data.thread.fid == 0 || response.data.thread.fid == forumID,
      response.data.post.id == parentPostID,
      response.data.post.floor >= 1,
      response.data.post.tid == 0 || response.data.post.tid == threadID
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    var agreements = [TiebaAgreementState]()
    var seenTargets = Set<TiebaAgreementTarget>()
    if response.data.post.floor == 1 {
      guard response.data.thread.firstPostID == parentPostID else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      try appendAgreement(
        agree: response.data.thread.hasAgree ? response.data.thread.agree : nil,
        target: .thread(firstPostID: parentPostID),
        expectedUserID: validatedUserID,
        forumID: forumID,
        threadID: threadID,
        agreements: &agreements,
        seenTargets: &seenTargets
      )
    } else {
      try appendAgreement(
        agree: response.data.post.hasAgree ? response.data.post.agree : nil,
        target: .post(postID: parentPostID),
        expectedUserID: validatedUserID,
        forumID: forumID,
        threadID: threadID,
        agreements: &agreements,
        seenTargets: &seenTargets
      )
    }
    for subpost in response.data.subpostList {
      guard subpost.id > 0 else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      try appendAgreement(
        agree: subpost.hasAgree ? subpost.agree : nil,
        target: .subpost(parentPostID: parentPostID, subpostID: subpost.id),
        expectedUserID: validatedUserID,
        forumID: forumID,
        threadID: threadID,
        agreements: &agreements,
        seenTargets: &seenTargets
      )
    }
    if let requiredSubpostID {
      let target = TiebaAgreementTarget.subpost(
        parentPostID: parentPostID,
        subpostID: requiredSubpostID
      )
      guard agreements.lazy.filter({ $0.target == target }).count == 1 else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    }
    return TiebaAgreementPage(
      userID: validatedUserID,
      forumID: forumID,
      threadID: threadID,
      agreements: agreements,
      pagination: try pagination(response.data.page)
    )
  }

  static func threadAgreement(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    firstPostID: Int64
  ) throws -> TiebaThreadAgreement {
    let agreement = try agreement(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: .thread(firstPostID: firstPostID)
    )
    return TiebaThreadAgreement(
      userID: agreement.userID,
      forumID: agreement.forumID,
      threadID: agreement.threadID,
      firstPostID: firstPostID,
      isAgreed: agreement.isAgreed,
      agreeScore: agreement.agreeScore
    )
  }

  static func agreementWriteScore(from body: Data) throws -> Int? {
    let object = try responseObject(from: body)
    try checkServerError(object)
    guard
      let data = object["data"] as? [String: Any],
      let agree = data["agree"] as? [String: Any],
      agree["score"] != nil
    else { return nil }
    guard let score = int64(agree["score"]) else {
      throw TiebaClientError.invalidJSON
    }
    return Int(clamping: score)
  }

  static func threadAgreementWriteScore(from body: Data) throws -> Int? {
    try agreementWriteScore(from: body)
  }

  private static func responseObject(from body: Data) throws -> [String: Any] {
    do {
      guard
        let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      else {
        throw TiebaClientError.invalidJSON
      }
      return object
    } catch let error as TiebaClientError {
      throw error
    } catch {
      throw TiebaClientError.invalidJSON
    }
  }

  private static func forumCheckInMetadata(
    from response: FrsPageResIdl,
    expectedUserID: Int64
  ) throws -> TiebaForumCheckIn? {
    guard response.data.forum.hasSignInInfo else { return nil }
    let signInfo = response.data.forum.signInInfo
    guard signInfo.hasUserInfo else { return nil }

    let userInfo = signInfo.userInfo
    guard
      userInfo.userID == expectedUserID,
      userInfo.isSignIn == 0 || userInfo.isSignIn == 1,
      userInfo.contSignNum >= 0,
      userInfo.userSignRank >= 0
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return TiebaForumCheckIn(
      isCheckedIn: userInfo.isSignIn == 1,
      consecutiveDays: Int(userInfo.contSignNum),
      rank: Int(userInfo.userSignRank)
    )
  }

  private static func agreeScore(_ agree: Agree) -> Int {
    if agree.diffAgreeNum != 0 {
      return Int(clamping: agree.diffAgreeNum)
    }
    let (score, overflow) = agree.agreeNum.subtractingReportingOverflow(agree.disagreeNum)
    guard !overflow else { return agree.agreeNum >= 0 ? Int.max : Int.min }
    return Int(clamping: score)
  }

  private static func resolvedFirstPost(
    _ data: PbPageResIdl.DataRes,
    threadID: Int64
  ) throws -> (id: Int64, post: Post?) {
    let declared = data.thread.firstPostID
    guard declared >= 0 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    if data.hasFirstFloorPost {
      guard
        data.firstFloorPost.id > 0,
        data.firstFloorPost.floor == 1,
        data.firstFloorPost.tid == 0 || data.firstFloorPost.tid == threadID
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    }
    let firstFloorPosts = data.postList.filter { $0.floor == 1 }
    guard
      firstFloorPosts.count <= 1,
      firstFloorPosts.allSatisfy({ post in
        post.id > 0 && (post.tid == 0 || post.tid == threadID)
      })
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let candidates = (data.hasFirstFloorPost ? [data.firstFloorPost] : []) + firstFloorPosts
    let candidateIDs = Set(candidates.map(\.id))
    guard candidateIDs.count <= 1 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    if declared > 0 {
      guard candidateIDs.isEmpty || candidateIDs == Set([declared]) else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      return (
        declared,
        firstFloorPosts.first ?? (data.hasFirstFloorPost ? data.firstFloorPost : nil)
      )
    }
    guard let candidate = candidateIDs.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return (
      candidate,
      firstFloorPosts.first ?? (data.hasFirstFloorPost ? data.firstFloorPost : nil)
    )
  }

  private static func appendInlineSubposts(
    from post: Post,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    agreements: inout [TiebaAgreementState],
    seenTargets: inout Set<TiebaAgreementTarget>
  ) throws {
    guard post.hasSubPostList else { return }
    let container = post.subPostList
    guard container.pid == 0 || container.pid == UInt64(post.id) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    for subpost in container.subPostList {
      guard subpost.id > 0 else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      try appendAgreement(
        agree: subpost.hasAgree ? subpost.agree : nil,
        target: .subpost(parentPostID: post.id, subpostID: subpost.id),
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        agreements: &agreements,
        seenTargets: &seenTargets
      )
    }
  }

  private static func appendAgreement(
    agree: Agree?,
    target: TiebaAgreementTarget,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    agreements: inout [TiebaAgreementState],
    seenTargets: inout Set<TiebaAgreementTarget>
  ) throws {
    guard seenTargets.insert(target).inserted else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let rawAgreement = agree?.hasAgree_p ?? 0
    guard rawAgreement == 0 || rawAgreement == 1 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    agreements.append(
      TiebaAgreementState(
        userID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        target: target,
        isAgreed: rawAgreement == 1,
        agreeScore: agree.map { agreeScore($0) } ?? 0
      )
    )
  }

  private static func pagination(_ page: Page) throws -> TiebaPagination {
    guard
      page.pageSize >= 0,
      page.currentPage >= 0,
      page.totalPage >= 0,
      page.newTotalPage >= 0,
      page.totalCount >= 0,
      page.hasMore_p == 0 || page.hasMore_p == 1,
      page.hasPrev_p == 0 || page.hasPrev_p == 1
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let pageSize = Int(page.pageSize)
    let currentPage = page.currentPage == 0 ? 1 : Int(page.currentPage)
    let totalPages = Int(page.newTotalPage > 0 ? page.newTotalPage : page.totalPage)
    guard totalPages == 0 || currentPage <= totalPages else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return TiebaPagination(
      pageSize: pageSize,
      currentPage: currentPage,
      totalPages: totalPages,
      totalCount: Int(page.totalCount),
      hasMore: page.hasMore_p != 0 || (totalPages > 0 && currentPage < totalPages),
      hasPrevious: page.hasPrev_p != 0 || currentPage > 1
    )
  }

  private static func checkServerError(_ object: [String: Any]) throws {
    var codes = [(Int64, String)]()
    let nestedError = object["error"] as? [String: Any]

    for key in ["error_code", "errno", "no"] where object[key] != nil {
      guard let code = int64(object[key]) else {
        throw TiebaClientError.invalidJSON
      }
      codes.append((code, errorMessage(object, nestedError: nestedError)))
    }
    if let nestedError, nestedError["errno"] != nil {
      guard let code = int64(nestedError["errno"]) else {
        throw TiebaClientError.invalidJSON
      }
      codes.append((code, errorMessage(object, nestedError: nestedError)))
    }

    guard !codes.isEmpty else {
      throw TiebaClientError.invalidJSON
    }
    if let failure = codes.first(where: { $0.0 != 0 }) {
      throw TiebaClientError.server(
        code: Int32(clamping: failure.0),
        message: failure.1
      )
    }
  }

  private static func errorMessage(
    _ object: [String: Any],
    nestedError: [String: Any]?
  ) -> String {
    string(object["error_msg"])
      ?? string(object["errmsg"])
      ?? string(nestedError?["usermsg"])
      ?? string(nestedError?["errmsg"])
      ?? ""
  }

  private static func canonicalForumName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }

  private static func followedForum(_ object: [String: Any]) -> TiebaFollowedForum? {
    guard
      let id = int64(object["id"]), id > 0,
      let name = string(object["name"]), !name.isEmpty
    else { return nil }
    return TiebaFollowedForum(
      id: id,
      name: name,
      level: Int(clamping: int64(object["level_id"]) ?? 0),
      experience: Int(clamping: int64(object["cur_score"]) ?? 0)
    )
  }

  private static func string(_ value: Any?) -> String? {
    switch value {
    case let value as String:
      value
    case let value as NSNumber:
      value.stringValue
    default:
      nil
    }
  }

  private static func int64(_ value: Any?) -> Int64? {
    switch value {
    case let value as NSNumber:
      guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
      return Int64(value.stringValue)
    case let value as Int64:
      return value
    case let value as Int:
      return Int64(value)
    case let value as String:
      return Int64(value)
    default:
      return nil
    }
  }

  private static func bool(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
      value
    case let value as NSNumber:
      value.intValue != 0
    case let value as String:
      switch value.lowercased() {
      case "1", "true": true
      case "0", "false", "": false
      default: nil
      }
    default:
      nil
    }
  }
}
