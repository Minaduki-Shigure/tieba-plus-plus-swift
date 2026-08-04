import SwiftUI

struct ErrorStateView: View {
  let message: String
  let retry: () -> Void

  @Environment(\.appAccentColor) private var appAccentColor

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "exclamationmark.triangle")
        .font(.largeTitle)
        .foregroundStyle(.secondary)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button(action: retry) {
        Label("重试", systemImage: "arrow.clockwise")
          .foregroundStyle(appAccentColor.onAccentColor)
      }
      .buttonStyle(.borderedProminent)
    }
    .padding(24)
  }
}

struct EmptyStateView: View {
  let title: String
  let systemImage: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: systemImage)
        .font(.largeTitle)
      Text(title)
        .font(.callout)
    }
    .foregroundStyle(.secondary)
    .padding(24)
  }
}

struct LoadMoreErrorView: View {
  let message: String
  let retry: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      Text(message)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      Button(action: retry) {
        Label("重试加载", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 12)
  }
}
