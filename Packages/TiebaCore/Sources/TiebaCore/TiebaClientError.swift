import Foundation

public enum TiebaClientError: Error, Sendable, Equatable {
  case invalidArgument(String)
  case invalidEndpoint
  case network(code: Int)
  case transportFailure
  case invalidHTTPResponse
  case httpStatus(Int)
  case responseTooLarge(maximumBytes: Int)
  case invalidProtobuf
  case invalidJSON
  case invalidAuthenticatedResponse
  case forumNotFollowed
  case forumCheckInUnavailable
  case threadAgreementWriteConflict
  case replyChallengeRequired(message: String)
  case replyOutcomeUnknown
  case replySubmissionIDConflict
  case server(code: Int32, message: String)
}

extension TiebaClientError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidArgument(let message):
      message
    case .invalidEndpoint:
      "The Tieba API endpoint could not be constructed securely."
    case .network(let code):
      "The network request failed (URL error \(code))."
    case .transportFailure:
      "The network transport failed."
    case .invalidHTTPResponse:
      "The Tieba server returned an invalid HTTP response."
    case .httpStatus(let status):
      "The Tieba server returned HTTP \(status)."
    case .responseTooLarge(let maximumBytes):
      "The Tieba server response exceeded the \(maximumBytes)-byte limit."
    case .invalidProtobuf:
      "The Tieba server returned an unreadable Protocol Buffer response."
    case .invalidJSON:
      "The Tieba server returned an unreadable JSON response."
    case .invalidAuthenticatedResponse:
      "Tieba returned account or forum data that did not match the authenticated request."
    case .forumNotFollowed:
      "The forum must be followed before checking in."
    case .forumCheckInUnavailable:
      "Tieba did not advertise check-in state for this forum."
    case .threadAgreementWriteConflict:
      "A conflicting thread agreement operation completed; read the current state before retrying."
    case .replyChallengeRequired(let message):
      message.isEmpty
        ? "Tieba requires additional verification before this reply can be submitted."
        : message
    case .replyOutcomeUnknown:
      "The reply may have been submitted, but Tieba did not return a verifiable receipt."
    case .replySubmissionIDConflict:
      "The reply submission identifier was already used for a different request."
    case .server(let code, let message):
      message.isEmpty ? "Tieba returned error \(code)." : message
    }
  }
}
