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

struct TiebaSubpostDeletionParentContext: Sendable {
  let deletion: TiebaOwnedContentDeletionContext
  let parentPostID: Int64
  let parentAuthorID: Int64
  let parentFloor: Int
  let firstPostID: Int64
  let threadAuthorID: Int64
  let subpostID: Int64
  let subpostAuthorID: Int64
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
    let expectedPostAuthorID: Int64
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
      expectedPostAuthorID = expectedUserID
    case .post(let postID):
      guard postID > 0, postID != response.data.thread.firstPostID else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      targetPostID = postID
      expectedPostAuthorID = expectedUserID
    case .postInOwnedThread(let postID, let postAuthorID, let floor):
      guard
        postID > 0,
        postAuthorID > 0,
        postAuthorID != expectedUserID,
        floor > 1,
        response.data.thread.firstPostID > 0,
        postID != response.data.thread.firstPostID,
        resolvedAuthorID(
          declared: response.data.thread.authorID,
          embedded: response.data.thread.hasAuthor ? response.data.thread.author.id : 0
        ) == expectedUserID
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      var firstFloorPosts = posts.filter {
        $0.id == response.data.thread.firstPostID || $0.floor == 1
      }
      if response.data.hasFirstFloorPost {
        firstFloorPosts.append(response.data.firstFloorPost)
      }
      guard firstFloorPosts.allSatisfy({ firstPost in
        firstPost.id == response.data.thread.firstPostID
          && firstPost.floor == 1
          && (firstPost.tid == 0 || firstPost.tid == threadID)
          && resolvedAuthorID(
            declared: firstPost.authorID,
            embedded: firstPost.hasAuthor ? firstPost.author.id : 0
          ) == expectedUserID
      }) else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      targetPostID = postID
      expectedPostAuthorID = postAuthorID
    case .subpost, .subpostInOwnedThread:
      // A page's inline preview cannot establish the exact nested reply.
      throw TiebaClientError.invalidAuthenticatedResponse
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
      ) == expectedPostAuthorID
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
    case .postInOwnedThread(_, _, let floor):
      guard Int(post.floor) == floor else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    case .subpost, .subpostInOwnedThread:
      throw TiebaClientError.invalidAuthenticatedResponse
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

  static func subpostDeletionParentContext(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaOwnedContentDeletionTarget
  ) throws -> TiebaSubpostDeletionParentContext {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    guard
      expectedUserID > 0, forumID > 0, threadID > 0,
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
      response.data.thread.firstPostID > 0,
      TiebaAuthenticatedRequestFactory.isValidTBS(response.data.anti.tbs),
      let threadAuthorID = resolvedAuthorID(
        declared: response.data.thread.authorID,
        embedded: response.data.thread.hasAuthor ? response.data.thread.author.id : 0
      )
    else { throw TiebaClientError.invalidAuthenticatedResponse }

    let parentPostID: Int64
    let subpostID: Int64
    let subpostAuthorID: Int64
    let expectedParentFloor: Int?
    switch target {
    case .subpost(let parentID, let childID):
      parentPostID = parentID
      subpostID = childID
      subpostAuthorID = expectedUserID
      expectedParentFloor = nil
    case .subpostInOwnedThread(let parentID, let childID, let authorID, let floor):
      guard
        threadAuthorID == expectedUserID,
        authorID > 0, authorID != expectedUserID, floor >= 1
      else { throw TiebaClientError.invalidAuthenticatedResponse }
      parentPostID = parentID
      subpostID = childID
      subpostAuthorID = authorID
      expectedParentFloor = floor
    case .thread, .post, .postInOwnedThread:
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard
      parentPostID > 0,
      subpostID > 0,
      subpostID != parentPostID,
      subpostID != response.data.thread.firstPostID
    else { throw TiebaClientError.invalidAuthenticatedResponse }

    var posts = response.data.postList
    if response.data.hasFirstFloorPost {
      let firstPost = response.data.firstFloorPost
      if let duplicate = posts.first(where: { $0.id == firstPost.id }) {
        guard sameDeletionIdentity(duplicate, firstPost) else {
          throw TiebaClientError.invalidAuthenticatedResponse
        }
      } else {
        posts.append(firstPost)
      }
    }
    guard !posts.contains(where: { $0.id == subpostID }) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    // A located page may omit the first floor. Every first-floor record that
    // is present must nevertheless agree with the verified thread identity.
    var firstFloorPosts = posts.filter {
      $0.id == response.data.thread.firstPostID || $0.floor == 1
    }
    if response.data.hasFirstFloorPost { firstFloorPosts.append(response.data.firstFloorPost) }
    for firstPost in firstFloorPosts {
      guard
        firstPost.id == response.data.thread.firstPostID,
        firstPost.floor == 1,
        firstPost.tid == 0 || firstPost.tid == threadID,
        resolvedAuthorID(
          declared: firstPost.authorID,
          embedded: firstPost.hasAuthor ? firstPost.author.id : 0
        ) == threadAuthorID
      else { throw TiebaClientError.invalidAuthenticatedResponse }
    }
    let matches = posts.filter { $0.id == parentPostID }
    guard
      matches.count == 1,
      let post = matches.first,
      post.floor >= 1,
      (post.floor == 1) == (post.id == response.data.thread.firstPostID),
      expectedParentFloor == nil || expectedParentFloor == Int(post.floor),
      post.tid == 0 || post.tid == threadID,
      let parentAuthorID = resolvedAuthorID(
        declared: post.authorID,
        embedded: post.hasAuthor ? post.author.id : 0
      )
    else { throw TiebaClientError.invalidAuthenticatedResponse }

    return TiebaSubpostDeletionParentContext(
      deletion: TiebaOwnedContentDeletionContext(
        userID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: target,
        tbs: response.data.anti.tbs
      ),
      parentPostID: parentPostID,
      parentAuthorID: parentAuthorID,
      parentFloor: Int(post.floor),
      firstPostID: response.data.thread.firstPostID,
      threadAuthorID: threadAuthorID,
      subpostID: subpostID,
      subpostAuthorID: subpostAuthorID
    )
  }

  static func ownedSubpostDeletionContext(
    from response: PbFloorResIdl,
    parent: TiebaSubpostDeletionParentContext
  ) throws -> TiebaOwnedContentDeletionContext {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    let context = parent.deletion
    let data = response.data
    // PbFloor has no signed-in user field; the preceding authenticated PbPage
    // binds the actor. The same credential reads the exact child and we require
    // the parent/thread identities to match across both fresh responses.
    guard
      response.hasData,
      data.hasForum, data.hasThread, data.hasPost, data.hasPage,
      data.forum.id == context.forumID,
      canonicalForumName(data.forum.name) == context.forumName,
      data.thread.id == context.threadID,
      data.thread.fid == 0 || data.thread.fid == context.forumID,
      data.thread.firstPostID == 0 || data.thread.firstPostID == parent.firstPostID,
      matchesVerifiedAuthorIfPresent(
        declared: data.thread.authorID,
        embedded: data.thread.hasAuthor ? data.thread.author.id : 0,
        expected: parent.threadAuthorID
      ),
      data.post.id == parent.parentPostID,
      Int(data.post.floor) == parent.parentFloor,
      data.post.tid == 0 || data.post.tid == context.threadID,
      matchesVerifiedAuthorIfPresent(
        declared: data.post.authorID,
        embedded: data.post.hasAuthor ? data.post.author.id : 0,
        expected: parent.parentAuthorID
      ),
      data.subpostList.allSatisfy({
        $0.id > 0 && $0.id != parent.parentPostID && $0.id != parent.firstPostID
      }),
      Set(data.subpostList.map(\.id)).count == data.subpostList.count
    else { throw TiebaClientError.invalidAuthenticatedResponse }

    let matches = data.subpostList.filter { $0.id == parent.subpostID }
    guard
      matches.count == 1,
      let subpost = matches.first,
      resolvedAuthorID(
        declared: subpost.authorID,
        embedded: subpost.hasAuthor ? subpost.author.id : 0
      ) == parent.subpostAuthorID
    else { throw TiebaClientError.invalidAuthenticatedResponse }

    // The authenticated parent page always supplies a validated fresh TBS.
    // Prefer a newer token if the exact-child response also supplies Anti.
    let tbs = data.hasAnti ? data.anti.tbs : context.tbs
    guard TiebaAuthenticatedRequestFactory.isValidTBS(tbs) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return TiebaOwnedContentDeletionContext(
      userID: context.userID,
      forumID: context.forumID,
      forumName: context.forumName,
      threadID: context.threadID,
      target: context.target,
      tbs: tbs
    )
  }

  private static func resolvedAuthorID(declared: Int64, embedded: Int64) -> Int64? {
    guard declared >= 0, embedded >= 0 else { return nil }
    guard declared == 0 || embedded == 0 || declared == embedded else { return nil }
    let resolved = declared > 0 ? declared : embedded
    return resolved > 0 ? resolved : nil
  }

  private static func matchesVerifiedAuthorIfPresent(
    declared: Int64, embedded: Int64, expected: Int64
  ) -> Bool {
    // PbFloor can omit metadata already obtained from the authenticated parent
    // page. Missing repeated metadata cannot grant authority, while any value
    // actually returned must agree with that fresh, verified parent context.
    if declared == 0, embedded == 0 { return true }
    return resolvedAuthorID(declared: declared, embedded: embedded) == expected
  }

  private static func sameDeletionIdentity(_ lhs: Post, _ rhs: Post) -> Bool {
    lhs.id == rhs.id
      && lhs.tid == rhs.tid
      && lhs.floor == rhs.floor
      && resolvedAuthorID(
        declared: lhs.authorID,
        embedded: lhs.hasAuthor ? lhs.author.id : 0
      )
        == resolvedAuthorID(
          declared: rhs.authorID,
          embedded: rhs.hasAuthor ? rhs.author.id : 0
        )
  }

  private static func canonicalForumName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }
}
