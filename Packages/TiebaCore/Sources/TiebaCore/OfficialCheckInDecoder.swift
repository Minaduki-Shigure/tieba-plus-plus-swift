import CoreFoundation
import Foundation

struct TiebaOfficialCheckInSessionContext:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let userID: Int64
  let tbs: String

  var description: String { "TiebaOfficialCheckInSessionContext(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["userID": userID], displayStyle: .struct)
  }
}

struct TiebaOfficialBatchEligibility: Sendable, Hashable {
  let minimumLevel: Int
  let maximumCount: Int
  let isAvailable: Bool
}

struct TiebaOfficialCheckInGuidePage: Sendable, Hashable {
  let forums: [TiebaOfficialCheckInForum]
  let hasMore: Bool
  let isBatchCheckInAvailable: Bool
  let advertisedMinimumLevel: Int
}

struct TiebaOfficialCheckInCatalogContext:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let catalog: TiebaOfficialCheckInCatalog
  let tbs: String

  var description: String { "TiebaOfficialCheckInCatalogContext(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["catalog": catalog], displayStyle: .struct)
  }
}

enum TiebaOfficialCheckInDecoder {
  static let maximumForumCount = 10_000
  static let maximumGuidePageCount = 200
  static let maximumBatchCount = 100
  static let maximumForumNameBytes = 1_024
  static let maximumAvatarBytes = 4_096
  static let maximumErrorMessageBytes = 8_192

  static func sessionContext(
    from body: Data,
    expectedUserID: Int64
  ) throws -> TiebaOfficialCheckInSessionContext {
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let object = try responseObject(from: body)
    try checkServerError(object)
    guard
      let user = object["user"] as? [String: Any],
      let userID = flexibleInteger(user["id"]),
      userID == expectedUserID,
      let anti = object["anti"] as? [String: Any],
      let tbs = anti["tbs"] as? String,
      TiebaAuthenticatedRequestFactory.isValidTBS(tbs)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return TiebaOfficialCheckInSessionContext(userID: userID, tbs: tbs)
  }

  static func eligibility(from body: Data) throws -> TiebaOfficialBatchEligibility {
    let object = try responseObject(from: body)
    try checkServerError(object)
    return try eligibility(from: object)
  }

  private static func eligibility(from object: [String: Any]) throws
    -> TiebaOfficialBatchEligibility
  {
    guard
      let minimumLevel = exactFlexibleInteger(object["level"]),
      let maximumCount = exactFlexibleInteger(object["msign_step_num"]),
      minimumLevel >= 0,
      maximumCount >= 0,
      minimumLevel <= Int64(Int.max),
      maximumCount <= Int64(Self.maximumBatchCount)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let canUse = try strictBit(object["can_use"])
    let isValid = try strictBit(object["valid"])
    return TiebaOfficialBatchEligibility(
      minimumLevel: Int(minimumLevel),
      maximumCount: Int(maximumCount),
      isAvailable: canUse && isValid && maximumCount > 0
    )
  }

  static func guidePage(
    from body: Data,
    expectedUserID: Int64,
    requestedPage: Int,
    pageSize: Int
  ) throws -> TiebaOfficialCheckInGuidePage {
    guard
      expectedUserID > 0,
      (1...maximumGuidePageCount).contains(requestedPage),
      (1...100).contains(pageSize)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let object = try responseObject(from: body)
    try checkServerError(object)
    guard
      let rawForums = object["like_forum"] as? [Any],
      rawForums.count <= pageSize,
      let rawHasMore = object["like_forum_has_more"],
      let hasMore = strictBoolean(rawHasMore),
      let rawIsLogin = object["is_login"],
      try strictBit(rawIsLogin),
      let rawBatchValid = object["msign_valid"],
      let rawBatchLevel = exactFlexibleInteger(object["msign_level"]),
      rawBatchLevel >= 0,
      rawBatchLevel <= Int64(Int.max)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let isBatchValid = try strictBit(rawBatchValid)
    if requestedPage == maximumGuidePageCount, hasMore {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    var forums = [TiebaOfficialCheckInForum]()
    forums.reserveCapacity(rawForums.count)
    var seen = Set<Int64>()
    for rawForum in rawForums {
      guard let object = rawForum as? [String: Any] else {
        throw TiebaClientError.invalidJSON
      }
      let forum = try forum(from: object)
      guard seen.insert(forum.id).inserted else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      forums.append(forum)
    }
    return TiebaOfficialCheckInGuidePage(
      forums: forums,
      hasMore: hasMore,
      isBatchCheckInAvailable: isBatchValid,
      advertisedMinimumLevel: Int(rawBatchLevel)
    )
  }

  static func batchResult(
    from body: Data,
    expectedUserID: Int64,
    requestedForums: [TiebaOfficialCheckInForum]
  ) throws -> TiebaOfficialBatchCheckInResult {
    guard expectedUserID > 0, !requestedForums.isEmpty else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let requestedIDs = requestedForums.map(\.id)
    guard
      requestedIDs.count <= maximumBatchCount,
      Set(requestedIDs).count == requestedIDs.count
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let object = try responseObject(from: body)
    try checkServerError(object)
    guard
      let timeout = object["is_timeout"],
      let showsDialog = object["show_dialog"],
      let ctime = exactFlexibleInteger(object["ctime"]), ctime >= 0,
      let time = exactFlexibleInteger(object["time"]), time >= 0,
      let logID = exactFlexibleInteger(object["logid"]), logID >= 0,
      let serverTime = exactFlexibleInteger(object["server_time"]), serverTime >= 0,
      let signNotice = object["sign_notice"] as? String,
      let timeoutNotice = object["timeout_notice"] as? String
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    _ = try strictBit(timeout)
    _ = try strictBit(showsDialog)
    _ = try boundedText(
      signNotice,
      maximumBytes: maximumErrorMessageBytes,
      allowsEmpty: true
    )
    _ = try boundedText(
      timeoutNotice,
      maximumBytes: maximumErrorMessageBytes,
      allowsEmpty: true
    )
    guard let rawItems = object["info"] as? [Any], rawItems.count == requestedForums.count else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let requestedIDSet = Set(requestedIDs)
    var decoded = [Int64: TiebaOfficialBatchCheckInItem]()
    for rawItem in rawItems {
      guard let itemObject = rawItem as? [String: Any] else {
        throw TiebaClientError.invalidJSON
      }
      let item = try batchItem(from: itemObject)
      guard requestedIDSet.contains(item.forumID), decoded[item.forumID] == nil else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      decoded[item.forumID] = item
    }

    let ordered = try requestedForums.map { forum in
      guard let item = decoded[forum.id], canonicalText(item.forumName) == canonicalText(forum.name)
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      return item
    }
    return TiebaOfficialBatchCheckInResult(userID: expectedUserID, items: ordered)
  }

  private static func forum(from object: [String: Any]) throws -> TiebaOfficialCheckInForum {
    guard
      let id = exactFlexibleInteger(object["forum_id"]), id > 0,
      let rawName = object["forum_name"] as? String,
      let level = exactFlexibleInteger(object["level_id"]),
      level >= 0,
      level <= Int64(Int.max),
      let rawStatus = exactFlexibleInteger(object["is_sign"]),
      (-1...1).contains(rawStatus),
      let rawForbidden = object["is_forbidden"],
      let rawAvatar = object["avatar"] as? String
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let isForbidden = try strictBit(rawForbidden)
    let name = try boundedText(rawName, maximumBytes: maximumForumNameBytes, allowsEmpty: false)
    let avatar = try boundedText(
      rawAvatar,
      maximumBytes: maximumAvatarBytes,
      allowsEmpty: true
    )
    let status: TiebaOfficialCheckInStatus
    switch rawStatus {
    case -1: status = .unknown
    case 0: status = .pending
    case 1: status = .checkedIn
    default: throw TiebaClientError.invalidAuthenticatedResponse
    }
    return TiebaOfficialCheckInForum(
      id: id,
      name: name,
      level: Int(level),
      avatar: avatar,
      checkInStatus: status,
      isForbidden: isForbidden
    )
  }

  private static func batchItem(from object: [String: Any]) throws
    -> TiebaOfficialBatchCheckInItem
  {
    guard
      let forumID = exactFlexibleInteger(object["forum_id"]), forumID > 0,
      let rawForumName = object["forum_name"] as? String,
      let rawSigned = object["signed"],
      let rawFiltered = object["is_filter"],
      let rawEnabled = object["is_on"],
      let currentExperience = exactFlexibleInteger(object["cur_score"]),
      currentExperience >= 0,
      currentExperience <= Int64(Int.max),
      let consecutiveDays = exactFlexibleInteger(object["sign_day_count"]),
      consecutiveDays >= 0,
      consecutiveDays <= Int64(Int.max),
      let error = object["error"] as? [String: Any],
      let errorCode = exactFlexibleInteger(error["err_no"])
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let signed = try strictBit(rawSigned)
    let filtered = try strictBit(rawFiltered)
    let enabled = try strictBit(rawEnabled)
    let forumName = try boundedText(
      rawForumName,
      maximumBytes: maximumForumNameBytes,
      allowsEmpty: false
    )
    let message = try boundedText(
      (error["usermsg"] as? String) ?? (error["errmsg"] as? String) ?? "",
      maximumBytes: maximumErrorMessageBytes,
      allowsEmpty: true
    )
    let disposition: TiebaOfficialBatchCheckInDisposition
    if signed {
      guard errorCode == 0 else { throw TiebaClientError.invalidAuthenticatedResponse }
      disposition = .confirmed
    } else {
      disposition = .rejected(code: Int32(clamping: errorCode), message: message)
    }
    return TiebaOfficialBatchCheckInItem(
      forumID: forumID,
      forumName: forumName,
      disposition: disposition,
      currentExperience: Int(currentExperience),
      consecutiveDays: Int(consecutiveDays),
      isFiltered: filtered,
      isEnabled: enabled
    )
  }

  private static func responseObject(from body: Data) throws -> [String: Any] {
    let value: Any
    do {
      value = try JSONSerialization.jsonObject(with: body)
    } catch {
      throw TiebaClientError.invalidJSON
    }
    guard let object = value as? [String: Any] else { throw TiebaClientError.invalidJSON }
    return object
  }

  private static func checkServerError(_ object: [String: Any]) throws {
    guard let code = exactFlexibleInteger(object["error_code"]) else {
      throw TiebaClientError.invalidJSON
    }
    let nested = object["error"] as? [String: Any]
    if let nestedCode = nested?["errno"] {
      guard let parsed = exactFlexibleInteger(nestedCode) else {
        throw TiebaClientError.invalidJSON
      }
      if parsed != 0 {
        throw TiebaClientError.server(
          code: Int32(clamping: parsed),
          message: serverMessage(object, nested: nested)
        )
      }
    }
    guard code == 0 else {
      throw TiebaClientError.server(
        code: Int32(clamping: code),
        message: serverMessage(object, nested: nested)
      )
    }
  }

  private static func serverMessage(
    _ object: [String: Any],
    nested: [String: Any]?
  ) -> String {
    [object["error_msg"], nested?["usermsg"], nested?["errmsg"]]
      .compactMap { $0 as? String }
      .first ?? ""
  }

  private static func exactFlexibleInteger(_ value: Any?) -> Int64? {
    switch value {
    case let value as NSNumber:
      guard
        CFGetTypeID(value) != CFBooleanGetTypeID(),
        !["f", "d"].contains(String(cString: value.objCType))
      else { return nil }
      return Int64(value.stringValue)
    case let value as String:
      guard !value.isEmpty else { return nil }
      return Int64(value)
    default:
      return nil
    }
  }

  private static func flexibleInteger(_ value: Any?) -> Int64? {
    exactFlexibleInteger(value)
  }

  private static func strictBit(_ value: Any?) throws -> Bool {
    guard let value = exactFlexibleInteger(value) else {
      throw TiebaClientError.invalidJSON
    }
    switch value {
    case 0: return false
    case 1: return true
    default: throw TiebaClientError.invalidJSON
    }
  }

  private static func strictBoolean(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    return try? strictBit(value)
  }

  private static func boundedText(
    _ value: String,
    maximumBytes: Int,
    allowsEmpty: Bool
  ) throws -> String {
    let value = canonicalText(value)
    guard
      (allowsEmpty || !value.isEmpty),
      value.utf8.count <= maximumBytes,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return value
  }

  private static func canonicalText(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }
}
