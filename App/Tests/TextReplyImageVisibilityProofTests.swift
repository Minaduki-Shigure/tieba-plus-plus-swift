import XCTest

@testable import TiebaPlusPlus

final class TextReplyImageVisibilityProofTests: XCTestCase {
  func testExactImageReplyAcceptsTextPrefixSeparatorsAndOrderedImages() throws {
    let first = try imageExpectation(1, pictureCharacter: "a", width: 640, height: 480)
    let second = try imageExpectation(2, pictureCharacter: "b", width: 800, height: 600)
    let contents: [BrowseContent] = [
      .text("正文\n"),
      imageContent(pictureCharacter: "a", width: 640, height: 480),
      .text("\n"),
      imageContent(pictureCharacter: "b", width: 800, height: 600),
    ]

    XCTAssertTrue(
      TextReplyImageVisibilityProof.exactDirectTopicReply(
        from: contents,
        matching: "正文",
        expectations: [first, second]
      )
    )
  }

  func testExactImageReplyAcceptsImageOnlyContent() throws {
    let expectation = try imageExpectation(1, pictureCharacter: "a", width: 640, height: 480)
    XCTAssertTrue(
      TextReplyImageVisibilityProof.exactDirectTopicReply(
        from: [imageContent(pictureCharacter: "a", width: 640, height: 480)],
        matching: "",
        expectations: [expectation]
      )
    )
  }

  func testExactImageReplyRejectsWrongOrderDimensionsAndURLIdentity() throws {
    let first = try imageExpectation(1, pictureCharacter: "a", width: 640, height: 480)
    let second = try imageExpectation(2, pictureCharacter: "b", width: 800, height: 600)
    let reversed: [BrowseContent] = [
      .text("正文\n"),
      imageContent(pictureCharacter: "b", width: 800, height: 600),
      .text("\n"),
      imageContent(pictureCharacter: "a", width: 640, height: 480),
    ]
    XCTAssertFalse(
      TextReplyImageVisibilityProof.exactDirectTopicReply(
        from: reversed,
        matching: "正文",
        expectations: [first, second]
      )
    )

    XCTAssertFalse(
      TextReplyImageVisibilityProof.exactDirectTopicReply(
        from: [imageContent(pictureCharacter: "a", width: 641, height: 480)],
        matching: "",
        expectations: [first]
      )
    )
    XCTAssertFalse(
      TextReplyImageVisibilityProof.exactDirectTopicReply(
        from: [
          imageContent(
            pictureCharacter: "a",
            width: 640,
            height: 480,
            fullSizePictureCharacter: "b"
          )
        ],
        matching: "",
        expectations: [first]
      )
    )
  }

  func testExactImageReplyRejectsMissingExtraAndInjectedTrailingContent() throws {
    let first = try imageExpectation(1, pictureCharacter: "a", width: 640, height: 480)
    let second = try imageExpectation(2, pictureCharacter: "b", width: 800, height: 600)
    XCTAssertFalse(
      TextReplyImageVisibilityProof.exactDirectTopicReply(
        from: [imageContent(pictureCharacter: "a", width: 640, height: 480)],
        matching: "",
        expectations: [first, second]
      )
    )
    XCTAssertFalse(
      TextReplyImageVisibilityProof.exactDirectTopicReply(
        from: [
          imageContent(pictureCharacter: "a", width: 640, height: 480),
          .text("注入内容"),
        ],
        matching: "",
        expectations: [first]
      )
    )
    XCTAssertFalse(
      TextReplyImageVisibilityProof.exactDirectTopicReply(
        from: [
          imageContent(pictureCharacter: "a", width: 640, height: 480),
          .text("\n"),
          imageContent(pictureCharacter: "b", width: 800, height: 600),
        ],
        matching: "",
        expectations: [first]
      )
    )
  }

  func testDynamicImageURLMustProveSamePictureIdentityWithoutGuessingFormat() throws {
    let expectation = try imageExpectation(1, pictureCharacter: "a", width: 640, height: 480)
    let matching = imageVisibilityURL("a")
    let conflicting = imageVisibilityURL("b")
    let unknownGIFPath = try XCTUnwrap(
      URL(
        string: "https://imgsrc.baidu.com/forum/pic/item/" + String(repeating: "a", count: 40)
          + ".gif"))
    for (dynamic, expected) in [(matching, true), (conflicting, false), (unknownGIFPath, false)] {
      let content = BrowseContent.image(
        thumbnail: matching, fullSize: matching, original: matching, dynamic: dynamic,
        width: 640, height: 480)
      XCTAssertEqual(
        TextReplyImageVisibilityProof.exactDirectTopicReply(
          from: [content], matching: "", expectations: [expectation]), expected)
    }
  }
}

private func imageExpectation(
  _ value: UInt8,
  pictureCharacter: Character,
  width: Int,
  height: Int
) throws -> TextReplyImageVisibilityExpectation {
  try XCTUnwrap(
    TextReplyImageVisibilityExpectation(
      attachmentID: imageVisibilityUUID(value),
      pictureID: String(repeating: String(pictureCharacter), count: 40),
      width: width,
      height: height
    )
  )
}

private func imageContent(
  pictureCharacter: Character,
  width: Int,
  height: Int,
  fullSizePictureCharacter: Character? = nil
) -> BrowseContent {
  let thumbnail = imageVisibilityURL(pictureCharacter)
  let fullSize = imageVisibilityURL(fullSizePictureCharacter ?? pictureCharacter)
  return .image(
    thumbnail: thumbnail,
    fullSize: fullSize,
    original: nil,
    width: width,
    height: height
  )
}

private func imageVisibilityURL(_ pictureCharacter: Character) -> URL {
  URL(
    string:
      "https://tiebapic.baidu.com/forum/pic/item/"
      + String(repeating: String(pictureCharacter), count: 40)
      + ".jpg"
  )!
}

private func imageVisibilityUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}
