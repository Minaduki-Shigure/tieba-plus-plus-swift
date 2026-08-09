import CoreFoundation
import Foundation

enum TiebaInboxUnreadSummaryDecoder {
  static let maximumCount = Int64(Int32.max)

  static func summary(
    from body: Data,
    expectedUserID: Int64
  ) throws -> TiebaInboxUnreadSummary {
    guard expectedUserID > 0 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let object = try responseObject(from: body)
    try checkServerError(object)
    guard
      let message = object["message"] as? [String: Any],
      message["replyme"] != nil,
      message["atme"] != nil
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let replyCount = try count(message["replyme"])
    let mentionCount = try count(message["atme"])
    let fanCount: Int
    if let rawFanCount = message["fans"], !(rawFanCount is NSNull) {
      fanCount = try count(rawFanCount)
    } else {
      fanCount = 0
    }

    return TiebaInboxUnreadSummary(
      userID: expectedUserID,
      replyCount: replyCount,
      mentionCount: mentionCount,
      fanCount: fanCount
    )
  }

  private static func responseObject(from body: Data) throws -> [String: Any] {
    do {
      guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      else {
        throw TiebaClientError.invalidJSON
      }
      return object
    } catch let error as TiebaClientError {
      throw error
    } catch {
      throw TiebaClientError.invalidJSON
    }
  }

  private static func checkServerError(_ object: [String: Any]) throws {
    guard let rawCode = object["error_code"], let code = signedInteger(rawCode) else {
      throw TiebaClientError.invalidJSON
    }
    guard code == 0 else {
      let message = (object["error_msg"] as? String) ?? (object["errmsg"] as? String) ?? ""
      throw TiebaClientError.server(code: Int32(clamping: code), message: message)
    }
  }

  private static func count(_ value: Any?) throws -> Int {
    guard
      let value,
      let integer = integer(value),
      integer >= 0,
      integer <= maximumCount,
      let count = Int(exactly: integer)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return count
  }

  private static func integer(_ value: Any) -> Int64? {
    switch value {
    case let value as NSNumber:
      guard
        CFGetTypeID(value) != CFBooleanGetTypeID(),
        !isFloatingPoint(value)
      else { return nil }
      return decimalInt64(value.stringValue)
    case let value as String:
      return decimalInt64(value)
    default:
      return nil
    }
  }

  private static func signedInteger(_ value: Any) -> Int64? {
    switch value {
    case let value as NSNumber:
      guard
        CFGetTypeID(value) != CFBooleanGetTypeID(),
        !isFloatingPoint(value)
      else { return nil }
      return Int64(value.stringValue)
    case let value as String:
      guard !value.isEmpty else { return nil }
      let digits: Substring
      if value.first == "-" {
        digits = value.dropFirst()
      } else {
        digits = Substring(value)
      }
      guard !digits.isEmpty, digits.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
        return nil
      }
      return Int64(value)
    default:
      return nil
    }
  }

  private static func isFloatingPoint(_ value: NSNumber) -> Bool {
    let type = String(cString: value.objCType)
    return type == "f" || type == "d"
  }

  private static func decimalInt64(_ value: String) -> Int64? {
    guard
      !value.isEmpty,
      value.utf8.allSatisfy({ (0x30...0x39).contains($0) })
    else { return nil }
    return Int64(value)
  }
}
