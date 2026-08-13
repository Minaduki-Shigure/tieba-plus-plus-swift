import CoreFoundation
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
    let object: [String: Any]
    do {
      guard
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      else {
        throw TiebaClientError.invalidJSON
      }
      object = decoded
    } catch let error as TiebaClientError {
      throw error
    } catch {
      throw TiebaClientError.invalidJSON
    }

    if newThreadHasChallengeSignal(object) {
      throw TiebaClientError.newThreadChallengeRequired(
        message: newThreadErrorMessage(object)
      )
    }
    guard let errorCode = newThreadErrorCode(object) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard errorCode == 0 else {
      throw TiebaClientError.server(
        code: errorCode,
        message: newThreadErrorMessage(object)
      )
    }
    guard
      let threadID = newThreadPositiveInt64(object["tid"]),
      let firstPostID = newThreadPositiveInt64(object["pid"])
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
      let submittedTokens = TiebaClassicEmoticonTokenizer.submissionTokens(
        in: submission.content
      ),
      let readbackTokens = TiebaClassicEmoticonTokenizer.readbackTokens(
        in: firstPost.content,
        maximumUTF8ByteCount: TiebaNewThreadContentPolicy.maximumContentUTF8ByteCount,
        allowsMentions: true
      ),
      readbackTokens == submittedTokens
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return receipt
  }

  private static func newThreadErrorCode(_ object: [String: Any]) -> Int32? {
    if let value = newThreadInt64(object["error_code"]) {
      return Int32(exactly: value)
    }
    if let nested = object["error"] as? [String: Any],
      let value = newThreadInt64(nested["errno"])
    {
      return Int32(exactly: value)
    }
    return nil
  }

  private static func newThreadHasChallengeSignal(_ object: [String: Any]) -> Bool {
    guard let info = object["info"] as? [String: Any] else { return false }
    if newThreadChallengeFlag(info["need_vcode"]) {
      return true
    }
    for key in ["vcode_md5", "vcode_pic_url", "pass_token"] {
      if newThreadChallengeFlag(info[key]) { return true }
    }
    return false
  }

  private static func newThreadChallengeFlag(_ rawValue: Any?) -> Bool {
    guard let rawValue, !(rawValue is NSNull) else { return false }
    if let value = rawValue as? Bool { return value }
    if let text = rawValue as? String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return false }
      return newThreadInt64(trimmed).map { $0 != 0 } ?? true
    }
    return newThreadInt64(rawValue).map { $0 != 0 } ?? true
  }

  private static func newThreadErrorMessage(_ object: [String: Any]) -> String {
    for key in ["msg", "errmsg", "error_msg"] {
      if let value = newThreadBoundedOptionalText(object[key], maximumBytes: 2_048) {
        return value
      }
    }
    if let value = newThreadBoundedOptionalText(object["error"], maximumBytes: 2_048) {
      return value
    }
    if let nested = object["error"] as? [String: Any] {
      for key in ["usermsg", "errmsg"] {
        if let value = newThreadBoundedOptionalText(nested[key], maximumBytes: 2_048) {
          return value
        }
      }
    }
    return ""
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

  private static func newThreadPositiveInt64(_ value: Any?) -> Int64? {
    guard let parsed = newThreadInt64(value), parsed > 0 else { return nil }
    return parsed
  }

  private static func newThreadInt64(_ value: Any?) -> Int64? {
    let text: String
    switch value {
    case let value as String:
      text = value
    case let value as NSNumber where CFGetTypeID(value) != CFBooleanGetTypeID():
      text = value.stringValue
    default:
      return nil
    }
    let bytes = Array(text.utf8)
    let digitStart = bytes.first == 0x2D ? 1 : 0
    guard
      digitStart < bytes.count,
      bytes[digitStart...].allSatisfy({ (0x30...0x39).contains($0) })
    else { return nil }
    return Int64(text)
  }

  private static func newThreadBoundedOptionalText(
    _ rawValue: Any?,
    maximumBytes: Int
  ) -> String? {
    guard let rawValue = rawValue as? String else { return nil }
    let value = rawValue.precomposedStringWithCanonicalMapping
    guard
      !value.isEmpty,
      value.utf8.count <= maximumBytes,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return value
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
