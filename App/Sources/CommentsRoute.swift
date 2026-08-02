import Foundation

enum CommentsRoute: Hashable, Identifiable, Sendable {
  case post(threadID: Int64, postID: Int64)
  case comment(threadID: Int64, commentID: Int64)

  init?(threadID: Int64, postID: Int64, commentID: Int64?) {
    guard threadID > 0, postID > 0 else { return nil }
    if let commentID {
      guard commentID > 0 else { return nil }
      self = .comment(threadID: threadID, commentID: commentID)
    } else {
      self = .post(threadID: threadID, postID: postID)
    }
  }

  var id: String {
    switch self {
    case .post(let threadID, let postID):
      "post:\(threadID):\(postID)"
    case .comment(let threadID, let commentID):
      "comment:\(threadID):\(commentID)"
    }
  }
}
