import Foundation

enum UserNameFormatter {
  static func displayName(
    preferredName rawPreferredName: String,
    username rawUsername: String,
    showsBoth: Bool
  ) -> String {
    let preferredName = rawPreferredName.trimmingCharacters(in: .whitespacesAndNewlines)
    let username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
    let primaryName = preferredName.isEmpty ? username : preferredName

    guard showsBoth, !username.isEmpty, username != primaryName else {
      return primaryName
    }
    return "\(primaryName)(\(username))"
  }
}
