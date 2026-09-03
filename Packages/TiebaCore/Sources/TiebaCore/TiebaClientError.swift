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
  case threadIdentityConflict
  case forumNotFollowed
  case forumCheckInUnavailable
  case officialBatchCheckInAuthorizationChanged
  case officialBatchCheckInOutcomeUnknown(
    dispatchedTargets: [TiebaOfficialBatchCheckInTarget]
  )
  case threadAgreementWriteConflict
  case contentAgreementOutcomeUnknown
  case threadCloudFavoriteOutcomeUnknown
  case pollOutcomeUnknown
  case userInteractionPermissionsOutcomeUnknown
  case selfProfileEditWriteConflict
  case selfProfileEditOutcomeUnknown
  case selfProfileAvatarModificationUnavailable(message: String)
  case selfProfileAvatarWriteConflict
  case selfProfileAvatarOutcomeUnknown
  case personalizedFeedbackWriteConflict
  case personalizedFeedbackOutcomeUnknown
  case ownedContentDeletionWriteConflict
  case ownedContentDeletionOutcomeUnknown
  case replyChallengeRequired(message: String)
  case replyOutcomeUnknown
  case replySubmissionIDConflict
  case newThreadChallengeRequired(message: String)
  case newThreadOutcomeUnknown
  case newThreadSubmissionIDConflict
  case staticImageUploadOutcomeUnknown(uploadID: UUID, dispatchedChunk: Int)
  case staticImageUploadIDConflict
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
    case .threadIdentityConflict:
      "Tieba returned conflicting thread and forum identity data."
    case .forumNotFollowed:
      "The forum must be followed before checking in."
    case .forumCheckInUnavailable:
      "Tieba did not advertise check-in state for this forum."
    case .officialBatchCheckInAuthorizationChanged:
      "The eligible batch check-in targets changed after authorization. Review them before retrying."
    case .officialBatchCheckInOutcomeUnknown:
      "The batch check-in was sent, but Tieba did not return a verifiable final result."
    case .threadAgreementWriteConflict:
      "A conflicting thread agreement operation completed; read the current state before retrying."
    case .contentAgreementOutcomeUnknown:
      "The content-agreement write may have been sent, but Tieba did not return a verifiable final state."
    case .threadCloudFavoriteOutcomeUnknown:
      "The cloud-favorite write was sent, but Tieba did not return a verifiable final state."
    case .pollOutcomeUnknown:
      "The poll vote was sent, but Tieba did not return a verifiable final selection."
    case .userInteractionPermissionsOutcomeUnknown:
      "The interaction-permission write was sent, but Tieba did not return a verifiable final state."
    case .selfProfileEditWriteConflict:
      "A different profile edit is already running for this account."
    case .selfProfileEditOutcomeUnknown:
      "The profile edit was sent, but Tieba did not return a verifiable final state."
    case .selfProfileAvatarModificationUnavailable(let message):
      message.isEmpty
        ? "Tieba does not currently allow this account to change its avatar."
        : message
    case .selfProfileAvatarWriteConflict:
      "A different profile mutation is already running for this account."
    case .selfProfileAvatarOutcomeUnknown:
      "The avatar upload was sent, but Tieba did not return a verifiable final state."
    case .personalizedFeedbackWriteConflict:
      "A different recommendation-feedback operation is already running for this thread."
    case .personalizedFeedbackOutcomeUnknown:
      "The recommendation feedback may have been sent, but Tieba did not return a verifiable acknowledgement."
    case .ownedContentDeletionWriteConflict:
      "A different deletion operation is already running for this content."
    case .ownedContentDeletionOutcomeUnknown:
      "The deletion request may have been sent, but Tieba did not return a verifiable acknowledgement."
    case .replyChallengeRequired(let message):
      message.isEmpty
        ? "Tieba requires additional verification before this reply can be submitted."
        : message
    case .replyOutcomeUnknown:
      "The reply may have been submitted, but Tieba did not return a verifiable receipt."
    case .replySubmissionIDConflict:
      "The reply submission identifier was already used for a different request."
    case .newThreadChallengeRequired(let message):
      message.isEmpty
        ? "Tieba requires additional verification before this thread can be submitted."
        : message
    case .newThreadOutcomeUnknown:
      "The thread may have been submitted, but Tieba did not return a verifiable receipt."
    case .newThreadSubmissionIDConflict:
      "The new-thread submission identifier was already used for a different request."
    case .staticImageUploadOutcomeUnknown(_, let dispatchedChunk):
      "Image upload chunk \(dispatchedChunk) was sent, but Tieba did not return a verifiable result."
    case .staticImageUploadIDConflict:
      "The image-upload identifier was already used for a different request."
    case .server(let code, let message):
      message.isEmpty ? "Tieba returned error \(code)." : message
    }
  }
}
