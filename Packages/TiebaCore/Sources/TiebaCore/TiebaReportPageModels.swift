import Foundation

public struct TiebaReportPage: Sendable, Hashable {
  public let postID: Int64
  public let url: URL

  public init(postID: Int64, url: URL) {
    self.postID = postID
    self.url = url
  }
}

enum TiebaReportPagePolicy {
  static let endpointHost = "c.tieba.baidu.com"
  static let reportHost = "tieba.baidu.com"
  static let endpointPath = "/c/f/ueg/checkjubao"
  static let reportPath = "/tpl/wise-bawu-core/report"
  static let maximumResponseBodyBytes = 64 * 1_024
  static let maximumRawURLBytes = 4_096

  static func allowsEndpoint(_ url: URL?) -> Bool {
    guard
      let url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      components.host?.lowercased() == endpointHost,
      components.port == nil,
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      components.percentEncodedPath == endpointPath,
      components.percentEncodedQuery == nil,
      strictAuthority(from: url.absoluteString)?.lowercased() == endpointHost
    else { return false }
    return true
  }

  static func canonicalReportURL(from rawValue: String, expectedPostID: Int64) -> URL? {
    guard
      expectedPostID > 0,
      !rawValue.isEmpty,
      rawValue.utf8.count <= maximumRawURLBytes,
      !rawValue.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
      !rawValue.contains("\\"),
      !rawValue.hasSuffix("?"),
      let components = URLComponents(string: rawValue),
      let scheme = components.scheme?.lowercased(),
      scheme == "http" || scheme == "https",
      components.host?.lowercased() == reportHost,
      components.port == nil,
      components.user == nil,
      components.password == nil,
      components.fragment == nil,
      components.percentEncodedPath == reportPath,
      strictAuthority(from: rawValue)?.lowercased() == reportHost,
      let rawQuery = components.percentEncodedQuery,
      exactReportQuery(rawQuery, expectedPostID: expectedPostID)
    else { return nil }

    var canonical = URLComponents()
    canonical.scheme = "https"
    canonical.host = reportHost
    canonical.path = reportPath
    canonical.queryItems = [
      URLQueryItem(name: "type", value: "2"),
      URLQueryItem(name: "post_id", value: String(expectedPostID)),
      URLQueryItem(name: "from", value: "threadPost"),
      URLQueryItem(name: "noshare", value: "1"),
      URLQueryItem(name: "loadingSignal", value: "1"),
    ]
    guard
      let url = canonical.url,
      url.scheme == "https",
      url.host == reportHost,
      url.port == nil,
      url.user == nil,
      url.password == nil
    else { return nil }
    return url
  }

  private static func exactReportQuery(_ rawQuery: String, expectedPostID: Int64) -> Bool {
    let expected = [
      "type": "2",
      "post_id": String(expectedPostID),
      "from": "threadPost",
      "noshare": "1",
      "loadingSignal": "1",
    ]
    let fields = rawQuery.split(separator: "&", omittingEmptySubsequences: false)
    guard fields.count == expected.count else { return false }

    var seen = Set<String>()
    for field in fields {
      let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard pair.count == 2 else { return false }
      let name = String(pair[0])
      guard
        let value = expected[name],
        value == String(pair[1]),
        seen.insert(name).inserted
      else { return false }
    }
    return seen.count == expected.count
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
