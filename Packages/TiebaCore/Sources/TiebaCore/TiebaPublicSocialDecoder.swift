import Foundation

enum TiebaPublicSocialDecoder {
  static func page(
    from body: Data,
    requestedUserID: Int64,
    kind: TiebaUserRelationKind,
    requestedPage: Int
  ) throws -> TiebaUserRelationPage {
    guard requestedUserID > 0, requestedPage >= 1, requestedPage <= Int(Int32.max) else {
      throw TiebaClientError.invalidArgument("Public user relation request context is invalid.")
    }

    switch kind {
    case .following:
      return try followingPage(
        from: body,
        requestedUserID: requestedUserID,
        requestedPage: requestedPage
      )
    case .followers:
      return try followersPage(
        from: body,
        requestedUserID: requestedUserID,
        requestedPage: requestedPage
      )
    }
  }

  private static func followingPage(
    from body: Data,
    requestedUserID: Int64,
    requestedPage: Int
  ) throws -> TiebaUserRelationPage {
    let header: PublicSocialResponseHeader = try decode(body)
    try checkServerError(header.errorCode.value, message: header.errorMessage ?? "")
    let data: FollowingPayload = try decode(body)
    guard
      data.page.value == Int64(requestedPage),
      data.hasMore.value == 0 || data.hasMore.value == 1,
      data.totalCount.value >= 0,
      (data.visibilitySwitch?.value ?? 0) >= 0,
      data.users.count <= TiebaPublicSocialPolicy.maximumResponseUserCount
    else {
      throw TiebaClientError.invalidJSON
    }

    let notice = try boundedText(
      data.notice ?? "",
      maximumBytes: TiebaPublicSocialPolicy.maximumNoticeBytes
    )
    let users = try relatedUsers(data.users)
    let rawCount = data.users.count
    let totalCount = try boundedNonnegativeInt(data.totalCount.value)
    let pageSize = TiebaPublicSocialPolicy.followingPageSize
    let hasMore = rawCount > 0
      && (data.hasMore.value == 1 || rawCount >= TiebaPublicSocialPolicy.followingPageSize)

    return TiebaUserRelationPage(
      requestedUserID: requestedUserID,
      kind: .following,
      users: users,
      pagination: TiebaPagination(
        pageSize: pageSize,
        currentPage: requestedPage,
        totalPages: 0,
        totalCount: totalCount,
        hasMore: hasMore,
        hasPrevious: requestedPage > 1
      ),
      notice: notice,
      visibilitySwitch: try data.visibilitySwitch.map {
        try boundedNonnegativeInt($0.value)
      }
    )
  }

  private static func followersPage(
    from body: Data,
    requestedUserID: Int64,
    requestedPage: Int
  ) throws -> TiebaUserRelationPage {
    let header: PublicSocialResponseHeader = try decode(body)
    try checkServerError(header.errorCode.value, message: header.errorMessage ?? "")
    let data: FollowersPayload = try decode(body)
    let page = data.page
    guard
      data.users.count <= TiebaPublicSocialPolicy.maximumResponseUserCount,
      (data.visibilitySwitch?.value ?? 0) >= 0,
      page.pageSize.value > 0,
      page.pageSize.value <= Int64(TiebaPublicSocialPolicy.maximumResponseUserCount),
      page.currentPage.value == Int64(requestedPage),
      page.totalCount.value >= 0,
      page.totalPage.value >= 0,
      page.hasMore.value == 0 || page.hasMore.value == 1,
      page.hasPrevious.value == 0 || page.hasPrevious.value == 1,
      (page.hasPrevious.value == 1) == (requestedPage > 1)
    else {
      throw TiebaClientError.invalidJSON
    }

    let rawCount = data.users.count
    let declaredPageSize = try boundedNonnegativeInt(page.pageSize.value)
    guard declaredPageSize == 0 || rawCount <= declaredPageSize else {
      throw TiebaClientError.invalidJSON
    }
    let totalCount = try boundedNonnegativeInt(page.totalCount.value)
    guard rawCount <= totalCount || totalCount == 0 else {
      throw TiebaClientError.invalidJSON
    }
    let totalPages = try boundedNonnegativeInt(page.totalPage.value)
    guard totalPages == 0 || requestedPage <= totalPages || rawCount == 0 else {
      throw TiebaClientError.invalidJSON
    }
    let users = try relatedUsers(data.users)
    let notice = try boundedText(
      data.notice ?? "",
      maximumBytes: TiebaPublicSocialPolicy.maximumNoticeBytes
    )

    return TiebaUserRelationPage(
      requestedUserID: requestedUserID,
      kind: .followers,
      users: users,
      pagination: TiebaPagination(
        pageSize: declaredPageSize,
        currentPage: requestedPage,
        totalPages: totalPages,
        totalCount: totalCount,
        hasMore: rawCount > 0 && page.hasMore.value == 1,
        hasPrevious: page.hasPrevious.value == 1
      ),
      notice: notice,
      visibilitySwitch: try data.visibilitySwitch.map {
        try boundedNonnegativeInt($0.value)
      }
    )
  }

  private static func relatedUsers(_ payloads: [RelatedUserPayload]) throws -> [TiebaRelatedUser] {
    var users = [TiebaRelatedUser]()
    users.reserveCapacity(payloads.count)
    var seen = Set<Int64>()

    for payload in payloads {
      guard payload.id.value > 0 else { continue }
      let username = try boundedText(
        payload.username ?? "",
        maximumBytes: TiebaPublicSocialPolicy.maximumNameBytes
      )
      let displayName = try boundedText(
        payload.displayName ?? "",
        maximumBytes: TiebaPublicSocialPolicy.maximumNameBytes
      )
      guard !username.isEmpty || !displayName.isEmpty else { continue }
      let portrait = try portraitWithoutQuery(payload.portrait ?? "")
      let introduction = try boundedText(
        payload.introduction ?? "",
        maximumBytes: TiebaPublicSocialPolicy.maximumIntroductionBytes
      )
      guard seen.insert(payload.id.value).inserted else { continue }
      users.append(
        TiebaRelatedUser(
          id: payload.id.value,
          username: username,
          displayName: displayName,
          portrait: portrait,
          introduction: introduction
        )
      )
    }
    return users
  }

  private static func portraitWithoutQuery(_ rawValue: String) throws -> String {
    let portrait = try boundedText(
      rawValue,
      maximumBytes: TiebaPublicSocialPolicy.maximumPortraitBytes
    )
    guard let queryStart = portrait.firstIndex(of: "?") else { return portrait }
    return String(portrait[..<queryStart])
  }

  private static func boundedText(_ rawValue: String, maximumBytes: Int) throws -> String {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard value.utf8.count <= maximumBytes else {
      throw TiebaClientError.invalidJSON
    }
    return value
  }

  private static func boundedNonnegativeInt(_ value: Int64) throws -> Int {
    guard value >= 0, let result = Int(exactly: value) else {
      throw TiebaClientError.invalidJSON
    }
    return result
  }

  private static func decode<Payload: Decodable>(_ body: Data) throws -> Payload {
    do {
      return try JSONDecoder().decode(Payload.self, from: body)
    } catch let error as TiebaClientError {
      throw error
    } catch {
      throw TiebaClientError.invalidJSON
    }
  }

  private static func checkServerError(_ code: Int64, message: String) throws {
    let message = try boundedText(
      message,
      maximumBytes: TiebaPublicSocialPolicy.maximumNoticeBytes
    )
    guard code == 0 else {
      throw TiebaClientError.server(code: Int32(clamping: code), message: message)
    }
  }
}

private struct PublicSocialResponseHeader: Decodable {
  let errorCode: PublicSocialFlexibleInteger
  let errorMessage: String?

  enum CodingKeys: String, CodingKey {
    case errorCode = "error_code"
    case errorMessage = "error_msg"
  }
}

private struct FollowingPayload: Decodable {
  let users: [RelatedUserPayload]
  let page: PublicSocialFlexibleInteger
  let hasMore: PublicSocialFlexibleInteger
  let totalCount: PublicSocialFlexibleInteger
  let visibilitySwitch: PublicSocialFlexibleInteger?
  let notice: String?

  enum CodingKeys: String, CodingKey {
    case users = "follow_list"
    case page = "pn"
    case hasMore = "has_more"
    case totalCount = "total_follow_num"
    case visibilitySwitch = "follow_list_switch"
    case notice = "tips_text"
  }
}

private struct FollowersPayload: Decodable {
  let users: [RelatedUserPayload]
  let page: FollowersPagePayload
  let visibilitySwitch: PublicSocialFlexibleInteger?
  let notice: String?

  enum CodingKeys: String, CodingKey {
    case users = "user_list"
    case page
    case visibilitySwitch = "follow_list_switch"
    case notice = "tips_text"
  }
}

private struct FollowersPagePayload: Decodable {
  let pageSize: PublicSocialFlexibleInteger
  let currentPage: PublicSocialFlexibleInteger
  let totalCount: PublicSocialFlexibleInteger
  let totalPage: PublicSocialFlexibleInteger
  let hasMore: PublicSocialFlexibleInteger
  let hasPrevious: PublicSocialFlexibleInteger

  enum CodingKeys: String, CodingKey {
    case pageSize = "page_size"
    case currentPage = "current_page"
    case totalCount = "total_count"
    case totalPage = "total_page"
    case hasMore = "has_more"
    case hasPrevious = "has_prev"
  }
}

private struct RelatedUserPayload: Decodable {
  let id: PublicSocialFlexibleInteger
  let username: String?
  let displayName: String?
  let portrait: String?
  let introduction: String?

  enum CodingKeys: String, CodingKey {
    case id
    case username = "name"
    case displayName = "name_show"
    case portrait
    case introduction = "intro"
  }
}

private struct PublicSocialFlexibleInteger: Decodable {
  let value: Int64

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let integer = try? container.decode(Int64.self) {
      value = integer
      return
    }
    if let string = try? container.decode(String.self),
      let integer = Int64(string.trimmingCharacters(in: .whitespacesAndNewlines))
    {
      value = integer
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Expected an integer or a decimal integer string."
    )
  }
}
