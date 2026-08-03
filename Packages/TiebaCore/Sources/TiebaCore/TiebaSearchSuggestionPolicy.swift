import Foundation

enum TiebaSearchSuggestionPolicy {
  static let maximumCharacterCount = 100
  static let maximumUTF8ByteCount = 400
  static let maximumResultCount = 10
  static let maximumResponseBodyBytes = 64 * 1_024

  static func validatedQuery(_ rawValue: String) throws -> String {
    guard let query = normalizedValue(rawValue, minimumCharacterCount: 2) else {
      throw TiebaClientError.invalidArgument(
        "Search suggestion query must contain between 2 and 100 non-control characters and no more than 400 UTF-8 bytes."
      )
    }
    return query
  }

  static func normalizedSuggestion(_ rawValue: String) -> String? {
    normalizedValue(rawValue, minimumCharacterCount: 1)
  }

  private static func normalizedValue(
    _ rawValue: String,
    minimumCharacterCount: Int
  ) -> String? {
    let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      (minimumCharacterCount...maximumCharacterCount).contains(value.count),
      value.utf8.count <= maximumUTF8ByteCount,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return value
  }
}
