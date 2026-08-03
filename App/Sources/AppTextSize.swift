import SwiftUI

enum AppDynamicTypeSizeResolver {
  private static let orderedSizes: [DynamicTypeSize] = [
    .xSmall,
    .small,
    .medium,
    .large,
    .xLarge,
    .xxLarge,
    .xxxLarge,
    .accessibility1,
    .accessibility2,
    .accessibility3,
    .accessibility4,
    .accessibility5,
  ]

  static func resolvedSize(
    systemSize: DynamicTypeSize,
    adjustment: AppTextSizeAdjustment
  ) -> DynamicTypeSize {
    guard
      adjustment != .standard,
      let systemIndex = orderedSizes.firstIndex(of: systemSize)
    else {
      return systemSize
    }

    let targetIndex = systemIndex + adjustment.rawValue
    let boundedIndex = min(max(targetIndex, 0), orderedSizes.count - 1)
    return orderedSizes[boundedIndex]
  }
}

enum AppDynamicTypeLayout {
  static func prefersExpandedControls(for size: DynamicTypeSize) -> Bool {
    size >= .xxLarge
  }

  static func prefersMenuPickers(for size: DynamicTypeSize) -> Bool {
    size >= .xxxLarge
  }
}

private struct AppTextSizeAdjustmentModifier: ViewModifier {
  @Environment(\.dynamicTypeSize) private var systemSize

  let adjustment: AppTextSizeAdjustment

  func body(content: Content) -> some View {
    content.dynamicTypeSize(
      AppDynamicTypeSizeResolver.resolvedSize(
        systemSize: systemSize,
        adjustment: adjustment
      )
    )
  }
}

extension View {
  func appTextSizeAdjustment(_ adjustment: AppTextSizeAdjustment) -> some View {
    modifier(AppTextSizeAdjustmentModifier(adjustment: adjustment))
  }
}
