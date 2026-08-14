import CryptoKit
import Foundation

public enum TiebaStaticImageWatermark: String, Codable, Sendable, Hashable {
  case none = "0"
  case username = "1"
  case forumName = "2"
}

public enum TiebaStaticImageUploadPolicy {
  public static let chunkSize = 512_000
  public static let maximumStandardImageBytes = 5 * 1_024 * 1_024
  public static let maximumOriginalImageBytes = 10 * 1_024 * 1_024
  public static let maximumPixelDimension = 65_535
  public static let maximumForumNameUTF8Bytes = 1_024
  public static let maximumResponseBodyBytes = 64 * 1_024

  static func contentDigest(of data: Data) -> [UInt8] {
    Array(SHA256.hash(data: data))
  }

  static func hexadecimalString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  static func resourceID(for data: Data) -> String {
    let digest = Insecure.MD5.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    return digest + String(chunkSize)
  }

  static func chunkCount(forByteCount byteCount: Int) -> Int? {
    guard byteCount > 0 else { return nil }
    return (byteCount - 1) / chunkSize + 1
  }
}

enum TiebaStaticImageUploadEndpointPolicy {
  static let host = "tiebac.baidu.com"
  static let path = "/c/s/uploadPicture"

  static func allows(_ url: URL?) -> Bool {
    guard
      let url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased() == host,
      components.port == nil,
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      components.percentEncodedPath == path,
      components.percentEncodedQuery == nil,
      strictAuthority(from: url.absoluteString)?.lowercased() == host
    else { return false }
    return true
  }

  private static func strictAuthority(from absoluteValue: String) -> Substring? {
    guard let separator = absoluteValue.range(of: "://") else { return nil }
    let remainder = absoluteValue[separator.upperBound...]
    let authorityEnd =
      remainder.firstIndex { character in
        character == "/" || character == "?" || character == "#"
      } ?? remainder.endIndex
    return remainder[..<authorityEnd]
  }
}

public struct TiebaStaticImageUpload:
  Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let uploadID: UUID
  public let forumName: String
  public let encodedBytes: Data
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let preservesOriginal: Bool
  public let watermark: TiebaStaticImageWatermark

  public init(
    uploadID: UUID,
    forumName: String,
    encodedBytes: Data,
    pixelWidth: Int,
    pixelHeight: Int,
    preservesOriginal: Bool = false,
    watermark: TiebaStaticImageWatermark = .forumName
  ) {
    self.uploadID = uploadID
    self.forumName = forumName
    self.encodedBytes = encodedBytes
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.preservesOriginal = preservesOriginal
    self.watermark = watermark
  }

  public var description: String { "TiebaStaticImageUpload(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "uploadID": uploadID,
        "pixelWidth": pixelWidth,
        "pixelHeight": pixelHeight,
        "byteCount": encodedBytes.count,
        "preservesOriginal": preservesOriginal,
        "watermark": watermark,
      ],
      displayStyle: .struct
    )
  }
}

public struct TiebaStaticImageUploadReceipt: Codable, Sendable, Hashable {
  public static let currentSchemaVersion = 1

  public let schemaVersion: Int
  public let uploadID: UUID
  public let contentSHA256: String
  public let userID: Int64
  public let forumName: String
  public let preservesOriginal: Bool
  public let watermark: TiebaStaticImageWatermark
  public let uploadedPixelWidth: Int
  public let uploadedPixelHeight: Int
  public let resourceID: String
  public let picID: String
  public let width: Int
  public let height: Int
  public let byteCount: Int
  public let chunkCount: Int

  init(
    uploadID: UUID,
    contentSHA256: String,
    userID: Int64,
    forumName: String,
    preservesOriginal: Bool,
    watermark: TiebaStaticImageWatermark,
    uploadedPixelWidth: Int,
    uploadedPixelHeight: Int,
    resourceID: String,
    picID: String,
    width: Int,
    height: Int,
    byteCount: Int,
    chunkCount: Int
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.uploadID = uploadID
    self.contentSHA256 = contentSHA256
    self.userID = userID
    self.forumName = forumName
    self.preservesOriginal = preservesOriginal
    self.watermark = watermark
    self.uploadedPixelWidth = uploadedPixelWidth
    self.uploadedPixelHeight = uploadedPixelHeight
    self.resourceID = resourceID
    self.picID = picID
    self.width = width
    self.height = height
    self.byteCount = byteCount
    self.chunkCount = chunkCount
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case uploadID
    case contentSHA256
    case userID
    case forumName
    case preservesOriginal
    case watermark
    case uploadedPixelWidth
    case uploadedPixelHeight
    case resourceID
    case picID
    case width
    case height
    case byteCount
    case chunkCount
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    let uploadID = try container.decode(UUID.self, forKey: .uploadID)
    let contentSHA256 = try container.decode(String.self, forKey: .contentSHA256)
    let userID = try container.decode(Int64.self, forKey: .userID)
    let forumName = try container.decode(String.self, forKey: .forumName)
    let preservesOriginal = try container.decode(Bool.self, forKey: .preservesOriginal)
    let watermark = try container.decode(TiebaStaticImageWatermark.self, forKey: .watermark)
    let uploadedPixelWidth = try container.decode(Int.self, forKey: .uploadedPixelWidth)
    let uploadedPixelHeight = try container.decode(Int.self, forKey: .uploadedPixelHeight)
    let resourceID = try container.decode(String.self, forKey: .resourceID)
    let picID = try container.decode(String.self, forKey: .picID)
    let width = try container.decode(Int.self, forKey: .width)
    let height = try container.decode(Int.self, forKey: .height)
    let byteCount = try container.decode(Int.self, forKey: .byteCount)
    let chunkCount = try container.decode(Int.self, forKey: .chunkCount)
    let maximumBytes =
      preservesOriginal
      ? TiebaStaticImageUploadPolicy.maximumOriginalImageBytes
      : TiebaStaticImageUploadPolicy.maximumStandardImageBytes
    guard
      schemaVersion == Self.currentSchemaVersion,
      Self.isValidSHA256(contentSHA256),
      userID > 0,
      Self.isValidNormalizedForumName(forumName),
      (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(uploadedPixelWidth),
      (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(uploadedPixelHeight),
      Self.isValidResourceID(resourceID),
      TiebaPicturePagePolicy.isValidPictureID(picID),
      (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(width),
      (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(height),
      (1...maximumBytes).contains(byteCount),
      chunkCount == (byteCount - 1) / TiebaStaticImageUploadPolicy.chunkSize + 1
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid image upload receipt.")
      )
    }
    self.init(
      uploadID: uploadID,
      contentSHA256: contentSHA256,
      userID: userID,
      forumName: forumName,
      preservesOriginal: preservesOriginal,
      watermark: watermark,
      uploadedPixelWidth: uploadedPixelWidth,
      uploadedPixelHeight: uploadedPixelHeight,
      resourceID: resourceID,
      picID: picID,
      width: width,
      height: height,
      byteCount: byteCount,
      chunkCount: chunkCount
    )
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(uploadID, forKey: .uploadID)
    try container.encode(contentSHA256, forKey: .contentSHA256)
    try container.encode(userID, forKey: .userID)
    try container.encode(forumName, forKey: .forumName)
    try container.encode(preservesOriginal, forKey: .preservesOriginal)
    try container.encode(watermark, forKey: .watermark)
    try container.encode(uploadedPixelWidth, forKey: .uploadedPixelWidth)
    try container.encode(uploadedPixelHeight, forKey: .uploadedPixelHeight)
    try container.encode(resourceID, forKey: .resourceID)
    try container.encode(picID, forKey: .picID)
    try container.encode(width, forKey: .width)
    try container.encode(height, forKey: .height)
    try container.encode(byteCount, forKey: .byteCount)
    try container.encode(chunkCount, forKey: .chunkCount)
  }

  public func isBound(
    to upload: TiebaStaticImageUpload,
    expectedUserID: Int64
  ) -> Bool {
    let normalizedForumName = upload.forumName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    let maximumBytes =
      upload.preservesOriginal
      ? TiebaStaticImageUploadPolicy.maximumOriginalImageBytes
      : TiebaStaticImageUploadPolicy.maximumStandardImageBytes
    guard
      schemaVersion == Self.currentSchemaVersion,
      expectedUserID > 0,
      Self.isValidNormalizedForumName(normalizedForumName),
      !upload.encodedBytes.isEmpty,
      upload.encodedBytes.count <= maximumBytes,
      (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(upload.pixelWidth),
      (1...TiebaStaticImageUploadPolicy.maximumPixelDimension).contains(upload.pixelHeight),
      let expectedChunkCount = TiebaStaticImageUploadPolicy.chunkCount(
        forByteCount: upload.encodedBytes.count
      )
    else { return false }

    let digest = TiebaStaticImageUploadPolicy.contentDigest(of: upload.encodedBytes)
    return
      uploadID == upload.uploadID
      && contentSHA256 == TiebaStaticImageUploadPolicy.hexadecimalString(digest)
      && userID == expectedUserID
      && forumName == normalizedForumName
      && preservesOriginal == upload.preservesOriginal
      && watermark == upload.watermark
      && uploadedPixelWidth == upload.pixelWidth
      && uploadedPixelHeight == upload.pixelHeight
      && resourceID == TiebaStaticImageUploadPolicy.resourceID(for: upload.encodedBytes)
      && byteCount == upload.encodedBytes.count
      && chunkCount == expectedChunkCount
  }

  private static func isValidResourceID(_ value: String) -> Bool {
    let suffix = String(TiebaStaticImageUploadPolicy.chunkSize)
    guard value.hasSuffix(suffix) else { return false }
    let digest = value.dropLast(suffix.count)
    return digest.utf8.count == 32 && digest.utf8.allSatisfy(Self.isLowercaseHex)
  }

  private static func isValidSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy(Self.isLowercaseHex)
  }

  private static func isValidNormalizedForumName(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    return
      !value.isEmpty
      && value.count <= 100
      && value.utf8.count <= TiebaStaticImageUploadPolicy.maximumForumNameUTF8Bytes
      && value.utf8.elementsEqual(normalized.utf8)
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }

  private static func isLowercaseHex(_ byte: UInt8) -> Bool {
    (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
  }
}

struct TiebaStaticImageUploadPlan: Sendable {
  let upload: TiebaStaticImageUpload
  let expectedUserID: Int64
  let normalizedForumName: String
  let resourceID: String
  let contentDigest: [UInt8]
  let chunkCount: Int

  var byteCount: Int { upload.encodedBytes.count }
  var contentSHA256: String {
    TiebaStaticImageUploadPolicy.hexadecimalString(contentDigest)
  }
}

enum TiebaStaticImageChunkDecodeResult: Sendable, Equatable {
  case accepted
  case completed(TiebaStaticImageUploadReceipt)
}
