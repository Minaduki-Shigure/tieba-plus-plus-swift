import Foundation

public enum TiebaPicturePageDirection: Sendable, Hashable {
  case next
  case previous
}

public struct TiebaPicturePageCursor: Sendable, Hashable {
  public let pictureID: String
  public let overallIndex: Int

  public init?(imageURL: URL, overallIndex: Int = 1) {
    guard
      (1...TiebaPicturePagePolicy.maximumPictureCount).contains(overallIndex),
      let pictureID = TiebaPictureMediaURLPolicy.pictureID(from: imageURL)
    else { return nil }
    self.pictureID = pictureID
    self.overallIndex = overallIndex
  }

  public init?(serverPictureID: String, overallIndex: Int) {
    guard
      TiebaPicturePagePolicy.isValidPictureID(serverPictureID),
      (1...TiebaPicturePagePolicy.maximumPictureCount).contains(overallIndex)
    else { return nil }
    self.pictureID = serverPictureID
    self.overallIndex = overallIndex
  }
}

public struct TiebaPicturePageImage: Identifiable, Sendable, Hashable {
  public var id: TiebaPicturePageCursor { cursor }
  public var pictureID: String { cursor.pictureID }
  public var overallIndex: Int { cursor.overallIndex }

  public let cursor: TiebaPicturePageCursor
  public let postID: Int64?
  public let thumbnailURL: URL?
  public let fullSizeURL: URL?
  public let originalURL: URL
  public let width: Int
  public let height: Int
  public let originalByteCount: Int
  public let isLongPicture: Bool
  public let offersOriginal: Bool

  public init(
    cursor: TiebaPicturePageCursor,
    postID: Int64?,
    thumbnailURL: URL?,
    fullSizeURL: URL?,
    originalURL: URL,
    width: Int,
    height: Int,
    originalByteCount: Int,
    isLongPicture: Bool,
    offersOriginal: Bool
  ) {
    self.cursor = cursor
    self.postID = postID
    self.thumbnailURL = thumbnailURL
    self.fullSizeURL = fullSizeURL
    self.originalURL = originalURL
    self.width = width
    self.height = height
    self.originalByteCount = originalByteCount
    self.isLongPicture = isLongPicture
    self.offersOriginal = offersOriginal
  }
}

public struct TiebaPicturePage: Sendable, Hashable {
  public let forumID: Int64
  public let forumName: String
  public let totalPictureCount: Int
  public let pictures: [TiebaPicturePageImage]
  public let hasPrevious: Bool
  public let hasNext: Bool

  public init(
    forumID: Int64,
    forumName: String,
    totalPictureCount: Int,
    pictures: [TiebaPicturePageImage],
    hasPrevious: Bool,
    hasNext: Bool
  ) {
    self.forumID = forumID
    self.forumName = forumName
    self.totalPictureCount = totalPictureCount
    self.pictures = pictures
    self.hasPrevious = hasPrevious
    self.hasNext = hasNext
  }
}

enum TiebaPicturePagePolicy {
  static let maximumPictureCount = 10_000
  static let requestedBatchSize = 10
  static let maximumResponsePictureCount = 50
  static let maximumDimension = 100_000
  static let maximumOriginalByteCount = 1_073_741_824
  static let maximumResponseBodyBytes = 1_048_576

  static func isValidPictureID(_ value: String) -> Bool {
    value.utf8.count == 40 && value.utf8.allSatisfy {
      (48...57).contains($0) || (97...102).contains($0)
    }
  }
}

enum TiebaPicturePageEndpointPolicy {
  static let host = "c.tieba.baidu.com"

  static func allows(_ url: URL?) -> Bool {
    guard
      let url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased() == host,
      components.port == nil,
      components.user == nil,
      components.password == nil,
      strictAuthority(from: url.absoluteString)?.lowercased() == host
    else { return false }
    return true
  }

  static func allowsRedirect(from source: URL?, to destination: URL?) -> Bool {
    guard allows(source), allows(destination) else { return false }
    return source?.host?.caseInsensitiveCompare(destination?.host ?? "") == .orderedSame
  }

  private static func strictAuthority(from absoluteValue: String) -> Substring? {
    guard let separator = absoluteValue.range(of: "://") else { return nil }
    let remainder = absoluteValue[separator.upperBound...]
    let authorityEnd = remainder.firstIndex { character in
      character == "/" || character == "?" || character == "#"
    } ?? remainder.endIndex
    return remainder[..<authorityEnd]
  }
}

enum TiebaPictureMediaURLPolicy {
  private static let allowedHosts: Set<String> = [
    "a.hiphotos.baidu.com",
    "b.hiphotos.baidu.com",
    "c.hiphotos.baidu.com",
    "d.hiphotos.baidu.com",
    "e.hiphotos.baidu.com",
    "f.hiphotos.baidu.com",
    "hiphotos.baidu.com",
    "imgsa.baidu.com",
    "imgsrc.baidu.com",
    "tiebapic.baidu.com",
  ]

  static func pictureID(from url: URL) -> String? {
    guard
      !url.absoluteString.hasSuffix("?"),
      let components = validatedComponents(for: url),
      isAllowedBootstrapQuery(components.percentEncodedQuery)
    else { return nil }

    let path = components.percentEncodedPath
    guard
      path.utf8.count <= 2_048,
      path.hasPrefix("/forum/"),
      !path.contains("\\")
    else { return nil }

    let lowercasePath = path.lowercased()
    guard
      !lowercasePath.contains("%2f"),
      !lowercasePath.contains("%5c"),
      !lowercasePath.contains("%2e")
    else { return nil }

    let segments = path.split(separator: "/", omittingEmptySubsequences: false)
    guard
      segments.count >= 4,
      segments.first?.isEmpty == true,
      segments.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
      let filename = segments.last,
      filename.utf8.count == 44,
      filename.hasSuffix(".jpg")
    else { return nil }

    let pictureID = String(filename.dropLast(4))
    return TiebaPicturePagePolicy.isValidPictureID(pictureID) ? pictureID : nil
  }

  static func normalizedMediaURL(from rawValue: String?) -> URL? {
    guard let rawValue, rawValue.utf8.count <= 4_096 else { return nil }
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !value.isEmpty,
      let url = URL(string: value),
      var components = validatedComponents(for: url),
      !components.percentEncodedPath.isEmpty,
      components.percentEncodedPath.utf8.count <= 2_048,
      !components.percentEncodedPath.contains("\\"),
      (components.percentEncodedQuery?.utf8.count ?? 0) <= 1_024
    else { return nil }

    components.scheme = "https"
    return components.url
  }

  private static func validatedComponents(for url: URL) -> URLComponents? {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      let host = components.host?.lowercased(),
      allowedHosts.contains(host),
      components.user == nil,
      components.password == nil,
      components.port == nil,
      components.percentEncodedFragment == nil,
      strictAuthority(from: url.absoluteString)?.lowercased() == host
    else { return nil }
    return components
  }

  private static func isAllowedBootstrapQuery(_ query: String?) -> Bool {
    guard let query else { return true }
    guard
      query.hasPrefix("tbpicau="),
      query.utf8.count <= 192
    else { return false }
    let value = query.utf8.dropFirst("tbpicau=".utf8.count)
    return !value.isEmpty && value.allSatisfy {
      (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        || $0 == 45 || $0 == 95
    }
  }

  private static func strictAuthority(from absoluteValue: String) -> Substring? {
    guard let separator = absoluteValue.range(of: "://") else { return nil }
    let remainder = absoluteValue[separator.upperBound...]
    let authorityEnd = remainder.firstIndex { character in
      character == "/" || character == "?" || character == "#"
    } ?? remainder.endIndex
    return remainder[..<authorityEnd]
  }
}
