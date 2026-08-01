import UIKit
import XCTest

@testable import TiebaPlusPlus

final class DownsampledImageTests: XCTestCase {
  @MainActor
  func testImageIODownsamplesToRequestedPixelBound() throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 600))
    let source = renderer.image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    }
    let fileURL = temporaryURL(extension: "jpg")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try XCTUnwrap(source.jpegData(compressionQuality: 0.9)).write(to: fileURL)

    let asset = try ImageDownsampler.image(at: fileURL, maxPixelSize: 120)

    let image = try XCTUnwrap(asset.image.cgImage)
    XCTAssertLessThanOrEqual(max(image.width, image.height), 120)
    XCTAssertEqual(image.width * 3, image.height * 4)
  }

  func testImageIODownsamplerRejectsInvalidInput() throws {
    let fileURL = temporaryURL(extension: "bin")
    defer { try? FileManager.default.removeItem(at: fileURL) }
    try Data("not an image".utf8).write(to: fileURL)

    XCTAssertThrowsError(try ImageDownsampler.image(at: fileURL, maxPixelSize: 200))
  }

  func testRepositoryRejectsCleartextURLBeforeNetworking() async throws {
    let repository = DownsampledImageRepository()
    let url = try XCTUnwrap(URL(string: "http://example.com/image.jpg"))

    do {
      _ = try await repository.image(at: url, maxPixelSize: 200)
      XCTFail("Expected cleartext URL rejection")
    } catch DownsampledImageError.invalidResponse {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func temporaryURL(extension pathExtension: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)
      .appendingPathExtension(pathExtension)
  }
}
