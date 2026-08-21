import Foundation
import TiebaProto

struct TiebaTextReplyContext:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let userID: Int64
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let target: TiebaTextReplyTarget
  let tbs: String
  let accountDisplayName: String
  let replyUserID: Int64?
  let replyUserDisplayName: String?
  let replyUserPortrait: String?

  var description: String { "TiebaTextReplyContext(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "userID": userID,
        "forumID": forumID,
        "threadID": threadID,
        "target": target,
      ],
      displayStyle: .struct
    )
  }
}

extension TiebaAuthenticatedDecoder {
  static func textReplyPageContext(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaTextReplyTarget
  ) throws -> TiebaTextReplyContext {
    try checkTextReplyPageEnvelope(
      response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      requiresTBS: true
    )

    let accountDisplayName = try boundedRequiredText(
      response.data.user.nameShow.isEmpty
        ? response.data.user.name
        : response.data.user.nameShow,
      maximumBytes: 512
    )
    let targetPostID: Int64
    switch target {
    case .thread(let firstPostID):
      guard response.data.thread.firstPostID == firstPostID else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      targetPostID = firstPostID
    case .post(let postID):
      targetPostID = postID
    case .subpost(let parentPostID, _):
      targetPostID = parentPostID
    }
    let post = try uniqueTextReplyPost(
      id: targetPostID,
      in: response.data,
      threadID: threadID
    )
    switch target {
    case .thread:
      guard post.floor == 1 else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    case .post:
      guard isValidTextReplyParent(
        post,
        firstPostID: response.data.thread.firstPostID,
        allowsFirstPost: false
      ) else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    case .subpost:
      guard isValidTextReplyParent(
        post,
        firstPostID: response.data.thread.firstPostID,
        allowsFirstPost: true
      ) else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    }

    let replyUser: TextReplyUserIdentity?
    switch target {
    case .thread:
      replyUser = nil
    case .post:
      replyUser = try textReplyUserIdentity(
        authorID: post.authorID,
        author: post.hasAuthor ? post.author : nil,
        requiresPresentation: false
      )
    case .subpost:
      replyUser = nil
    }

    return TiebaTextReplyContext(
      userID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: target,
      tbs: response.data.anti.tbs,
      accountDisplayName: accountDisplayName,
      replyUserID: replyUser?.id,
      replyUserDisplayName: nil,
      replyUserPortrait: nil
    )
  }

  static func textReplySubpostContext(
    from response: PbFloorResIdl,
    parentContext: TiebaTextReplyContext,
    subpostID: Int64
  ) throws -> TiebaTextReplyContext {
    guard case .subpost(let parentPostID, let expectedSubpostID) = parentContext.target,
      expectedSubpostID == subpostID
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: preferredErrorMessage(response.error)
      )
    }
    guard
      response.hasData,
      response.data.hasForum,
      response.data.hasThread,
      response.data.hasPost,
      response.data.hasPage,
      response.data.hasAnti,
      response.data.forum.id == parentContext.forumID,
      textReplyCanonicalForumName(response.data.forum.name) == parentContext.forumName,
      response.data.thread.id == parentContext.threadID,
      response.data.thread.fid == 0 || response.data.thread.fid == parentContext.forumID,
      response.data.post.id == parentPostID,
      isValidTextReplyParent(
        response.data.post,
        firstPostID: response.data.thread.firstPostID,
        allowsFirstPost: true
      ),
      response.data.post.tid == 0 || response.data.post.tid == parentContext.threadID,
      TiebaAuthenticatedRequestFactory.isValidTBS(response.data.anti.tbs)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let matches = response.data.subpostList.filter { $0.id == subpostID }
    guard matches.count == 1, let subpost = matches.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let replyUser = try textReplyUserIdentity(
      authorID: subpost.authorID,
      author: subpost.hasAuthor ? subpost.author : nil,
      requiresPresentation: true
    )
    return TiebaTextReplyContext(
      userID: parentContext.userID,
      forumID: parentContext.forumID,
      forumName: parentContext.forumName,
      threadID: parentContext.threadID,
      target: parentContext.target,
      tbs: response.data.anti.tbs,
      accountDisplayName: parentContext.accountDisplayName,
      replyUserID: replyUser.id,
      replyUserDisplayName: replyUser.displayName,
      replyUserPortrait: replyUser.portrait
    )
  }

  static func textReplyReceipt(
    from body: Data,
    submission: TiebaTextReplySubmission
  ) throws -> TiebaTextReplyReceipt {
    let response: AddPostResIdl
    do {
      response = try AddPostResIdl(serializedBytes: body)
    } catch {
      throw TiebaClientError.invalidProtobuf
    }
    if let message = textReplyChallengeMessage(response) {
      throw TiebaClientError.replyChallengeRequired(message: message)
    }
    guard response.hasError else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: preferredErrorMessage(response.error)
      )
    }
    guard
      response.hasData,
      let responseThreadID = textReplyDecimalInt64(response.data.tid),
      responseThreadID == submission.threadID,
      let responsePostID = textReplyDecimalInt64(response.data.pid),
      responsePostID > 0
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    switch submission.target {
    case .thread:
      return .post(postID: responsePostID)
    case .post(let parentPostID), .subpost(let parentPostID, _):
      return .subpost(parentPostID: parentPostID, subpostID: responsePostID)
    }
  }

  static func verifiedTextReplyPost(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    postID: Int64,
    content: String
  ) throws -> TiebaCreatedReply? {
    try verifiedTextReplyPost(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      postID: postID,
      content: content,
      imageProofs: [],
      submissionID: UUID()
    )
  }

  static func verifiedTextReplyPost(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    postID: Int64,
    submission: TiebaTextReplySubmission
  ) throws -> TiebaCreatedReply? {
    guard
      submission.forumID == forumID,
      submission.threadID == threadID,
      textReplyCanonicalForumName(submission.forumName) == forumName,
      case .thread = submission.target
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return try verifiedTextReplyPost(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      postID: postID,
      content: submission.content,
      imageProofs: submission.imageProofs,
      submissionID: submission.submissionID
    )
  }

  private static func verifiedTextReplyPost(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    postID: Int64,
    content: String,
    imageProofs: [TiebaStaticImageContentProof],
    submissionID: UUID
  ) throws -> TiebaCreatedReply? {
    try checkTextReplyPageEnvelope(
      response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      requiresTBS: false
    )
    let matches = textReplyPosts(in: response.data).filter { $0.id == postID }
    guard !matches.isEmpty else { return nil }
    guard matches.count == 1, let post = matches.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard
      post.floor > 1,
      post.tid == 0 || post.tid == threadID,
      try textReplyUserIdentity(
        authorID: post.authorID,
        author: post.hasAuthor ? post.author : nil,
        requiresPresentation: false
      ).id == expectedUserID
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard
      TiebaStaticImageContentCompiler.readbackMatches(
        post.content,
        userContent: content,
        imageProofs: imageProofs,
        submissionID: submissionID,
        expectedUserID: expectedUserID,
        forumID: forumID,
        normalizedForumName: forumName,
        maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount,
        allowsMentions: true
      )
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return .post(postID: postID, floor: Int(post.floor))
  }

  static func verifiedTextReplySubpost(
    from response: PbFloorResIdl,
    context: TiebaTextReplyContext,
    newSubpostID: Int64,
    content: String
  ) throws -> TiebaCreatedReply? {
    let parentPostID: Int64
    let quotedSubpostID: Int64?
    let allowsFirstPostParent: Bool
    switch context.target {
    case .post(let postID):
      parentPostID = postID
      quotedSubpostID = nil
      allowsFirstPostParent = false
    case .subpost(let postID, let subpostID):
      parentPostID = postID
      quotedSubpostID = subpostID
      allowsFirstPostParent = true
    case .thread:
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: preferredErrorMessage(response.error)
      )
    }
    guard
      response.hasData,
      response.data.hasForum,
      response.data.hasThread,
      response.data.hasPost,
      response.data.hasPage,
      response.data.forum.id == context.forumID,
      textReplyCanonicalForumName(response.data.forum.name) == context.forumName,
      response.data.thread.id == context.threadID,
      response.data.thread.fid == 0 || response.data.thread.fid == context.forumID,
      response.data.post.id == parentPostID,
      isValidTextReplyParent(
        response.data.post,
        firstPostID: response.data.thread.firstPostID,
        allowsFirstPost: allowsFirstPostParent
      ),
      response.data.post.tid == 0 || response.data.post.tid == context.threadID
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let matches = response.data.subpostList.filter { $0.id == newSubpostID }
    guard !matches.isEmpty else { return nil }
    guard matches.count == 1, let subpost = matches.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let author = try textReplyUserIdentity(
      authorID: subpost.authorID,
      author: subpost.hasAuthor ? subpost.author : nil,
      requiresPresentation: false
    )
    guard author.id == context.userID else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    if let quotedSubpostID {
      guard
        quotedSubpostID > 0,
        let replyUserID = context.replyUserID,
        nestedReplyBodyMatches(
          subpost.content,
          replyUserID: replyUserID,
          content: content
        )
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    } else {
      guard
        let submittedTokens = TiebaClassicEmoticonTokenizer.submissionTokens(in: content),
        let readbackTokens = TiebaClassicEmoticonTokenizer.readbackTokens(
          in: subpost.content,
          maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount,
          allowsMentions: true
        ),
        readbackTokens == submittedTokens
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    }
    return .subpost(parentPostID: parentPostID, subpostID: newSubpostID)
  }

  private struct TextReplyUserIdentity {
    let id: Int64
    let displayName: String
    let portrait: String
  }

  private static func checkTextReplyPageEnvelope(
    _ response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    requiresTBS: Bool
  ) throws {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: preferredErrorMessage(response.error)
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
      response.data.user.isLogin == 1,
      response.data.user.id == expectedUserID,
      response.data.forum.id == forumID,
      textReplyCanonicalForumName(response.data.forum.name) == forumName,
      response.data.thread.id == threadID,
      response.data.thread.fid == 0 || response.data.thread.fid == forumID,
      !requiresTBS
        || (response.data.hasAnti
          && TiebaAuthenticatedRequestFactory.isValidTBS(response.data.anti.tbs))
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
  }

  private static func uniqueTextReplyPost(
    id: Int64,
    in data: PbPageResIdl.DataRes,
    threadID: Int64
  ) throws -> Post {
    let matches = textReplyPosts(in: data).filter { $0.id == id }
    guard matches.count == 1, let post = matches.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard post.floor >= 1, post.tid == 0 || post.tid == threadID else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return post
  }

  private static func isValidTextReplyParent(
    _ post: Post,
    firstPostID: Int64,
    allowsFirstPost: Bool
  ) -> Bool {
    guard firstPostID > 0 else { return false }
    if post.id == firstPostID {
      return allowsFirstPost && post.floor == 1
    }
    return post.floor > 1
  }

  private static func textReplyPosts(in data: PbPageResIdl.DataRes) -> [Post] {
    var posts = data.postList
    if data.hasFirstFloorPost,
      !posts.contains(where: { $0.id == data.firstFloorPost.id })
    {
      posts.append(data.firstFloorPost)
    }
    return posts
  }

  private static func textReplyUserIdentity(
    authorID: Int64,
    author: User?,
    requiresPresentation: Bool
  ) throws -> TextReplyUserIdentity {
    let nestedID = author?.id ?? 0
    guard authorID == 0 || nestedID == 0 || authorID == nestedID else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let id = authorID > 0 ? authorID : nestedID
    guard id > 0 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let displayName: String
    let portrait: String
    if let author {
      let rawName = author.nameShow.isEmpty ? author.name : author.nameShow
      if requiresPresentation {
        displayName = try boundedRequiredText(rawName, maximumBytes: 512)
      } else {
        displayName = boundedOptionalText(rawName, maximumBytes: 512) ?? ""
      }
      if requiresPresentation {
        portrait = try boundedRequiredText(author.portrait, maximumBytes: 2_048)
      } else {
        portrait = boundedOptionalText(author.portrait, maximumBytes: 2_048) ?? ""
      }
    } else {
      guard !requiresPresentation else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      displayName = ""
      portrait = ""
    }
    return TextReplyUserIdentity(id: id, displayName: displayName, portrait: portrait)
  }

  private static func textReplyChallengeMessage(_ response: AddPostResIdl) -> String? {
    guard response.hasData else { return nil }
    let data = response.data
    let info = data.info
    let hasPostAntiSignal = data.hasInfo
      && (info.hasAccessState
        || !info.confilterHitwords.isEmpty
        || nonzeroFlag(info.needVcode)
        || !info.vcodeMd5.isEmpty
        || !info.vcodePrevType.isEmpty
        || !info.vcodeType.isEmpty
        || !info.passToken.isEmpty
        || !info.blockContent.isEmpty
        || !info.blockCancel.isEmpty
        || !info.blockConfirm.isEmpty
        || !info.vcodePicURL.isEmpty
        || (info.hasVcodeExtra && hasVcodeExtraSignal(info.vcodeExtra)))
    let antiStat = data.antiStat
    let hasAntiStatSignal = data.hasAntiStat
      && (antiStat.forbidFlag != 0
        || !antiStat.forbidInfo.isEmpty
        || antiStat.blockStat != 0
        || antiStat.hideStat != 0
        || antiStat.vcodeStat != 0)
    let anti = data.anti
    let hasVcodeSignal = data.hasAnti
      && (!anti.vcodeMd5.isEmpty
        || !anti.vcodePicURL.isEmpty
        || !anti.vcodeType.isEmpty
        || (anti.hasVcodeExtra && hasVcodeExtraSignal(anti.vcodeExtra)))
    guard hasPostAntiSignal || hasAntiStatSignal || hasVcodeSignal else { return nil }

    for candidate in [
      info.blockContent,
      antiStat.forbidInfo,
      response.error.userMsg,
      response.error.errmsg,
      data.extMsg,
      data.msg,
      data.preMsg,
      data.colorMsg,
    ] {
      if let message = boundedOptionalText(candidate, maximumBytes: 2_048), !message.isEmpty {
        return message
      }
    }
    if data.hasToast {
      for item in data.toast.content {
        if let message = boundedOptionalText(item.text, maximumBytes: 2_048), !message.isEmpty {
          return message
        }
      }
    }
    return "Tieba requires additional verification before this reply can be submitted."
  }

  private static func preferredErrorMessage(_ error: TiebaProto.Error) -> String {
    for candidate in [error.userMsg, error.errmsg] {
      if let message = boundedOptionalText(candidate, maximumBytes: 2_048), !message.isEmpty {
        return message
      }
    }
    return ""
  }

  private static func nestedReplyBodyMatches(
    _ fragments: [PbContent],
    replyUserID: Int64,
    content: String
  ) -> Bool {
    guard fragments.count >= 3 else { return false }
    let prefix = fragments[0]
    let mention = fragments[1]
    guard
      [UInt32(0), UInt32(9), UInt32(18), UInt32(27), UInt32(40)].contains(prefix.type),
      prefix.text.trimmingCharacters(in: .whitespacesAndNewlines) == "回复",
      mention.type == 4,
      mention.uid == replyUserID
    else { return false }

    let suffixFragments = Array(fragments.dropFirst(2))
    guard !suffixFragments.contains(where: { $0.type == 4 }) else { return false }
    guard
      let submittedTokens = TiebaClassicEmoticonTokenizer.submissionTokens(in: content),
      let suffixTokens = TiebaClassicEmoticonTokenizer.readbackTokens(
        in: suffixFragments,
        maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount + 2
      ),
      let bodyTokens = TiebaClassicEmoticonTokenizer.droppingNestedReplySeparator(
        from: suffixTokens
      )
    else { return false }
    return bodyTokens == submittedTokens
  }

  private static func hasVcodeExtraSignal(_ extra: VcodeExtra) -> Bool {
    !extra.textimg.isEmpty
      || !extra.slideimg.isEmpty
      || !extra.endpoint.isEmpty
      || !extra.successimg.isEmpty
      || !extra.slideendpoint.isEmpty
  }

  private static func nonzeroFlag(_ value: String) -> Bool {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !value.isEmpty && value != "0"
  }

  private static func boundedRequiredText(
    _ rawValue: String,
    maximumBytes: Int
  ) throws -> String {
    guard let value = boundedOptionalText(rawValue, maximumBytes: maximumBytes), !value.isEmpty else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return value
  }

  private static func boundedOptionalText(
    _ rawValue: String,
    maximumBytes: Int
  ) -> String? {
    let value = rawValue.precomposedStringWithCanonicalMapping
    guard
      value.utf8.count <= maximumBytes,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return value
  }

  private static func textReplyCanonicalForumName(_ rawValue: String) -> String {
    rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }

  private static func textReplyDecimalInt64(_ value: String) -> Int64? {
    guard !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
      return nil
    }
    return Int64(value)
  }
}
