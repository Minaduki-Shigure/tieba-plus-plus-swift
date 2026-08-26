import Foundation

enum AccountHubItem: String, CaseIterable, Hashable, Identifiable, Sendable {
  case localFavorites = "local-favorites"
  case history
  case appearance
  case settings
  case about

  var id: Self { self }

  var title: String {
    switch self {
    case .localFavorites:
      "本机收藏"
    case .history:
      "浏览记录"
    case .appearance:
      "外观"
    case .settings:
      "设置"
    case .about:
      "关于贴吧++"
    }
  }

  var systemImage: String {
    switch self {
    case .localFavorites:
      "bookmark"
    case .history:
      "clock.arrow.circlepath"
    case .appearance:
      "circle.lefthalf.filled"
    case .settings:
      "gearshape"
    case .about:
      "info.circle"
    }
  }

  var accessibilityIdentifier: String {
    "account-hub-\(rawValue)"
  }

  var destination: RootDestination? {
    switch self {
    case .localFavorites:
      .favorites
    case .history:
      .history
    case .appearance:
      nil
    case .settings:
      .settings
    case .about:
      .about
    }
  }
}
