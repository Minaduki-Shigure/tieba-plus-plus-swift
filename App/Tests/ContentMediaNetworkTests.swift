import SwiftUI
import XCTest

@testable import TiebaPlusPlus

final class ContentMediaNetworkTests: XCTestCase {
  func testOnlyAvailableEconomicalUnconstrainedNetworkAllowsAutomaticLoading() {
    let cases: [(ContentMediaNetworkSnapshot, Bool)] = [
      (.unknown, false),
      (snapshot(status: .unavailable), false),
      (snapshot(status: .available), true),
      (snapshot(status: .available, isExpensive: true), false),
      (snapshot(status: .available, isConstrained: true), false),
      (
        snapshot(status: .available, isExpensive: true, isConstrained: true),
        false
      ),
    ]

    for (snapshot, expected) in cases {
      XCTAssertEqual(snapshot.allowsEconomicalAutomaticLoading, expected)
    }
  }

  func testAutomaticPolicyIgnoresEveryNetworkSnapshot() {
    for networkSnapshot in representativeSnapshots {
      XCTAssertEqual(
        ContentMediaLoadBehavior.resolved(
          policy: .automatic,
          networkSnapshot: networkSnapshot
        ),
        .automatic
      )
    }
  }

  func testNetworkAwarePolicyUsesEconomicalNetworkOnlyWhenAvailableAndUnrestricted() {
    for networkSnapshot in representativeSnapshots {
      let expected: ContentMediaLoadBehavior =
        networkSnapshot.allowsEconomicalAutomaticLoading
        ? .economicalNetworkOnly
        : .userInitiated

      XCTAssertEqual(
        ContentMediaLoadBehavior.resolved(
          policy: .networkAware,
          networkSnapshot: networkSnapshot
        ),
        expected
      )
    }
  }

  func testTapToLoadPolicyAlwaysRequiresUserInitiation() {
    for networkSnapshot in representativeSnapshots {
      XCTAssertEqual(
        ContentMediaLoadBehavior.resolved(
          policy: .tapToLoad,
          networkSnapshot: networkSnapshot
        ),
        .userInitiated
      )
    }
  }

  @MainActor
  func testEnvironmentDefaultsToAutomaticAndCanBeOverridden() {
    var environment = EnvironmentValues()
    XCTAssertEqual(environment.contentMediaLoadBehavior, .automatic)

    environment.contentMediaLoadBehavior = .economicalNetworkOnly

    XCTAssertEqual(environment.contentMediaLoadBehavior, .economicalNetworkOnly)
  }

  private var representativeSnapshots: [ContentMediaNetworkSnapshot] {
    [
      .unknown,
      snapshot(status: .unavailable),
      snapshot(status: .available),
      snapshot(status: .available, isExpensive: true),
      snapshot(status: .available, isConstrained: true),
    ]
  }

  private func snapshot(
    status: ContentMediaNetworkSnapshot.Status,
    isExpensive: Bool = false,
    isConstrained: Bool = false
  ) -> ContentMediaNetworkSnapshot {
    ContentMediaNetworkSnapshot(
      status: status,
      isExpensive: isExpensive,
      isConstrained: isConstrained
    )
  }
}
