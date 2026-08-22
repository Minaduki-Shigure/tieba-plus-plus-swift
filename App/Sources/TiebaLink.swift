import Foundation
import SwiftUI
import UIKit

struct TiebaThreadRoute: Hashable, Sendable {
  let threadID: Int64
  let onlyThreadAuthor: Bool
  let postID: Int64?

  init(
    threadID: Int64,
    onlyThreadAuthor: Bool = false,
    postID: Int64? = nil
  ) {
    self.threadID = threadID
    self.onlyThreadAuthor = onlyThreadAuthor
    self.postID = postID.flatMap { $0 > 0 ? $0 : nil }
  }

  var options: ThreadBrowseOptions {
    ThreadBrowseOptions(onlyThreadAuthor: onlyThreadAuthor)
  }

  var placeholderThread: BrowseThread {
    BrowseThread(
      id: threadID,
      forumID: 0,
      forumName: "",
      title: "帖子 \(threadID)",
      excerpt: "",
      authorName: "",
      replyCount: 0,
      viewCount: 0,
      createdAt: nil,
      lastReplyAt: nil,
      contents: []
    )
  }
}

enum TiebaLinkTarget: Hashable, Sendable {
  case forum(String)
  case thread(TiebaThreadRoute)
  case user(Int64)
}

enum TiebaLink {
  static let appScheme = "tieba-plus-plus"
  static let officialHost = "tieba.baidu.com"

  static func canonicalURL(for target: TiebaLinkTarget) -> URL? {
    var components = URLComponents()
    components.scheme = "https"
    components.host = officialHost

    switch target {
    case .forum(let rawName):
      guard let forumName = normalizedForumName(rawName) else { return nil }
      components.path = "/f"
      components.queryItems = [URLQueryItem(name: "kw", value: forumName)]
    case .thread(let route):
      guard route.threadID > 0 else { return nil }
      components.path = "/p/\(route.threadID)"
    case .user:
      return nil
    }
    return urlPreservingLiteralQueryPluses(from: components)
  }

  static func appURL(for target: TiebaLinkTarget) -> URL? {
    var components = URLComponents()
    components.scheme = appScheme

    switch target {
    case .forum(let rawName):
      guard let forumName = normalizedForumName(rawName) else { return nil }
      components.host = "forum"
      components.path = "/\(forumName)"
    case .thread(let route):
      guard route.threadID > 0 else { return nil }
      components.host = "thread"
      components.path = "/\(route.threadID)"
      components.queryItems = threadQueryItems(
        onlyThreadAuthor: route.onlyThreadAuthor ? true : nil,
        postID: route.postID
      )
    case .user(let userID):
      guard userID > 0 else { return nil }
      components.host = "user"
      components.path = "/\(userID)"
    }
    return components.url
  }

  static func target(from text: String) -> TiebaLinkTarget? {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let url = URL(string: text) else { return nil }
    return target(from: url)
  }

  static func target(fromPastedText text: String) -> TiebaLinkTarget? {
    if let exactTarget = target(from: text) {
      return exactTarget
    }
    let targets = Set(
      text.components(separatedBy: .newlines).compactMap { line in
        target(from: line)
      }
    )
    guard targets.count == 1 else { return nil }
    return targets.first
  }

  static func target(from url: URL) -> TiebaLinkTarget? {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil,
      components.password == nil
    else { return nil }

    switch components.scheme?.lowercased() {
    case "https", "http":
      return officialTarget(from: components)
    case "com.baidu.tieba":
      return officialSchemeTarget(from: components)
    case appScheme:
      return appTarget(from: components)
    default:
      return nil
    }
  }

  private static func officialTarget(from components: URLComponents) -> TiebaLinkTarget? {
    let standardPort = components.scheme?.lowercased() == "http" ? 80 : 443
    guard
      components.host?.lowercased() == officialHost,
      components.port == nil || components.port == standardPort
    else { return nil }

    if components.path.lowercased() == "/f" {
      guard components.fragment == nil else { return nil }
      let forumItems = (components.queryItems ?? []).filter { $0.name == "kw" }
      guard
        forumItems.count == 1,
        let rawForumName = forumItems[0].value,
        let forumName = normalizedForumName(rawForumName)
      else {
        return nil
      }
      return .forum(forumName)
    }

    let path = components.path.split(separator: "/", omittingEmptySubsequences: false)
    guard
      path.count == 3,
      path[0].isEmpty,
      path[1].lowercased() == "p",
      let threadID = Int64(path[2]),
      threadID > 0,
      components.fragment == nil || components.fragment == "/"
    else { return nil }
    guard let route = threadRoute(
      threadID: threadID,
      queryItems: components.queryItems ?? [],
      allowsUnknownItems: true
    ) else { return nil }
    return .thread(route)
  }

  private static func officialSchemeTarget(
    from components: URLComponents
  ) -> TiebaLinkTarget? {
    guard
      components.host?.lowercased() == "unidispatch",
      components.port == nil,
      components.fragment == nil
    else { return nil }

    let items = components.queryItems ?? []
    switch components.path.lowercased() {
    case "/frs":
      let forumItems = items.filter { $0.name == "kw" }
      guard
        forumItems.count == 1,
        let rawForumName = forumItems[0].value,
        let forumName = normalizedForumName(rawForumName)
      else {
        return nil
      }
      return .forum(forumName)
    case "/pb":
      let threadIDItems = items.filter { $0.name == "tid" }
      guard
        threadIDItems.count == 1,
        let rawThreadID = threadIDItems[0].value,
        let threadID = Int64(rawThreadID),
        threadID > 0,
        let route = threadRoute(
          threadID: threadID,
          queryItems: items,
          postIDNames: ["pid", "post_id", "hightlight_anchor_pid"],
          allowsUnknownItems: true
        )
      else { return nil }
      return .thread(route)
    default:
      return nil
    }
  }

  private static func appTarget(from components: URLComponents) -> TiebaLinkTarget? {
    guard
      components.port == nil,
      components.fragment == nil,
      let host = components.host?.lowercased()
    else { return nil }

    let path = components.path.split(separator: "/", omittingEmptySubsequences: false)
    guard path.count == 2, path[0].isEmpty else { return nil }

    switch host {
    case "forum":
      guard components.query == nil else { return nil }
      guard let forumName = normalizedForumName(String(path[1])) else { return nil }
      return .forum(forumName)
    case "thread":
      guard let threadID = Int64(path[1]), threadID > 0 else { return nil }
      guard components.query != "" else { return nil }
      guard let route = threadRoute(
        threadID: threadID,
        queryItems: components.queryItems ?? [],
        allowsUnknownItems: false
      ) else { return nil }
      return .thread(route)
    case "user":
      guard components.query == nil else { return nil }
      guard let userID = Int64(path[1]), userID > 0 else { return nil }
      return .user(userID)
    default:
      return nil
    }
  }

  static func threadCopyURL(
    threadID: Int64,
    onlyThreadAuthor: Bool
  ) -> URL? {
    guard
      var components = canonicalURL(for: .thread(TiebaThreadRoute(threadID: threadID)))
        .flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    else { return nil }
    components.queryItems = threadQueryItems(
      onlyThreadAuthor: onlyThreadAuthor,
      postID: nil
    )
    return components.url
  }

  static func shareText(url: URL, title: String) -> String {
    "「\(title)」\n\(url.absoluteString)\n（分享自贴吧++）"
  }

  private static func threadRoute(
    threadID: Int64,
    queryItems: [URLQueryItem],
    postIDNames: Set<String> = ["pid", "post_id"],
    allowsUnknownItems: Bool
  ) -> TiebaThreadRoute? {
    let knownNames = postIDNames.union(["see_lz"])
    guard allowsUnknownItems || queryItems.allSatisfy({ knownNames.contains($0.name) }) else {
      return nil
    }

    let threadAuthorItems = queryItems.filter { $0.name == "see_lz" }
    guard threadAuthorItems.count <= 1 else { return nil }
    let onlyThreadAuthor: Bool
    if threadAuthorItems.isEmpty {
      onlyThreadAuthor = false
    } else {
      guard let rawValue = threadAuthorItems[0].value else { return nil }
      switch rawValue {
      case "0":
        onlyThreadAuthor = false
      case "1":
        onlyThreadAuthor = true
      default:
        return nil
      }
    }

    let postItems = queryItems.filter { postIDNames.contains($0.name) }
    guard postItems.count <= 1 else { return nil }
    let postID: Int64?
    if postItems.isEmpty {
      postID = nil
    } else {
      guard let rawPostID = postItems[0].value else { return nil }
      guard let parsedPostID = Int64(rawPostID), parsedPostID > 0 else { return nil }
      postID = parsedPostID
    }

    return TiebaThreadRoute(
      threadID: threadID,
      onlyThreadAuthor: onlyThreadAuthor,
      postID: postID
    )
  }

  private static func threadQueryItems(
    onlyThreadAuthor: Bool?,
    postID: Int64?
  ) -> [URLQueryItem]? {
    var items: [URLQueryItem] = []
    if let onlyThreadAuthor {
      items.append(URLQueryItem(name: "see_lz", value: onlyThreadAuthor ? "1" : "0"))
    }
    if let postID, postID > 0 {
      items.append(URLQueryItem(name: "pid", value: String(postID)))
    }
    return items.isEmpty ? nil : items
  }

  private static func urlPreservingLiteralQueryPluses(
    from source: URLComponents
  ) -> URL? {
    var components = source
    components.percentEncodedQuery = components.percentEncodedQuery?
      .replacingOccurrences(of: "+", with: "%2B")
    return components.url
  }

  private static func normalizedForumName(_ rawName: String) -> String? {
    let name = rawName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      (1...100).contains(name.count),
      name.rangeOfCharacter(from: .controlCharacters) == nil,
      name.rangeOfCharacter(from: CharacterSet(charactersIn: "/\\")) == nil
    else { return nil }
    return name
  }
}

struct TiebaShareMenu: View {
  let url: URL
  let copyURL: URL?
  let title: String

  init(url: URL, copyURL: URL? = nil, title: String) {
    self.url = url
    self.copyURL = copyURL
    self.title = title
  }

  var body: some View {
    Menu {
      ShareLink(
        item: TiebaLink.shareText(url: url, title: title),
        subject: Text(title)
      ) {
        Label("分享链接", systemImage: "square.and.arrow.up")
      }

      if let copyURL {
        Button {
          UIPasteboard.general.string = copyURL.absoluteString
        } label: {
          Label("复制链接", systemImage: "doc.on.doc")
        }
      }
    } label: {
      Image(systemName: "square.and.arrow.up")
    }
    .accessibilityLabel("分享")
    .help("分享")
  }
}

struct TiebaLinkDestination: View {
  let target: TiebaLinkTarget
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository

  @ViewBuilder
  var body: some View {
    switch target {
    case .forum(let forumName):
      ForumView(
        forumName: forumName,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    case .thread(let route):
      ThreadView(
        thread: route.placeholderThread,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository,
        linkRoute: route
      )
    case .user(let userID):
      UserProfileView(
        userID: userID,
        service: service,
        historyRepository: historyRepository,
        favoritesRepository: favoritesRepository,
        searchHistoryRepository: searchHistoryRepository
      )
    }
  }
}
