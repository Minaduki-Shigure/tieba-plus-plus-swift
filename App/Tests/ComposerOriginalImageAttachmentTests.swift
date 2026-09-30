import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ComposerOriginalImageAttachmentTests: XCTestCase {
  func testLegacyAttachmentCanonicalJSONDoesNotGainFieldsOrChangeMeaning() throws {
    let legacy =
      #"{"byteCount":100,"encoding":"jpeg","id":"AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","pixelHeight":480,"pixelWidth":640,"quality":"highQuality","relativePrivateFilename":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa.jpg","sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#
    let attachment = try JSONDecoder().decode(
      ComposerImageAttachment.self, from: Data(legacy.utf8)
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    XCTAssertEqual(try encoder.encode(attachment), Data(legacy.utf8))
    XCTAssertEqual(attachment.quality, .highQuality)
    XCTAssertTrue(attachment.quality.preservesOriginalForUpload)
    XCTAssertFalse(ComposerImageAttachmentQuality.standard.preservesOriginalForUpload)
  }

  func testOriginalAcceptsTwelveMegapixelPhotoWithoutRelaxingRecompressedBudget() throws {
    for encoding in [ComposerImageAttachmentEncoding.jpeg, .png] {
      let original = try XCTUnwrap(makeAttachment(encoding: encoding, quality: .original))
      XCTAssertEqual(original.pixelWidth, 4_032)
      XCTAssertEqual(original.pixelHeight, 3_024)
      XCTAssertTrue(original.quality.preservesOriginalForUpload)
      XCTAssertEqual(
        try JSONDecoder().decode(
          ComposerImageAttachment.self, from: JSONEncoder().encode(original)
        ), original
      )
    }
    XCTAssertNil(makeAttachment(encoding: .jpeg, quality: .highQuality))
    XCTAssertNil(makeAttachment(encoding: .jpeg, quality: .standard))
    XCTAssertNil(makeAttachment(encoding: .png, quality: .highQuality, width: 10, height: 10))
    XCTAssertNil(makeAttachment(encoding: .png, quality: .standard, width: 10, height: 10))
    XCTAssertNil(makeAttachment(encoding: .png, quality: .original, width: 8_000, height: 8_000))
    XCTAssertNil(makeAttachment(encoding: .png, quality: .original, width: 16_385, height: 1))
  }

  func testPrivateFilenamesRemainCanonicalAndEncodingBound() throws {
    let attachment = try XCTUnwrap(makeAttachment(encoding: .png, quality: .original))
    XCTAssertTrue(
      ComposerImageAttachment.isValidRelativePrivateFilename(
        attachment.relativePrivateFilename
      ))
    for invalid in [
      attachment.relativePrivateFilename.uppercased(),
      "../" + attachment.relativePrivateFilename,
      attachment.relativePrivateFilename + ".jpg",
      attachment.id.uuidString.lowercased() + ".webp",
    ] {
      XCTAssertFalse(ComposerImageAttachment.isValidRelativePrivateFilename(invalid), invalid)
    }
    XCTAssertNil(
      ComposerImageAttachment(
        id: attachment.id,
        relativePrivateFilename: attachment.id.uuidString.lowercased() + ".jpg",
        sha256: attachment.sha256,
        byteCount: attachment.byteCount,
        pixelWidth: attachment.pixelWidth,
        pixelHeight: attachment.pixelHeight,
        encoding: .png,
        quality: .original
      ))
  }

  func testGIFOriginalAttachmentUsesCanonicalFilenameAndItsOwnCanvasBudget() throws {
    let attachment = try XCTUnwrap(
      makeAttachment(encoding: .gif, quality: .original, width: 640, height: 480))
    XCTAssertEqual(
      attachment.relativePrivateFilename, attachment.id.uuidString.lowercased() + ".gif")
    XCTAssertTrue(
      ComposerImageAttachment.isValidRelativePrivateFilename(attachment.relativePrivateFilename))
    XCTAssertEqual(
      try JSONDecoder().decode(
        ComposerImageAttachment.self, from: JSONEncoder().encode(attachment)),
      attachment)
    XCTAssertNil(makeAttachment(encoding: .gif, quality: .standard, width: 10, height: 10))
    XCTAssertNil(makeAttachment(encoding: .gif, quality: .highQuality, width: 10, height: 10))
    XCTAssertNil(makeAttachment(encoding: .gif, quality: .original, width: 4_097, height: 1))
    XCTAssertNil(makeAttachment(encoding: .gif, quality: .original, width: 4_096, height: 1_025))
    XCTAssertNotNil(makeAttachment(encoding: .gif, quality: .original, width: 2_048, height: 2_048))
  }

  private func makeAttachment(
    encoding: ComposerImageAttachmentEncoding,
    quality: ComposerImageAttachmentQuality,
    width: Int = 4_032,
    height: Int = 3_024
  ) -> ComposerImageAttachment? {
    ComposerImageAttachment(
      id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
      sha256: String(repeating: "a", count: 64),
      byteCount: 100,
      pixelWidth: width,
      pixelHeight: height,
      encoding: encoding,
      quality: quality
    )
  }
}
