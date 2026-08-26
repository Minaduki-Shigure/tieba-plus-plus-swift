import SwiftUI
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class HomeExploreEntryTests: XCTestCase {
  @MainActor
  func testExploreEntryLabelDoesNotAddASecondMinimumRowHeight() {
    let widths: [CGFloat] = [320, 390, 768]
    for width in widths {
      let host = UIHostingController(
        rootView: HomeExploreEntryLabel()
          .environment(\.dynamicTypeSize, .large)
          .frame(width: width)
      )

      let size = host.sizeThatFits(in: CGSize(width: width, height: 1_000))

      XCTAssertEqual(size.width, width, accuracy: 0.5)
      XCTAssertLessThan(size.height, 44)
    }
  }
}
