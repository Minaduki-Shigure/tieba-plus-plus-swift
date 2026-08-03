import XCTest

@testable import TiebaPlusPlus

final class RootStartupNavigationTests: XCTestCase {
  func testStartDestinationCreatesExpectedInitialPath() {
    let cases: [(destination: AppStartDestination, expected: [RootDestination])] = [
      (.home, []),
      (.hotThreads, [.hotThreads]),
      (.hotTopics, [.hotTopics]),
      (.favorites, [.favorites]),
      (.history, [.history]),
    ]

    for testCase in cases {
      XCTAssertEqual(
        RootStartupNavigation.initialPath(startDestination: testCase.destination),
        testCase.expected
      )
    }
  }

  func testLinkTargetsRemainTopmostForEveryStartDestination() {
    let route = TiebaThreadRoute(threadID: 42, postID: 43)
    let targets: [(target: TiebaLinkTarget, expected: RootDestination)] = [
      (.forum("swift"), .forum("swift")),
      (.thread(route), .linkedThread(route)),
      (.user(44), .user(44)),
    ]

    for startDestination in AppStartDestination.allCases {
      let initialPath = RootStartupNavigation.initialPath(
        startDestination: startDestination
      )
      for target in targets {
        let path = RootStartupNavigation.appending(
          target: target.target,
          to: initialPath
        )

        XCTAssertEqual(Array(path.dropLast()), initialPath)
        XCTAssertEqual(path.last, target.expected)
      }
    }
  }
}
