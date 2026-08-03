import UIKit
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
    XCTAssertEqual(RemoteImageDownloadPolicy.kind(forMaxPixelSize: 720), .preview)
    XCTAssertEqual(RemoteImageDownloadPolicy.kind(forMaxPixelSize: 721), .original)
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

  @MainActor
  func testRepositorySelectsSharedPreviewAndOriginalTransportLimits() async throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16))
    let image = renderer.image { context in
      UIColor.systemBlue.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    }
    let downloader = RecordingRemoteImageDownloader(
      imageData: try XCTUnwrap(image.jpegData(compressionQuality: 0.9))
    )
    let repository = DownsampledImageRepository(downloader: downloader)
    let url = try XCTUnwrap(URL(string: "https://img.example/image.jpg"))

    _ = try await repository.image(at: url, maxPixelSize: 720)
    _ = try await repository.image(at: url, maxPixelSize: 721)

    let recordedKinds = await downloader.recordedKinds()
    XCTAssertEqual(recordedKinds, [.preview, .original])
  }
}

private actor RecordingRemoteImageDownloader: RemoteImageDownloading {
  private let imageData: Data
  private var kinds: [RemoteImageDownloadKind] = []

  init(imageData: Data) {
    self.imageData = imageData
  }

  func download(from url: URL, kind: RemoteImageDownloadKind) async throws
    -> RemoteImageFileLease
  {
    kinds.append(kind)
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RecordingRemoteImageDownloader", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("image.jpg")
    try imageData.write(to: fileURL)
    return RemoteImageFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: directory,
      sourceURL: url,
      mimeType: "image/jpeg",
      suggestedFilename: "image.jpg",
      byteCount: Int64(imageData.count)
    )
  }

  func recordedKinds() -> [RemoteImageDownloadKind] {
    kinds
  }
}
