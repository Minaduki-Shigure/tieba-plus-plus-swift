import Foundation
import TiebaProto

struct TiebaNewThreadContext:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let userID: Int64
  let forumID: Int64
  let forumName: String
  let tbs: String
  let accountDisplayName: String

  var description: String { "TiebaNewThreadContext(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "userID": userID,
        "forumID": forumID,
      ],
      displayStyle: .struct
    )
  }
}

extension TiebaAuthenticatedDecoder {
  static func newThreadContext(
    from response: FrsPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) throws -> TiebaNewThreadContext {
    let membership = try forumMembership(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName
    )
    guard response.data.user.isLogin == 1 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let rawDisplayName =
      response.data.user.nameShow.isEmpty
      ? response.data.user.name
      : response.data.user.nameShow
    let displayName = try newThreadRequiredText(rawDisplayName, maximumBytes: 512)
    return TiebaNewThreadContext(
      userID: expectedUserID,
      forumID: forumID,
      forumName: membership.membership.forumName,
      tbs: membership.tbs,
      accountDisplayName: displayName
    )
  }

  static func newThreadReceipt(
    from body: Data,
    submission: TiebaNewThreadSubmission
  ) throws -> TiebaNewThreadReceipt {
    let response: AddThreadResIdl
    do {
      response = try AddThreadResIdl(serializedBytes: body)
    } catch {
      throw TiebaClientError.invalidProtobuf
    }
    let data = response.data
    if response.hasData,
      let message = creationChallengeMessage(
        info: data.hasInfo ? data.info : nil,
        antiStat: data.hasAntiStat ? data.antiStat : nil,
        anti: data.hasAnti ? data.anti : nil,
        error: response.error,
        messages: [data.extMsg, data.msg, data.preMsg, data.colorMsg],
        toast: data.hasToast ? data.toast : nil,
        fallback: "Tieba requires additional verification before this topic can be submitted."
      )
    {
      throw TiebaClientError.newThreadChallengeRequired(message: message)
    }
    guard response.hasError else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: newThreadProtoErrorMessage(response.error)
      )
    }
    guard
      response.hasData,
      let threadID = newThreadPositiveInt64(data.tid),
      let firstPostID = newThreadPositiveInt64(data.pid)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let receipt = TiebaNewThreadReceipt(threadID: threadID, firstPostID: firstPostID)
    guard receipt.isValid else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return receipt
  }

  static func verifiedNewThread(
    from response: PbPageResIdl,
    context: TiebaNewThreadContext,
    submission: TiebaNewThreadSubmission,
    receipt: TiebaNewThreadReceipt
  ) throws -> TiebaNewThreadReceipt? {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: newThreadProtoErrorMessage(response.error)
      )
    }
    guard
      receipt.isValid,
      response.hasData,
      response.data.hasUser,
      response.data.hasForum,
      response.data.hasThread,
      response.data.hasPage,
      response.data.user.isLogin == 1,
      response.data.user.id == context.userID,
      response.data.forum.id == context.forumID,
      newThreadCanonicalForumName(response.data.forum.name) == context.forumName,
      response.data.thread.id == receipt.threadID,
      response.data.thread.fid == 0 || response.data.thread.fid == context.forumID,
      response.data.thread.firstPostID == receipt.firstPostID,
      newThreadAuthorID(
        directID: response.data.thread.authorID,
        nested: response.data.thread.hasAuthor ? response.data.thread.author : nil
      ) == context.userID
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let submittedTitle = submission.title.precomposedStringWithCanonicalMapping
    if !submittedTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      guard response.data.thread.title.precomposedStringWithCanonicalMapping == submittedTitle
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    }

    var posts = response.data.postList
    if response.data.hasFirstFloorPost,
      !posts.contains(where: { $0.id == response.data.firstFloorPost.id })
    {
      posts.append(response.data.firstFloorPost)
    }
    let matches = posts.filter { $0.id == receipt.firstPostID }
    guard !matches.isEmpty else { return nil }
    guard matches.count == 1, let firstPost = matches.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard
      firstPost.floor == 1,
      firstPost.tid == 0 || firstPost.tid == receipt.threadID,
      newThreadAuthorID(
        directID: firstPost.authorID,
        nested: firstPost.hasAuthor ? firstPost.author : nil
      ) == context.userID,
      TiebaStaticImageContentCompiler.readbackMatches(
        firstPost.content,
        userContent: submission.content,
        imageProofs: submission.imageProofs,
        submissionID: submission.submissionID,
        expectedUserID: context.userID,
        forumID: context.forumID,
        normalizedForumName: context.forumName,
        maximumUTF8ByteCount: TiebaNewThreadContentPolicy.maximumContentUTF8ByteCount,
        allowsMentions: true
      )
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return receipt
  }

  private static func newThreadProtoErrorMessage(_ error: TiebaProto.Error) -> String {
    for candidate in [error.userMsg, error.errmsg] {
      let value = candidate.precomposedStringWithCanonicalMapping
      if !value.isEmpty,
        value.utf8.count <= 2_048,
        !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
      {
        return value
      }
    }
    return ""
  }

  private static func newThreadPositiveInt64(_ value: String) -> Int64? {
    guard
      !value.isEmpty,
      value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
      let parsed = Int64(value), parsed > 0
    else { return nil }
    return parsed
  }

  private static func newThreadRequiredText(
    _ rawValue: String,
    maximumBytes: Int
  ) throws -> String {
    let value = rawValue.precomposedStringWithCanonicalMapping
    guard
      !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      value.utf8.count <= maximumBytes,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return value
  }

  private static func newThreadCanonicalForumName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }

  private static func newThreadAuthorID(directID: Int64, nested: User?) -> Int64? {
    let nestedID = nested?.id ?? 0
    guard directID == 0 || nestedID == 0 || directID == nestedID else { return nil }
    let resolved = directID > 0 ? directID : nestedID
    return resolved > 0 ? resolved : nil
  }
}
