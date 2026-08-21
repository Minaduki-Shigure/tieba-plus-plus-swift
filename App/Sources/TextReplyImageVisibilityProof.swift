import Foundation
import TiebaCore

struct TextReplyImageVisibilityExpectation: Hashable, Sendable {
  let attachmentID: UUID
  let pictureID: String
  let width: Int
  let height: Int

  init?(
    attachmentID: UUID,
    pictureID: String,
    width: Int,
    height: Int
  ) {
    guard
      attachmentID
        != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)),
      TiebaPicturePageCursor(serverPictureID: pictureID, overallIndex: 1) != nil,
      width > 0,
      height > 0,
      width <= TiebaStaticImageUploadPolicy.maximumPixelDimension,
      height <= TiebaStaticImageUploadPolicy.maximumPixelDimension
    else { return nil }
    self.attachmentID = attachmentID
    self.pictureID = pictureID
    self.width = width
    self.height = height
  }

  init?(_ upload: ComposerImageUploadResult) {
    guard
      upload.attachment.id == upload.proof.uploadID,
      upload.receipt.uploadID == upload.attachment.id,
      upload.receipt.picID == upload.proof.picID,
      upload.receipt.width == upload.proof.width,
      upload.receipt.height == upload.proof.height
    else { return nil }
    self.init(
      attachmentID: upload.attachment.id,
      pictureID: upload.proof.picID,
      width: upload.proof.width,
      height: upload.proof.height
    )
  }
}

enum TextReplyImageVisibilityProof {
  static func exactDirectTopicReply(
    from contents: [BrowseContent],
    matching expectedContent: String,
    uploads: [ComposerImageUploadResult]
  ) -> Bool {
    let expectations = uploads.compactMap(TextReplyImageVisibilityExpectation.init)
    guard expectations.count == uploads.count else { return false }
    return exactDirectTopicReply(
      from: contents,
      matching: expectedContent,
      expectations: expectations
    )
  }

  static func exactDirectTopicReply(
    from contents: [BrowseContent],
    matching expectedContent: String,
    expectations: [TextReplyImageVisibilityExpectation]
  ) -> Bool {
    guard
      !expectations.isEmpty,
      expectations.count <= TiebaStaticImageContentPolicy.maximumImageCount,
      Set(expectations.map(\.attachmentID)).count == expectations.count,
      Set(expectations.map(\.pictureID)).count == expectations.count,
      TiebaStaticImageContentPolicy.canCompileWithinLimits(
        userContent: expectedContent,
        imageCount: expectations.count,
        maximumCharacterCount: TextReplyContentPolicy.maximumCharacterCount,
        maximumUTF8ByteCount: TextReplyContentPolicy.maximumUTF8ByteCount
      ),
      let expectedTokens = TiebaClassicEmoticonTokenizer.submissionProofTokens(
        in: expectedContent
      ),
      let firstImageIndex = contents.firstIndex(where: isImage),
      let observedPrefix = contentTokens(from: contents[..<firstImageIndex]),
      observedPrefix == expectedTokens
        || droppingOneTrailingNewline(from: observedPrefix) == expectedTokens
    else { return false }

    var expectationIndex = 0
    var allowsSeparator = false
    for content in contents[firstImageIndex...] {
      switch content {
      case .image:
        guard
          expectationIndex < expectations.count,
          image(content, matches: expectations[expectationIndex])
        else { return false }
        expectationIndex += 1
        allowsSeparator = expectationIndex < expectations.count
      case .text(let value) where value.isEmpty:
        continue
      case .text(let value) where allowsSeparator && value == "\n":
        allowsSeparator = false
      default:
        return false
      }
    }
    return expectationIndex == expectations.count
  }

  private static func isImage(_ content: BrowseContent) -> Bool {
    if case .image = content { return true }
    return false
  }

  private static func image(
    _ content: BrowseContent,
    matches expectation: TextReplyImageVisibilityExpectation
  ) -> Bool {
    guard
      case .image(
        let thumbnail,
        let fullSize,
        let original,
        let dynamic,
        let width,
        let height
      ) = content,
      width == expectation.width,
      height == expectation.height
    else { return false }
    let urls = [thumbnail, fullSize, original, dynamic].compactMap { $0 }
    let pictureIDs = urls.compactMap {
      TiebaPicturePageCursor(imageURL: $0, overallIndex: 1)?.pictureID
    }
    return !urls.isEmpty
      && pictureIDs.count == urls.count
      && pictureIDs.allSatisfy { $0 == expectation.pictureID }
  }

  private static func contentTokens(
    from contents: ArraySlice<BrowseContent>
  ) -> [[UInt8]]? {
    var result = [[UInt8]]()
    for content in contents {
      switch content {
      case .text(let fragment):
        appendTextToken(fragment, to: &result)
      case .emoticon(let name, _):
        guard TiebaClassicEmoticonCatalog.token(for: name) != nil else { return nil }
        result.append([UInt8(1)] + Array(name.utf8))
      case .mention(let name, _):
        appendTextToken(name.hasPrefix("@") ? name : "@\(name)", to: &result)
      case .link, .image, .video, .voice, .unsupported:
        return nil
      }
    }
    return result
  }

  private static func droppingOneTrailingNewline(
    from tokens: [[UInt8]]
  ) -> [[UInt8]]? {
    guard
      var final = tokens.last,
      final.first == 0,
      final.last == 0x0A
    else { return nil }
    final.removeLast()
    var result = tokens
    if final.count == 1 {
      result.removeLast()
    } else {
      result[result.count - 1] = final
    }
    return result
  }

  private static func appendTextToken(
    _ value: String,
    to tokens: inout [[UInt8]]
  ) {
    guard !value.isEmpty else { return }
    if tokens.last?.first == 0 {
      tokens[tokens.count - 1].append(contentsOf: value.utf8)
    } else {
      tokens.append([UInt8(0)] + Array(value.utf8))
    }
  }
}
