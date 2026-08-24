import Combine
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class HomeScreenQuickActionTests: XCTestCase {
  func testTypesAreExactStableIdentifiers() {
    XCTAssertEqual(
      HomeScreenQuickAction.allCases.map(\.rawValue),
      [
        "io.github.minaduki.tieba-plus-plus.quick-action.batch-check-in",
        "io.github.minaduki.tieba-plus-plus.quick-action.cloud-favorites",
        "io.github.minaduki.tieba-plus-plus.quick-action.search",
        "io.github.minaduki.tieba-plus-plus.quick-action.notifications",
      ]
    )
  }

  func testActionsMapToExpectedAppRoutes() {
    let cases: [(action: HomeScreenQuickAction, route: TiebaAppRoute)] = [
      (.batchCheckIn, .batchCheckIn),
      (.cloudFavorites, .cloudFavorites),
      (.search, .search),
      (.notificationReplies, .notifications(.replies)),
    ]

    for testCase in cases {
      XCTAssertEqual(testCase.action.appRoute, testCase.route)
      XCTAssertEqual(
        HomeScreenQuickActionInvocation(id: quickActionTestUUID(1), action: testCase.action)
          .appRoute,
        testCase.route
      )
    }
  }

  func testParserAcceptsOnlyKnownTypesWithoutRoutingMetadata() {
    for action in HomeScreenQuickAction.allCases {
      XCTAssertEqual(
        HomeScreenQuickAction.parse(
          type: action.rawValue,
          userInfoCount: nil,
          hasTargetContentIdentifier: false
        ),
        action
      )
      XCTAssertEqual(
        HomeScreenQuickAction.parse(
          type: action.rawValue,
          userInfoCount: 0,
          hasTargetContentIdentifier: false
        ),
        action
      )
    }

    XCTAssertNil(
      HomeScreenQuickAction.parse(
        type: "io.github.minaduki.tieba-plus-plus.quick-action.unknown",
        userInfoCount: nil,
        hasTargetContentIdentifier: false
      )
    )
    XCTAssertNil(
      HomeScreenQuickAction.parse(
        type: HomeScreenQuickAction.search.rawValue,
        userInfoCount: 1,
        hasTargetContentIdentifier: false
      )
    )
    XCTAssertNil(
      HomeScreenQuickAction.parse(
        type: HomeScreenQuickAction.search.rawValue,
        userInfoCount: nil,
        hasTargetContentIdentifier: true
      )
    )
  }

  func testReceivingSamePendingActionPreservesInvocationAndDoesNotGenerateAnotherID() {
    var state = HomeScreenQuickActionPendingState()
    let generatedIDs = [quickActionTestUUID(1), quickActionTestUUID(2)]
    var generationCount = 0
    let makeID = {
      defer { generationCount += 1 }
      return generatedIDs[generationCount]
    }

    let first = state.receive(.search, makeID: makeID)
    let duplicate = state.receive(.search, makeID: makeID)

    XCTAssertEqual(first.id, quickActionTestUUID(1))
    XCTAssertEqual(duplicate, first)
    XCTAssertEqual(state.invocation, first)
    XCTAssertEqual(generationCount, 1)
  }

  func testDifferentPendingActionUsesLatestInvocation() {
    var state = HomeScreenQuickActionPendingState()
    let first = state.receive(.search) { quickActionTestUUID(1) }
    let latest = state.receive(.cloudFavorites) { quickActionTestUUID(2) }

    XCTAssertNotEqual(latest.id, first.id)
    XCTAssertEqual(latest.action, .cloudFavorites)
    XCTAssertEqual(state.invocation, latest)
  }

  func testReceivingSameActionAfterConsumeCreatesFreshInvocation() {
    var state = HomeScreenQuickActionPendingState()
    let first = state.receive(.search) { quickActionTestUUID(1) }
    XCTAssertTrue(state.consume(first))

    let next = state.receive(.search) { quickActionTestUUID(2) }

    XCTAssertNotEqual(next.id, first.id)
    XCTAssertEqual(state.invocation, next)
  }

  func testConsumeRequiresExactPendingInvocation() {
    var state = HomeScreenQuickActionPendingState()
    let stale = state.receive(.search) { quickActionTestUUID(1) }
    let current = state.receive(.cloudFavorites) { quickActionTestUUID(2) }

    XCTAssertFalse(state.consume(stale))
    XCTAssertEqual(state.invocation, current)

    let forged = HomeScreenQuickActionInvocation(id: current.id, action: .search)
    XCTAssertFalse(state.consume(forged))
    XCTAssertEqual(state.invocation, current)

    XCTAssertTrue(state.consume(current))
    XCTAssertNil(state.invocation)
    XCTAssertFalse(state.consume(current))
  }

  @MainActor
  func testSceneDelegateConvergesWhenSubscriberConsumesDuringPublishedWillSet() {
    let sceneDelegate = TiebaSceneDelegate()
    var receivedInvocations: [HomeScreenQuickActionInvocation] = []
    let observation = sceneDelegate.$pendingQuickAction
      .compactMap { $0 }
      .sink { invocation in
        receivedInvocations.append(invocation)
        XCTAssertTrue(sceneDelegate.consume(invocation))
      }

    let invocation = sceneDelegate.receive(.search)

    XCTAssertEqual(receivedInvocations, [invocation])
    XCTAssertNil(sceneDelegate.pendingQuickAction)
    withExtendedLifetime(observation) {}
  }

  @MainActor
  func testSceneDelegateReplaysAColdPendingInvocationToALateSubscriber() {
    let sceneDelegate = TiebaSceneDelegate()
    let invocation = sceneDelegate.receive(.search)
    var receivedInvocations: [HomeScreenQuickActionInvocation] = []

    let observation = sceneDelegate.$pendingQuickAction
      .compactMap { $0 }
      .sink { pending in
        receivedInvocations.append(pending)
        XCTAssertTrue(sceneDelegate.consume(pending))
      }

    XCTAssertEqual(receivedInvocations, [invocation])
    XCTAssertNil(sceneDelegate.pendingQuickAction)
    withExtendedLifetime(observation) {}
  }

  @MainActor
  func testSceneDelegateLateSubscriberReceivesOnlyTheLatestColdInvocation() {
    let sceneDelegate = TiebaSceneDelegate()
    _ = sceneDelegate.receive(.search)
    let latest = sceneDelegate.receive(.cloudFavorites)
    var receivedInvocations: [HomeScreenQuickActionInvocation] = []

    let observation = sceneDelegate.$pendingQuickAction
      .compactMap { $0 }
      .sink { pending in
        receivedInvocations.append(pending)
        XCTAssertTrue(sceneDelegate.consume(pending))
      }

    XCTAssertEqual(receivedInvocations, [latest])
    XCTAssertNil(sceneDelegate.pendingQuickAction)
    withExtendedLifetime(observation) {}
  }

  @MainActor
  func testSceneConfigurationOnlyInstallsDelegateForWindowApplicationRole() {
    let windowConfiguration = TiebaApplicationDelegate.sceneConfiguration(
      for: .windowApplication
    )
    XCTAssertEqual(windowConfiguration.role, .windowApplication)
    XCTAssertEqual(
      windowConfiguration.delegateClass.map { ObjectIdentifier($0) },
      ObjectIdentifier(TiebaSceneDelegate.self)
    )

    let externalConfiguration = TiebaApplicationDelegate.sceneConfiguration(
      for: .windowExternalDisplay
    )
    XCTAssertEqual(externalConfiguration.role, .windowExternalDisplay)
    XCTAssertNil(externalConfiguration.delegateClass)
  }
}

private func quickActionTestUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}
