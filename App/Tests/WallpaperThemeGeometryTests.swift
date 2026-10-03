import Foundation
import XCTest
@testable import TiebaPlusPlus

final class WallpaperThemeGeometryTests: XCTestCase {
  func testLandscapeImageFillsPortraitViewportWithoutStretching() {
    let geometry = WallpaperCropGeometry(
      sourcePixelSize: CGSize(width: 4_000, height: 2_000),
      viewportSize: CGSize(width: 300, height: 600))
    XCTAssertEqual(geometry.sourceCropRect(for: .initial), CGRect(x: 1_500, y: 0, width: 1_000, height: 2_000))
    XCTAssertEqual(geometry.displayFrame(for: .initial), CGRect(x: -450, y: 0, width: 1_200, height: 600))
  }

  func testPanMovesImageInGestureDirectionAndZoomUsesExistingCenter() {
    let geometry = WallpaperCropGeometry(
      sourcePixelSize: CGSize(width: 1_000, height: 1_000),
      viewportSize: CGSize(width: 200, height: 200))
    let zoomed = geometry.applying(magnification: 2, translation: .zero, to: .initial)
    let moved = geometry.applying(
      magnification: 1, translation: CGSize(width: 50, height: -50), to: zoomed)
    XCTAssertEqual(moved.centerX, 0.375)
    XCTAssertEqual(moved.centerY, 0.625)
    XCTAssertEqual(geometry.sourceCropRect(for: moved), CGRect(x: 125, y: 375, width: 500, height: 500))
    XCTAssertEqual(geometry.displayFrame(for: moved), CGRect(x: -50, y: -150, width: 400, height: 400))
  }

  func testRotationReclampsOffCenterCropAndPreservesZoom() {
    let portrait = WallpaperCropGeometry(
      sourcePixelSize: CGSize(width: 1_200, height: 800),
      viewportSize: CGSize(width: 300, height: 600))
    let landscape = WallpaperCropGeometry(
      sourcePixelSize: portrait.sourcePixelSize,
      viewportSize: CGSize(width: 600, height: 300))
    let edge = portrait.clamped(.init(centerX: 0, centerY: 1, zoom: 2))
    let rotated = landscape.clamped(edge)
    XCTAssertEqual(rotated.zoom, 2)
    XCTAssertGreaterThan(rotated.centerX, edge.centerX)
    assertCoverage(landscape, rotated)
  }

  func testGeometryIsIndependentOfViewportPointScale() {
    let first = WallpaperCropGeometry(
      sourcePixelSize: CGSize(width: 1_024, height: 768),
      viewportSize: CGSize(width: 150, height: 300))
    let second = WallpaperCropGeometry(
      sourcePixelSize: first.sourcePixelSize,
      viewportSize: CGSize(width: 450, height: 900))
    let state = WallpaperCropState(centerX: 0.4, centerY: 0.6, zoom: 2.5)
    XCTAssertEqual(first.sourceCropRect(for: state), second.sourceCropRect(for: state))
  }

  func testExtremeGesturesAlwaysCoverViewportAndRemainInsideSource() {
    for source in [CGSize(width: 2_048, height: 200), CGSize(width: 100, height: 2_048), CGSize(width: 600, height: 600)] {
      for viewport in [CGSize(width: 300, height: 600), CGSize(width: 600, height: 300)] {
        let geometry = WallpaperCropGeometry(sourcePixelSize: source, viewportSize: viewport)
        for zoom in [0.1, 1, 2, 4, 100] {
          for center in [-100.0, 0, 0.5, 1, 100] {
            let state = geometry.clamped(.init(centerX: center, centerY: center, zoom: zoom))
            XCTAssertTrue(state.isValid)
            assertCoverage(geometry, state)
          }
        }
      }
    }
  }

  func testInvalidGeometryAndNonFiniteGesturesAreSafe() {
    let invalid = WallpaperCropGeometry(sourcePixelSize: .zero, viewportSize: CGSize(width: 300, height: 600))
    XCTAssertEqual(invalid.sourceCropRect(for: .initial), .zero)
    XCTAssertEqual(invalid.displayFrame(for: .initial), .zero)
    let geometry = WallpaperCropGeometry(
      sourcePixelSize: CGSize(width: 800, height: 600), viewportSize: CGSize(width: 300, height: 600))
    XCTAssertEqual(geometry.clamped(.init(centerX: .nan, centerY: .infinity, zoom: .nan)), .initial)
    XCTAssertEqual(geometry.applying(magnification: .nan, translation: CGSize(width: CGFloat.nan, height: CGFloat.infinity), to: .initial), .initial)
  }

  func testPersistedSettingsRejectNonFiniteAndOutOfRangeValues() throws {
    XCTAssertEqual(WallpaperThemeSettings.defaultValue.imageOpacity, 1)
    var settings = WallpaperThemeSettings.defaultValue
    settings.imageOpacity = .nan
    XCTAssertFalse(settings.isValid)
    settings = .defaultValue
    settings.blurRadius = 30.001
    XCTAssertFalse(settings.isValid)
    settings.blurRadius = 30
    settings.accentRGB = 0x1_FF_FF_FF
    XCTAssertFalse(settings.isValid)
    settings.accentRGB = 0x12_34_56
    XCTAssertTrue(settings.isValid)
    XCTAssertEqual(try JSONDecoder().decode(WallpaperThemeSettings.self, from: JSONEncoder().encode(settings)), settings)
  }

  private func assertCoverage(
    _ geometry: WallpaperCropGeometry, _ state: WallpaperCropState,
    file: StaticString = #filePath, line: UInt = #line
  ) {
    let crop = geometry.sourceCropRect(for: state)
    let frame = geometry.displayFrame(for: state)
    let epsilon = 0.000_001
    XCTAssertGreaterThanOrEqual(crop.minX, -epsilon, file: file, line: line)
    XCTAssertGreaterThanOrEqual(crop.minY, -epsilon, file: file, line: line)
    XCTAssertLessThanOrEqual(crop.maxX, geometry.sourcePixelSize.width + epsilon, file: file, line: line)
    XCTAssertLessThanOrEqual(crop.maxY, geometry.sourcePixelSize.height + epsilon, file: file, line: line)
    XCTAssertEqual(crop.width / crop.height, geometry.viewportSize.width / geometry.viewportSize.height, accuracy: epsilon, file: file, line: line)
    XCTAssertLessThanOrEqual(frame.minX, epsilon, file: file, line: line)
    XCTAssertLessThanOrEqual(frame.minY, epsilon, file: file, line: line)
    XCTAssertGreaterThanOrEqual(frame.maxX, geometry.viewportSize.width - epsilon, file: file, line: line)
    XCTAssertGreaterThanOrEqual(frame.maxY, geometry.viewportSize.height - epsilon, file: file, line: line)
  }
}
