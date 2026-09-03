import Foundation
import SwiftProtobuf
import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct TiebaAuthenticatedRequestFactory: Sendable {
  static let appSalt = TiebaFormSigner.appSalt
  static let followClientVersion = "7.2.0.0"
  static let unfollowClientVersion = "11.10.8.6"
  static let checkInClientVersion = "11.10.8.6"
  static let agreementClientVersion = "22.6.5.1"
  static let notificationClientVersion = "22.6.5.1"
  static let inboxUnreadSummaryClientVersion = "8.2.2"
  static let sessionClientVersion = "11.10.8.6"
  static let cloudFavoritesClientVersion = "11.10.8.6"
  static let threadCloudFavoriteClientVersion = "12.41.7.1"
  static let textReplyClientVersion = "12.35.1.0"
  static let pollReadClientVersion = "12.52.1.0"
  static let pollWriteClientVersion = "11.10.8.6"
  static let newThreadClientVersion = "7.2.0.0"
  static let staticImageUploadClientVersion = "12.41.7.1"
  static let concernClientVersion = "11.10.8.6"
  static let selfProfileClientVersion = "12.52.1.0"
  static let selfProfileEditClientVersion = "12.41.7.1"
  static let selfProfileAvatarUploadClientVersion = "12.52.1.0"
  static let ownFollowingClientVersion = "12.41.7.1"
  static let userFollowClientVersion = "11.10.8.6"
  static let userInteractionPermissionsClientVersion = "12.41.7.1"
  static let personalizedFeedbackClientVersion = "12.41.7.1"
  static let ownedContentDeletionClientVersion = "12.41.7.1"
  static let personalizedReadClientVersion = TiebaRequestFactory.personalizedClientVersion
  static let officialCheckInClientVersion = "11.10.8.6"
  static let officialCheckInGuideClientVersion = "12.41.7.1"
  static let selfProfileUserAgent =
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) "
    + "Version/4.0 Chrome/135.0.0.0 Mobile Safari/537.36 tieba/12.52.1.0"
  static let selfProfileEditUserAgent = "bdtb for Android 12.41.7.1"
  static let selfProfileAvatarUploadUserAgent = "bdtb for Android 12.52.1.0"
  static let pollReadUserAgent =
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) "
    + "Version/4.0 Chrome/135.0.0.0 Mobile Safari/537.36 tieba/12.52.1.0"
  static let pollWriteUserAgent =
    "Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) "
    + "Version/4.0 Chrome/135.0.0.0 Mobile Safari/537.36 tieba/12.35.1.0"
  static let userInteractionPermissionsUserAgent = "bdtb for Android 12.41.7.1"
  static let maximumConcernPageTagBytes = 4_096
  static let writeHost = TiebaRequestFactory.serviceHost
  static let webIdentityHost = "tieba.baidu.com"

  let configuration: TiebaClientConfiguration
  private let agreementCUID: String

  init(
    configuration: TiebaClientConfiguration,
    agreementCUID: String = TiebaGalaxy2CUID.generate()
  ) {
    self.configuration = configuration
    self.agreementCUID = agreementCUID
  }

  func validateAccount(credential: TiebaBDUSSCredential) throws -> URLRequest {
    try validate(credential)
    return try signedFormRequest(
      path: "/c/s/login",
      fields: [
        ("_client_version", configuration.authenticatedClientVersion),
        ("bdusstoken", credential.bduss),
      ]
    )
  }

  func validateSessionApp(credential: TiebaSessionCredential) throws -> URLRequest {
    try validate(credential)
    return try signedFormRequest(
      path: "/c/s/login",
      fields: [
        ("_client_version", Self.sessionClientVersion),
        ("authsid", "null"),
        ("bdusstoken", "\(credential.bduss)|"),
        ("channel_id", ""),
        ("channel_uid", ""),
        ("stoken", credential.stoken),
      ],
      userAgent: "bdtb for Android \(Self.sessionClientVersion)",
      cookie: "ka=open"
    )
  }

  func validateSessionWeb(credential: TiebaSessionCredential) throws -> URLRequest {
    try validate(credential)
    try validateConfiguration()

    var components = URLComponents()
    components.scheme = "https"
    components.host = Self.webIdentityHost
    components.path = "/mo/q/newmoindex"
    components.queryItems = [URLQueryItem(name: "need_user", value: "1")]
    guard
      let url = components.url,
      url.scheme?.lowercased() == "https",
      url.host?.lowercased() == Self.webIdentityHost,
      url.port == nil,
      url.user == nil,
      url.password == nil
    else {
      throw TiebaClientError.invalidEndpoint
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue(
      "\(credential.bdussCookieName.rawValue)=\(credential.bduss); STOKEN=\(credential.stoken)",
      forHTTPHeaderField: "Cookie"
    )
    return request
  }

  func officialCheckInEligibility(
    credential: TiebaSessionCredential,
    expectedUserID: Int64
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    return try signedFormRequest(
      path: "/c/f/forum/getforumlist",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", Self.officialCheckInClientVersion),
        ("stoken", credential.stoken),
        ("user_id", String(expectedUserID)),
      ],
      userAgent: "bdtb for Android \(Self.officialCheckInClientVersion)",
      cookie: "ka=open"
    )
  }

  func officialCheckInGuide(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    tbs: String,
    page: Int,
    pageSize: Int
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard (1...TiebaOfficialCheckInDecoder.maximumGuidePageCount).contains(page) else {
      throw TiebaClientError.invalidArgument("Check-in catalog page is out of range.")
    }
    guard (1...100).contains(pageSize) else {
      throw TiebaClientError.invalidArgument("Check-in catalog page size must be between 1 and 100.")
    }
    return try signedFormRequest(
      path: "/c/f/forum/forumGuide",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", Self.officialCheckInGuideClientVersion),
        ("call_from", "3"),
        ("page_no", String(page)),
        ("res_num", String(pageSize)),
        ("sort_type", "3"),
        ("stoken", credential.stoken),
        ("tbs", tbs),
        ("top_forum_num", "0"),
      ],
      userAgent: "bdtb for Android \(Self.officialCheckInGuideClientVersion)",
      cookie: "ka=open"
    )
  }

  func officialBatchCheckIn(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    tbs: String,
    forumIDs: [Int64]
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard
      !forumIDs.isEmpty,
      forumIDs.count <= TiebaOfficialCheckInDecoder.maximumBatchCount,
      forumIDs.allSatisfy({ $0 > 0 }),
      Set(forumIDs).count == forumIDs.count
    else {
      throw TiebaClientError.invalidArgument("Batch check-in forum IDs are invalid.")
    }
    let encodedForumIDs = forumIDs.map(String.init).joined(separator: ",")
    return try signedFormRequest(
      host: Self.writeHost,
      path: "/c/c/forum/msign",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", Self.officialCheckInClientVersion),
        ("authsid", "null"),
        ("forum_ids", encodedForumIDs),
        ("stoken", credential.stoken),
        ("tbs", tbs),
        ("user_id", String(expectedUserID)),
      ],
      userAgent: "bdtb for Android \(Self.officialCheckInClientVersion)",
      cookie: "ka=open"
    )
  }

  func selfProfile(
    credential: TiebaSessionCredential,
    expectedUserID: Int64
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    try validateConfiguration()

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = Self.selfProfileClientVersion
    common.bduss = credential.bduss
    common.stoken = credential.stoken

    var data = ProfileReqIdl.DataReq()
    data.uid = expectedUserID
    data.needPostCount = 1
    data.isGuest = 0
    data.pn = 1
    data.rn = 20
    data.hasPlist_p = 1
    data.common = common
    data.isFromUsercenter = 1
    data.page = 1

    var message = ProfileReqIdl()
    message.data = data
    return try authenticatedProtobufReadRequest(
      path: "/c/u/user/profile",
      command: 303_012,
      message: message,
      fields: [("stoken", credential.stoken)],
      userAgent: Self.selfProfileUserAgent,
      clientUserToken: String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func editSelfProfile(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    edit: TiebaSelfProfileEdit,
    birthday: TiebaSelfProfileBirthday
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard let edit = TiebaSelfProfileEditPolicy.normalized(edit) else {
      throw TiebaClientError.invalidArgument("The profile edit contains invalid text.")
    }
    guard
      birthday.timeMilliseconds >= 0,
      birthday.timeMilliseconds.isMultiple(of: 1_000)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    return try signedFormRequest(
      path: "/c/c/profile/modify",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_type", "2"),
        ("_client_version", Self.selfProfileEditClientVersion),
        ("birthday_show_status", birthday.showsConstellationOnly ? "1" : "0"),
        ("birthday_time", String(birthday.timeMilliseconds / 1_000)),
        ("intro", edit.biography),
        ("sex", String(edit.sex.rawValue)),
        ("nick_name", edit.displayName),
        ("stoken", credential.stoken),
        ("cam", ""),
        ("need_cam_decrypt", "1"),
        ("need_keep_nickname_flag", "0"),
      ],
      userAgent: Self.selfProfileEditUserAgent,
      cookie: "ka=open"
    )
  }

  func validatedSelfProfileAvatarUpload(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    upload: TiebaSelfProfileAvatarUpload
  ) throws -> TiebaSelfProfileAvatarUploadPlan {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard TiebaSelfProfileAvatarUploadPolicy.isValid(upload) else {
      throw TiebaClientError.invalidArgument(
        "The avatar must be a valid JPEG within the size and dimension limits."
      )
    }
    return TiebaSelfProfileAvatarUploadPlan(
      upload: upload,
      contentSHA256: TiebaSelfProfileAvatarUploadPolicy.contentSHA256(of: upload)
    )
  }

  func uploadSelfProfileAvatar(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    upload: TiebaSelfProfileAvatarUpload
  ) throws -> URLRequest {
    try uploadSelfProfileAvatar(
      credential: credential,
      expectedUserID: expectedUserID,
      plan: validatedSelfProfileAvatarUpload(
        credential: credential,
        expectedUserID: expectedUserID,
        upload: upload
      )
    )
  }

  func uploadSelfProfileAvatar(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    plan: TiebaSelfProfileAvatarUploadPlan
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard
      TiebaSelfProfileAvatarUploadPolicy.isValid(plan.upload),
      plan.contentSHA256
        == TiebaSelfProfileAvatarUploadPolicy.contentSHA256(of: plan.upload)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    try validateConfiguration()

    let fields = [
      ("BDUSS", credential.bduss),
      ("_client_type", "2"),
      ("_client_version", Self.selfProfileAvatarUploadClientVersion),
    ]
    let signedFields =
      fields.sorted {
        $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
      } + [("sign", Self.signature(for: fields))]
    let boundary = Self.selfProfileAvatarMultipartBoundary(
      fields: signedFields,
      jpegData: plan.upload.jpegData
    )

    var components = URLComponents()
    components.scheme = "https"
    components.host = TiebaSelfProfileAvatarUploadEndpointPolicy.host
    components.path = TiebaSelfProfileAvatarUploadEndpointPolicy.path
    guard let url = components.url, TiebaSelfProfileAvatarUploadEndpointPolicy.allows(url) else {
      throw TiebaClientError.invalidEndpoint
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.httpBody = Self.selfProfileAvatarMultipartBody(
      fields: signedFields,
      jpegData: plan.upload.jpegData,
      boundary: boundary
    )
    request.setValue(Self.selfProfileAvatarUploadUserAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("ka=open", forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    return request
  }

  func ownFollowing(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    page: Int
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    try validatePage(page, name: "Page")
    return try signedFormRequest(
      path: "/c/u/follow/followList",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_type", "2"),
        ("_client_version", Self.ownFollowingClientVersion),
        ("pn", String(page)),
      ],
      userAgent: "bdtb for Android \(Self.ownFollowingClientVersion)"
    )
  }

  func userRelationship(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64
  ) throws -> URLRequest {
    try validate(credential)
    try validateDistinctUserIDs(expectedUserID: expectedUserID, targetUserID: targetUserID)
    try validateConfiguration()

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = Self.selfProfileClientVersion
    common.bduss = credential.bduss
    common.stoken = credential.stoken

    var data = ProfileReqIdl.DataReq()
    data.uid = expectedUserID
    data.needPostCount = 1
    data.friendUid = targetUserID
    data.isGuest = 1
    data.pn = 1
    data.rn = 20
    data.hasPlist_p = 1
    data.common = common
    data.isFromUsercenter = 1
    data.page = 1

    var message = ProfileReqIdl()
    message.data = data
    return try authenticatedProtobufReadRequest(
      path: "/c/u/user/profile",
      command: 303_012,
      message: message,
      fields: [("stoken", credential.stoken)],
      userAgent: Self.selfProfileUserAgent,
      clientUserToken: String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func userInteractionPermissions(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64
  ) throws -> URLRequest {
    try validate(credential)
    try validateDistinctUserIDs(expectedUserID: expectedUserID, targetUserID: targetUserID)
    return try signedFormRequest(
      path: "/c/u/user/getUserBlackInfo",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_type", "2"),
        ("_client_version", Self.userInteractionPermissionsClientVersion),
        ("black_uid", String(targetUserID)),
        ("stoken", credential.stoken),
      ],
      userAgent: Self.userInteractionPermissionsUserAgent,
      cookie: "ka=open"
    )
  }

  func personalizedThreads(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    page: Int
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard page > 0, page <= Int(Int32.max) else {
      throw TiebaClientError.invalidArgument("Page must be between 1 and Int32.max.")
    }
    try validateConfiguration()
    let personalizedCUID = try validatedPersonalizedCUID()

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = Self.personalizedReadClientVersion
    common.bduss = credential.bduss
    common.stoken = credential.stoken
    common.cuid = personalizedCUID
    common.netType = 1
    common.personalizedRecSwitch = 1

    var data = PersonalizedReqIdl.DataReq()
    data.common = common
    data.loadType = page == 1 ? 1 : 2
    data.pageThreadCount = UInt32(TiebaRequestFactory.personalizedPageSize)
    data.pn = UInt32(page)
    data.qType = 1
    data.newNetType = 1

    var message = PersonalizedReqIdl()
    message.data = data
    return try authenticatedProtobufReadRequest(
      path: "/c/f/excellent/personalized",
      command: 309_264,
      message: message,
      fields: [("stoken", credential.stoken)],
      userAgent: Self.selfProfileUserAgent,
      clientUserToken: String(expectedUserID),
      cookie: "ka=open",
      includesFormatQuery: false
    )
  }

  func personalizedFeedback(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaPersonalizedFeedbackSubmission
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard submission.threadID > 0, submission.forumID > 0 else {
      throw TiebaClientError.invalidArgument("Feedback thread and forum IDs must be positive.")
    }
    guard
      !submission.reasonIDs.isEmpty,
      submission.reasonIDs.count <= 16,
      submission.reasonIDs.allSatisfy({ $0 > 0 }),
      Set(submission.reasonIDs).count == submission.reasonIDs.count,
      submission.reasonExtras.count == submission.reasonIDs.count
    else {
      throw TiebaClientError.invalidArgument("Feedback reasons are invalid.")
    }
    guard
      submission.clickTimeMilliseconds > 0,
      submission.reasonExtras.allSatisfy({ $0.utf8.count <= 4_096 }),
      submission.reasonExtras.reduce(0, { $0 + $1.utf8.count }) <= 16_384
    else {
      throw TiebaClientError.invalidArgument("Feedback metadata is invalid.")
    }
    let personalizedCUID = try validatedPersonalizedCUID()

    let object: [[String: Any]] = [
      [
        "click_time": submission.clickTimeMilliseconds,
        "dislike_ids": submission.reasonIDs.map(String.init).joined(separator: ","),
        "extra": submission.reasonExtras.joined(separator: ","),
        "fid": String(submission.forumID),
        "tid": String(submission.threadID),
      ]
    ]
    let jsonData: Data
    do {
      jsonData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    } catch {
      throw TiebaClientError.invalidArgument("Unable to encode recommendation feedback.")
    }
    guard
      jsonData.count <= 24_576,
      let dislike = String(data: jsonData, encoding: .utf8)
    else {
      throw TiebaClientError.invalidArgument("Recommendation feedback is too large.")
    }

    return try signedFormRequest(
      host: Self.writeHost,
      path: "/c/c/excellent/submitDislike",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_type", "2"),
        ("_client_version", Self.personalizedFeedbackClientVersion),
        ("cuid", personalizedCUID),
        ("dislike", dislike),
        ("dislike_from", "homepage"),
        ("stoken", credential.stoken),
      ],
      userAgent: "bdtb for Android \(Self.personalizedFeedbackClientVersion)",
      cookie: "ka=open"
    )
  }

  func setUserInteractionPermissions(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64,
    tbs: String,
    permissions: TiebaUserInteractionPermissions
  ) throws -> URLRequest {
    try validate(credential)
    try validateDistinctUserIDs(expectedUserID: expectedUserID, targetUserID: targetUserID)
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let permissionList = try encodedUserInteractionPermissions(permissions)
    return try signedFormRequest(
      path: "/c/c/user/setUserBlack",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_type", "2"),
        ("_client_version", Self.userInteractionPermissionsClientVersion),
        ("black_uid", String(targetUserID)),
        ("perm_list", permissionList),
        ("stoken", credential.stoken),
        ("tbs", tbs),
      ],
      userAgent: Self.userInteractionPermissionsUserAgent,
      cookie: "ka=open"
    )
  }

  private func encodedUserInteractionPermissions(
    _ permissions: TiebaUserInteractionPermissions
  ) throws -> String {
    let object: [String: Int] = [
      "follow": permissions.blocksFollow ? 1 : 0,
      "interact": permissions.blocksInteraction ? 1 : 0,
      "chat": permissions.blocksChat ? 1 : 0,
    ]
    do {
      let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      guard let value = String(data: data, encoding: .utf8) else {
        throw TiebaClientError.invalidArgument("Unable to encode interaction permissions.")
      }
      return value
    } catch let error as TiebaClientError {
      throw error
    } catch {
      throw TiebaClientError.invalidArgument("Unable to encode interaction permissions.")
    }
  }

  func pollState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) throws -> URLRequest {
    try validatePollContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
    try validateConfiguration()

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = Self.pollReadClientVersion
    common.bduss = credential.bduss
    common.stoken = credential.stoken
    common.userAgent = Self.pollReadUserAgent

    var data = PbPageReqIdl.DataReq()
    data.common = common
    data.kz = threadID
    data.forumID = forumID
    data.pn = 1
    data.rn = 2

    var message = PbPageReqIdl()
    message.data = data
    return try authenticatedProtobufReadRequest(
      path: "/c/f/pb/page",
      command: 302_001,
      message: message,
      fields: [("stoken", credential.stoken)],
      userAgent: Self.pollReadUserAgent,
      clientUserToken: String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func submitPollVote(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    selectedOptionIDs: [Int32]
  ) throws -> URLRequest {
    let optionIDs = try validatePollVoteArguments(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      selectedOptionIDs: selectedOptionIDs
    )

    var data = AddPollPostReqIdl.DataReq()
    data.threadID = UInt64(threadID)
    data.options = optionIDs.map(String.init).joined(separator: ",")
    data.forumID = UInt64(forumID)

    var message = AddPollPostReqIdl()
    message.data = data
    return try authenticatedProtobufWriteRequest(
      path: "/c/c/post/addPollPost",
      command: 309_006,
      message: message,
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_type", "2"),
        ("_client_version", Self.pollWriteClientVersion),
        ("stoken", credential.stoken),
      ],
      userAgent: Self.pollWriteUserAgent,
      clientUserToken: String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func validatePollVoteArguments(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    selectedOptionIDs: [Int32]
  ) throws -> [Int32] {
    try validatePollContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
    return try canonicalPollOptionIDs(selectedOptionIDs)
  }

  func canonicalPollOptionIDs(_ selectedOptionIDs: [Int32]) throws -> [Int32] {
    guard !selectedOptionIDs.isEmpty, selectedOptionIDs.count <= 100 else {
      throw TiebaClientError.invalidArgument("A poll vote must select between 1 and 100 options.")
    }
    guard selectedOptionIDs.allSatisfy({ $0 > 0 }) else {
      throw TiebaClientError.invalidArgument("Poll option IDs must be positive.")
    }
    guard Set(selectedOptionIDs).count == selectedOptionIDs.count else {
      throw TiebaClientError.invalidArgument("Poll option IDs must not contain duplicates.")
    }
    return selectedOptionIDs.sorted()
  }

  private func validatePollContext(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) throws {
    try validate(credential)
    try validateAgreementContext(
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: nil
    )
  }

  func setUserFollowState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64,
    targetPortrait: String,
    tbs: String,
    isFollowed: Bool,
    timestampMilliseconds: Int64? = nil
  ) throws -> URLRequest {
    try validate(credential)
    try validateDistinctUserIDs(expectedUserID: expectedUserID, targetUserID: targetUserID)
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let portrait = try normalizedPortraitToken(targetPortrait)

    var fields: [(String, String)] = [
      ("BDUSS", credential.bduss),
      ("_client_version", Self.userFollowClientVersion),
      ("authsid", "null"),
      ("from_type", "2"),
      ("in_live", "0"),
      ("portrait", portrait),
      ("stoken", credential.stoken),
      ("tbs", tbs),
    ]
    if !isFollowed {
      let timestamp = timestampMilliseconds
        ?? Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
      guard timestamp > 0 else {
        throw TiebaClientError.invalidArgument("Timestamp must be positive.")
      }
      fields.append(("timestamp", String(timestamp)))
    }
    return try signedFormRequest(
      host: Self.writeHost,
      path: isFollowed ? "/c/c/user/follow" : "/c/c/user/unfollow",
      fields: fields,
      userAgent: "bdtb for Android \(Self.userFollowClientVersion)",
      cookie: "ka=open"
    )
  }

  func cloudFavorites(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    offset: Int,
    pageSize: Int
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard (0...Int(Int32.max)).contains(offset) else {
      throw TiebaClientError.invalidArgument("Offset must be between 0 and \(Int32.max).")
    }
    guard (1...100).contains(pageSize) else {
      throw TiebaClientError.invalidArgument("Page size must be between 1 and 100.")
    }

    return try signedFormRequest(
      host: Self.writeHost,
      path: "/c/f/post/threadstore",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", Self.cloudFavoritesClientVersion),
        ("offset", String(offset)),
        ("rn", String(pageSize)),
        ("stoken", credential.stoken),
        ("user_id", String(expectedUserID)),
      ],
      userAgent: "bdtb for Android \(Self.cloudFavoritesClientVersion)",
      clientUserToken: String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func threadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) throws -> URLRequest {
    try validate(credential)
    try validateAgreementContext(
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: nil
    )
    try validateConfiguration()

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = configuration.clientVersion
    common.bduss = credential.bduss

    var data = PbPageReqIdl.DataReq()
    data.common = common
    data.kz = threadID
    data.forumID = forumID
    data.pn = 1
    data.rn = 2

    var message = PbPageReqIdl()
    message.data = data
    return try protobufRequest(
      path: "/c/f/pb/page",
      command: 302_001,
      message: message
    )
  }

  func setThreadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    tbs: String,
    markedPostID: Int64?
  ) throws -> URLRequest {
    try validateThreadCloudFavoriteWriteArguments(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      markedPostID: markedPostID
    )
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let clientVersion = Self.threadCloudFavoriteClientVersion
    let fields: [(String, String)]
    let path: String
    if let markedPostID {
      let object: [[String: Any]] = [
        [
          "tid": String(threadID),
          "pid": String(markedPostID),
          "status": 1,
        ]
      ]
      let jsonData: Data
      do {
        jsonData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
      } catch {
        throw TiebaClientError.invalidArgument("Unable to encode cloud-favorite marker data.")
      }
      guard let data = String(data: jsonData, encoding: .utf8) else {
        throw TiebaClientError.invalidArgument("Unable to encode cloud-favorite marker data.")
      }
      path = "/c/c/post/addstore"
      fields = [
        ("BDUSS", credential.bduss),
        ("_client_version", clientVersion),
        ("data", data),
        ("stoken", credential.stoken),
      ]
    } else {
      path = "/c/c/post/rmstore"
      fields = [
        ("BDUSS", credential.bduss),
        ("_client_version", clientVersion),
        ("fid", String(forumID)),
        ("stoken", credential.stoken),
        ("tbs", tbs),
        ("tid", String(threadID)),
        ("user_id", String(expectedUserID)),
      ]
    }

    return try signedFormRequest(
      host: Self.writeHost,
      path: path,
      fields: fields,
      userAgent: "bdtb for Android \(clientVersion)",
      clientUserToken: String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func validateThreadCloudFavoriteWriteArguments(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    markedPostID: Int64?
  ) throws {
    try validate(credential)
    try validateAgreementContext(
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: nil
    )
    if let markedPostID {
      try validatePositiveID(markedPostID, name: "Marked post ID")
    }
  }

  func validateTextReplyArguments(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission
  ) throws -> String {
    try validatedTextReplySubmission(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission
    ).normalizedForumName
  }

  private func validatedTextReplySubmission(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission
  ) throws -> (normalizedForumName: String, content: TiebaCompiledSubmissionContent) {
    try validate(credential)
    try validateAgreementContext(
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      threadID: submission.threadID,
      target: nil
    )
    let allowsImages: Bool
    switch submission.target {
    case .thread(let firstPostID):
      try validatePositiveID(firstPostID, name: "First post ID")
      allowsImages = true
    case .post(let postID):
      try validatePositiveID(postID, name: "Post ID")
      allowsImages = false
    case .subpost(let parentPostID, let subpostID):
      try validatePositiveID(parentPostID, name: "Parent post ID")
      try validatePositiveID(subpostID, name: "Subpost ID")
      guard parentPostID != subpostID else {
        throw TiebaClientError.invalidArgument(
          "Parent post ID and subpost ID must be different."
        )
      }
      allowsImages = false
    }
    let forumName = try normalizedForumName(submission.forumName)
    let content = try TiebaStaticImageContentCompiler.compile(
      userContent: submission.content,
      imageProofs: submission.imageProofs,
      submissionID: submission.submissionID,
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      normalizedForumName: forumName,
      allowsImages: allowsImages,
      maximumCharacterCount: TiebaTextReplyContentPolicy.maximumCharacterCount,
      maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount
    )
    return (forumName, content)
  }

  func validateNewThreadArguments(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaNewThreadSubmission
  ) throws -> String {
    try validatedNewThreadSubmission(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission
    ).normalizedForumName
  }

  private func validatedNewThreadSubmission(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaNewThreadSubmission
  ) throws -> (normalizedForumName: String, content: TiebaCompiledSubmissionContent) {
    try validate(credential)
    try validateIdentity(expectedUserID: expectedUserID, forumID: submission.forumID)
    guard TiebaNewThreadContentPolicy.isValidTitle(submission.title) else {
      throw TiebaClientError.invalidArgument(
        "The new-thread title or content is invalid, too large, contains unsupported control characters, or contains an unsupported Tieba rich-content marker."
      )
    }
    let forumName = try normalizedForumName(submission.forumName)
    let content = try TiebaStaticImageContentCompiler.compile(
      userContent: submission.content,
      imageProofs: submission.imageProofs,
      submissionID: submission.submissionID,
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      normalizedForumName: forumName,
      allowsImages: true,
      maximumCharacterCount: TiebaNewThreadContentPolicy.maximumContentCharacterCount,
      maximumUTF8ByteCount: TiebaNewThreadContentPolicy.maximumContentUTF8ByteCount
    )
    return (forumName, content)
  }

  func validateStaticImageUploadArguments(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    upload: TiebaStaticImageUpload
  ) throws -> TiebaStaticImageUploadPlan {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    let forumName = try normalizedForumName(upload.forumName)
    guard forumName.utf8.count <= TiebaStaticImageUploadPolicy.maximumForumNameUTF8Bytes else {
      throw TiebaClientError.invalidArgument("Forum name is too large to upload an image.")
    }
    guard !upload.encodedBytes.isEmpty else {
      throw TiebaClientError.invalidArgument("Image data must not be empty.")
    }
    let maximumBytes =
      upload.preservesOriginal
      ? TiebaStaticImageUploadPolicy.maximumOriginalImageBytes
      : TiebaStaticImageUploadPolicy.maximumStandardImageBytes
    guard upload.encodedBytes.count <= maximumBytes else {
      throw TiebaClientError.invalidArgument(
        "Image data exceeds the \(maximumBytes)-byte upload limit."
      )
    }
    let dimensions = [upload.pixelWidth, upload.pixelHeight]
    let dimensionsAreValid = dimensions.allSatisfy {
      (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains($0)
    }
    guard dimensionsAreValid else {
      throw TiebaClientError.invalidArgument(
        "Image dimensions must be between 1 and \(TiebaStaticImageUploadPolicy.maximumPixelDimension) pixels."
      )
    }

    let contentDigest = TiebaStaticImageUploadPolicy.contentDigest(of: upload.encodedBytes)
    guard
      let chunkCount = TiebaStaticImageUploadPolicy.chunkCount(
        forByteCount: upload.encodedBytes.count
      )
    else {
      throw TiebaClientError.invalidArgument("Image data must not be empty.")
    }
    return TiebaStaticImageUploadPlan(
      upload: upload,
      expectedUserID: expectedUserID,
      normalizedForumName: forumName,
      resourceID: TiebaStaticImageUploadPolicy.resourceID(for: upload.encodedBytes),
      contentDigest: contentDigest,
      chunkCount: chunkCount
    )
  }

  func staticImageUploadChunk(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    plan: TiebaStaticImageUploadPlan,
    chunkNumber: Int
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard expectedUserID == plan.expectedUserID else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard (1...plan.chunkCount).contains(chunkNumber) else {
      throw TiebaClientError.invalidArgument(
        "Image chunk number must be between 1 and \(plan.chunkCount)."
      )
    }
    try validateConfiguration()

    let chunkStart = (chunkNumber - 1) * TiebaStaticImageUploadPolicy.chunkSize
    let chunkEnd = min(
      chunkStart + TiebaStaticImageUploadPolicy.chunkSize,
      plan.upload.encodedBytes.count
    )
    let chunk = plan.upload.encodedBytes.subdata(in: chunkStart..<chunkEnd)
    let isFinal = chunkNumber == plan.chunkCount
    let fields = [
      ("BDUSS", credential.bduss),
      ("_client_type", "2"),
      ("_client_version", Self.staticImageUploadClientVersion),
      ("alt", "json"),
      ("chunkNo", String(chunkNumber)),
      ("forum_name", plan.normalizedForumName),
      ("groupId", "1"),
      ("height", String(plan.upload.pixelHeight)),
      ("isFinish", isFinal ? "1" : "0"),
      ("is_bjh", "0"),
      ("pic_water_type", plan.upload.watermark.rawValue),
      ("resourceId", plan.resourceID),
      ("saveOrigin", plan.upload.preservesOriginal ? "1" : "0"),
      ("size", String(plan.upload.encodedBytes.count)),
      ("small_flow_fname", plan.normalizedForumName),
      ("width", String(plan.upload.pixelWidth)),
    ]
    let signedFields =
      fields.sorted {
        $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
      } + [("sign", Self.signature(for: fields))]
    let multipartBoundary = Self.staticImageUploadMultipartBoundary(
      fields: signedFields,
      chunk: chunk
    )

    var components = URLComponents()
    components.scheme = "https"
    components.host = TiebaStaticImageUploadEndpointPolicy.host
    components.path = TiebaStaticImageUploadEndpointPolicy.path
    guard let url = components.url, TiebaStaticImageUploadEndpointPolicy.allows(url) else {
      throw TiebaClientError.invalidEndpoint
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.httpBody = Self.staticImageUploadMultipartBody(
      fields: signedFields,
      chunk: chunk,
      boundary: multipartBoundary
    )
    request.setValue(
      "bdtb for Android \(Self.staticImageUploadClientVersion)",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue("ka=open", forHTTPHeaderField: "Cookie")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(
      "multipart/form-data; boundary=\(multipartBoundary)",
      forHTTPHeaderField: "Content-Type"
    )
    return request
  }

  func newThread(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaNewThreadSubmission,
    normalizedForumName: String,
    tbs: String,
    accountDisplayName: String
  ) throws -> URLRequest {
    let validatedSubmission = try validatedNewThreadSubmission(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission
    )
    guard
      validatedSubmission.normalizedForumName == normalizedForumName,
      Self.isValidTBS(tbs)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let displayName = try validatedReplyMetadata(
      accountDisplayName,
      name: "Account display name",
      maximumBytes: 512,
      allowsEmpty: false
    )
    let title = submission.title.precomposedStringWithCanonicalMapping
    let isUntitled = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    return try signedFormRequest(
      host: Self.writeHost,
      path: "/c/c/thread/add",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_type", "2"),
        ("_client_version", Self.newThreadClientVersion),
        ("anonymous", "1"),
        ("call_from", "2"),
        ("can_no_forum", "0"),
        ("content", validatedSubmission.content.wireValue),
        ("cuid_gid", ""),
        ("entrance_type", "1"),
        ("fid", String(submission.forumID)),
        ("from", "1021636m"),
        ("is_feedback", "0"),
        ("is_hide", "1"),
        ("is_ntitle", isUntitled ? "1" : "0"),
        ("kw", normalizedForumName),
        ("name_show", displayName),
        ("new_vcode", "1"),
        ("reply_uid", "null"),
        ("stoken", credential.stoken),
        ("subapp_type", "mini"),
        ("takephoto_num", "0"),
        ("tbs", tbs),
        ("title", title),
        ("vcode_tag", "12"),
        ("z_id", ""),
      ],
      userAgent: "bdtb for Android \(Self.newThreadClientVersion)",
      clientUserToken: String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func textReply(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission,
    normalizedForumName: String,
    tbs: String,
    accountDisplayName: String,
    replyUserID: Int64?,
    replyUserDisplayName: String?,
    replyUserPortrait: String?
  ) throws -> URLRequest {
    let validatedSubmission = try validatedTextReplySubmission(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission
    )
    guard validatedSubmission.normalizedForumName == normalizedForumName else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let accountDisplayName = try validatedReplyMetadata(
      accountDisplayName,
      name: "Account display name",
      maximumBytes: 512,
      allowsEmpty: false
    )

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = Self.textReplyClientVersion
    common.bduss = credential.bduss
    common.stoken = credential.stoken
    common.tbs = tbs

    var data = AddPostReqIdl.DataReq()
    data.common = common
    data.anonymous = "1"
    data.canNoForum = "0"
    data.isFeedback = "0"
    data.takephotoNum = "0"
    data.entranceType = "0"
    data.vcodeTag = "12"
    data.newVcode = "1"
    data.fid = String(submission.forumID)
    data.kw = normalizedForumName
    data.isBarrage = "0"
    data.isTwzhiboThread = "0"
    data.floorNum = "0"
    data.isAd = "0"
    data.isAddition = "0"
    data.isGiftpost = "0"
    data.nameShow = accountDisplayName
    data.isPictxt = "0"
    data.showCustomFigure = 0
    data.isShowBless = 0
    data.tid = String(submission.threadID)

    switch submission.target {
    case .thread:
      guard replyUserID == nil, replyUserDisplayName == nil, replyUserPortrait == nil else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      data.content = validatedSubmission.content.wireValue
      data.barrageTime = "0"
      data.postFrom = "13"
      data.vFid = ""
      data.vFname = ""
    case .post(let postID):
      guard
        let replyUserID,
        replyUserID > 0,
        replyUserDisplayName == nil,
        replyUserPortrait == nil
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      data.content = validatedSubmission.content.wireValue
      data.replyUid = String(replyUserID)
      data.quoteID = String(postID)
      data.repostid = String(postID)
      data.postFrom = "0"
    case .subpost(let parentPostID, let subpostID):
      guard let replyUserID, replyUserID > 0, let replyUserDisplayName else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      let displayName = try validatedReplyMarkerComponent(
        replyUserDisplayName,
        name: "Reply-user display name",
        maximumBytes: 512,
        allowsEmpty: false
      )
      let portrait = try validatedReplyMarkerComponent(
        replyUserPortrait ?? "",
        name: "Reply-user portrait",
        maximumBytes: 2_048,
        allowsEmpty: false
      )
      data.content =
        "回复 #(reply, \(portrait), \(displayName)) :\(validatedSubmission.content.wireValue)"
      data.replyUid = String(replyUserID)
      data.quoteID = String(parentPostID)
      data.repostid = String(parentPostID)
      data.subPostID = String(subpostID)
    }

    var message = AddPostReqIdl()
    message.data = data
    return try authenticatedProtobufWriteRequest(
      path: "/c/c/post/add",
      command: 309_731,
      message: message,
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_type", "2"),
        ("_client_version", Self.textReplyClientVersion),
        ("stoken", credential.stoken),
      ],
      userAgent: "bdtb for Android \(Self.textReplyClientVersion)",
      clientUserToken: String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func concernFeed(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    pageTag: String?,
    lastRequestUnix: UInt64
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard lastRequestUnix <= UInt64(Int64.max) else {
      throw TiebaClientError.invalidArgument("Concern snapshot timestamp is out of range.")
    }
    if let pageTag {
      guard Self.isValidConcernPageTag(pageTag) else {
        throw TiebaClientError.invalidArgument("Concern page tag is invalid.")
      }
      guard lastRequestUnix > 0 else {
        throw TiebaClientError.invalidArgument(
          "Concern load-more requests require a snapshot timestamp."
        )
      }
    }
    let cuid = try validatedConcernCUID()

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = Self.concernClientVersion
    common.cuid = cuid
    common.bduss = credential.bduss
    common.netType = 1
    common.stoken = credential.stoken

    var data = UserLikeReqIdl.DataReq()
    data.common = common
    data.pageTag = pageTag ?? ""
    data.lastReqUnix = lastRequestUnix
    data.followType = 1
    data.loadType = pageTag == nil ? 1 : 2

    var message = UserLikeReqIdl()
    message.data = data
    let fields = [
      ("BDUSS", credential.bduss),
      ("_client_version", Self.concernClientVersion),
      ("stoken", credential.stoken),
    ]
    return try signedProtobufRequest(
      path: "/c/f/concern/userlike",
      command: 309_474,
      message: message,
      fields: fields,
      userAgent: "bdtb for Android \(Self.concernClientVersion)",
      clientUserToken: String(expectedUserID)
    )
  }

  func followedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int,
    pageSize: Int
  ) throws -> URLRequest {
    try likedForums(
      credential: credential,
      accountUserID: userID,
      targetUserID: userID,
      page: page,
      pageSize: pageSize
    )
  }

  func likedForums(
    credential: TiebaBDUSSCredential,
    accountUserID: Int64,
    targetUserID: Int64,
    page: Int,
    pageSize: Int
  ) throws -> URLRequest {
    try validate(credential)
    guard accountUserID > 0 else {
      throw TiebaClientError.invalidArgument("Account user ID must be positive.")
    }
    guard targetUserID > 0 else {
      throw TiebaClientError.invalidArgument("Target user ID must be positive.")
    }
    guard (1...Int(Int32.max)).contains(page) else {
      throw TiebaClientError.invalidArgument("Page must be between 1 and \(Int32.max).")
    }
    guard (1...100).contains(pageSize) else {
      throw TiebaClientError.invalidArgument("Page size must be between 1 and 100.")
    }
    var fields = [
      ("BDUSS", credential.bduss),
      ("_client_version", configuration.authenticatedClientVersion),
      ("page_no", String(page)),
      ("page_size", String(pageSize)),
      ("uid", String(accountUserID)),
    ]
    if targetUserID != accountUserID {
      fields.append(("friend_uid", String(targetUserID)))
      fields.append(("is_guest", "1"))
    }
    return try signedFormRequest(path: "/c/f/forum/like", fields: fields)
  }

  func notifications(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    kind: TiebaNotificationKind,
    page: Int
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    try validatePage(page, name: "Page")
    try validateConfiguration()

    switch kind {
    case .replies:
      var common = CommonReq()
      common.clientVersion = Self.notificationClientVersion
      common.bduss = credential.bduss

      var data = ReplyMeReqIdl.DataReq()
      data.pn = String(page)
      data.common = common

      var message = ReplyMeReqIdl()
      message.data = data
      return try protobufRequest(
        path: "/c/u/feed/replyme",
        command: 303_007,
        message: message
      )
    case .mentions:
      return try signedFormRequest(
        path: "/c/u/feed/atme",
        fields: [
          ("BDUSS", credential.bduss),
          ("_client_version", Self.notificationClientVersion),
          ("pn", String(page)),
        ]
      )
    }
  }

  func inboxUnreadSummary(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }

    return try signedFormRequest(
      path: "/c/s/msg",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", Self.inboxUnreadSummaryClientVersion),
        ("bookmark", "1"),
      ],
      userAgent: "bdtb for Android \(Self.inboxUnreadSummaryClientVersion)"
    )
  }

  func forumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) throws -> URLRequest {
    try validate(credential)
    try validateIdentity(expectedUserID: expectedUserID, forumID: forumID)
    let forumName = try normalizedForumName(forumName)
    try validateConfiguration()

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = configuration.clientVersion
    common.bduss = credential.bduss

    var data = FrsPageReqIdl.DataReq()
    data.common = common
    data.kw = forumName
    data.rn = 1
    data.rnNeed = 1

    var message = FrsPageReqIdl()
    message.data = data
    return try protobufRequest(
      path: "/c/f/frs/page",
      command: 301_001,
      message: message
    )
  }

  func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    tbs: String,
    isFollowed: Bool
  ) throws -> URLRequest {
    try validate(credential)
    try validateIdentity(expectedUserID: expectedUserID, forumID: forumID)
    let forumName = try normalizedForumName(forumName)
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let clientVersion = isFollowed ? Self.followClientVersion : Self.unfollowClientVersion
    return try signedFormRequest(
      host: Self.writeHost,
      path: isFollowed ? "/c/c/forum/like" : "/c/c/forum/unfavolike",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", clientVersion),
        ("fid", String(forumID)),
        ("kw", forumName),
        ("tbs", tbs),
      ],
      userAgent: "bdtb for Android \(clientVersion)",
      clientUserToken: isFollowed ? nil : String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    tbs: String
  ) throws -> URLRequest {
    try validate(credential)
    try validateIdentity(expectedUserID: expectedUserID, forumID: forumID)
    let forumName = try normalizedForumName(forumName)
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    return try signedFormRequest(
      host: Self.writeHost,
      path: "/c/c/forum/sign",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", Self.checkInClientVersion),
        ("fid", String(forumID)),
        ("kw", forumName),
        ("tbs", tbs),
      ],
      userAgent: "bdtb for Android \(Self.checkInClientVersion)",
      clientUserToken: String(expectedUserID),
      cookie: "ka=open"
    )
  }

  func agreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    page: Int,
    pageSize: Int,
    sort: TiebaPostSort,
    onlyThreadAuthor: Bool,
    location: TiebaPostLocation?,
    includeSubposts: Bool,
    subpostsSortedByAgree: Bool,
    subpostPageSize: Int
  ) throws -> URLRequest {
    try validate(credential)
    try validateAgreementContext(
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: nil
    )
    if case .pageCursor = location {
      try validateCursorPage(page)
    } else {
      try validatePage(page, name: "Page")
    }
    try validatePageSize(pageSize, maximum: 100, name: "Page size")
    try validatePageSize(subpostPageSize, maximum: 50, name: "Subpost page size")
    try validateConfiguration()

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = configuration.clientVersion
    common.bduss = credential.bduss

    var data = PbPageReqIdl.DataReq()
    data.common = common
    data.kz = threadID
    data.forumID = forumID
    switch location {
    case .postID(let postID):
      try validatePositiveID(postID, name: "Post ID")
      data.pid = postID
      data.pn = 0
    case .pageNumber:
      data.pn = Int32(page)
    case .pageCursor(let postID):
      try validatePositiveID(postID, name: "Post cursor ID")
      data.pid = postID
      data.pn = Int32(page)
    case .latestReplies(let postID):
      try validatePositiveID(postID, name: "Last post ID")
      data.pid = postID
      data.pn = 0
      data.lastPid = postID
    case nil:
      data.pn = sort == .descending && page == 1 ? 0 : Int32(page)
    }
    data.rn = Int32(max(pageSize, 2))
    data.r = sort.rawValue
    data.lz = onlyThreadAuthor ? 1 : 0
    if includeSubposts {
      data.withFloor = 1
      data.floorSortType = subpostsSortedByAgree ? 1 : 0
      data.floorRn = Int32(subpostPageSize)
    }

    var message = PbPageReqIdl()
    message.data = data
    return try protobufRequest(
      path: "/c/f/pb/page",
      command: 302_001,
      message: message
    )
  }

  func subpostAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    parentPostID: Int64,
    aroundSubpostID: Int64?,
    page: Int
  ) throws -> URLRequest {
    let target: TiebaAgreementTarget
    if let aroundSubpostID {
      target = .subpost(parentPostID: parentPostID, subpostID: aroundSubpostID)
    } else {
      target = .post(postID: parentPostID)
    }
    try validate(credential)
    try validateAgreementContext(
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: target
    )
    try validatePage(page, name: "Page")
    try validateConfiguration()

    var common = CommonReq()
    common.clientType = 2
    common.clientVersion = configuration.clientVersion
    common.bduss = credential.bduss

    var data = PbFloorReqIdl.DataReq()
    data.common = common
    data.kz = threadID
    data.pid = parentPostID
    data.spid = aroundSubpostID ?? 0
    data.pn = Int32(page)
    data.forumID = forumID

    var message = PbFloorReqIdl()
    message.data = data
    return try protobufRequest(
      path: "/c/f/pb/floor",
      command: 302_002,
      message: message
    )
  }

  func setAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaAgreementTarget,
    tbs: String,
    isAgreed: Bool
  ) throws -> URLRequest {
    try validate(credential)
    try validateAgreementContext(
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: target
    )
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard TiebaGalaxy2CUID.isValid(agreementCUID) else {
      throw TiebaClientError.invalidArgument("Agreement client identifier is invalid.")
    }

    let objectType: String
    let postID: Int64
    switch target {
    case .thread(let firstPostID):
      objectType = "3"
      postID = firstPostID
    case .post(let targetPostID):
      objectType = "1"
      postID = targetPostID
    case .subpost(_, let subpostID):
      objectType = "2"
      postID = subpostID
    }

    let clientVersion = Self.agreementClientVersion
    return try signedFormRequest(
      host: Self.writeHost,
      path: "/c/c/agree/opAgree",
      fields: [
        ("BDUSS", credential.bduss),
        ("_client_version", clientVersion),
        ("agree_type", "2"),
        ("cuid", agreementCUID),
        ("obj_type", objectType),
        ("op_type", isAgreed ? "0" : "1"),
        ("post_id", String(postID)),
        ("tbs", tbs),
        ("thread_id", String(threadID)),
      ],
      userAgent: "bdtb for Android \(clientVersion)"
    )
  }

  func deleteOwnedContent(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaOwnedContentDeletionTarget,
    tbs: String
  ) throws -> URLRequest {
    try validate(credential)
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    try validatePositiveID(forumID, name: "Forum ID")
    try validatePositiveID(threadID, name: "Thread ID")
    let forumName = try normalizedForumName(forumName)
    guard Self.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let path: String
    var fields: [(String, String)] = [
      ("BDUSS", credential.bduss),
      ("_client_version", Self.ownedContentDeletionClientVersion),
      ("fid", String(forumID)),
      ("word", forumName),
      ("z", String(threadID)),
    ]
    switch target {
    case .thread(let firstPostID):
      try validatePositiveID(firstPostID, name: "First post ID")
      path = "/c/c/bawu/delthread"
      fields.append(contentsOf: [
        ("tbs", tbs),
        ("src", "1"),
        ("is_vipdel", "0"),
        ("delete_my_thread", "1"),
        ("is_frs_mask", "0"),
      ])
    case .post(let postID):
      try validatePositiveID(postID, name: "Post ID")
      path = "/c/c/bawu/delpost"
      fields.append(contentsOf: [
        ("pid", String(postID)),
        ("isfloor", "0"),
        ("src", "1"),
        ("is_vipdel", "0"),
        ("delete_my_post", "1"),
        ("tbs", tbs),
      ])
    }

    return try signedFormRequest(
      host: Self.writeHost,
      path: path,
      fields: fields,
      userAgent: "bdtb for Android \(Self.ownedContentDeletionClientVersion)",
      cookie: "ka=open"
    )
  }

  func threadAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    firstPostID: Int64
  ) throws -> URLRequest {
    try agreementPage(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      page: 1,
      pageSize: 2,
      sort: .ascending,
      onlyThreadAuthor: false,
      location: .postID(firstPostID),
      includeSubposts: false,
      subpostsSortedByAgree: true,
      subpostPageSize: 4
    )
  }

  func setThreadAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    firstPostID: Int64,
    tbs: String,
    isAgreed: Bool
  ) throws -> URLRequest {
    try setAgreement(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: .thread(firstPostID: firstPostID),
      tbs: tbs,
      isAgreed: isAgreed
    )
  }

  static func signature(for fields: [(String, String)]) -> String {
    TiebaFormSigner.signature(for: fields)
  }

  private func signedFormRequest(
    host: String = TiebaRequestFactory.serviceHost,
    path: String,
    fields: [(String, String)],
    userAgent: String? = nil,
    clientUserToken: String? = nil,
    cookie: String? = nil
  ) throws -> URLRequest {
    try validateConfiguration()

    var urlComponents = URLComponents()
    urlComponents.scheme = "https"
    urlComponents.host = host
    urlComponents.path = path
    guard let url = urlComponents.url, Self.allows(url, expectedHost: host) else {
      throw TiebaClientError.invalidEndpoint
    }

    let signedFields = fields + [("sign", Self.signature(for: fields))]
    guard let encodedBody = TiebaFormSigner.encodedBody(for: signedFields) else {
      throw TiebaClientError.invalidArgument("Unable to encode authenticated request.")
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.httpBody = encodedBody
    request.setValue(userAgent ?? configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    if let clientUserToken {
      request.setValue(clientUserToken, forHTTPHeaderField: "client_user_token")
    }
    if let cookie {
      request.setValue(cookie, forHTTPHeaderField: "Cookie")
    }
    return request
  }

  private static func staticImageUploadMultipartBody(
    fields: [(String, String)],
    chunk: Data,
    boundary: String
  ) -> Data {
    var body = Data()
    for (name, value) in fields {
      body.append(Data("--\(boundary)\r\n".utf8))
      body.append(
        Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
      )
      body.append(Data(value.utf8))
      body.append(Data("\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(
      Data("Content-Disposition: form-data; name=\"chunk\"; filename=\"file\"\r\n\r\n".utf8)
    )
    body.append(chunk)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
  }

  private static func staticImageUploadMultipartBoundary(
    fields: [(String, String)],
    chunk: Data
  ) -> String {
    while true {
      let candidate = "TiebaPlusPlusBoundary-\(UUID().uuidString.lowercased())"
      let candidateBytes = Data(candidate.utf8)
      guard
        !fields.contains(where: { $0.1.contains(candidate) }),
        chunk.range(of: candidateBytes) == nil
      else { continue }
      return candidate
    }
  }

  private static func selfProfileAvatarMultipartBody(
    fields: [(String, String)],
    jpegData: Data,
    boundary: String
  ) -> Data {
    var body = Data()
    for (name, value) in fields {
      body.append(Data("--\(boundary)\r\n".utf8))
      body.append(
        Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
      )
      body.append(Data(value.utf8))
      body.append(Data("\r\n".utf8))
    }
    body.append(Data("--\(boundary)\r\n".utf8))
    body.append(
      Data("Content-Disposition: form-data; name=\"pic\"; filename=\"file\"\r\n\r\n".utf8)
    )
    body.append(jpegData)
    body.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return body
  }

  private static func selfProfileAvatarMultipartBoundary(
    fields: [(String, String)],
    jpegData: Data
  ) -> String {
    while true {
      let candidate = "TiebaPlusPlusAvatarBoundary-\(UUID().uuidString.lowercased())"
      let candidateBytes = Data(candidate.utf8)
      guard
        !fields.contains(where: { $0.1.contains(candidate) }),
        jpegData.range(of: candidateBytes) == nil
      else { continue }
      return candidate
    }
  }

  private func protobufRequest<Message: SwiftProtobuf.Message>(
    path: String,
    command: Int,
    message: Message
  ) throws -> URLRequest {
    var components = URLComponents()
    components.scheme = "https"
    components.host = TiebaRequestFactory.serviceHost
    components.path = path
    components.queryItems = [URLQueryItem(name: "cmd", value: String(command))]
    guard
      let url = components.url,
      Self.allows(url, expectedHost: TiebaRequestFactory.serviceHost)
    else {
      throw TiebaClientError.invalidEndpoint
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.httpBody = TiebaRequestFactory.multipartBody(protobuf: try message.serializedData())
    request.setValue(configuration.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("protobuf", forHTTPHeaderField: "x_bd_data_type")
    request.setValue(
      "multipart/form-data; boundary=\(TiebaRequestFactory.multipartBoundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  private func signedProtobufRequest<Message: SwiftProtobuf.Message>(
    path: String,
    command: Int,
    message: Message,
    fields: [(String, String)],
    userAgent: String,
    clientUserToken: String
  ) throws -> URLRequest {
    try validateConfiguration()
    let signedFields = fields.sorted {
      $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
    } + [("sign", Self.signature(for: fields))]

    var components = URLComponents()
    components.scheme = "https"
    components.host = TiebaRequestFactory.serviceHost
    components.path = path
    components.queryItems = [URLQueryItem(name: "cmd", value: String(command))]
    guard
      let url = components.url,
      Self.allows(url, expectedHost: TiebaRequestFactory.serviceHost)
    else {
      throw TiebaClientError.invalidEndpoint
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.httpBody = TiebaRequestFactory.multipartBody(
      fields: signedFields,
      protobuf: try message.serializedData()
    )
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("protobuf", forHTTPHeaderField: "x_bd_data_type")
    request.setValue(clientUserToken, forHTTPHeaderField: "client_user_token")
    request.setValue(
      "multipart/form-data; boundary=\(TiebaRequestFactory.multipartBoundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  private func authenticatedProtobufWriteRequest<Message: SwiftProtobuf.Message>(
    path: String,
    command: Int,
    message: Message,
    fields: [(String, String)],
    userAgent: String,
    clientUserToken: String,
    cookie: String
  ) throws -> URLRequest {
    try validateConfiguration()
    let signedFields = fields.sorted {
      $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
    } + [("sign", Self.signature(for: fields))]
    var components = URLComponents()
    components.scheme = "https"
    components.host = Self.writeHost
    components.path = path
    components.queryItems = [
      URLQueryItem(name: "cmd", value: String(command)),
      URLQueryItem(name: "format", value: "protobuf"),
    ]
    guard let url = components.url, Self.allows(url, expectedHost: Self.writeHost) else {
      throw TiebaClientError.invalidEndpoint
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.httpBody = TiebaRequestFactory.multipartBody(
      fields: signedFields,
      protobuf: try message.serializedData()
    )
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("protobuf", forHTTPHeaderField: "x_bd_data_type")
    request.setValue(clientUserToken, forHTTPHeaderField: "client_user_token")
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue(
      "multipart/form-data; boundary=\(TiebaRequestFactory.multipartBoundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  private func authenticatedProtobufReadRequest<Message: SwiftProtobuf.Message>(
    path: String,
    command: Int,
    message: Message,
    fields: [(String, String)],
    userAgent: String,
    clientUserToken: String,
    cookie: String,
    includesFormatQuery: Bool = true
  ) throws -> URLRequest {
    var components = URLComponents()
    components.scheme = "https"
    components.host = Self.writeHost
    components.path = path
    components.queryItems = [URLQueryItem(name: "cmd", value: String(command))]
    if includesFormatQuery {
      components.queryItems?.append(URLQueryItem(name: "format", value: "protobuf"))
    }
    guard let url = components.url, Self.allows(url, expectedHost: Self.writeHost) else {
      throw TiebaClientError.invalidEndpoint
    }

    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: configuration.requestTimeout
    )
    request.httpMethod = "POST"
    request.httpShouldHandleCookies = false
    request.httpBody = TiebaRequestFactory.multipartBody(
      fields: fields,
      protobuf: try message.serializedData()
    )
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("2", forHTTPHeaderField: "client_type")
    request.setValue("protobuf", forHTTPHeaderField: "x_bd_data_type")
    request.setValue(clientUserToken, forHTTPHeaderField: "client_user_token")
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue(
      "multipart/form-data; boundary=\(TiebaRequestFactory.multipartBoundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("gzip", forHTTPHeaderField: "Accept-Encoding")
    return request
  }

  static func isValidConcernPageTag(_ value: String) -> Bool {
    let bytes = value.utf8
    guard !bytes.isEmpty, bytes.count <= maximumConcernPageTagBytes else { return false }
    return !value.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0)
    }
  }

  private func validatedConcernCUID() throws -> String {
    let rawValue = configuration.concernCUID
    guard
      rawValue.utf8.count == 36,
      let value = UUID(uuidString: rawValue),
      value.uuidString.caseInsensitiveCompare(rawValue) == .orderedSame
    else {
      throw TiebaClientError.invalidArgument(
        "Concern-feed identifier must be a canonical UUID."
      )
    }
    let personalizedValue = UUID(
      uuidString: configuration.personalizedCUID.trimmingCharacters(
        in: .whitespacesAndNewlines
      )
    )
    guard personalizedValue != value else {
      throw TiebaClientError.invalidArgument(
        "Concern-feed identifier must not reuse the personalized recommendation identifier."
      )
    }
    return value.uuidString.lowercased()
  }

  private func validatedPersonalizedCUID() throws -> String {
    let rawValue = configuration.personalizedCUID.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      rawValue.utf8.count == 36,
      let value = UUID(uuidString: rawValue),
      value.uuidString.caseInsensitiveCompare(rawValue) == .orderedSame
    else {
      throw TiebaClientError.invalidArgument(
        "Personalized recommendation identifier must be a canonical UUID."
      )
    }
    return value.uuidString.lowercased()
  }

  private func validate(_ credential: TiebaBDUSSCredential) throws {
    guard Self.isValidCookieValue(credential.bduss, expectedLength: 192) else {
      throw TiebaClientError.invalidArgument("Account credentials have an invalid format.")
    }
  }

  private func validate(_ credential: TiebaSessionCredential) throws {
    guard
      Self.isValidCookieValue(credential.bduss, expectedLength: 192),
      Self.isValidCookieValue(credential.stoken, expectedLength: 64)
    else {
      throw TiebaClientError.invalidArgument("Account credentials have an invalid format.")
    }
  }

  private static func isValidCookieValue(_ value: String, expectedLength: Int) -> Bool {
    let bytes = value.utf8
    guard bytes.count == expectedLength else { return false }
    return bytes.allSatisfy { byte in
      byte == 0x21
        || (0x23...0x2B).contains(byte)
        || (0x2D...0x3A).contains(byte)
        || (0x3C...0x5B).contains(byte)
        || (0x5D...0x7E).contains(byte)
    }
  }

  private func validateIdentity(expectedUserID: Int64, forumID: Int64) throws {
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard forumID > 0 else {
      throw TiebaClientError.invalidArgument("Forum ID must be positive.")
    }
  }

  private func validateAgreementContext(
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaAgreementTarget?
  ) throws {
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidArgument("Expected user ID must be positive.")
    }
    guard threadID > 0 else {
      throw TiebaClientError.invalidArgument("Thread ID must be positive.")
    }
    guard forumID > 0 else {
      throw TiebaClientError.invalidArgument("Forum ID must be positive.")
    }
    switch target {
    case .thread(let firstPostID):
      try validatePositiveID(firstPostID, name: "First post ID")
    case .post(let postID):
      try validatePositiveID(postID, name: "Post ID")
    case .subpost(let parentPostID, let subpostID):
      try validatePositiveID(parentPostID, name: "Parent post ID")
      try validatePositiveID(subpostID, name: "Subpost ID")
    case nil:
      break
    }
  }

  private func validatePositiveID(_ value: Int64, name: String) throws {
    guard value > 0 else {
      throw TiebaClientError.invalidArgument("\(name) must be positive.")
    }
  }

  private func validatePage(_ value: Int, name: String) throws {
    guard (1...Int(Int32.max)).contains(value) else {
      throw TiebaClientError.invalidArgument("\(name) must be between 1 and \(Int32.max).")
    }
  }

  private func validateCursorPage(_ value: Int) throws {
    guard (0...Int(Int32.max)).contains(value) else {
      throw TiebaClientError.invalidArgument(
        "Cursor page must be between 0 and \(Int32.max)."
      )
    }
  }

  private func validatePageSize(_ value: Int, maximum: Int, name: String) throws {
    guard (1...maximum).contains(value) else {
      throw TiebaClientError.invalidArgument("\(name) must be between 1 and \(maximum).")
    }
  }

  func normalizedForumName(_ value: String) throws -> String {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      !value.isEmpty,
      value.count <= 100,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw TiebaClientError.invalidArgument(
        "Forum name must contain between 1 and 100 non-control characters."
      )
    }
    return value
  }

  private func validateDistinctUserIDs(expectedUserID: Int64, targetUserID: Int64) throws {
    guard expectedUserID > 0, targetUserID > 0, expectedUserID != targetUserID else {
      throw TiebaClientError.invalidArgument(
        "Account and target user IDs must be distinct positive integers."
      )
    }
  }

  private func normalizedPortraitToken(_ rawValue: String) throws -> String {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !value.isEmpty,
      value.utf8.count <= TiebaAuthenticatedDecoder.selfProfilePortraitMaximumBytes,
      !value.contains("?"),
      !value.contains("#"),
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return value
  }

  private func validatedReplyMetadata(
    _ rawValue: String,
    name: String,
    maximumBytes: Int,
    allowsEmpty: Bool
  ) throws -> String {
    let value = rawValue.precomposedStringWithCanonicalMapping
    guard
      (allowsEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
      value.utf8.count <= maximumBytes,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return value
  }

  private func validatedReplyMarkerComponent(
    _ rawValue: String,
    name: String,
    maximumBytes: Int,
    allowsEmpty: Bool
  ) throws -> String {
    let value = try validatedReplyMetadata(
      rawValue,
      name: name,
      maximumBytes: maximumBytes,
      allowsEmpty: allowsEmpty
    )
    guard
      !value.contains(","),
      !value.contains("("),
      !value.contains(")"),
      !value.contains("#(")
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return value
  }

  static func isValidTBS(_ value: String) -> Bool {
    value.utf8.count == 26
      && value.utf8.allSatisfy { byte in
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
      }
  }

  private static func allows(_ url: URL, expectedHost: String) -> Bool {
    url.scheme?.lowercased() == "https"
      && url.host?.caseInsensitiveCompare(expectedHost) == .orderedSame
      && (url.port == nil || url.port == 443)
      && url.user == nil
      && url.password == nil
  }

  private func validateConfiguration() throws {
    guard
      !configuration.clientVersion.isEmpty,
      !configuration.clientVersion.contains(where: { $0.isNewline }),
      !configuration.authenticatedClientVersion.isEmpty,
      !configuration.authenticatedClientVersion.contains(where: { $0.isNewline }),
      !configuration.userAgent.isEmpty,
      !configuration.userAgent.contains(where: { $0.isNewline }),
      configuration.requestTimeout.isFinite,
      configuration.requestTimeout > 0
    else {
      throw TiebaClientError.invalidArgument(
        "Client versions and user agent must be non-empty single-line values, and timeout must be positive."
      )
    }
  }
}
