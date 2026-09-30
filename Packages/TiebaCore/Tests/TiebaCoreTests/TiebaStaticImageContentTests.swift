import Foundation
@_spi(TiebaPlusPlusApp) @testable import TiebaCore
import XCTest

@testable import TiebaProto

final class TiebaStaticImageContentTests: XCTestCase {
  private let userID: Int64 = 1_001
  private let forumID: Int64 = 2_002
  private let forumName = "swift"

  func testProofBinderBindsUploadReceiptAccountSubmissionAndForum() throws {
    let submissionID = UUID()
    let proof = try makeStaticImageContentProof(
      submissionID: submissionID,
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      picID: pictureID("a")
    )

    XCTAssertEqual(proof.submissionID, submissionID)
    XCTAssertEqual(proof.userID, userID)
    XCTAssertEqual(proof.forumID, forumID)
    XCTAssertEqual(proof.forumName, forumName)
    XCTAssertEqual(proof.picID, pictureID("a"))
    XCTAssertEqual(proof.width, 640)
    XCTAssertEqual(proof.height, 480)
    XCTAssertEqual(String(describing: proof), "TiebaStaticImageContentProof(redacted)")
    XCTAssertFalse(String(reflecting: proof).contains(proof.picID))
    requireSendableAndHashable(proof)
  }

  func testProofBinderRejectsEveryUploadAndAccountMismatch() throws {
    let submissionID = UUID()
    let fixture = staticImageContentFixture(
      submissionID: submissionID,
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      picID: pictureID("a")
    )
    let differentBytes = TiebaStaticImageUpload(
      uploadID: fixture.upload.uploadID,
      forumName: forumName,
      encodedBytes: Data([0xFF]),
      pixelWidth: 640,
      pixelHeight: 480
    )
    let differentForum = TiebaStaticImageUpload(
      uploadID: fixture.upload.uploadID,
      forumName: "other",
      encodedBytes: fixture.upload.encodedBytes,
      pixelWidth: 640,
      pixelHeight: 480
    )
    for (upload, expectedUserID, intendedForumID) in [
      (differentBytes, userID, forumID),
      (differentForum, userID, forumID),
      (fixture.upload, userID + 1, forumID),
      (fixture.upload, userID, Int64(0)),
    ] {
      XCTAssertThrowsError(
        try TiebaStaticImageContentProof.bind(
          upload: upload,
          receipt: fixture.receipt,
          expectedUserID: expectedUserID,
          submissionID: submissionID,
          forumID: intendedForumID
        )
      ) { error in
        guard case .invalidArgument = error as? TiebaClientError else {
          return XCTFail("Unexpected error: \(error)")
        }
      }
    }
  }

  func testProofHashIdentityIncludesUploadOptionsAndReceiptBinding() throws {
    let submissionID = UUID()
    let uploadID = UUID()
    let standard = try makeStaticImageContentProof(
      submissionID: submissionID,
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      uploadID: uploadID,
      picID: pictureID("a"),
      preservesOriginal: false,
      watermark: .forumName
    )
    let original = try makeStaticImageContentProof(
      submissionID: submissionID,
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      uploadID: uploadID,
      picID: pictureID("a"),
      preservesOriginal: true,
      watermark: .username
    )
    XCTAssertNotEqual(standard, original)
    XCTAssertEqual(Set([standard, original]).count, 2)
  }

  func testOriginalPNGUsesReceiptDimensionsForMarkerAndReadbackWithoutChangingUploadBinding()
    throws
  {
    let submissionID = UUID()
    // A real, local 2 x 3 static PNG. The synthetic server receipt below swaps
    // dimensions to exercise orientation handling; this is not a live upload.
    let png = try XCTUnwrap(
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAEUlEQVR4nGP4z8DA8B+MEBQAQdMF+08zgXEAAAAASUVORK5CYII="
      ))
    let fixture = staticImageContentFixture(
      submissionID: submissionID,
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      picID: pictureID("a"),
      width: 2,
      height: 3,
      serverWidth: 3,
      serverHeight: 2,
      preservesOriginal: true,
      bytes: png
    )
    XCTAssertTrue(fixture.receipt.isBound(to: fixture.upload, expectedUserID: userID))
    let proof = try TiebaStaticImageContentProof.bind(
      upload: fixture.upload,
      receipt: fixture.receipt,
      expectedUserID: userID,
      submissionID: submissionID,
      forumID: forumID
    )
    XCTAssertEqual(
      try compile("", proofs: [proof], submissionID: submissionID).wireValue,
      "#(pic,\(proof.picID),3,2)"
    )

    let incorrectlyReorientedUpload = TiebaStaticImageUpload(
      uploadID: fixture.upload.uploadID,
      forumName: forumName,
      encodedBytes: png,
      pixelWidth: 3,
      pixelHeight: 2,
      preservesOriginal: true
    )
    XCTAssertFalse(
      fixture.receipt.isBound(
        to: incorrectlyReorientedUpload, expectedUserID: userID
      ))
    XCTAssertThrowsError(
      try TiebaStaticImageContentProof.bind(
        upload: incorrectlyReorientedUpload,
        receipt: fixture.receipt,
        expectedUserID: userID,
        submissionID: submissionID,
        forumID: forumID
      ))

    // CDN filenames and uploaded encoding are separate: readback still proves
    // the same PID, with the dimensions reported by the server receipt.
    var returnedImage = imageFragment(type: 3, picID: proof.picID)
    returnedImage.bsize = "3,2"
    XCTAssertTrue(
      readbackMatches(
        [returnedImage], userContent: "", proofs: [proof], submissionID: submissionID
      ))
    returnedImage.bsize = "2,3"
    XCTAssertFalse(
      readbackMatches(
        [returnedImage], userContent: "", proofs: [proof], submissionID: submissionID
      ))
  }

  func testCompilerBuildsOnlyInternalTiebaLiteMarkersAndAllowsImageOnlyBody() throws {
    let submissionID = UUID()
    let proofs = try ["a", "b"].map {
      try makeStaticImageContentProof(
        submissionID: submissionID,
        userID: userID,
        forumID: forumID,
        forumName: forumName,
        picID: pictureID(Character($0))
      )
    }
    let compiled = try compile("正文#(呵呵)", proofs: proofs, submissionID: submissionID)
    XCTAssertEqual(
      compiled.wireValue,
      "正文#(呵呵)\n#(pic,\(pictureID("a")),640,480)"
        + "\n#(pic,\(pictureID("b")),640,480)"
    )
    XCTAssertEqual(
      try compile("", proofs: [proofs[0]], submissionID: submissionID).wireValue,
      "#(pic,\(pictureID("a")),640,480)"
    )
    XCTAssertThrowsError(
      try compile(" \n\t ", proofs: [proofs[0]], submissionID: submissionID)
    )
    XCTAssertThrowsError(
      try compile(
        "#(pic,\(pictureID("a")),640,480)",
        proofs: [proofs[0]],
        submissionID: submissionID
      )
    )
  }

  func testCompilerRejectsReplayDuplicatesCountAndFinalWireLimits() throws {
    let submissionID = UUID()
    let proof = try makeStaticImageContentProof(
      submissionID: submissionID,
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      picID: pictureID("a")
    )
    for operation in [
      { try self.compile("body", proofs: [proof], submissionID: UUID()) },
      {
        try self.compile(
          "body", proofs: [proof], submissionID: submissionID, expectedUserID: self.userID + 1)
      },
      {
        try self.compile(
          "body", proofs: [proof], submissionID: submissionID, forumID: self.forumID + 1)
      },
      {
        try self.compile(
          "body", proofs: [proof], submissionID: submissionID, forumName: "other")
      },
      { try self.compile("body", proofs: [proof, proof], submissionID: submissionID) },
      {
        try TiebaStaticImageContentCompiler.compile(
          userContent: "body",
          imageProofs: [proof],
          submissionID: submissionID,
          expectedUserID: self.userID,
          forumID: self.forumID,
          normalizedForumName: self.forumName,
          allowsImages: false,
          maximumCharacterCount: TiebaTextReplyContentPolicy.maximumCharacterCount,
          maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount
        )
      },
    ] {
      XCTAssertThrowsError(try operation())
    }

    let tenProofs = try (0..<10).map { index in
      try makeStaticImageContentProof(
        submissionID: submissionID,
        userID: userID,
        forumID: forumID,
        forumName: forumName,
        picID: pictureID(Character(String(index)))
      )
    }
    XCTAssertThrowsError(try compile("body", proofs: tenProofs, submissionID: submissionID))

    let secondUploadSamePicture = try makeStaticImageContentProof(
      submissionID: submissionID,
      userID: userID,
      forumID: forumID,
      forumName: forumName,
      picID: proof.picID
    )
    XCTAssertThrowsError(
      try compile(
        "body", proofs: [proof, secondUploadSamePicture], submissionID: submissionID)
    )

    XCTAssertThrowsError(
      try TiebaStaticImageContentCompiler.compile(
        userContent: String(
          repeating: "a",
          count: TiebaTextReplyContentPolicy.maximumCharacterCount
        ),
        imageProofs: [proof],
        submissionID: submissionID,
        expectedUserID: userID,
        forumID: forumID,
        normalizedForumName: forumName,
        allowsImages: true,
        maximumCharacterCount: TiebaTextReplyContentPolicy.maximumCharacterCount,
        maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount
      )
    )
  }

  func testCompilerRejectsDuplicateUploadIDEvenWhenPictureIDsDiffer() throws {
    let submissionID = UUID()
    let uploadID = UUID()
    let proofs = try ["a", "b"].map {
      try makeStaticImageContentProof(
        submissionID: submissionID,
        userID: userID,
        forumID: forumID,
        forumName: forumName,
        uploadID: uploadID,
        picID: pictureID(Character($0))
      )
    }
    XCTAssertThrowsError(try compile("body", proofs: proofs, submissionID: submissionID))
  }

  func testPreUploadBudgetUsesWorstCaseMarkerAndSeparatorLengths() {
    XCTAssertTrue(
      TiebaStaticImageContentPolicy.canCompileWithinLimits(
        userContent: "",
        imageCount: TiebaStaticImageContentPolicy.maximumImageCount,
        maximumCharacterCount: TiebaTextReplyContentPolicy.maximumCharacterCount,
        maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount
      )
    )
    XCTAssertFalse(
      TiebaStaticImageContentPolicy.canCompileWithinLimits(
        userContent: String(
          repeating: "a",
          count: TiebaTextReplyContentPolicy.maximumCharacterCount - 1
        ),
        imageCount: 1,
        maximumCharacterCount: TiebaTextReplyContentPolicy.maximumCharacterCount,
        maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount
      )
    )
    XCTAssertFalse(
      TiebaStaticImageContentPolicy.canCompileWithinLimits(
        userContent: "正文",
        imageCount: TiebaStaticImageContentPolicy.maximumImageCount + 1,
        maximumCharacterCount: TiebaTextReplyContentPolicy.maximumCharacterCount,
        maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount
      )
    )
  }

  func testPreUploadBudgetAllowsEmptyImageOnlyButRejectsWhitespaceOnlyText() {
    XCTAssertTrue(
      TiebaStaticImageContentPolicy.canCompileWithinLimits(
        userContent: "",
        imageCount: 1,
        maximumCharacterCount: TiebaTextReplyContentPolicy.maximumCharacterCount,
        maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount
      )
    )
    XCTAssertFalse(
      TiebaStaticImageContentPolicy.canCompileWithinLimits(
        userContent: " \n\t ",
        imageCount: 1,
        maximumCharacterCount: TiebaTextReplyContentPolicy.maximumCharacterCount,
        maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount
      )
    )
  }

  func testReadbackAcceptsType3And20InProofOrderWithStrictDimensions() throws {
    let submissionID = UUID()
    let proofs = try ["a", "b"].map {
      try makeStaticImageContentProof(
        submissionID: submissionID,
        userID: userID,
        forumID: forumID,
        forumName: forumName,
        picID: pictureID(Character($0))
      )
    }
    var first = imageFragment(type: 3, picID: proofs[0].picID)
    first.cdnSrc = "//imgsrc.baidu.com/forum/w%3D960/sign=abc/\(proofs[0].picID).jpg"
    first.originSrc =
      "http://tiebapic.baidu.com/forum/pic/item/\(proofs[0].picID).jpg?tbpicau=token_1"
    first.bsize = "640,480"

    var second = imageFragment(type: 20, picID: proofs[1].picID)
    second.width = 640
    second.height = 480
    XCTAssertTrue(
      readbackMatches(
        [textFragment("正文\n"), first, textFragment("\n"), second],
        userContent: "正文",
        proofs: proofs,
        submissionID: submissionID
      )
    )
    XCTAssertTrue(
      readbackMatches(
        [textFragment("正文"), first, second],
        userContent: "正文",
        proofs: proofs,
        submissionID: submissionID
      )
    )
  }

  func testReadbackRejectsUnknownConflictingOrIncompleteImages() throws {
    let submissionID = UUID()
    let proofs = try ["a", "b"].map {
      try makeStaticImageContentProof(
        submissionID: submissionID,
        userID: userID,
        forumID: forumID,
        forumName: forumName,
        picID: pictureID(Character($0))
      )
    }
    var valid = imageFragment(type: 3, picID: proofs[0].picID)
    valid.bsize = "640,480"

    var foreignOnly = valid
    foreignOnly.src = "https://example.com/forum/pic/item/\(proofs[0].picID).jpg"
    var validPlusForeign = valid
    validPlusForeign.cdnSrc = "https://example.com/\(proofs[0].picID).jpg"
    var conflictingURLs = valid
    conflictingURLs.originSrc =
      "https://tiebapic.baidu.com/forum/pic/item/\(proofs[1].picID).jpg"
    var wrongBSize = valid
    wrongBSize.bsize = "641,480"
    var conflictingExplicitSize = valid
    conflictingExplicitSize.width = 641
    var noDimensions = valid
    noDimensions.bsize = ""
    var partialDimensions = noDimensions
    partialDimensions.width = 640
    var malformedBSize = valid
    malformedBSize.bsize = "0640,480"

    for fragment in [
      foreignOnly, validPlusForeign, conflictingURLs, wrongBSize,
      conflictingExplicitSize, noDimensions, partialDimensions, malformedBSize,
    ] {
      XCTAssertFalse(
        readbackMatches(
          [textFragment("正文"), fragment],
          userContent: "正文",
          proofs: [proofs[0]],
          submissionID: submissionID
        )
      )
    }
    XCTAssertFalse(
      readbackMatches(
        [textFragment("正文"), valid],
        userContent: "正文",
        proofs: proofs,
        submissionID: submissionID
      )
    )
    XCTAssertFalse(
      readbackMatches(
        [textFragment("正文"), imageFragment(type: 20, picID: proofs[1].picID), valid],
        userContent: "正文",
        proofs: proofs,
        submissionID: submissionID
      )
    )
  }

  func testReadbackAcceptsSamePictureDynamicAndFallbackURLsWithoutChangingStaticImages() throws {
    let submissionID = UUID()
    let proof = try makeStaticImageContentProof(
      submissionID: submissionID, userID: userID, forumID: forumID,
      forumName: forumName, picID: pictureID("a")
    )
    let matchingURL = "https://tiebapic.baidu.com/forum/pic/item/\(proof.picID).jpg"
    for type: UInt32 in [3, 20] {
      var fragment = imageFragment(type: type, picID: proof.picID)
      fragment.bsize = "640,480"
      // Static images continue to pass with empty dynamic/fallback fields.
      XCTAssertTrue(
        readbackMatches(
          [fragment], userContent: "", proofs: [proof], submissionID: submissionID
        ))
      fragment.dynamic = matchingURL
      fragment.cdnSrcActive = matchingURL
      fragment.bigSrc = matchingURL
      XCTAssertTrue(
        readbackMatches(
          [fragment], userContent: "", proofs: [proof], submissionID: submissionID
        ))

      // Any actual display candidate can supply evidence when the usual src
      // is absent, but it must still identify the receipt's exact picture.
      for field: WritableKeyPath<PbContent, String> in [
        \.dynamic, \.cdnSrcActive, \.bigSrc,
      ] {
        var fallbackOnly = PbContent()
        fallbackOnly.type = type
        fallbackOnly.bsize = "640,480"
        fallbackOnly[keyPath: field] = matchingURL
        XCTAssertTrue(
          readbackMatches(
            [fallbackOnly], userContent: "", proofs: [proof], submissionID: submissionID
          ))
      }
    }
  }

  func testReadbackRejectsUnprovenDynamicAndFallbackURLsEvenWithMatchingStillPreview() throws {
    let submissionID = UUID()
    let proof = try makeStaticImageContentProof(
      submissionID: submissionID, userID: userID, forumID: forumID,
      forumName: forumName, picID: pictureID("a")
    )
    for field: WritableKeyPath<PbContent, String> in [
      \.dynamic, \.cdnSrcActive, \.bigSrc,
    ] {
      for rawURL in [
        "https://tiebapic.baidu.com/forum/pic/item/\(pictureID("b")).jpg",
        "https://tiebapic.baidu.com/forum/pic/item/\(proof.picID).gif",
        "https://tiebapic.baidu.com/forum/pic/item/\(proof.picID).png",
        "https://example.com/forum/pic/item/\(proof.picID).jpg",
        "https://tiebapic.baidu.com/forum/pic/item/\(proof.picID).jpg?unknown=1",
        "not a URL",
      ] {
        var fragment = imageFragment(type: 3, picID: proof.picID)
        fragment.bsize = "640,480"
        fragment[keyPath: field] = rawURL
        XCTAssertFalse(
          readbackMatches(
            [fragment], userContent: "", proofs: [proof], submissionID: submissionID
          ), rawURL)
      }
    }
  }

  private func compile(
    _ userContent: String,
    proofs: [TiebaStaticImageContentProof],
    submissionID: UUID,
    expectedUserID: Int64? = nil,
    forumID: Int64? = nil,
    forumName: String? = nil
  ) throws -> TiebaCompiledSubmissionContent {
    try TiebaStaticImageContentCompiler.compile(
      userContent: userContent,
      imageProofs: proofs,
      submissionID: submissionID,
      expectedUserID: expectedUserID ?? self.userID,
      forumID: forumID ?? self.forumID,
      normalizedForumName: forumName ?? self.forumName,
      allowsImages: true,
      maximumCharacterCount: TiebaTextReplyContentPolicy.maximumCharacterCount,
      maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount
    )
  }

  private func readbackMatches(
    _ fragments: [PbContent],
    userContent: String,
    proofs: [TiebaStaticImageContentProof],
    submissionID: UUID
  ) -> Bool {
    TiebaStaticImageContentCompiler.readbackMatches(
      fragments,
      userContent: userContent,
      imageProofs: proofs,
      submissionID: submissionID,
      expectedUserID: userID,
      forumID: forumID,
      normalizedForumName: forumName,
      maximumUTF8ByteCount: TiebaTextReplyContentPolicy.maximumUTF8ByteCount,
      allowsMentions: true
    )
  }

  private func imageFragment(type: UInt32, picID: String) -> PbContent {
    var fragment = PbContent()
    fragment.type = type
    fragment.src = "https://tiebapic.baidu.com/forum/pic/item/\(picID).jpg"
    return fragment
  }

  private func textFragment(_ text: String) -> PbContent {
    var fragment = PbContent()
    fragment.type = 0
    fragment.text = text
    return fragment
  }
}

func makeStaticImageContentProof(
  submissionID: UUID,
  userID: Int64,
  forumID: Int64,
  forumName: String,
  uploadID: UUID = UUID(),
  picID: String,
  width: Int = 640,
  height: Int = 480,
  preservesOriginal: Bool = false,
  watermark: TiebaStaticImageWatermark = .forumName,
  bytes: Data = Data([0x01, 0x02, 0x03])
) throws -> TiebaStaticImageContentProof {
  let fixture = staticImageContentFixture(
    submissionID: submissionID,
    userID: userID,
    forumID: forumID,
    forumName: forumName,
    uploadID: uploadID,
    picID: picID,
    width: width,
    height: height,
    preservesOriginal: preservesOriginal,
    watermark: watermark,
    bytes: bytes
  )
  return try TiebaStaticImageContentProof.bind(
    upload: fixture.upload,
    receipt: fixture.receipt,
    expectedUserID: userID,
    submissionID: submissionID,
    forumID: forumID
  )
}

func staticImageContentFixture(
  submissionID: UUID,
  userID: Int64,
  forumID: Int64,
  forumName: String,
  uploadID: UUID = UUID(),
  picID: String,
  width: Int = 640,
  height: Int = 480,
  serverWidth: Int? = nil,
  serverHeight: Int? = nil,
  preservesOriginal: Bool = false,
  watermark: TiebaStaticImageWatermark = .forumName,
  bytes: Data = Data([0x01, 0x02, 0x03])
) -> (upload: TiebaStaticImageUpload, receipt: TiebaStaticImageUploadReceipt) {
  _ = submissionID
  _ = forumID
  let upload = TiebaStaticImageUpload(
    uploadID: uploadID,
    forumName: forumName,
    encodedBytes: bytes,
    pixelWidth: width,
    pixelHeight: height,
    preservesOriginal: preservesOriginal,
    watermark: watermark
  )
  let chunkCount = TiebaStaticImageUploadPolicy.chunkCount(forByteCount: bytes.count)!
  let receipt = TiebaStaticImageUploadReceipt(
    uploadID: uploadID,
    contentSHA256: TiebaStaticImageUploadPolicy.hexadecimalString(
      TiebaStaticImageUploadPolicy.contentDigest(of: bytes)
    ),
    userID: userID,
    forumName: forumName,
    preservesOriginal: preservesOriginal,
    watermark: watermark,
    uploadedPixelWidth: width,
    uploadedPixelHeight: height,
    resourceID: TiebaStaticImageUploadPolicy.resourceID(for: bytes),
    picID: picID,
    width: serverWidth ?? width,
    height: serverHeight ?? height,
    byteCount: bytes.count,
    chunkCount: chunkCount
  )
  return (upload, receipt)
}

func pictureID(_ character: Character) -> String {
  String(repeating: String(character), count: 40)
}

private func requireSendableAndHashable<T: Sendable & Hashable>(_: T) {}
