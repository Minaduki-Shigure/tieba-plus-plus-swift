import CoreGraphics
import XCTest

@testable import TiebaPlusPlus

final class ProfileAvatarCropGeometryTests: XCTestCase {
  func testInitialWideImageCropUsesCenteredFullHeightSquare() throws {
    let geometry = ProfileAvatarCropGeometry(
      sourcePixelSize: CGSize(width: 2_000, height: 1_000),
      viewportSide: 400
    )

    let rect = try XCTUnwrap(geometry.sourceCropRect(for: .initial))

    XCTAssertEqual(rect, CGRect(x: 500, y: 0, width: 1_000, height: 1_000))
    XCTAssertEqual(
      geometry.displayedImageSize(for: .initial),
      CGSize(width: 800, height: 400)
    )
    XCTAssertEqual(geometry.displayedImageOffset(for: .initial), .zero)
  }

  func testInitialTallImageCropUsesCenteredFullWidthSquare() throws {
    let geometry = ProfileAvatarCropGeometry(
      sourcePixelSize: CGSize(width: 1_000, height: 2_000),
      viewportSide: 400
    )

    let rect = try XCTUnwrap(geometry.sourceCropRect(for: .initial))

    XCTAssertEqual(rect, CGRect(x: 0, y: 500, width: 1_000, height: 1_000))
  }

  func testZoomProducesSmallerCenteredSourceCrop() throws {
    let geometry = ProfileAvatarCropGeometry(
      sourcePixelSize: CGSize(width: 2_000, height: 1_000),
      viewportSide: 400
    )
    let state = ProfileAvatarCropState(
      normalizedCenter: CGPoint(x: 0.5, y: 0.5),
      zoom: 2
    )

    let rect = try XCTUnwrap(geometry.sourceCropRect(for: state))

    XCTAssertEqual(rect, CGRect(x: 750, y: 250, width: 500, height: 500))
  }

  func testDraggingImageRightMovesCropTowardSourceLeft() throws {
    let geometry = ProfileAvatarCropGeometry(
      sourcePixelSize: CGSize(width: 2_000, height: 1_000),
      viewportSide: 400
    )

    let state = geometry.applying(
      magnification: 1,
      translation: CGSize(width: 100, height: 0),
      to: .initial
    )
    let rect = try XCTUnwrap(geometry.sourceCropRect(for: state))

    XCTAssertEqual(state.normalizedCenter.x, 0.375, accuracy: 0.000_001)
    XCTAssertEqual(rect, CGRect(x: 250, y: 0, width: 1_000, height: 1_000))
  }

  func testPanAndZoomAreClampedWithoutExposingEmptyArea() throws {
    let geometry = ProfileAvatarCropGeometry(
      sourcePixelSize: CGSize(width: 2_000, height: 1_000),
      viewportSide: 400
    )

    let state = geometry.applying(
      magnification: 100,
      translation: CGSize(width: 100_000, height: -100_000),
      to: .initial
    )
    let rect = try XCTUnwrap(geometry.sourceCropRect(for: state))

    XCTAssertEqual(state.zoom, ProfileAvatarCropGeometry.maximumZoom)
    XCTAssertEqual(rect.minX, 0)
    XCTAssertEqual(rect.maxY, 1_000)
    XCTAssertEqual(rect.width, 250)
    XCTAssertEqual(rect.height, 250)
  }

  func testCropResultDoesNotDependOnViewportPointSize() throws {
    let sourceSize = CGSize(width: 1_600, height: 900)
    let state = ProfileAvatarCropState(
      normalizedCenter: CGPoint(x: 0.35, y: 0.55),
      zoom: 1.75
    )
    let compact = ProfileAvatarCropGeometry(
      sourcePixelSize: sourceSize,
      viewportSide: 280
    )
    let regular = ProfileAvatarCropGeometry(
      sourcePixelSize: sourceSize,
      viewportSide: 720
    )

    XCTAssertEqual(
      try XCTUnwrap(compact.sourceCropRect(for: state)),
      try XCTUnwrap(regular.sourceCropRect(for: state))
    )
  }

  func testInvalidGeometryAndExportStateFailClosed() {
    let invalidGeometry = ProfileAvatarCropGeometry(
      sourcePixelSize: CGSize(width: 0, height: 100),
      viewportSide: 300
    )
    XCTAssertFalse(invalidGeometry.isValid)
    XCTAssertNil(invalidGeometry.sourceCropRect(for: .initial))

    let geometry = ProfileAvatarCropGeometry(
      sourcePixelSize: CGSize(width: 100, height: 100),
      viewportSide: 300
    )
    XCTAssertNil(
      geometry.sourceCropRect(
        for: ProfileAvatarCropState(
          normalizedCenter: CGPoint(x: .nan, y: 0.5),
          zoom: 1
        )
      )
    )
    XCTAssertNil(
      geometry.sourceCropRect(
        for: ProfileAvatarCropState(
          normalizedCenter: CGPoint(x: 0.5, y: 0.5),
          zoom: .infinity
        )
      )
    )
  }
}
