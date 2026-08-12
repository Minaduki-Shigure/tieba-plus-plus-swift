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

struct TiebaThreadCloudFavoriteContext:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let state: TiebaThreadCloudFavoriteState
  let tbs: String

  var description: String { "TiebaThreadCloudFavoriteContext(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["state": state], displayStyle: .struct)
  }
}

struct TiebaUserRelationshipContext:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let relationship: TiebaUserRelationship
  let portrait: String
  let tbs: String

  var description: String { "TiebaUserRelationshipContext(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["relationship": relationship], displayStyle: .struct)
  }
}

enum TiebaAuthenticatedDecoder {
  static let selfProfileNameMaximumBytes = 1_024
  static let selfProfilePortraitMaximumBytes = 4_096
  static let selfProfileBiographyMaximumBytes = 16 * 1_024
  static let followedForumNameMaximumBytes = 1_024
  static let followedForumAvatarMaximumBytes = 4_096
  static let followedForumSloganMaximumBytes = 4_096

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

  static func selfProfile(
    from response: ProfileResIdl,
    expectedUserID: Int64
  ) throws -> TiebaSelfProfileSummary {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    guard
      expectedUserID > 0,
      response.hasData,
      response.data.hasUser,
      response.data.user.id == expectedUserID
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let user = response.data.user
    let username = try boundedSelfProfileSingleLineText(
      user.name,
      maximumBytes: selfProfileNameMaximumBytes
    )
    let displayName = try boundedSelfProfileSingleLineText(
      user.nameShow,
      maximumBytes: selfProfileNameMaximumBytes
    )
    guard !username.isEmpty || !displayName.isEmpty else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let portrait = try normalizedSelfProfilePortrait(user.portrait)
    let biographySource = user.displayIntro.trimmingCharacters(in: .whitespacesAndNewlines)
      .isEmpty ? user.intro : user.displayIntro
    let biography = try boundedSelfProfileMultilineText(
      biographySource,
      maximumBytes: selfProfileBiographyMaximumBytes
    )
    let counts = [user.concernNum, user.fansNum, user.postNum]
    guard counts.allSatisfy({ $0 >= 0 }) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    return TiebaSelfProfileSummary(
      userID: expectedUserID,
      username: username,
      displayName: displayName,
      portrait: portrait,
      biography: biography,
      followingCount: Int(user.concernNum),
      followerCount: Int(user.fansNum),
      postCount: Int(user.postNum)
    )
  }

  static func userRelationship(
    from response: ProfileResIdl,
    expectedUserID: Int64,
    targetUserID: Int64
  ) throws -> TiebaUserRelationshipContext {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    guard
      expectedUserID > 0,
      targetUserID > 0,
      expectedUserID != targetUserID,
      response.hasData,
      response.data.hasUser,
      response.data.user.id == targetUserID,
      response.data.hasAntiStat,
      TiebaAuthenticatedRequestFactory.isValidTBS(response.data.antiStat.tbs)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let rawFollowed = response.data.user.hasConcerned_p
    guard (0...2).contains(rawFollowed) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let portrait = try normalizedSelfProfilePortrait(response.data.user.portrait)
    guard !portrait.isEmpty else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return TiebaUserRelationshipContext(
      relationship: TiebaUserRelationship(
        userID: expectedUserID,
        targetUserID: targetUserID,
        isFollowed: rawFollowed != 0
      ),
      portrait: portrait,
      tbs: response.data.antiStat.tbs
    )
  }

  private static func boundedSelfProfileSingleLineText(
    _ rawValue: String,
    maximumBytes: Int
  ) throws -> String {
    guard
      rawValue.utf8.count <= maximumBytes,
      !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func boundedSelfProfileMultilineText(
    _ rawValue: String,
    maximumBytes: Int
  ) throws -> String {
    guard rawValue.utf8.count <= maximumBytes else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let allowedControls = CharacterSet(charactersIn: "\n\r")
    guard !rawValue.unicodeScalars.contains(where: { scalar in
      CharacterSet.controlCharacters.contains(scalar) && !allowedControls.contains(scalar)
    }) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return rawValue
      .replacingOccurrences(of: "\r\n", with: "\n")
      .replacingOccurrences(of: "\r", with: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func normalizedSelfProfilePortrait(_ rawValue: String) throws -> String {
    let source = try boundedSelfProfileSingleLineText(
      rawValue,
      maximumBytes: selfProfilePortraitMaximumBytes
    )
    guard !source.isEmpty else { return "" }
    guard !source.contains("#") else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let parts = source.split(
      separator: "?",
      maxSplits: 1,
      omittingEmptySubsequences: false
    )
    guard let token = parts.first, !token.isEmpty else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    if parts.count == 2 {
      let query = parts[1]
      guard query.hasPrefix("t=") else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      let digits = query.utf8.dropFirst(2)
      guard (1...20).contains(digits.count), digits.allSatisfy({ (48...57).contains($0) })
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    }
    return String(token)
  }

  static func webAccountID(from body: Data) throws -> Int64 {
    let object = try responseObject(from: body)
    guard object["no"] != nil, let result = int64(object["no"]) else {
      throw TiebaClientError.invalidJSON
    }
    try checkServerError(object)
    guard
      result == 0,
      let data = object["data"] as? [String: Any],
      let userID = int64(data["id"]),
      userID > 0
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return userID
  }

  static func followedForums(
    from body: Data,
    page: Int,
    pageSize: Int,
    accountUserID: Int64,
    targetUserID: Int64
  ) throws -> TiebaFollowedForumPage {
    guard
      accountUserID > 0,
      targetUserID > 0,
      (1...Int(Int32.max)).contains(page),
      (1...100).contains(pageSize)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let object = try responseObject(from: body)
    try checkServerError(object)

    var rawForums = [[String: Any]]()
    if let rawGroups = object["forum_list"] {
      guard let groups = rawGroups as? [String: Any] else {
        throw TiebaClientError.invalidJSON
      }
      for key in ["non-gconforum", "gconforum"] {
        guard let rawEntries = groups[key] else { continue }
        guard let entries = rawEntries as? [[String: Any]] else {
          throw TiebaClientError.invalidJSON
        }
        rawForums.append(contentsOf: entries)
      }
    }
    // The endpoint may return one page from each of its two known forum groups.
    let maximumRawForumCount = min(pageSize * 2, 100)
    guard rawForums.count <= maximumRawForumCount else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    var forums = try rawForums.map(followedForum)
    var seen = Set<Int64>()
    forums = forums.filter { seen.insert($0.id).inserted }
    let hasMore: Bool
    if let rawHasMore = object["has_more"] {
      guard let parsedHasMore = binaryBool(rawHasMore) else {
        throw TiebaClientError.invalidJSON
      }
      hasMore = parsedHasMore
    } else {
      // The endpoint schema defaults an omitted pagination flag to its final-page value.
      hasMore = false
    }
    return TiebaFollowedForumPage(
      accountUserID: accountUserID,
      targetUserID: targetUserID,
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

  static func cloudFavorites(
    from body: Data,
    expectedUserID: Int64,
    offset: Int,
    pageSize: Int
  ) throws -> TiebaCloudFavoritePage {
    let object = try responseObject(from: body)
    try checkServerError(object)
    guard
      expectedUserID > 0,
      offset >= 0,
      pageSize > 0
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    guard let rawFavorites = object["store_thread"] as? [Any] else {
      throw TiebaClientError.invalidJSON
    }
    guard rawFavorites.count <= pageSize, offset <= Int.max - pageSize else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let favorites = try rawFavorites.map { rawFavorite -> TiebaCloudFavorite in
      guard let rawFavorite = rawFavorite as? [String: Any] else {
        throw TiebaClientError.invalidJSON
      }
      return try cloudFavorite(rawFavorite)
    }
    return TiebaCloudFavoritePage(
      requestedUserID: expectedUserID,
      favorites: favorites,
      offset: offset,
      pageSize: pageSize,
      hasMore: !favorites.isEmpty
    )
  }

  static func threadCloudFavoriteContext(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) throws -> TiebaThreadCloudFavoriteContext {
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
      response.data.hasForum,
      response.data.hasThread,
      response.data.hasAnti,
      response.data.user.isLogin == 1,
      response.data.user.id == expectedUserID,
      response.data.forum.id == forumID,
      response.data.thread.id == threadID,
      response.data.thread.fid == 0 || response.data.thread.fid == forumID,
      TiebaAuthenticatedRequestFactory.isValidTBS(response.data.anti.tbs)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let status = response.data.thread.collectStatus
    let rawMarkedPostID = response.data.thread.collectMarkPid
    let markedPostID: Int64?
    switch status {
    case 0:
      guard
        rawMarkedPostID.isEmpty
          || (decimalInt64(rawMarkedPostID) == 0)
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      markedPostID = nil
    case 1:
      guard let value = decimalInt64(rawMarkedPostID), value > 0 else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      markedPostID = value
    default:
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    return TiebaThreadCloudFavoriteContext(
      state: TiebaThreadCloudFavoriteState(
        userID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        markedPostID: markedPostID
      ),
      tbs: response.data.anti.tbs
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

  static func checkUserFollowWriteResponse(_ body: Data) throws {
    let object = try responseObject(from: body)
    try checkServerError(object)
  }

  static func userInteractionPermissions(
    from body: Data,
    expectedUserID: Int64,
    targetUserID: Int64
  ) throws -> TiebaUserInteractionPermissionState {
    guard expectedUserID > 0, targetUserID > 0, expectedUserID != targetUserID else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let object = try responseObject(from: body)
    let code = try requiredExactJSONInteger(object["error_code"])
    if code != 0 {
      throw TiebaClientError.server(
        code: Int32(clamping: code),
        message: errorMessage(object, nestedError: object["error"] as? [String: Any])
      )
    }
    guard let permissionList = object["perm_list"] as? [String: Any] else {
      throw TiebaClientError.invalidJSON
    }
    let follow = try requiredExactJSONBit(permissionList["follow"])
    let interaction = try requiredExactJSONBit(permissionList["interact"])
    let chat = try requiredExactJSONBit(permissionList["chat"])
    return TiebaUserInteractionPermissionState(
      userID: expectedUserID,
      targetUserID: targetUserID,
      permissions: TiebaUserInteractionPermissions(
        blocksFollow: follow,
        blocksInteraction: interaction,
        blocksChat: chat
      )
    )
  }

  static func checkUserInteractionPermissionsWriteResponse(_ body: Data) throws {
    let object = try responseObject(from: body)
    let code = try requiredExactJSONInteger(object["error_code"])
    guard code == 0 else {
      throw TiebaClientError.server(
        code: Int32(clamping: code),
        message: errorMessage(object, nestedError: object["error"] as? [String: Any])
      )
    }
  }

  static func checkThreadCloudFavoriteWriteResponse(_ body: Data) throws {
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
      ?? string(object["error"])
      ?? string(nestedError?["usermsg"])
      ?? string(nestedError?["errmsg"])
      ?? ""
  }

  private static func canonicalForumName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }

  private static func decimalInt64(_ value: String) -> Int64? {
    guard
      !value.isEmpty,
      value.utf8.allSatisfy({ (0x30...0x39).contains($0) })
    else { return nil }
    return Int64(value)
  }

  private static func followedForum(_ object: [String: Any]) throws -> TiebaFollowedForum {
    guard
      let id = int64(object["id"]), id > 0,
      let rawName = object["name"] as? String
    else { throw TiebaClientError.invalidJSON }
    let name = normalizedForumMetadata(
      rawName,
      maximumBytes: followedForumNameMaximumBytes
    )
    guard !name.isEmpty else { throw TiebaClientError.invalidJSON }
    return TiebaFollowedForum(
      id: id,
      name: name,
      level: max(Int(clamping: int64(object["level_id"]) ?? 0), 0),
      experience: max(Int(clamping: int64(object["cur_score"]) ?? 0), 0),
      avatar: normalizedForumMetadata(
        object["avatar"] as? String,
        maximumBytes: followedForumAvatarMaximumBytes
      ),
      slogan: normalizedForumMetadata(
        object["slogan"] as? String,
        maximumBytes: followedForumSloganMaximumBytes
      )
    )
  }

  private static func normalizedForumMetadata(
    _ value: String?,
    maximumBytes: Int
  ) -> String {
    guard let value else { return "" }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      normalized.utf8.count <= maximumBytes
    else { return "" }
    return normalized
  }

  private static func cloudFavorite(_ object: [String: Any]) throws -> TiebaCloudFavorite {
    guard
      let threadID = int64(object["thread_id"]), threadID > 0,
      let title = string(object["title"]),
      let forumName = string(object["forum_name"]),
      let authorObject = object["author"] as? [String: Any],
      let isDeleted = int64(object["is_deleted"]), isDeleted == 0 || isDeleted == 1,
      let lastTimestamp = int64(object["last_time"]), lastTimestamp >= 0,
      let threadTypeValue = int64(object["type"]), threadTypeValue >= 0,
      let statusValue = int64(object["status"]), statusValue >= 0,
      let maximumPostID = int64(object["max_pid"]), maximumPostID >= 0,
      let minimumPostID = int64(object["min_pid"]), minimumPostID >= 0,
      let markedPostID = int64(object["mark_pid"]), markedPostID >= 0,
      let markStatusValue = int64(object["mark_status"]), markStatusValue >= 0,
      let postNumberValue = int64(object["post_no"]), postNumberValue >= 0,
      let postNumberMessage = string(object["post_no_msg"]),
      let updateCountValue = int64(object["count"]), updateCountValue >= 0,
      let threadType = Int(exactly: threadTypeValue),
      let status = Int(exactly: statusValue),
      let markStatus = Int(exactly: markStatusValue),
      let postNumber = Int(exactly: postNumberValue),
      let updateCount = Int(exactly: updateCountValue)
    else {
      throw TiebaClientError.invalidJSON
    }

    let authorID: Int64?
    if authorObject["lz_uid"] == nil || authorObject["lz_uid"] is NSNull {
      authorID = nil
    } else if let value = string(authorObject["lz_uid"]), value.isEmpty {
      authorID = nil
    } else if let value = int64(authorObject["lz_uid"]), value >= 0 {
      authorID = value == 0 ? nil : value
    } else {
      throw TiebaClientError.invalidJSON
    }

    return TiebaCloudFavorite(
      id: threadID,
      title: title,
      forumName: forumName,
      author: TiebaCloudFavoriteAuthor(
        userID: authorID,
        username: string(authorObject["name"]) ?? "",
        displayName: string(authorObject["name_show"]) ?? "",
        portrait: string(authorObject["user_portrait"]) ?? ""
      ),
      isDeleted: isDeleted == 1,
      lastTimestamp: lastTimestamp,
      threadType: threadType,
      status: status,
      maximumPostID: maximumPostID,
      minimumPostID: minimumPostID,
      markedPostID: markedPostID,
      markStatus: markStatus,
      postNumber: postNumber,
      postNumberMessage: postNumberMessage,
      updateCount: updateCount
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

  private static func requiredExactJSONInteger(_ value: Any?) throws -> Int64 {
    guard
      let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      !["f", "d"].contains(String(cString: number.objCType)),
      let integer = Int64(number.stringValue)
    else {
      throw TiebaClientError.invalidJSON
    }
    return integer
  }

  private static func requiredExactJSONBit(_ value: Any?) throws -> Bool {
    switch try requiredExactJSONInteger(value) {
    case 0: return false
    case 1: return true
    default: throw TiebaClientError.invalidJSON
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

  private static func binaryBool(_ value: Any?) -> Bool? {
    switch value {
    case let value as Bool:
      return value
    case let value as NSNumber:
      if CFGetTypeID(value) == CFBooleanGetTypeID() {
        return value.boolValue
      }
      guard let integer = Int64(value.stringValue) else { return nil }
      switch integer {
      case 0: return false
      case 1: return true
      default: return nil
      }
    case let value as String:
      switch value.lowercased() {
      case "0", "false": return false
      case "1", "true": return true
      default: return nil
      }
    default:
      return nil
    }
  }
}
