import Foundation

enum ComposerImageAttachmentQuality: String, Codable, CaseIterable, Sendable {
  case standard
  case highQuality

  var maximumPixelSize: Int {
    switch self {
    case .standard:
      1_080
    case .highQuality:
      4_096
    }
  }

  var maximumByteCount: Int64 {
    switch self {
    case .standard:
      5 * 1_024 * 1_024
    case .highQuality:
      10 * 1_024 * 1_024
    }
  }
}

enum ComposerImageAttachmentEncoding: String, Codable, Sendable {
  case jpeg

  var filenameExtension: String {
    switch self {
    case .jpeg:
      "jpg"
    }
  }
}

struct ComposerImageAttachment:
  Identifiable, Hashable, Codable, Sendable, CustomStringConvertible,
  CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let relativePrivateFilename: String
  let sha256: String
  let byteCount: Int64
  let pixelWidth: Int
  let pixelHeight: Int
  let encoding: ComposerImageAttachmentEncoding
  let quality: ComposerImageAttachmentQuality

  init?(
    id: UUID,
    relativePrivateFilename: String,
    sha256: String,
    byteCount: Int64,
    pixelWidth: Int,
    pixelHeight: Int,
    encoding: ComposerImageAttachmentEncoding,
    quality: ComposerImageAttachmentQuality
  ) {
    guard
      relativePrivateFilename == Self.privateFilename(for: id, encoding: encoding),
      Self.isValidSHA256(sha256),
      byteCount > 0,
      byteCount <= quality.maximumByteCount,
      Self.acceptsDimensions(
        width: pixelWidth,
        height: pixelHeight,
        maximumPixelSize: quality.maximumPixelSize
      )
    else { return nil }

    self.id = id
    self.relativePrivateFilename = relativePrivateFilename
    self.sha256 = sha256
    self.byteCount = byteCount
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.encoding = encoding
    self.quality = quality
  }

  init?(
    id: UUID,
    sha256: String,
    byteCount: Int64,
    pixelWidth: Int,
    pixelHeight: Int,
    encoding: ComposerImageAttachmentEncoding = .jpeg,
    quality: ComposerImageAttachmentQuality
  ) {
    self.init(
      id: id,
      relativePrivateFilename: Self.privateFilename(for: id, encoding: encoding),
      sha256: sha256,
      byteCount: byteCount,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      encoding: encoding,
      quality: quality
    )
  }

  var description: String { "ComposerImageAttachment(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": id,
        "byteCount": byteCount,
        "pixelWidth": pixelWidth,
        "pixelHeight": pixelHeight,
        "encoding": encoding,
        "quality": quality,
      ],
      displayStyle: .struct
    )
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case relativePrivateFilename
    case sha256
    case byteCount
    case pixelWidth
    case pixelHeight
    case encoding
    case quality
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let id = try container.decode(UUID.self, forKey: .id)
    let relativePrivateFilename = try container.decode(
      String.self,
      forKey: .relativePrivateFilename
    )
    let sha256 = try container.decode(String.self, forKey: .sha256)
    let byteCount = try container.decode(Int64.self, forKey: .byteCount)
    let pixelWidth = try container.decode(Int.self, forKey: .pixelWidth)
    let pixelHeight = try container.decode(Int.self, forKey: .pixelHeight)
    let encoding = try container.decode(
      ComposerImageAttachmentEncoding.self,
      forKey: .encoding
    )
    let quality = try container.decode(
      ComposerImageAttachmentQuality.self,
      forKey: .quality
    )
    guard
      let validated = Self(
        id: id,
        relativePrivateFilename: relativePrivateFilename,
        sha256: sha256,
        byteCount: byteCount,
        pixelWidth: pixelWidth,
        pixelHeight: pixelHeight,
        encoding: encoding,
        quality: quality
      )
    else {
      throw DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: decoder.codingPath,
          debugDescription: "Invalid private composer image attachment metadata."
        )
      )
    }
    self = validated
  }

  static func privateFilename(
    for id: UUID,
    encoding: ComposerImageAttachmentEncoding = .jpeg
  ) -> String {
    "\(id.uuidString.lowercased()).\(encoding.filenameExtension)"
  }

  static func isValidRelativePrivateFilename(_ value: String) -> Bool {
    guard
      !value.isEmpty,
      value == URL(fileURLWithPath: value).lastPathComponent,
      !value.contains("/"),
      !value.contains("\\"),
      !value.contains("..")
    else { return false }
    return UUID(uuidString: String(value.dropLast(4))) != nil && value.hasSuffix(".jpg")
  }

  static func isValidSHA256(_ value: String) -> Bool {
    value.count == 64
      && value.unicodeScalars.allSatisfy { scalar in
        (scalar.value >= 48 && scalar.value <= 57)
          || (scalar.value >= 97 && scalar.value <= 102)
      }
  }

  static func acceptsDimensions(
    width: Int,
    height: Int,
    maximumPixelSize: Int
  ) -> Bool {
    guard
      width > 0,
      height > 0,
      maximumPixelSize > 0,
      width <= maximumPixelSize,
      height <= maximumPixelSize,
      width <= ComposerImageProcessingPolicy.maximumDecodedPixelCount / height
    else { return false }
    return true
  }
}
