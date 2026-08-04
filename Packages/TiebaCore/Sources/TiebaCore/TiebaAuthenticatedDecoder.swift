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

  static func threadAgreement(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    firstPostID: Int64
  ) throws -> TiebaThreadAgreement {
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
      firstPostID > 0,
      response.hasData,
      response.data.hasThread,
      response.data.hasForum,
      response.data.thread.id == threadID,
      response.data.forum.id == forumID,
      response.data.thread.hasAgree
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let data = response.data
    let declaredFirstPostID = data.thread.firstPostID
    guard declaredFirstPostID == 0 || declaredFirstPostID == firstPostID else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    if declaredFirstPostID == 0 {
      let matchesExpectedFirstPost: (Post) -> Bool = { post in
        post.id == firstPostID
          && post.floor == 1
          && (post.tid == 0 || post.tid == threadID)
      }
      guard
        matchesExpectedFirstPost(data.firstFloorPost)
          || data.postList.contains(where: matchesExpectedFirstPost)
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    }

    let rawAgreement = data.thread.agree.hasAgree
    guard rawAgreement == 0 || rawAgreement == 1 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return TiebaThreadAgreement(
      userID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      firstPostID: firstPostID,
      isAgreed: rawAgreement == 1,
      agreeScore: agreeScore(data.thread.agree)
    )
  }

  static func threadAgreementWriteScore(from body: Data) throws -> Int? {
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
