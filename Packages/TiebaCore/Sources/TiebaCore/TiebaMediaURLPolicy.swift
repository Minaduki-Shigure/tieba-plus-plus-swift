import Foundation

public enum TiebaMediaURLPolicy {
  private static let upgradeableHostSuffixes = [
    "baidu.com",
    "bdimg.com",
    "bdstatic.com",
    "bcebos.com",
    "baidubce.com",
  ]

  public static func normalizedURL(from rawValue: String?) -> URL? {
    guard let rawValue else { return nil }
    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedValue.isEmpty else { return nil }
    let absoluteValue =
      trimmedValue.hasPrefix("//")
      ? "https:\(trimmedValue)"
      : trimmedValue
    return normalizedURL(URL(string: absoluteValue))
  }

  public static func normalizedURL(_ url: URL?) -> URL? {
    guard
      let url,
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.user == nil,
      components.password == nil,
      let host = components.host?.lowercased(),
      !host.isEmpty
    else { return nil }

    var requiresRebuild = false
    if host == "tb.himg.baidu.com" {
      components.host = "himg.bdimg.com"
      requiresRebuild = true
    }

    switch components.scheme?.lowercased() {
    case "https":
      break
    case "http" where isUpgradeable(host):
      components.scheme = "https"
      if components.port == 80 {
        components.port = nil
      }
      requiresRebuild = true
    default:
      return nil
    }
    return requiresRebuild ? components.url : url
  }

  private static func isUpgradeable(_ host: String) -> Bool {
    upgradeableHostSuffixes.contains { suffix in
      host == suffix || host.hasSuffix(".\(suffix)")
    }
  }
}
