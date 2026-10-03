import SwiftUI
import TiebaCore
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class ClassicEmoticonPickerTests: XCTestCase {
  func testTapToLoadAndRestrictedNetworksDoNotDownloadUncachedEmoticons() async throws {
    let entry = try thumbnailEntry()
    let restrictedSnapshots: [ContentMediaNetworkSnapshot] = [
      .unknown,
      .init(status: .unavailable, isExpensive: false, isConstrained: false),
      .init(status: .available, isExpensive: true, isConstrained: false),
      .init(status: .available, isExpensive: false, isConstrained: true),
    ]
    let cases: [(ContentMediaLoadPolicy, ContentMediaLoadBehavior)] =
      [(.tapToLoad, .userInitiated)]
      + restrictedSnapshots.map {
        (.networkAware, .resolved(policy: .networkAware, networkSnapshot: $0))
      }

    for (policy, behavior) in cases {
      let downloader = EmoticonThumbnailDownloader(imageData: Data())
      let repository = DownsampledImageRepository(downloader: downloader)
      let request = ClassicEmoticonThumbnailRequest(
        entry: entry,
        policy: policy,
        behavior: behavior,
        networkAccess: .unrestricted
      )

      do {
        _ = try await repository.image(
          at: try XCTUnwrap(request.url),
          maxPixelSize: ClassicEmoticonThumbnailRequest.maximumPixelSize,
          fetchPolicy: request.fetchPolicy,
          urlPolicy: .classicEmoticon,
          onProgress: nil
        )
        XCTFail("An uncached thumbnail must stay unavailable without network permission")
      } catch DownsampledImageError.cacheMiss {
        // The picker keeps its local name and insertion button usable.
      }
      let requests = await downloader.recordedRequests()
      XCTAssertTrue(requests.isEmpty)
    }
  }

  func testAutomaticThumbnailsApplyPreviewTransportRestrictions() async throws {
    let entry = try thumbnailEntry()
    let economicalBehavior = ContentMediaLoadBehavior.resolved(
      policy: .networkAware,
      networkSnapshot: .init(status: .available, isExpensive: false, isConstrained: false)
    )
    let cases:
      [(
        ContentMediaLoadPolicy, ContentMediaLoadBehavior, RemoteImageNetworkAccess,
        RemoteImageNetworkAccess
      )] = [
        (.automatic, .automatic, .unrestricted, .unrestricted),
        (.automatic, .automatic, .economicalOnly, .economicalOnly),
        (.networkAware, economicalBehavior, .unrestricted, .economicalOnly),
      ]

    for (policy, behavior, networkAccess, expectedAccess) in cases {
      let downloader = EmoticonThumbnailDownloader(imageData: try imageData())
      let repository = DownsampledImageRepository(downloader: downloader)
      let request = ClassicEmoticonThumbnailRequest(
        entry: entry,
        policy: policy,
        behavior: behavior,
        networkAccess: networkAccess
      )

      let asset = try await repository.image(
        at: try XCTUnwrap(request.url),
        maxPixelSize: ClassicEmoticonThumbnailRequest.maximumPixelSize,
        fetchPolicy: request.fetchPolicy,
        urlPolicy: .classicEmoticon,
        onProgress: nil
      )

      let requests = await downloader.recordedRequests()
      XCTAssertEqual(requests, [.init(kind: .preview, networkAccess: expectedAccess)])
      XCTAssertLessThanOrEqual(asset.image.size.width * asset.image.scale, 120)
      XCTAssertLessThanOrEqual(asset.image.size.height * asset.image.scale, 120)
    }
  }

  func testCachedEmoticonRemainsVisibleAfterSwitchingToTapToLoad() async throws {
    let entry = try thumbnailEntry()
    let downloader = EmoticonThumbnailDownloader(imageData: try imageData())
    let repository = DownsampledImageRepository(downloader: downloader)
    for (policy, behavior) in [
      (ContentMediaLoadPolicy.automatic, ContentMediaLoadBehavior.automatic),
      (.tapToLoad, .userInitiated),
    ] {
      let request = ClassicEmoticonThumbnailRequest(
        entry: entry,
        policy: policy,
        behavior: behavior,
        networkAccess: .unrestricted
      )
      _ = try await repository.image(
        at: try XCTUnwrap(request.url),
        maxPixelSize: ClassicEmoticonThumbnailRequest.maximumPixelSize,
        fetchPolicy: request.fetchPolicy,
        urlPolicy: .classicEmoticon,
        onProgress: nil
      )
    }

    let requests = await downloader.recordedRequests()
    XCTAssertEqual(requests.count, 1)
  }

  @MainActor
  func testCellPreservesProposedWidthAndMinimumTapSizeWithoutAThumbnail() throws {
    let longestNamedEntry = try XCTUnwrap(
      TiebaClassicEmoticonCatalog.entries.max { $0.name.count < $1.name.count }
    )
    for (width, dynamicTypeSize) in [
      (CGFloat(80), DynamicTypeSize.large),
      (CGFloat(296), DynamicTypeSize.accessibility5),
    ] {
      let host = UIHostingController(
        rootView: ClassicEmoticonPickerCell(entry: longestNamedEntry, onSelect: {})
          .environment(\.dynamicTypeSize, dynamicTypeSize)
          .environment(\.contentMediaLoadPolicy, .tapToLoad)
          .environment(\.contentMediaLoadBehavior, .userInitiated)
          .frame(width: width)
      )
      let size = host.sizeThatFits(in: CGSize(width: width, height: 1_000))

      XCTAssertEqual(size.width, width, accuracy: 0.5)
      XCTAssertGreaterThanOrEqual(size.height, 44)
      XCTAssertLessThan(size.height, 1_000)
    }
  }

  private func thumbnailEntry() throws -> TiebaClassicEmoticonCatalog.Entry {
    try XCTUnwrap(TiebaClassicEmoticonCatalog.entries.first { $0.thumbnailURL != nil })
  }

  private func imageData() throws -> Data {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 128))
    return renderer.pngData { context in
      UIColor.systemYellow.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 256, height: 128))
    }
  }
}

private actor EmoticonThumbnailDownloader: RemoteImageDownloading {
  struct Request: Equatable, Sendable {
    let kind: RemoteImageDownloadKind
    let networkAccess: RemoteImageNetworkAccess
  }

  let imageData: Data
  private var requests: [Request] = []

  init(imageData: Data) {
    self.imageData = imageData
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease {
    requests.append(Request(kind: kind, networkAccess: networkAccess))
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("EmoticonThumbnailDownloader", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("thumbnail.png")
    try imageData.write(to: fileURL)
    return RemoteImageFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: directory,
      sourceURL: url,
      mimeType: "image/png",
      suggestedFilename: "thumbnail.png",
      byteCount: Int64(imageData.count)
    )
  }

  func recordedRequests() -> [Request] { requests }
}
