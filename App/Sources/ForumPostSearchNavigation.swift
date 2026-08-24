import Foundation

enum ForumPostSearchDestination: Hashable, Sendable {
  case thread(thread: BrowseThread, route: TiebaThreadRoute)
  case resolvingComment(threadID: Int64, commentID: Int64)
  case user(Int64)
}

enum ForumPostSearchNavigationPolicy {
  static func primaryDestination(
    for result: ForumPostSearchItem
  ) -> ForumPostSearchDestination? {
    guard result.localVisibility == .visible, result.thread.id > 0 else { return nil }
    switch result.target {
    case .thread:
      return .thread(
        thread: result.thread,
        route: TiebaThreadRoute(threadID: result.thread.id)
      )
    case .post(let postID):
      guard postID > 0 else { return nil }
      return .thread(
        thread: result.thread,
        route: TiebaThreadRoute(threadID: result.thread.id, postID: postID)
      )
    case .comment(_, let commentID):
      guard commentID > 0 else { return nil }
      return .resolvingComment(threadID: result.thread.id, commentID: commentID)
    }
  }

  static func contextDestination(
    for result: ForumPostSearchItem,
    context: ForumPostSearchContext
  ) -> ForumPostSearchDestination? {
    guard
      result.localVisibility == .visible,
      result.thread.id > 0,
      result.contexts.contains(context),
      context.summary.localVisibility == .visible
    else { return nil }

    switch context.target {
    case .mainPost(let threadID):
      guard threadID == result.thread.id else { return nil }
      switch result.target {
      case .post, .comment:
        return .thread(
          thread: result.thread,
          route: TiebaThreadRoute(threadID: threadID)
        )
      case .thread:
        return nil
      }
    case .parentPost(let threadID, let postID):
      guard
        threadID == result.thread.id,
        postID > 0,
        context.summary.postID == postID,
        case .comment(let expectedPostID, _) = result.target,
        expectedPostID == postID
      else { return nil }
      return .thread(
        thread: result.thread,
        route: TiebaThreadRoute(threadID: threadID, postID: postID)
      )
    }
  }

  static func authorDestination(
    for result: ForumPostSearchItem
  ) -> ForumPostSearchDestination? {
    guard result.localVisibility == .visible, result.matchedAuthorID > 0 else { return nil }
    return .user(result.matchedAuthorID)
  }
}
