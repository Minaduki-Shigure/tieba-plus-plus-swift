import XCTest

@testable import TiebaPlusPlus

final class DownsampledRemoteImageTests: XCTestCase {
  func testAutomaticPreviewUsesLowerTransferLimit() {
    XCTAssertEqual(
      RemoteImageDownloadPolicy.maximumResponseBytes(for: 720),
      16 * 1_024 * 1_024
    )
    XCTAssertEqual(
      RemoteImageDownloadPolicy.maximumResponseBytes(for: 721),
      80 * 1_024 * 1_024
    )
  }

  func testTransferLimitRejectsDeclaredOrObservedOversizeResponses() {
    let limit: Int64 = 16 * 1_024 * 1_024

    XCTAssertTrue(
      RemoteImageDownloadPolicy.exceedsLimit(
        totalBytesWritten: 1,
        totalBytesExpected: limit + 1,
        maximumResponseBytes: limit
      )
    )
    XCTAssertTrue(
      RemoteImageDownloadPolicy.exceedsLimit(
        totalBytesWritten: limit + 1,
        totalBytesExpected: -1,
        maximumResponseBytes: limit
      )
    )
    XCTAssertFalse(
      RemoteImageDownloadPolicy.exceedsLimit(
        totalBytesWritten: limit,
        totalBytesExpected: -1,
        maximumResponseBytes: limit
      )
    )
  }
}
