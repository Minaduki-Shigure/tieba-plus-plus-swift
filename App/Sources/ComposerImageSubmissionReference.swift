import Foundation

struct ComposerImageSubmissionReference:
  Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let submissionID: UUID
  let sessionRevision: UUID

  init?(submissionID: UUID, sessionRevision: UUID) {
    guard submissionID != Self.zeroUUID, sessionRevision != Self.zeroUUID else { return nil }
    self.submissionID = submissionID
    self.sessionRevision = sessionRevision
  }

  var description: String { "ComposerImageSubmissionReference(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  private enum CodingKeys: CodingKey {
    case submissionID
    case sessionRevision
  }

  private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
      self.intValue = nil
    }

    init?(intValue: Int) {
      self.stringValue = String(intValue)
      self.intValue = intValue
    }
  }

  init(from decoder: any Decoder) throws {
    let allKeys = try decoder.container(keyedBy: AnyCodingKey.self).allKeys.map(\.stringValue)
    guard Set(allKeys) == Set(["submissionID", "sessionRevision"]) else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Invalid image submission reference fields."
        )
      )
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let validated = Self(
        submissionID: try container.decode(UUID.self, forKey: .submissionID),
        sessionRevision: try container.decode(UUID.self, forKey: .sessionRevision)
      )
    else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Invalid image submission reference."
        )
      )
    }
    self = validated
  }

  private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}
