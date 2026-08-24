import Foundation

enum TiebaAppRoute: Hashable, Sendable {
  case search
  case history
  case cloudFavorites
  case batchCheckIn
  case notifications(InboxKind)
}

enum TiebaAppLink {
  static func appURL(for route: TiebaAppRoute) -> URL? {
    var components = URLComponents()
    components.scheme = TiebaLink.appScheme

    switch route {
    case .search:
      components.host = "search"
    case .history:
      components.host = "history"
    case .cloudFavorites:
      components.host = "favorite"
    case .batchCheckIn:
      components.host = "check-in"
    case .notifications(let kind):
      components.host = "notifications"
      switch kind {
      case .replies:
        components.path = "/0"
      case .mentions:
        components.path = "/1"
      }
    }

    return components.url
  }

  static func route(from url: URL) -> TiebaAppRoute? {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == TiebaLink.appScheme,
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.query == nil,
      components.fragment == nil,
      let host = components.host,
      components.encodedHost == host
    else { return nil }

    let route: TiebaAppRoute
    switch (host, components.percentEncodedPath) {
    case ("search", ""):
      route = .search
    case ("history", ""):
      route = .history
    case ("favorite", ""):
      route = .cloudFavorites
    case ("check-in", ""):
      route = .batchCheckIn
    case ("notifications", "/0"):
      route = .notifications(.replies)
    case ("notifications", "/1"):
      route = .notifications(.mentions)
    default:
      return nil
    }

    guard appURL(for: route)?.absoluteString == url.absoluteString else { return nil }
    return route
  }
}
