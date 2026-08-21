import Foundation
import TiebaProto

public enum TiebaStaticImageContentPolicy {
  public static let maximumImageCount = 9

  public static func canCompileWithinLimits(
    userContent: String,
    imageCount: Int,
    maximumCharacterCount: Int,
    maximumUTF8ByteCount: Int
  ) -> Bool {
    guard
      (0...maximumImageCount).contains(imageCount),
      maximumCharacterCount >= 0,
      maximumUTF8ByteCount >= 0,
      TiebaTextReplyContentPolicy.isValidUserText(
        userContent,
        allowsVisuallyEmptyValue: imageCount > 0 && userContent.isEmpty
      )
    else { return false }

    let maximumDimension = String(TiebaStaticImageUploadPolicy.maximumPixelDimension)
    let maximumMarker =
      "#(pic,"
      + String(repeating: "f", count: TiebaPicturePagePolicy.pictureIDByteCount)
      + ",\(maximumDimension),\(maximumDimension))"
    let separatorCount = imageCount == 0 ? 0 : imageCount - (userContent.isEmpty ? 1 : 0)
    let addedCharacterCount = imageCount * maximumMarker.count + separatorCount
    let addedUTF8ByteCount = imageCount * maximumMarker.utf8.count + separatorCount
    guard
      addedCharacterCount <= maximumCharacterCount,
      addedUTF8ByteCount <= maximumUTF8ByteCount
    else { return false }
    return userContent.count <= maximumCharacterCount - addedCharacterCount
      && userContent.utf8.count <= maximumUTF8ByteCount - addedUTF8ByteCount
  }
}

public struct TiebaStaticImageContentProof:
  Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let submissionID: UUID
  public let userID: Int64
  public let forumID: Int64
  public let forumName: String
  public let uploadID: UUID
  public let picID: String
  public let width: Int
  public let height: Int

  private let contentSHA256: String
  private let resourceID: String
  private let preservesOriginal: Bool
  private let watermark: TiebaStaticImageWatermark
  private let uploadedPixelWidth: Int
  private let uploadedPixelHeight: Int
  private let byteCount: Int
  private let chunkCount: Int

  private init(
    submissionID: UUID,
    userID: Int64,
    forumID: Int64,
    forumName: String,
    uploadID: UUID,
    picID: String,
    width: Int,
    height: Int,
    contentSHA256: String,
    resourceID: String,
    preservesOriginal: Bool,
    watermark: TiebaStaticImageWatermark,
    uploadedPixelWidth: Int,
    uploadedPixelHeight: Int,
    byteCount: Int,
    chunkCount: Int
  ) {
    self.submissionID = submissionID
    self.userID = userID
    self.forumID = forumID
    self.forumName = forumName
    self.uploadID = uploadID
    self.picID = picID
    self.width = width
    self.height = height
    self.contentSHA256 = contentSHA256
    self.resourceID = resourceID
    self.preservesOriginal = preservesOriginal
    self.watermark = watermark
    self.uploadedPixelWidth = uploadedPixelWidth
    self.uploadedPixelHeight = uploadedPixelHeight
    self.byteCount = byteCount
    self.chunkCount = chunkCount
  }

  @_spi(TiebaPlusPlusApp)
  public static func bind(
    upload: TiebaStaticImageUpload,
    receipt: TiebaStaticImageUploadReceipt,
    expectedUserID: Int64,
    submissionID: UUID,
    forumID: Int64
  ) throws -> Self {
    guard
      expectedUserID > 0,
      forumID > 0,
      receipt.isBound(to: upload, expectedUserID: expectedUserID),
      receipt.userID == expectedUserID,
      TiebaPicturePagePolicy.isValidPictureID(receipt.picID),
      (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(receipt.width),
      (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(receipt.height)
    else {
      throw TiebaClientError.invalidArgument(
        "The image upload receipt is not bound to the supplied upload and account."
      )
    }

    return Self(
      submissionID: submissionID,
      userID: expectedUserID,
      forumID: forumID,
      forumName: receipt.forumName,
      uploadID: upload.uploadID,
      picID: receipt.picID,
      width: receipt.width,
      height: receipt.height,
      contentSHA256: receipt.contentSHA256,
      resourceID: receipt.resourceID,
      preservesOriginal: receipt.preservesOriginal,
      watermark: receipt.watermark,
      uploadedPixelWidth: receipt.uploadedPixelWidth,
      uploadedPixelHeight: receipt.uploadedPixelHeight,
      byteCount: receipt.byteCount,
      chunkCount: receipt.chunkCount
    )
  }

  public var description: String { "TiebaStaticImageContentProof(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "submissionID": submissionID,
        "userID": userID,
        "forumID": forumID,
        "uploadID": uploadID,
        "width": width,
        "height": height,
      ],
      displayStyle: .struct
    )
  }

  fileprivate var wireMarker: String {
    "#(pic,\(picID),\(width),\(height))"
  }

  fileprivate func isBound(
    to submissionID: UUID,
    expectedUserID: Int64,
    forumID: Int64,
    normalizedForumName: String
  ) -> Bool {
    self.submissionID == submissionID
      && userID == expectedUserID
      && self.forumID == forumID
      && forumName.utf8.elementsEqual(normalizedForumName.utf8)
      && TiebaPicturePagePolicy.isValidPictureID(picID)
      && (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(width)
      && (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(height)
      && contentSHA256.utf8.count == 64
      && resourceID.hasSuffix(String(TiebaStaticImageUploadPolicy.chunkSize))
      && (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(uploadedPixelWidth)
      && (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(uploadedPixelHeight)
      && byteCount > 0
      && chunkCount == (byteCount - 1) / TiebaStaticImageUploadPolicy.chunkSize + 1
  }
}

struct TiebaCompiledSubmissionContent: Sendable, Hashable {
  let wireValue: String
  let imageProofs: [TiebaStaticImageContentProof]
}

enum TiebaStaticImageContentCompiler {
  static func compile(
    userContent: String,
    imageProofs: [TiebaStaticImageContentProof],
    submissionID: UUID,
    expectedUserID: Int64,
    forumID: Int64,
    normalizedForumName: String,
    allowsImages: Bool,
    maximumCharacterCount: Int,
    maximumUTF8ByteCount: Int
  ) throws -> TiebaCompiledSubmissionContent {
    guard imageProofs.count <= TiebaStaticImageContentPolicy.maximumImageCount else {
      throw TiebaClientError.invalidArgument(
        "A submission may contain at most \(TiebaStaticImageContentPolicy.maximumImageCount) images."
      )
    }
    guard allowsImages || imageProofs.isEmpty else {
      throw TiebaClientError.invalidArgument(
        "Images can only be attached to a direct thread reply."
      )
    }
    guard
      TiebaTextReplyContentPolicy.isValidUserText(
        userContent,
        allowsVisuallyEmptyValue: !imageProofs.isEmpty && userContent.isEmpty
      )
    else {
      throw TiebaClientError.invalidArgument(
        "Submission text is empty, too large, contains unsupported control characters, or contains an unsupported Tieba rich-content marker."
      )
    }

    var uploadIDs = Set<UUID>()
    var picIDs = Set<String>()
    for proof in imageProofs {
      guard
        proof.isBound(
          to: submissionID,
          expectedUserID: expectedUserID,
          forumID: forumID,
          normalizedForumName: normalizedForumName
        ),
        uploadIDs.insert(proof.uploadID).inserted,
        picIDs.insert(proof.picID).inserted
      else {
        throw TiebaClientError.invalidArgument(
          "Image proofs must be unique and bound to this submission, account, and forum."
        )
      }
    }

    var wireValue = userContent
    for proof in imageProofs {
      if !wireValue.isEmpty {
        wireValue.append("\n")
      }
      wireValue.append(proof.wireMarker)
    }
    guard
      wireValue.count <= maximumCharacterCount,
      wireValue.utf8.count <= maximumUTF8ByteCount
    else {
      throw TiebaClientError.invalidArgument(
        "Compiled submission content exceeds Tieba's character or UTF-8 byte limit."
      )
    }
    return TiebaCompiledSubmissionContent(wireValue: wireValue, imageProofs: imageProofs)
  }

  static func readbackMatches(
    _ fragments: [PbContent],
    userContent: String,
    imageProofs: [TiebaStaticImageContentProof],
    submissionID: UUID,
    expectedUserID: Int64,
    forumID: Int64,
    normalizedForumName: String,
    maximumUTF8ByteCount: Int,
    allowsMentions: Bool
  ) -> Bool {
    guard
      imageProofs.count <= TiebaStaticImageContentPolicy.maximumImageCount,
      imageProofs.allSatisfy({
        $0.isBound(
          to: submissionID,
          expectedUserID: expectedUserID,
          forumID: forumID,
          normalizedForumName: normalizedForumName
        )
      }),
      Set(imageProofs.map(\.uploadID)).count == imageProofs.count,
      Set(imageProofs.map(\.picID)).count == imageProofs.count,
      let submittedTokens = TiebaClassicEmoticonTokenizer.submissionTokens(in: userContent)
    else { return false }

    guard !imageProofs.isEmpty else {
      guard
        let readbackTokens = TiebaClassicEmoticonTokenizer.readbackTokens(
          in: fragments,
          maximumUTF8ByteCount: maximumUTF8ByteCount,
          allowsMentions: allowsMentions
        )
      else { return false }
      return readbackTokens == submittedTokens
    }

    guard let firstImageIndex = fragments.firstIndex(where: { isImageFragment($0) }) else {
      return false
    }
    let prefixFragments = Array(fragments[..<firstImageIndex])
    guard
      let readbackPrefix = TiebaClassicEmoticonTokenizer.readbackTokens(
        in: prefixFragments,
        maximumUTF8ByteCount: maximumUTF8ByteCount,
        allowsMentions: allowsMentions
      ),
      readbackPrefix == submittedTokens
        || droppingOneTrailingWireNewline(from: readbackPrefix) == submittedTokens
    else { return false }

    var proofIndex = 0
    var allowsWireSeparator = false
    for fragment in fragments[firstImageIndex...] {
      if Self.isImageFragment(fragment) {
        guard
          proofIndex < imageProofs.count,
          imageFragment(fragment, matches: imageProofs[proofIndex])
        else { return false }
        proofIndex += 1
        allowsWireSeparator = proofIndex < imageProofs.count
      } else if Self.isEmptyTextFragment(fragment) {
        continue
      } else if allowsWireSeparator && Self.isWireSeparatorFragment(fragment) {
        allowsWireSeparator = false
      } else {
        return false
      }
    }
    return proofIndex == imageProofs.count
  }

  private static func droppingOneTrailingWireNewline(
    from tokens: [TiebaClassicEmoticonContentToken]
  ) -> [TiebaClassicEmoticonContentToken]? {
    guard case .text(let text)? = tokens.last, text.last == "\n" else { return nil }
    var result = tokens
    let shortened = String(text.dropLast())
    if shortened.isEmpty {
      result.removeLast()
    } else {
      result[result.count - 1] = .text(shortened)
    }
    return result
  }

  private static func isImageFragment(_ fragment: PbContent) -> Bool {
    fragment.type == 3 || fragment.type == 20
  }

  private static func isEmptyTextFragment(_ fragment: PbContent) -> Bool {
    TiebaClassicEmoticonTokenizer.isReadbackTextType(fragment.type) && fragment.text.isEmpty
  }

  private static func isWireSeparatorFragment(_ fragment: PbContent) -> Bool {
    TiebaClassicEmoticonTokenizer.isReadbackTextType(fragment.type) && fragment.text == "\n"
  }

  private static func imageFragment(
    _ fragment: PbContent,
    matches proof: TiebaStaticImageContentProof
  ) -> Bool {
    let rawURLs = [fragment.src, fragment.cdnSrc, fragment.bigCdnSrc, fragment.originSrc]
      .filter { !$0.isEmpty }
    let pictureIDs = rawURLs.compactMap { pictureID(from: $0) }
    guard
      !rawURLs.isEmpty,
      pictureIDs.count == rawURLs.count,
      pictureIDs.allSatisfy({ $0 == pictureIDs[0] }),
      pictureIDs[0] == proof.picID
    else { return false }

    let bsize: (width: Int, height: Int)?
    if fragment.bsize.isEmpty {
      bsize = nil
    } else {
      guard let parsed = parsedBSize(fragment.bsize) else { return false }
      bsize = parsed
    }
    let explicitWidth = fragment.width == 0 ? nil : Int(exactly: fragment.width)
    let explicitHeight = fragment.height == 0 ? nil : Int(exactly: fragment.height)
    guard
      explicitWidth.map({ $0 == proof.width }) ?? true,
      explicitHeight.map({ $0 == proof.height }) ?? true,
      bsize.map({ $0.width == proof.width && $0.height == proof.height }) ?? true,
      bsize != nil || (explicitWidth != nil && explicitHeight != nil)
    else { return false }
    return true
  }

  private static func pictureID(from rawValue: String) -> String? {
    guard !rawValue.isEmpty, rawValue.utf8.count <= 4_096 else { return nil }
    let absoluteValue = rawValue.hasPrefix("//") ? "https:\(rawValue)" : rawValue
    guard let url = URL(string: absoluteValue) else { return nil }
    return TiebaPictureMediaURLPolicy.pictureID(from: url)
  }

  private static func parsedBSize(_ value: String) -> (width: Int, height: Int)? {
    let parts = value.utf8.split(separator: 0x2C, omittingEmptySubsequences: false)
    guard
      parts.count == 2,
      let width = canonicalPositiveInt(Array(parts[0])),
      let height = canonicalPositiveInt(Array(parts[1])),
      width <= TiebaStaticImageUploadPolicy.maximumPixelDimension,
      height <= TiebaStaticImageUploadPolicy.maximumPixelDimension
    else { return nil }
    return (width, height)
  }

  private static func canonicalPositiveInt(_ bytes: [UInt8]) -> Int? {
    guard
      !bytes.isEmpty,
      bytes.allSatisfy({ (0x30...0x39).contains($0) }),
      bytes.first != 0x30,
      let value = Int(String(decoding: bytes, as: UTF8.self)),
      value > 0
    else { return nil }
    return value
  }
}
