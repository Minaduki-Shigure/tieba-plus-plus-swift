import Foundation
import TiebaProto

enum TiebaThreadIdentityDecoder {
  static func identity(
    from response: PbPageResIdl,
    expectedThreadID: Int64,
    expectedForumName: String
  ) throws -> TiebaThreadIdentity {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    guard
      expectedThreadID > 0,
      response.hasData,
      response.data.hasForum,
      response.data.hasThread
    else { throw TiebaClientError.invalidProtobuf }

    let forum = response.data.forum
    let thread = response.data.thread
    let forumName = canonicalForumName(forum.name)
    let threadForumName = canonicalForumName(thread.fname)
    let rawExpectedForumName = expectedForumName
    let expectedForumName = canonicalForumName(rawExpectedForumName)
    guard
      thread.id == expectedThreadID,
      forum.id > 0,
      thread.fid == 0 || thread.fid == forum.id,
      !forumName.isEmpty,
      forumName.count <= 100,
      !forum.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !forumName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !thread.fname.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !rawExpectedForumName.unicodeScalars.contains(
        where: CharacterSet.controlCharacters.contains
      ),
      threadForumName.isEmpty || threadForumName == forumName,
      expectedForumName.isEmpty || expectedForumName == forumName
    else { throw TiebaClientError.invalidProtobuf }

    return TiebaThreadIdentity(
      threadID: expectedThreadID,
      forumID: forum.id,
      forumName: forumName
    )
  }

  private static func canonicalForumName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }
}
