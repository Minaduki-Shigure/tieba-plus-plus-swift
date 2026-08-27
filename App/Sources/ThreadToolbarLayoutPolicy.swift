import SwiftUI

enum ThreadToolbarLayoutMode: Equatable, Sendable {
  case compact
  case expanded
}

enum ThreadToolbarPrimaryAction: Equatable, Sendable {
  case readingMode
  case share
  case localFavorite
  case cloudFavorite
  case more
}

enum ThreadToolbarLayoutPolicy {
  static func mode(
    horizontalSizeClass: UserInterfaceSizeClass?,
    dynamicTypeSize: DynamicTypeSize
  ) -> ThreadToolbarLayoutMode {
    guard
      horizontalSizeClass == .regular,
      !AppDynamicTypeLayout.prefersExpandedControls(for: dynamicTypeSize)
    else {
      return .compact
    }
    return .expanded
  }

  static func primaryActions(
    for mode: ThreadToolbarLayoutMode
  ) -> [ThreadToolbarPrimaryAction] {
    switch mode {
    case .compact:
      [.share, .more]
    case .expanded:
      [.readingMode, .share, .localFavorite, .cloudFavorite, .more]
    }
  }
}
