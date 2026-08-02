import Foundation

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

  private static func checkServerError(_ object: [String: Any]) throws {
    guard let rawCode = int64(object["error_code"]) else {
      throw TiebaClientError.invalidJSON
    }
    guard rawCode == 0 else {
      throw TiebaClientError.server(
        code: Int32(clamping: rawCode),
        message: string(object["error_msg"]) ?? ""
      )
    }
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
    case let value as Int64:
      value
    case let value as Int:
      Int64(value)
    case let value as NSNumber:
      value.int64Value
    case let value as String:
      Int64(value)
    default:
      nil
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
