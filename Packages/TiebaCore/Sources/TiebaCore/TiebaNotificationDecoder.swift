import CoreFoundation
import Foundation
import TiebaProto

enum TiebaNotificationDecoder {
  private static let maximumItemCount = 200

  static func replyPage(
    from response: ReplyMeResIdl,
    expectedUserID: Int64,
    requestedPage: Int
  ) throws -> TiebaNotificationPage {
    try validateRequestIdentity(expectedUserID: expectedUserID, requestedPage: requestedPage)
    guard response.hasError else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    guard response.hasData, response.data.hasPage else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let entries = response.data.replyList
    guard entries.count <= maximumItemCount else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let pagination = try protobufPagination(
      response.data.page,
      requestedPage: requestedPage,
      itemCount: entries.count
    )

    var seenPostIDs = Set<Int64>()
    let items = try entries.map { entry -> TiebaNotificationItem in
      guard
        entry.threadID > 0, entry.threadID <= UInt64(Int64.max),
        entry.postID > 0, entry.postID <= UInt64(Int64.max),
        entry.isFloor == 0 || entry.isFloor == 1,
        entry.hasReplyer,
        entry.replyer.id > 0
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      let postID = Int64(entry.postID)
      guard seenPostIDs.insert(postID).inserted else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      let quotedPostID: Int64?
      if entry.quotePid == 0 {
        quotedPostID = nil
      } else {
        guard entry.quotePid <= UInt64(Int64.max) else {
          throw TiebaClientError.invalidAuthenticatedResponse
        }
        quotedPostID = Int64(entry.quotePid)
      }
      let quotedUser: TiebaNotificationSender?
      if entry.hasQuoteUser {
        quotedUser = try protobufSender(entry.quoteUser)
      } else {
        quotedUser = nil
      }
      return TiebaNotificationItem(
        sender: try protobufSender(entry.replyer),
        quotedUser: quotedUser,
        threadID: Int64(entry.threadID),
        postID: postID,
        quotedPostID: quotedPostID,
        title: "",
        content: entry.content,
        quotedContent: entry.quoteContent,
        forumName: entry.fname,
        timestamp: Int64(entry.time),
        isFloorReply: entry.isFloor == 1,
        isFirstPost: false,
        isUnread: false,
        threadType: 0
      )
    }
    return TiebaNotificationPage(
      userID: expectedUserID,
      kind: .replies,
      items: items,
      pagination: pagination
    )
  }

  static func mentionPage(
    from body: Data,
    expectedUserID: Int64,
    requestedPage: Int
  ) throws -> TiebaNotificationPage {
    try validateRequestIdentity(expectedUserID: expectedUserID, requestedPage: requestedPage)
    let object = try responseObject(from: body)
    try checkServerError(object)
    guard object["at_list"] != nil else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let entries = try list(object["at_list"])
    guard entries.count <= maximumItemCount else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    if let replyList = object["reply_list"], !(try list(replyList)).isEmpty {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard let pageObject = object["page"] as? [String: Any] else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let currentPage = try requiredInteger(pageObject["current_page"])
    let hasMore = try requiredFlag(pageObject["has_more"])
    let hasPrevious = try requiredFlag(pageObject["has_prev"])
    guard currentPage == Int64(requestedPage) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    try validatePaginationEdges(
      requestedPage: requestedPage,
      itemCount: entries.count,
      hasMore: hasMore,
      hasPrevious: hasPrevious
    )

    var seenPostIDs = Set<Int64>()
    let items = try entries.map { entry -> TiebaNotificationItem in
      let item = try mentionItem(entry)
      guard seenPostIDs.insert(item.postID).inserted else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      return item
    }
    return TiebaNotificationPage(
      userID: expectedUserID,
      kind: .mentions,
      items: items,
      pagination: TiebaPagination(
        pageSize: items.count,
        currentPage: requestedPage,
        totalPages: 0,
        totalCount: 0,
        hasMore: hasMore,
        hasPrevious: hasPrevious
      )
    )
  }

  private static func mentionItem(_ object: [String: Any]) throws -> TiebaNotificationItem {
    guard
      let replyer = object["replyer"] as? [String: Any],
      let threadID = integer(object["thread_id"]), threadID > 0,
      let postID = integer(object["post_id"]), postID > 0,
      let timestamp = integer(object["time"]), timestamp >= 0
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let isFloorReply = try requiredFlag(object["is_floor"])
    let isFirstPost = try requiredFlag(object["is_first_post"])
    return TiebaNotificationItem(
      sender: try jsonSender(replyer, includesRelationship: true),
      quotedUser: try optionalJSONSender(object["quote_user"]),
      threadID: threadID,
      postID: postID,
      quotedPostID: try optionalPositiveIdentifier(object["quote_pid"]),
      title: try optionalText(object, key: "title"),
      content: try requiredText(object, key: "content"),
      quotedContent: try optionalText(object, key: "quote_content"),
      forumName: try requiredText(object, key: "fname"),
      timestamp: timestamp,
      isFloorReply: isFloorReply,
      isFirstPost: isFirstPost,
      isUnread: try optionalFlag(object["unread"], default: false),
      threadType: try optionalNonnegativeInteger(object["thread_type"])
    )
  }

  private static func protobufSender(_ user: User) throws -> TiebaNotificationSender {
    guard user.id > 0, user.isFriend == 0 || user.isFriend == 1,
      user.isFans == 0 || user.isFans == 1
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return TiebaNotificationSender(
      id: user.id,
      username: user.name,
      displayName: user.nameShow,
      portrait: user.portrait,
      isFriend: user.isFriend == 1,
      isFan: user.isFans == 1
    )
  }

  private static func jsonSender(
    _ object: [String: Any],
    includesRelationship: Bool
  ) throws -> TiebaNotificationSender {
    guard let id = integer(object["id"]), id > 0 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return TiebaNotificationSender(
      id: id,
      username: try optionalText(object, key: "name"),
      displayName: try optionalText(object, key: "name_show"),
      portrait: try optionalText(object, key: "portrait"),
      isFriend: includesRelationship
        ? try optionalFlag(object["is_friend"], default: false) : false,
      isFan: includesRelationship
        ? try optionalFlag(object["is_fans"], default: false) : false
    )
  }

  private static func optionalJSONSender(_ value: Any?) throws -> TiebaNotificationSender? {
    guard let value, !(value is NSNull) else { return nil }
    guard let object = value as? [String: Any] else {
      throw TiebaClientError.invalidJSON
    }
    return try jsonSender(object, includesRelationship: false)
  }

  private static func protobufPagination(
    _ page: Page,
    requestedPage: Int,
    itemCount: Int
  ) throws -> TiebaPagination {
    guard
      page.pageSize >= 0,
      page.currentPage == Int32(requestedPage),
      page.totalCount >= 0,
      page.totalPage >= 0,
      page.newTotalPage >= 0,
      page.hasMore_p == 0 || page.hasMore_p == 1,
      page.hasPrev_p == 0 || page.hasPrev_p == 1
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let totalPages = Int(page.newTotalPage > 0 ? page.newTotalPage : page.totalPage)
    guard
      totalPages == 0 || requestedPage <= totalPages,
      totalPages == 0 || (page.hasMore_p == 1) == (requestedPage < totalPages)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let hasMore = page.hasMore_p == 1
    let hasPrevious = page.hasPrev_p == 1
    try validatePaginationEdges(
      requestedPage: requestedPage,
      itemCount: itemCount,
      hasMore: hasMore,
      hasPrevious: hasPrevious
    )
    return TiebaPagination(
      pageSize: itemCount,
      currentPage: requestedPage,
      totalPages: totalPages,
      totalCount: Int(page.totalCount),
      hasMore: hasMore,
      hasPrevious: hasPrevious
    )
  }

  private static func validatePaginationEdges(
    requestedPage: Int,
    itemCount: Int,
    hasMore: Bool,
    hasPrevious: Bool
  ) throws {
    guard
      hasPrevious == (requestedPage > 1),
      !(hasMore && requestedPage == Int(Int32.max)),
      !hasMore || itemCount > 0
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
  }

  private static func validateRequestIdentity(
    expectedUserID: Int64,
    requestedPage: Int
  ) throws {
    guard expectedUserID > 0, (1...Int(Int32.max)).contains(requestedPage) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
  }

  private static func list(_ value: Any?) throws -> [[String: Any]] {
    if let entries = value as? [[String: Any]] { return entries }
    if value is NSNull { return [] }
    if let value = value as? String, value.isEmpty { return [] }
    if let value = integer(value), value == 0 { return [] }
    throw TiebaClientError.invalidJSON
  }

  private static func requiredText(_ object: [String: Any], key: String) throws -> String {
    guard let value = object[key] as? String else { throw TiebaClientError.invalidJSON }
    return value
  }

  private static func optionalText(_ object: [String: Any], key: String) throws -> String {
    guard let value = object[key], !(value is NSNull) else { return "" }
    guard let value = value as? String else { throw TiebaClientError.invalidJSON }
    return value
  }

  private static func optionalPositiveIdentifier(_ value: Any?) throws -> Int64? {
    guard let value, !(value is NSNull) else { return nil }
    if let value = value as? String, value.isEmpty { return nil }
    guard let identifier = integer(value) else { throw TiebaClientError.invalidJSON }
    if identifier == 0 { return nil }
    guard identifier > 0 else { throw TiebaClientError.invalidAuthenticatedResponse }
    return identifier
  }

  private static func optionalNonnegativeInteger(_ value: Any?) throws -> Int {
    guard let value, !(value is NSNull) else { return 0 }
    guard let integer = integer(value), integer >= 0, integer <= Int64(Int.max) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return Int(integer)
  }

  private static func requiredFlag(_ value: Any?) throws -> Bool {
    guard let value = integer(value), value == 0 || value == 1 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return value == 1
  }

  private static func optionalFlag(_ value: Any?, default defaultValue: Bool) throws -> Bool {
    guard let value, !(value is NSNull) else { return defaultValue }
    return try requiredFlag(value)
  }

  private static func requiredInteger(_ value: Any?) throws -> Int64 {
    guard let value = integer(value) else { throw TiebaClientError.invalidJSON }
    return value
  }

  private static func integer(_ value: Any?) -> Int64? {
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

  private static func responseObject(from body: Data) throws -> [String: Any] {
    do {
      guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
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

  private static func checkServerError(_ object: [String: Any]) throws {
    guard object["error_code"] != nil else { throw TiebaClientError.invalidJSON }
    let code = try requiredInteger(object["error_code"])
    guard code == 0 else {
      let message = (object["error_msg"] as? String) ?? (object["errmsg"] as? String) ?? ""
      throw TiebaClientError.server(code: Int32(clamping: code), message: message)
    }
  }
}
