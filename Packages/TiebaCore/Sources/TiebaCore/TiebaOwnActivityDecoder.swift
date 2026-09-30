import Foundation
import TiebaProto

enum TiebaOwnActivityDecoder {
  static let maximumGroups = 100
  static let maximumRepliesPerGroup = 100

  static func threads(
    from response: UserPostResIdl,
    expectedUserID: Int64,
    page: Int,
    pageSize: Int
  ) throws -> TiebaUserThreadPage {
    let data = try validatedData(response, expectedUserID: expectedUserID)
    guard data.postList.allSatisfy({ $0.userID == 0 || $0.userID == expectedUserID }) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return TiebaProtoMapper.userThreadPage(
      data, userID: expectedUserID, requestedPage: page, pageSize: pageSize
    )
  }

  static func replies(
    from response: UserPostResIdl,
    expectedUserID: Int64,
    page: Int,
    pageSize: Int
  ) throws -> TiebaUserReplyPage {
    let data = try validatedData(response, expectedUserID: expectedUserID)
    for group in data.postList {
      guard group.content.count <= maximumRepliesPerGroup else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      for item in group.content {
        guard
          let postID = Int64(exactly: item.postID), postID > 0,
          Int64(exactly: item.createTime) != nil
        else { throw TiebaClientError.invalidAuthenticatedResponse }
      }
    }
    return TiebaProtoMapper.userReplyPage(
      data, userID: expectedUserID, requestedPage: page, pageSize: pageSize,
      usesAuthenticatedThreadCardContext: true
    )
  }

  private static func validatedData(
    _ response: UserPostResIdl,
    expectedUserID: Int64
  ) throws -> UserPostResIdl.DataRes {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno, message: response.error.errmsg
      )
    }
    guard
      expectedUserID > 0, response.hasData,
      response.data.postList.count <= maximumGroups
    else { throw TiebaClientError.invalidAuthenticatedResponse }
    for group in response.data.postList {
      guard
        let threadID = Int64(exactly: group.threadID), threadID > 0,
        Int64(exactly: group.forumID) != nil,
        Int64(exactly: group.postID) != nil
      else { throw TiebaClientError.invalidAuthenticatedResponse }
    }
    return response.data
  }
}
