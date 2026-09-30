import Foundation

/// Resolve once at the app root, using the shared network monitor. Image rows
/// receive concrete quality and transport policy without observing the network.
struct ContentImagePreviewPolicy: Equatable, Sendable {
  let quality: ContentImagePreviewQuality
  let networkAccess: RemoteImageNetworkAccess

  static func resolved(
    preference: ContentImagePreviewQuality,
    networkSnapshot: ContentMediaNetworkSnapshot
  ) -> Self {
    switch preference {
    case .standard, .highDefinition:
      Self(quality: preference, networkAccess: .unrestricted)
    case .automatic:
      if networkSnapshot.allowsEconomicalAutomaticLoading {
        // Keep the request restricted if the path changes before SwiftUI
        // receives the next network snapshot and replaces this preview.
        Self(quality: .highDefinition, networkAccess: .economicalOnly)
      } else {
        Self(quality: .standard, networkAccess: .unrestricted)
      }
    }
  }
}
