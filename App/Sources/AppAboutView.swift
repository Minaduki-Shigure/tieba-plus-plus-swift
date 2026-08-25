import Foundation
import SwiftUI

struct AppAboutMetadata: Equatable, Sendable {
  static let fallbackDisplayName = "贴吧++"

  let displayName: String
  let versionName: String?
  let buildNumber: String?

  init(infoDictionary: [String: Any]?) {
    displayName =
      Self.normalizedString(infoDictionary?["CFBundleDisplayName"], maximumLength: 100)
      ?? Self.normalizedString(infoDictionary?["CFBundleName"], maximumLength: 100)
      ?? Self.fallbackDisplayName
    versionName = Self.normalizedString(
      infoDictionary?["CFBundleShortVersionString"],
      maximumLength: 64
    )
    buildNumber = Self.normalizedString(
      infoDictionary?["CFBundleVersion"],
      maximumLength: 64
    )
  }

  init(bundle: Bundle = .main) {
    self.init(infoDictionary: bundle.infoDictionary)
  }

  var versionDescription: String {
    switch (versionName, buildNumber) {
    case (.some(let versionName), .some(let buildNumber)):
      return "版本 \(versionName)（\(buildNumber)）"
    case (.some(let versionName), nil):
      return "版本 \(versionName)"
    case (nil, .some(let buildNumber)):
      return "构建 \(buildNumber)"
    case (nil, nil):
      return "版本未知"
    }
  }

  private static func normalizedString(
    _ value: Any?,
    maximumLength: Int
  ) -> String? {
    guard let value = value as? String else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      !normalized.isEmpty,
      normalized.count <= maximumLength,
      normalized.utf8.count <= maximumLength * 4,
      !normalized.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { return nil }
    return normalized
  }
}

enum AppAboutSourceLink {
  static let absoluteString =
    "https://github.com/Minaduki-Shigure/tieba-plus-plus-swift"

  static var validatedURL: URL? {
    guard
      let components = URLComponents(string: absoluteString),
      components.scheme == "https",
      components.host == "github.com",
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.percentEncodedPath == "/Minaduki-Shigure/tieba-plus-plus-swift",
      components.query == nil,
      components.fragment == nil,
      let url = components.url,
      url.absoluteString == absoluteString
    else { return nil }
    return url
  }

  static func disposition(mode: ExternalWebOpenMode) -> BrowseContentLinkDisposition {
    guard let validatedURL else { return .rejected }
    return BrowseContentLinkRouter.disposition(for: validatedURL, mode: mode)
  }

  @MainActor
  @discardableResult
  static func open(
    mode: ExternalWebOpenMode,
    inAppSafari: (URL) -> Bool,
    systemBrowser: (URL) -> Void
  ) -> Bool {
    switch disposition(mode: mode) {
    case .system(let validatedURL):
      systemBrowser(validatedURL)
      return true
    case .inAppSafari(let validatedURL):
      if !inAppSafari(validatedURL) {
        systemBrowser(validatedURL)
      }
      return true
    case .tieba, .rejected:
      return false
    }
  }
}

struct AppAboutView: View {
  @Environment(\.externalWebOpenMode) private var externalWebOpenMode
  @Environment(\.openExternalWeb) private var openExternalWeb
  @Environment(\.openURL) private var openURL

  let metadata: AppAboutMetadata

  init(metadata: AppAboutMetadata = AppAboutMetadata()) {
    self.metadata = metadata
  }

  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Text(metadata.displayName)
            .font(.title2.weight(.semibold))
          Text(metadata.versionDescription)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("about-app-metadata")
      }

      Section("项目") {
        Button(action: openProjectSource) {
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
              sourceLabel
              Spacer(minLength: 12)
              sourceDestinationLabel
            }

            VStack(alignment: .leading, spacing: 5) {
              sourceLabel
              sourceDestinationLabel
                .font(.subheadline)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(AppAboutSourceLink.validatedURL == nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("项目源代码")
        .accessibilityHint("在 GitHub 打开")
        .accessibilityIdentifier("about-project-source")
      }
    }
    .listStyle(.insetGrouped)
    .appScrollableSurface()
    .navigationTitle("关于")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func openProjectSource() {
    AppAboutSourceLink.open(
      mode: externalWebOpenMode,
      inAppSafari: { openExternalWeb($0) },
      systemBrowser: { openURL($0) }
    )
  }

  private var sourceLabel: some View {
    Label("项目源代码", systemImage: "chevron.left.forwardslash.chevron.right")
  }

  private var sourceDestinationLabel: some View {
    HStack(spacing: 5) {
      Text("GitHub")
      Image(systemName: "arrow.up.right")
        .font(.footnote.weight(.semibold))
        .accessibilityHidden(true)
    }
    .foregroundStyle(.secondary)
  }
}
