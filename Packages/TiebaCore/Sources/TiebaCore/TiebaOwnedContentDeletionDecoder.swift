import Foundation
import TiebaProto

struct TiebaOwnedContentDeletionContext: Sendable {
  let userID: Int64
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let target: TiebaOwnedContentDeletionTarget
  let tbs: String
}

extension TiebaAuthenticatedDecoder {
  static func ownedContentDeletionContext(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaOwnedContentDeletionTarget
  ) throws -> TiebaOwnedContentDeletionContext {
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
      response.data.hasPage,
      response.data.hasAnti,
      response.data.user.isLogin == 1,
      response.data.user.id == expectedUserID,
      response.data.forum.id == forumID,
      canonicalForumName(response.data.forum.name) == forumName,
      response.data.thread.id == threadID,
      response.data.thread.fid == 0 || response.data.thread.fid == forumID,
      TiebaAuthenticatedRequestFactory.isValidTBS(response.data.anti.tbs)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    var posts = response.data.postList
    if response.data.hasFirstFloorPost {
      let firstFloorPost = response.data.firstFloorPost
      if let duplicate = posts.first(where: { $0.id == firstFloorPost.id }) {
        guard sameDeletionIdentity(duplicate, firstFloorPost) else {
          throw TiebaClientError.invalidAuthenticatedResponse
        }
      } else {
        posts.append(firstFloorPost)
      }
    }

    let targetPostID: Int64
    switch target {
    case .thread(let firstPostID):
      guard
        firstPostID > 0,
        response.data.thread.firstPostID == firstPostID,
        resolvedAuthorID(
          declared: response.data.thread.authorID,
          embedded: response.data.thread.hasAuthor ? response.data.thread.author.id : 0
        ) == expectedUserID
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      targetPostID = firstPostID
    case .post(let postID):
      guard postID > 0, postID != response.data.thread.firstPostID else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      targetPostID = postID
    }

    let matches = posts.filter { $0.id == targetPostID }
    guard matches.count == 1, let post = matches.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard
      post.tid == 0 || post.tid == threadID,
      resolvedAuthorID(
        declared: post.authorID,
        embedded: post.hasAuthor ? post.author.id : 0
      ) == expectedUserID
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    switch target {
    case .thread:
      guard post.floor == 1 else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    case .post:
      guard post.floor > 1 else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    }

    return TiebaOwnedContentDeletionContext(
      userID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: target,
      tbs: response.data.anti.tbs
    )
  }

  private static func resolvedAuthorID(declared: Int64, embedded: Int64) -> Int64? {
    guard declared >= 0, embedded >= 0 else { return nil }
    guard declared == 0 || embedded == 0 || declared == embedded else { return nil }
    let resolved = declared > 0 ? declared : embedded
    return resolved > 0 ? resolved : nil
  }

  private static func sameDeletionIdentity(_ lhs: Post, _ rhs: Post) -> Bool {
    lhs.id == rhs.id
      && lhs.tid == rhs.tid
      && lhs.floor == rhs.floor
      && resolvedAuthorID(
        declared: lhs.authorID,
        embedded: lhs.hasAuthor ? lhs.author.id : 0
      ) == resolvedAuthorID(
        declared: rhs.authorID,
        embedded: rhs.hasAuthor ? rhs.author.id : 0
      )
  }

  private static func canonicalForumName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }
}
