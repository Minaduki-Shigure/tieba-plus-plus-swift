import Foundation

enum AccountBDUSSCookieName: String, Codable, Sendable, CaseIterable {
  case bduss = "BDUSS"
  case bdussBFESS = "BDUSS_BFESS"
}

enum AccountCredentialFormat {
  static let bdussLength = 192
  static let stokenLength = 64

  static func isValidBDUSS(_ value: String) -> Bool {
    isValidCookieValue(value, expectedLength: bdussLength)
  }

  static func isValidSTOKEN(_ value: String) -> Bool {
    isValidCookieValue(value, expectedLength: stokenLength)
  }

  static func isValidCookieValue(_ value: String, expectedLength: Int) -> Bool {
    let bytes = value.utf8
    guard bytes.count == expectedLength else { return false }
    return bytes.allSatisfy { byte in
      switch byte {
      case 0x21, 0x23...0x2B, 0x2D...0x3A, 0x3C...0x5B, 0x5D...0x7E:
        return true
      default:
        return false
      }
    }
  }
}

struct AccountCredentials:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let bduss: String
  let stoken: String
  let bdussCookieName: AccountBDUSSCookieName

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
  let stoken: String?
  let bdussCookieName: AccountBDUSSCookieName
  let createdAt: Date
  let updatedAt: Date
  let sessionRevision: UUID

  init(
    id: Int64,
    username: String,
    displayName: String,
    portrait: String,
    bduss: String,
    stoken: String? = nil,
    bdussCookieName: AccountBDUSSCookieName = .bduss,
    createdAt: Date,
    updatedAt: Date,
    sessionRevision: UUID = UUID()
  ) {
    self.id = id
    self.username = username
    self.displayName = displayName
    self.portrait = portrait
    self.bduss = bduss
    self.stoken = stoken
    self.bdussCookieName = bdussCookieName
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.sessionRevision = sessionRevision
  }

  var bdussCredential: String { bduss }

  var credentials: AccountCredentials? {
    guard
      let stoken,
      AccountCredentialFormat.isValidBDUSS(bduss),
      AccountCredentialFormat.isValidSTOKEN(stoken)
    else { return nil }
    return AccountCredentials(
      bduss: bduss,
      stoken: stoken,
      bdussCookieName: bdussCookieName
    )
  }

  var description: String {
    "StoredAccountSession(id: \(id), hasFullCredentials: \(credentials != nil), credentials: redacted)"
  }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["id": id, "hasFullCredentials": credentials != nil],
      displayStyle: .struct
    )
  }
}

struct AccountSessionLease: Hashable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }

  func matches(_ session: StoredAccountSession) -> Bool {
    userID == session.id && sessionRevision == session.sessionRevision
  }
}

typealias FollowedForumsSessionLease = AccountSessionLease

struct AccountSummary: Identifiable, Hashable, Sendable {
  let id: Int64
  let username: String
  let displayName: String
  let portraitURL: URL?
  let isActive: Bool
  let hasFullCredentials: Bool
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

protocol AccountSessionLookup: Sendable {
  func session(userID: Int64) async throws -> StoredAccountSession?
}
