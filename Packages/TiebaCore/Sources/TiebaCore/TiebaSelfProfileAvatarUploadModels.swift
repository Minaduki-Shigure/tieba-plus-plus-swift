import CryptoKit
import Foundation

public enum TiebaSelfProfileAvatarModificationPermission: Sendable, Hashable {
  case allowed
  case denied(message: String)
}

public struct TiebaSelfProfileAvatarUpload:
  Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  public let uploadID: UUID
  public let jpegData: Data
  public let squarePixelSize: Int

  public init(uploadID: UUID = UUID(), jpegData: Data, squarePixelSize: Int) {
    self.uploadID = uploadID
    self.jpegData = jpegData
    self.squarePixelSize = squarePixelSize
  }

  public var description: String { "TiebaSelfProfileAvatarUpload(redacted)" }
  public var debugDescription: String { description }
  public var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "uploadID": uploadID,
        "byteCount": jpegData.count,
        "squarePixelSize": squarePixelSize,
      ],
      displayStyle: .struct
    )
  }
}

public enum TiebaSelfProfileAvatarUploadPolicy {
  public static let maximumJPEGByteCount = 2 * 1_024 * 1_024
  public static let minimumSquarePixelSize = 64
  public static let maximumSquarePixelSize = 1_024

  public static func isValid(_ upload: TiebaSelfProfileAvatarUpload) -> Bool {
    guard
      (4...maximumJPEGByteCount).contains(upload.jpegData.count),
      (minimumSquarePixelSize...maximumSquarePixelSize).contains(upload.squarePixelSize),
      upload.jpegData.prefix(2).elementsEqual([UInt8(0xFF), UInt8(0xD8)]),
      upload.jpegData.suffix(2).elementsEqual([UInt8(0xFF), UInt8(0xD9)]),
      let dimensions = jpegSOFDimensions(upload.jpegData)
    else { return false }
    return dimensions.width == upload.squarePixelSize
      && dimensions.height == upload.squarePixelSize
  }

  static func contentSHA256(of upload: TiebaSelfProfileAvatarUpload) -> String {
    SHA256.hash(data: upload.jpegData)
      .map { String(format: "%02x", $0) }
      .joined()
  }

  private static func jpegSOFDimensions(_ data: Data) -> (width: Int, height: Int)? {
    let bytes = [UInt8](data)
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
    var offset = 2
    var dimensions: (width: Int, height: Int)?
    var foundStartOfScan = false

    while offset < bytes.count {
      guard bytes[offset] == 0xFF else { return nil }
      while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
      guard offset < bytes.count else { return nil }
      let marker = bytes[offset]
      offset += 1

      if marker == 0xD9 {
        guard offset == bytes.count, foundStartOfScan else { return nil }
        return dimensions
      }
      guard
        marker != 0x00,
        marker != 0xD8,
        marker != 0x01,
        !(0xD0...0xD7).contains(marker)
      else { return nil }
      guard offset + 1 < bytes.count else { return nil }
      let segmentLength = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
      guard segmentLength >= 2, offset + segmentLength <= bytes.count else { return nil }
      let payloadStart = offset + 2
      let segmentEnd = offset + segmentLength

      switch marker {
      case 0xE0:
        guard isStandardJFIFPayload(bytes[payloadStart..<segmentEnd]) else { return nil }
      case 0xE1...0xEF, 0xFE:
        // Uploads are generated from a controlled render. Reject metadata-bearing
        // application and comment segments at the Core boundary as well.
        return nil
      case 0xC0, 0xC1, 0xC2:
        guard dimensions == nil, segmentEnd - payloadStart >= 6 else { return nil }
        let precision = bytes[payloadStart]
        let height = Int(bytes[payloadStart + 1]) << 8 | Int(bytes[payloadStart + 2])
        let width = Int(bytes[payloadStart + 3]) << 8 | Int(bytes[payloadStart + 4])
        let componentCount = Int(bytes[payloadStart + 5])
        guard
          precision == 8,
          componentCount == 3,
          segmentEnd - payloadStart == 6 + 3 * componentCount,
          width > 0,
          height > 0
        else { return nil }
        dimensions = (width, height)
      case 0xC4, 0xDB, 0xDD:
        break
      case 0xDA:
        guard dimensions != nil, segmentEnd - payloadStart >= 6 else { return nil }
        let componentCount = Int(bytes[payloadStart])
        guard
          componentCount > 0,
          segmentEnd - payloadStart == 4 + 2 * componentCount
        else { return nil }
        foundStartOfScan = true
      default:
        return nil
      }

      offset = segmentEnd
      if marker == 0xDA {
        guard let nextMarker = nextJPEGMarkerOffset(in: bytes, afterScanHeader: offset)
        else { return nil }
        offset = nextMarker
      }
    }
    return nil
  }

  private static func nextJPEGMarkerOffset(
    in bytes: [UInt8],
    afterScanHeader start: Int
  ) -> Int? {
    var offset = start
    while offset < bytes.count {
      guard bytes[offset] == 0xFF else {
        offset += 1
        continue
      }
      let markerOffset = offset
      while offset < bytes.count, bytes[offset] == 0xFF { offset += 1 }
      guard offset < bytes.count else { return nil }
      let marker = bytes[offset]
      if marker == 0x00 || (0xD0...0xD7).contains(marker) {
        offset += 1
        continue
      }
      return markerOffset
    }
    return nil
  }

  private static func isStandardJFIFPayload(_ payload: ArraySlice<UInt8>) -> Bool {
    let bytes = Array(payload)
    guard
      bytes.count >= 14,
      Array(bytes[0..<5]) == [0x4A, 0x46, 0x49, 0x46, 0x00],
      bytes[5] == 1
    else { return false }
    let thumbnailByteCount = Int(bytes[12]) * Int(bytes[13]) * 3
    return bytes.count == 14 + thumbnailByteCount
  }
}

struct TiebaSelfProfileAvatarUploadPlan: Sendable {
  let upload: TiebaSelfProfileAvatarUpload
  let contentSHA256: String
}

enum TiebaSelfProfileAvatarUploadEndpointPolicy {
  static let host = "tiebac.baidu.com"
  static let path = "/c/c/img/portrait"

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

public enum TiebaSelfProfileAvatarUploadDisposition: Sendable, Hashable {
  case confirmed
  case acceptedPendingReview(message: String)
}

public struct TiebaSelfProfileAvatarUploadResult: Sendable, Hashable {
  public let latestProfile: TiebaSelfProfileSummary
  public let disposition: TiebaSelfProfileAvatarUploadDisposition

  public init(
    latestProfile: TiebaSelfProfileSummary,
    disposition: TiebaSelfProfileAvatarUploadDisposition
  ) {
    self.latestProfile = latestProfile
    self.disposition = disposition
  }
}
