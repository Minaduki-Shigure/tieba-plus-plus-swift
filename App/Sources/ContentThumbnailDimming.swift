import SwiftUI

enum ContentThumbnailDimmingDecision {
  static let darkModeMultiplier = 0.4

  static func multiplier(isDarkMode: Bool, isEnabled: Bool) -> Double {
    isDarkMode && isEnabled ? darkModeMultiplier : 1
  }
}

private struct ContentThumbnailDimmingModifier: ViewModifier {
  let applies: Bool

  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.darkensContentThumbnailsInDarkMode) private var isEnabled

  func body(content: Content) -> some View {
    let multiplier = ContentThumbnailDimmingDecision.multiplier(
      isDarkMode: colorScheme == .dark,
      isEnabled: isEnabled && applies
    )
    content.colorMultiply(Color(white: multiplier))
  }
}

extension View {
  func contentThumbnailDimming(applies: Bool = true) -> some View {
    modifier(ContentThumbnailDimmingModifier(applies: applies))
  }
}
