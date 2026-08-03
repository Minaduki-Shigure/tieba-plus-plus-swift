import Combine
import Foundation
import Network
import SwiftUI

struct ContentMediaNetworkSnapshot: Equatable, Sendable {
  enum Status: Equatable, Sendable {
    case unknown
    case unavailable
    case available
  }

  static let unknown = ContentMediaNetworkSnapshot(
    status: .unknown,
    isExpensive: false,
    isConstrained: false
  )

  let status: Status
  let isExpensive: Bool
  let isConstrained: Bool

  init(
    status: Status,
    isExpensive: Bool,
    isConstrained: Bool
  ) {
    self.status = status
    self.isExpensive = isExpensive
    self.isConstrained = isConstrained
  }

  var allowsEconomicalAutomaticLoading: Bool {
    status == .available && !isExpensive && !isConstrained
  }

  fileprivate init(path: NWPath) {
    switch path.status {
    case .satisfied:
      status = .available
    case .requiresConnection, .unsatisfied:
      status = .unavailable
    @unknown default:
      status = .unknown
    }
    isExpensive = path.isExpensive
    isConstrained = path.isConstrained
  }
}

enum ContentMediaLoadBehavior: Equatable, Sendable {
  case automatic
  case economicalNetworkOnly
  case userInitiated

  static func resolved(
    policy: ContentMediaLoadPolicy,
    networkSnapshot: ContentMediaNetworkSnapshot
  ) -> Self {
    switch policy {
    case .automatic:
      .automatic
    case .networkAware:
      networkSnapshot.allowsEconomicalAutomaticLoading
        ? .economicalNetworkOnly
        : .userInitiated
    case .tapToLoad:
      .userInitiated
    }
  }
}

private struct ContentMediaLoadBehaviorEnvironmentKey: EnvironmentKey {
  static let defaultValue = ContentMediaLoadBehavior.automatic
}

extension EnvironmentValues {
  var contentMediaLoadBehavior: ContentMediaLoadBehavior {
    get { self[ContentMediaLoadBehaviorEnvironmentKey.self] }
    set { self[ContentMediaLoadBehaviorEnvironmentKey.self] = newValue }
  }
}

@MainActor
final class ContentMediaNetworkMonitor: ObservableObject {
  @Published private(set) var snapshot = ContentMediaNetworkSnapshot.unknown

  private let monitor: NWPathMonitor
  private let queue = DispatchQueue(label: "TiebaPlusPlus.ContentMediaNetworkMonitor")

  init() {
    let monitor = NWPathMonitor()
    self.monitor = monitor
    monitor.pathUpdateHandler = { [weak self] path in
      let snapshot = ContentMediaNetworkSnapshot(path: path)
      Task { @MainActor [weak self] in
        self?.snapshot = snapshot
      }
    }
    monitor.start(queue: queue)
  }

  deinit {
    monitor.cancel()
  }
}
