import Foundation

struct AccountCredentials:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let bduss: String

  var description: String { "AccountCredentials(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

struct StoredAccountSession:
  Identifiable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let id: Int64
  let username: String
  let displayName: String
  let portrait: String
  let bduss: String
  let createdAt: Date
  let updatedAt: Date
  let sessionRevision: UUID

  init(
    id: Int64,
    username: String,
    displayName: String,
    portrait: String,
    bduss: String,
    createdAt: Date,
    updatedAt: Date,
    sessionRevision: UUID = UUID()
  ) {
    self.id = id
    self.username = username
    self.displayName = displayName
    self.portrait = portrait
    self.bduss = bduss
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.sessionRevision = sessionRevision
  }

  var credentials: AccountCredentials {
    AccountCredentials(bduss: bduss)
  }

  var description: String { "StoredAccountSession(id: \(id), credentials: redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["id": id, "credentials": "redacted"], displayStyle: .struct)
  }
}

struct AccountSummary: Identifiable, Hashable, Sendable {
  let id: Int64
  let username: String
  let displayName: String
  let portraitURL: URL?
  let isActive: Bool
  let updatedAt: Date

  var preferredName: String {
    for candidate in [displayName, username] {
      let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
      if !name.isEmpty { return name }
    }
    return "用户 \(id)"
  }
}

protocol AccountVault: Sendable {
  func accountSummaries() async throws -> [AccountSummary]
  func activeSession() async throws -> StoredAccountSession?
  func upsert(_ session: StoredAccountSession) async throws
  func switchActive(to userID: Int64) async throws
  func remove(userID: Int64) async throws
  func removeAll() async throws
}
