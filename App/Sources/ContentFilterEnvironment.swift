import SwiftUI

private struct ContentFilterRepositoryEnvironmentKey: EnvironmentKey {
  static let defaultValue: any ContentFilterRepository = EmptyContentFilterRepository()
}

extension EnvironmentValues {
  var contentFilterRepository: any ContentFilterRepository {
    get { self[ContentFilterRepositoryEnvironmentKey.self] }
    set { self[ContentFilterRepositoryEnvironmentKey.self] = newValue }
  }
}
