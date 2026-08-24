import CryptoKit
import Foundation
import SwiftProtobuf
import TiebaProto

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private struct TiebaForumCheckInResourceKey: Hashable, Sendable {
  let userID: Int64
  let forumID: Int64
}

private struct TiebaUserFollowResourceKey: Hashable, Sendable {
  let userID: Int64
  let targetUserID: Int64
}

private struct TiebaUserFollowIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let credential: TiebaSessionCredential

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.credential.bduss == rhs.credential.bduss
      && lhs.credential.stoken == rhs.credential.stoken
      && lhs.credential.bdussCookieName == rhs.credential.bdussCookieName
  }

  var description: String { "TiebaUserFollowIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

private struct TiebaUserFollowFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaUserFollowIdentity
  let isFollowed: Bool
  let task: Task<TiebaUserRelationship, Swift.Error>

  var description: String { "TiebaUserFollowFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["id": id, "identity": identity, "isFollowed": isFollowed],
      displayStyle: .struct
    )
  }
}

private enum TiebaUserFollowWaitOutcome: Sendable, Equatable {
  case completed
  case cancelled
}

private struct TiebaUserInteractionPermissionsResourceKey: Hashable, Sendable {
  let userID: Int64
  let targetUserID: Int64
}

private struct TiebaUserInteractionPermissionsIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let credential: TiebaSessionCredential

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.credential.bduss == rhs.credential.bduss
      && lhs.credential.stoken == rhs.credential.stoken
      && lhs.credential.bdussCookieName == rhs.credential.bdussCookieName
  }

  var description: String { "TiebaUserInteractionPermissionsIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

private struct TiebaUserInteractionPermissionsFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaUserInteractionPermissionsIdentity
  let permissions: TiebaUserInteractionPermissions
  let task: Task<TiebaUserInteractionPermissionState, Swift.Error>
  var stage: TiebaUserInteractionPermissionsFlightStage

  var description: String { "TiebaUserInteractionPermissionsFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": id,
        "identity": identity,
        "permissions": permissions,
        "stage": stage,
      ],
      displayStyle: .struct
    )
  }
}

private enum TiebaUserInteractionPermissionsFlightStage: Sendable, Equatable {
  case queued
  case preflight
  case writeDispatched
  case completed
}

private enum TiebaUserInteractionPermissionsWaitOutcome: Sendable, Equatable {
  case completed
  case cancelled
}

private struct TiebaPollResourceKey: Hashable, Sendable {
  let userID: Int64
  let forumID: Int64
  let threadID: Int64
}

private struct TiebaPersonalizedFeedbackResourceKey: Hashable, Sendable {
  let userID: Int64
  let threadID: Int64
}

private struct TiebaPersonalizedFeedbackIdentity:
  Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  private let bduss: String
  private let stoken: String
  private let cookieName: TiebaBDUSSCookieName
  let submission: TiebaPersonalizedFeedbackSubmission

  init(
    credential: TiebaSessionCredential,
    submission: TiebaPersonalizedFeedbackSubmission
  ) {
    bduss = credential.bduss
    stoken = credential.stoken
    cookieName = credential.bdussCookieName
    self.submission = submission
  }

  var description: String { "TiebaPersonalizedFeedbackIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

private struct TiebaPersonalizedFeedbackFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaPersonalizedFeedbackIdentity
  let task: Task<Void, Swift.Error>
  var stage: TiebaPersonalizedFeedbackFlightStage

  var description: String { "TiebaPersonalizedFeedbackFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["id": id, "stage": stage], displayStyle: .struct)
  }
}

private enum TiebaPersonalizedFeedbackFlightStage: Sendable, Equatable {
  case queued
  case preflight
  case writeDispatched
  case completed
}

private enum TiebaPersonalizedFeedbackWaitOutcome: Sendable, Equatable {
  case completed
  case cancelled
}

private struct TiebaPollFlightIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let credential: TiebaSessionCredential

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.credential.bduss == rhs.credential.bduss
      && lhs.credential.stoken == rhs.credential.stoken
      && lhs.credential.bdussCookieName == rhs.credential.bdussCookieName
  }

  var description: String { "TiebaPollFlightIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

private struct TiebaPollFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaPollFlightIdentity
  let selectedOptionIDs: [Int32]
  let task: Task<TiebaPollState, Swift.Error>
  var stage: TiebaPollFlightStage

  var isCompleted: Bool { stage == .completed }

  var description: String { "TiebaPollFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": id,
        "identity": identity,
        "selectedOptionIDs": selectedOptionIDs,
        "stage": stage,
      ],
      displayStyle: .struct
    )
  }
}

private enum TiebaPollFlightStage: Sendable, Equatable {
  case queued
  case preflight
  case writeDispatched
  case completed
}

private enum TiebaPollWaitOutcome: Sendable, Equatable {
  case completed
  case cancelled
}

private struct TiebaForumCheckInIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let credential: TiebaBDUSSCredential
  let forumName: String

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.credential.bduss == rhs.credential.bduss && lhs.forumName == rhs.forumName
  }

  var description: String { "TiebaForumCheckInIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["forumName": forumName], displayStyle: .struct)
  }
}

private struct TiebaForumCheckInFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaForumCheckInIdentity
  let task: Task<TiebaForumAccountState, Swift.Error>

  var description: String { "TiebaForumCheckInFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["id": id, "identity": identity], displayStyle: .struct)
  }
}

private struct TiebaAgreementResourceKey: Hashable, Sendable {
  let userID: Int64
  let forumID: Int64
  let threadID: Int64
  let target: TiebaAgreementTarget
}

private struct TiebaAgreementIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let credential: TiebaBDUSSCredential
  let forumID: Int64
  let forumName: String

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.credential.bduss == rhs.credential.bduss
      && lhs.forumID == rhs.forumID
      && lhs.forumName == rhs.forumName
  }

  var description: String { "TiebaAgreementIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "forumID": forumID,
        "forumName": forumName,
      ],
      displayStyle: .struct
    )
  }
}

private struct TiebaAgreementFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaAgreementIdentity
  let targetAgreed: Bool
  let task: Task<TiebaAgreementState, Swift.Error>

  var description: String { "TiebaAgreementFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": id,
        "identity": identity,
        "targetAgreed": targetAgreed,
      ],
      displayStyle: .struct
    )
  }
}

private struct TiebaAgreementAccountTail: Sendable {
  let id: UUID
  let task: Task<Void, Never>
}

private struct TiebaThreadCloudFavoriteResourceKey: Hashable, Sendable {
  let userID: Int64
  let threadID: Int64
}

private struct TiebaThreadCloudFavoriteIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let credential: TiebaSessionCredential
  let forumID: Int64

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.credential.bduss == rhs.credential.bduss
      && lhs.credential.stoken == rhs.credential.stoken
      && lhs.credential.bdussCookieName == rhs.credential.bdussCookieName
      && lhs.forumID == rhs.forumID
  }

  var description: String { "TiebaThreadCloudFavoriteIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(self, children: ["forumID": forumID], displayStyle: .struct)
  }
}

private struct TiebaThreadCloudFavoriteFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaThreadCloudFavoriteIdentity
  let markedPostID: Int64?
  let task: Task<TiebaThreadCloudFavoriteState, Swift.Error>

  var description: String { "TiebaThreadCloudFavoriteFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": id,
        "identity": identity,
        "markedPostID": markedPostID as Any,
      ],
      displayStyle: .struct
    )
  }
}

private enum TiebaThreadCloudFavoriteWaitOutcome: Sendable, Equatable {
  case completed
  case cancelled
}

private struct TiebaTextReplyFlightIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let expectedUserID: Int64
  let submission: TiebaTextReplySubmission
  let normalizedForumName: String
  private let bduss: String
  private let stoken: String
  private let cookieName: TiebaBDUSSCookieName

  init(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission,
    normalizedForumName: String
  ) {
    self.expectedUserID = expectedUserID
    self.submission = submission
    self.normalizedForumName = normalizedForumName
    self.bduss = credential.bduss
    self.stoken = credential.stoken
    self.cookieName = credential.bdussCookieName
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.expectedUserID == rhs.expectedUserID
      && lhs.submission == rhs.submission
      && lhs.normalizedForumName == rhs.normalizedForumName
      && lhs.bduss == rhs.bduss
      && lhs.stoken == rhs.stoken
      && lhs.cookieName == rhs.cookieName
  }

  var description: String { "TiebaTextReplyFlightIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "expectedUserID": expectedUserID,
        "submissionID": submission.submissionID,
        "forumID": submission.forumID,
        "threadID": submission.threadID,
        "target": submission.target,
      ],
      displayStyle: .struct
    )
  }
}

private struct TiebaTextReplyFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let identity: TiebaTextReplyFlightIdentity
  let task: Task<TiebaTextReplyResult, Swift.Error>
  var stage: TiebaTextReplyFlightStage

  var isCompleted: Bool { stage == .completed }

  var description: String { "TiebaTextReplyFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "identity": identity,
        "stage": stage,
      ],
      displayStyle: .struct
    )
  }
}

private enum TiebaTextReplyFlightStage: Sendable, Equatable {
  case queued
  case preflight
  case writeDispatched
  case completed
}

private struct TiebaTextReplyAccountTail: Sendable {
  let submissionID: UUID
  let task: Task<Void, Never>
}

private enum TiebaTextReplyWaitOutcome: Sendable, Equatable {
  case completed
  case cancelled
}

struct TiebaNewThreadCredentialFingerprint:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  private let digest: [UInt8]

  init(credential: TiebaSessionCredential) {
    var input = Data("TiebaNewThreadCredentialFingerprint/v1".utf8)
    for value in [
      credential.bdussCookieName.rawValue,
      credential.bduss,
      credential.stoken,
    ] {
      var byteCount = UInt64(value.utf8.count).bigEndian
      withUnsafeBytes(of: &byteCount) { input.append(contentsOf: $0) }
      input.append(contentsOf: value.utf8)
    }
    self.digest = Array(SHA256.hash(data: input))
  }

  var description: String { "TiebaNewThreadCredentialFingerprint(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

private struct TiebaNewThreadFlightIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let expectedUserID: Int64
  let submission: TiebaNewThreadSubmission
  let normalizedForumName: String
  private let credentialFingerprint: TiebaNewThreadCredentialFingerprint

  init(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaNewThreadSubmission,
    normalizedForumName: String
  ) {
    self.expectedUserID = expectedUserID
    self.submission = submission
    self.normalizedForumName = normalizedForumName
    self.credentialFingerprint = TiebaNewThreadCredentialFingerprint(credential: credential)
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.expectedUserID == rhs.expectedUserID
      && lhs.submission == rhs.submission
      && lhs.normalizedForumName == rhs.normalizedForumName
      && lhs.credentialFingerprint == rhs.credentialFingerprint
  }

  var description: String { "TiebaNewThreadFlightIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "expectedUserID": expectedUserID,
        "submissionID": submission.submissionID,
        "forumID": submission.forumID,
      ],
      displayStyle: .struct
    )
  }
}

private struct TiebaNewThreadFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let identity: TiebaNewThreadFlightIdentity
  let task: Task<TiebaNewThreadResult, Swift.Error>
  var stage: TiebaNewThreadFlightStage

  var isCompleted: Bool { stage == .completed }

  var description: String { "TiebaNewThreadFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "identity": identity,
        "stage": stage,
      ],
      displayStyle: .struct
    )
  }
}

private enum TiebaNewThreadFlightStage: Sendable, Equatable {
  case queued
  case preflight
  case writeDispatched
  case completed
}

private struct TiebaNewThreadAccountTail: Sendable {
  let submissionID: UUID
  let task: Task<Void, Never>
}

private enum TiebaNewThreadWaitOutcome: Sendable, Equatable {
  case completed
  case cancelled
}

private struct TiebaStaticImageUploadCredentialFingerprint:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  private let digest: [UInt8]

  init(credential: TiebaSessionCredential) {
    var input = Data("TiebaStaticImageUploadCredentialFingerprint/v1".utf8)
    for value in [
      credential.bdussCookieName.rawValue,
      credential.bduss,
      credential.stoken,
    ] {
      var byteCount = UInt64(value.utf8.count).bigEndian
      withUnsafeBytes(of: &byteCount) { input.append(contentsOf: $0) }
      input.append(contentsOf: value.utf8)
    }
    self.digest = Array(SHA256.hash(data: input))
  }

  var description: String { "TiebaStaticImageUploadCredentialFingerprint(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

private struct TiebaStaticImageUploadFlightIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let expectedUserID: Int64
  let uploadID: UUID
  let normalizedForumName: String
  let contentDigest: [UInt8]
  let byteCount: Int
  let pixelWidth: Int
  let pixelHeight: Int
  let preservesOriginal: Bool
  let watermark: TiebaStaticImageWatermark
  private let credentialFingerprint: TiebaStaticImageUploadCredentialFingerprint

  init(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    plan: TiebaStaticImageUploadPlan
  ) {
    self.expectedUserID = expectedUserID
    self.uploadID = plan.upload.uploadID
    self.normalizedForumName = plan.normalizedForumName
    self.contentDigest = plan.contentDigest
    self.byteCount = plan.byteCount
    self.pixelWidth = plan.upload.pixelWidth
    self.pixelHeight = plan.upload.pixelHeight
    self.preservesOriginal = plan.upload.preservesOriginal
    self.watermark = plan.upload.watermark
    self.credentialFingerprint = TiebaStaticImageUploadCredentialFingerprint(
      credential: credential
    )
  }

  var description: String { "TiebaStaticImageUploadFlightIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "expectedUserID": expectedUserID,
        "uploadID": uploadID,
        "byteCount": byteCount,
        "pixelWidth": pixelWidth,
        "pixelHeight": pixelHeight,
        "preservesOriginal": preservesOriginal,
        "watermark": watermark,
      ],
      displayStyle: .struct
    )
  }
}

private struct TiebaStaticImageUploadFlight:
  Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  let id: UUID
  let identity: TiebaStaticImageUploadFlightIdentity
  let task: Task<TiebaStaticImageUploadReceipt, Swift.Error>
  var stage: TiebaStaticImageUploadFlightStage

  var isCompleted: Bool { stage == .completed }

  var description: String { "TiebaStaticImageUploadFlight(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: ["identity": identity, "stage": stage],
      displayStyle: .struct
    )
  }
}

private enum TiebaStaticImageUploadFlightStage: Sendable, Equatable {
  case queued
  case preflight
  case chunkDispatched(Int)
  case completed
}

private struct TiebaStaticImageUploadLeaseWaiter {
  let uploadID: UUID
  let flightID: UUID
  let continuation: CheckedContinuation<TiebaStaticImageUploadLeaseOutcome, Never>
}

private enum TiebaStaticImageUploadLeaseOutcome: Sendable, Equatable {
  case acquired
  case cancelled
}

private enum TiebaStaticImageUploadWaitOutcome: Sendable, Equatable {
  case completed
  case cancelled
}

private struct TiebaOfficialBatchCheckInIdentity:
  Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  private let bduss: String
  private let stoken: String
  private let cookieName: TiebaBDUSSCookieName
  let authorizedTargets: [TiebaOfficialBatchCheckInTarget]

  init(
    credential: TiebaSessionCredential,
    authorizedTargets: [TiebaOfficialBatchCheckInTarget]
  ) {
    bduss = credential.bduss
    stoken = credential.stoken
    cookieName = credential.bdussCookieName
    self.authorizedTargets = authorizedTargets
  }

  var description: String { "TiebaOfficialBatchCheckInIdentity(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }
}

private struct TiebaOfficialBatchCheckInFlight: Sendable {
  let id: UUID
  let identity: TiebaOfficialBatchCheckInIdentity
  let task: Task<TiebaOfficialBatchCheckInResult, Swift.Error>
  var stage: TiebaOfficialBatchCheckInFlightStage

  var isCompleted: Bool { stage == .completed }
}

private enum TiebaOfficialBatchCheckInFlightStage: Sendable, Equatable {
  case queued
  case preflight
  case writeDispatched
  case completed
}

private enum TiebaOfficialBatchCheckInWaitOutcome: Sendable, Equatable {
  case completed
  case cancelled
}

public actor TiebaAuthenticatedClient {
  nonisolated static func officialBatchCheckInIdentityDebugValues(
    credential: TiebaSessionCredential,
    authorizedTargets: [TiebaOfficialBatchCheckInTarget] = []
  ) -> (description: String, reflection: String, mirrorChildCount: Int) {
    let identity = TiebaOfficialBatchCheckInIdentity(
      credential: credential,
      authorizedTargets: authorizedTargets
    )
    return (
      description: String(describing: identity),
      reflection: String(reflecting: identity),
      mirrorChildCount: Array(identity.customMirror.children).count
    )
  }

  static let accountResponseMaximumBytes = 512 * 1_024
  static let selfProfileResponseMaximumBytes = 2 * 1_024 * 1_024
  static let ownFollowingResponseMaximumBytes = TiebaPublicSocialPolicy.maximumResponseBodyBytes
  static let userRelationshipResponseMaximumBytes = 2 * 1_024 * 1_024
  static let userFollowWriteResponseMaximumBytes = 64 * 1_024
  static let userInteractionPermissionsResponseMaximumBytes = 64 * 1_024
  static let userInteractionPermissionsWriteResponseMaximumBytes = 64 * 1_024
  static let personalizedFeedbackResponseMaximumBytes = 64 * 1_024
  static let personalizedResponseMaximumBytes = 4 * 1_024 * 1_024
  static let pollStateResponseMaximumBytes = 8 * 1_024 * 1_024
  static let pollWriteResponseMaximumBytes = 64 * 1_024
  static let webSessionResponseMaximumBytes = 256 * 1_024
  static let followedForumsResponseMaximumBytes = 2 * 1_024 * 1_024
  static let cloudFavoritesResponseMaximumBytes = 2 * 1_024 * 1_024
  static let threadCloudFavoriteStateResponseMaximumBytes = 4 * 1_024 * 1_024
  static let threadCloudFavoriteWriteResponseMaximumBytes = 64 * 1_024
  static let concernResponseMaximumBytes = 4 * 1_024 * 1_024
  static let notificationResponseMaximumBytes = 2 * 1_024 * 1_024
  static let inboxUnreadSummaryResponseMaximumBytes = 64 * 1_024
  static let forumMembershipResponseMaximumBytes = 512 * 1_024
  static let forumFollowWriteResponseMaximumBytes = 64 * 1_024
  static let forumCheckInResponseMaximumBytes = 64 * 1_024
  static let officialCheckInSessionResponseMaximumBytes = 512 * 1_024
  static let officialCheckInEligibilityResponseMaximumBytes = 512 * 1_024
  static let officialCheckInGuideResponseMaximumBytes = 2 * 1_024 * 1_024
  static let officialBatchCheckInResponseMaximumBytes = 512 * 1_024
  static let agreementPageResponseMaximumBytes = 8 * 1_024 * 1_024
  static let subpostAgreementPageResponseMaximumBytes = 4 * 1_024 * 1_024
  static let threadAgreementWriteResponseMaximumBytes = 64 * 1_024
  static let textReplyWriteResponseMaximumBytes = 128 * 1_024
  static let retainedTextReplySubmissionLimit = 64
  static let newThreadWriteResponseMaximumBytes = 128 * 1_024
  static let retainedNewThreadSubmissionLimit = 64
  static let staticImageUploadResponseMaximumBytes =
    TiebaStaticImageUploadPolicy.maximumResponseBodyBytes
  static let retainedStaticImageUploadLimit = 64

  private let requestFactory: TiebaAuthenticatedRequestFactory
  private let transport: any TiebaTransport
  private let staticImageUploadLeaseAcquired: (@Sendable (UUID) async -> Void)?
  private var userFollowFlights = [TiebaUserFollowResourceKey: TiebaUserFollowFlight]()
  private var userFollowWaiters = [
    TiebaUserFollowResourceKey: [UUID: CheckedContinuation<TiebaUserFollowWaitOutcome, Never>]
  ]()
  private var userInteractionPermissionsFlights = [
    TiebaUserInteractionPermissionsResourceKey: TiebaUserInteractionPermissionsFlight
  ]()
  private var userInteractionPermissionsWaiters = [
    TiebaUserInteractionPermissionsResourceKey: [
      UUID: CheckedContinuation<TiebaUserInteractionPermissionsWaitOutcome, Never>
    ]
  ]()
  private var userInteractionPermissionsSharedWaiterIDs = [
    TiebaUserInteractionPermissionsResourceKey: Set<UUID>
  ]()
  private var pollFlights = [TiebaPollResourceKey: TiebaPollFlight]()
  private var pollWaiters = [
    TiebaPollResourceKey: [UUID: CheckedContinuation<TiebaPollWaitOutcome, Never>]
  ]()
  private var pollSharedWaiterIDs = [TiebaPollResourceKey: Set<UUID>]()
  private var personalizedFeedbackFlights = [
    TiebaPersonalizedFeedbackResourceKey: TiebaPersonalizedFeedbackFlight
  ]()
  private var personalizedFeedbackWaiters = [
    TiebaPersonalizedFeedbackResourceKey: [
      UUID: CheckedContinuation<TiebaPersonalizedFeedbackWaitOutcome, Never>
    ]
  ]()
  private var personalizedFeedbackSharedWaiterIDs = [
    TiebaPersonalizedFeedbackResourceKey: Set<UUID>
  ]()
  private var forumCheckInFlights = [TiebaForumCheckInResourceKey: TiebaForumCheckInFlight]()
  private var forumCheckInSharedWaiterCounts = [UUID: Int]()
  private var forumCheckInConflictWaiters = [
    TiebaForumCheckInResourceKey: [UUID: CheckedContinuation<Void, Never>]
  ]()
  private var officialBatchCheckInFlights = [Int64: TiebaOfficialBatchCheckInFlight]()
  private var officialBatchCheckInWaiters = [
    Int64: [UUID: CheckedContinuation<TiebaOfficialBatchCheckInWaitOutcome, Never>]
  ]()
  private var officialBatchCheckInSharedWaiterIDs = [Int64: Set<UUID>]()
  private var agreementFlights = [
    TiebaAgreementResourceKey: TiebaAgreementFlight
  ]()
  private var agreementSharedWaiterCounts = [UUID: Int]()
  private var agreementConflictWaiterCounts = [TiebaAgreementResourceKey: Int]()
  private var agreementAccountTails = [Int64: TiebaAgreementAccountTail]()
  private var threadCloudFavoriteFlights = [
    TiebaThreadCloudFavoriteResourceKey: TiebaThreadCloudFavoriteFlight
  ]()
  private var threadCloudFavoriteSharedWaiters = [
    UUID: [UUID: CheckedContinuation<TiebaThreadCloudFavoriteWaitOutcome, Never>]
  ]()
  private var threadCloudFavoriteConflictWaiters = [
    TiebaThreadCloudFavoriteResourceKey: [
      UUID: CheckedContinuation<TiebaThreadCloudFavoriteWaitOutcome, Never>
    ]
  ]()
  private var textReplyFlights = [UUID: TiebaTextReplyFlight]()
  private var textReplyFlightOrder = [UUID]()
  private var textReplyAccountTails = [Int64: TiebaTextReplyAccountTail]()
  private var textReplyWaiters = [
    UUID: [UUID: CheckedContinuation<TiebaTextReplyWaitOutcome, Never>]
  ]()
  private var newThreadFlights = [UUID: TiebaNewThreadFlight]()
  private var newThreadFlightOrder = [UUID]()
  private var newThreadAccountTails = [Int64: TiebaNewThreadAccountTail]()
  private var newThreadWaiters = [
    UUID: [UUID: CheckedContinuation<TiebaNewThreadWaitOutcome, Never>]
  ]()
  private var staticImageUploadFlights = [UUID: TiebaStaticImageUploadFlight]()
  private var staticImageUploadFlightOrder = [UUID]()
  private var staticImageUploadLeaseOwners = [Int64: UUID]()
  private var staticImageUploadLeaseWaiters = [
    Int64: [TiebaStaticImageUploadLeaseWaiter]
  ]()
  private var staticImageUploadWaiters = [
    UUID: [UUID: CheckedContinuation<TiebaStaticImageUploadWaitOutcome, Never>]
  ]()

  public init(configuration: TiebaClientConfiguration = .init()) {
    self.requestFactory = TiebaAuthenticatedRequestFactory(configuration: configuration)
    self.transport = URLSessionTiebaTransport(redirectPolicy: .rejectAll)
    self.staticImageUploadLeaseAcquired = nil
  }

  init(
    configuration: TiebaClientConfiguration = .init(),
    transport: any TiebaTransport,
    staticImageUploadLeaseAcquired: (@Sendable (UUID) async -> Void)? = nil
  ) {
    self.requestFactory = TiebaAuthenticatedRequestFactory(configuration: configuration)
    self.transport = transport
    self.staticImageUploadLeaseAcquired = staticImageUploadLeaseAcquired
  }

  public func validateAccount(
    credential: TiebaBDUSSCredential
  ) async throws -> TiebaAuthenticatedAccount {
    let request = try requestFactory.validateAccount(credential: credential)
    let body = try await send(
      request,
      maximumBodyBytes: Self.accountResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.account(from: body)
  }

  public func validateSession(
    credential: TiebaSessionCredential
  ) async throws -> TiebaAuthenticatedAccount {
    let appRequest = try requestFactory.validateSessionApp(credential: credential)
    let appBody = try await send(
      appRequest,
      maximumBodyBytes: Self.accountResponseMaximumBytes
    )
    let account = try TiebaAuthenticatedDecoder.account(from: appBody)
    try Task.checkCancellation()

    let webRequest = try requestFactory.validateSessionWeb(credential: credential)
    let webBody = try await send(
      webRequest,
      maximumBodyBytes: Self.webSessionResponseMaximumBytes
    )
    let webUserID = try TiebaAuthenticatedDecoder.webAccountID(from: webBody)
    try Task.checkCancellation()
    guard webUserID == account.userID else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return account
  }

  public func submitPersonalizedFeedback(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaPersonalizedFeedbackSubmission
  ) async throws {
    try Task.checkCancellation()
    let request = try requestFactory.personalizedFeedback(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission
    )

    let resourceKey = TiebaPersonalizedFeedbackResourceKey(
      userID: expectedUserID,
      threadID: submission.threadID
    )
    let identity = TiebaPersonalizedFeedbackIdentity(
      credential: credential,
      submission: submission
    )
    if let flight = personalizedFeedbackFlights[resourceKey] {
      guard flight.identity == identity else {
        throw TiebaClientError.personalizedFeedbackWriteConflict
      }
      return try await waitForPersonalizedFeedbackFlight(
        resourceKey: resourceKey,
        flightID: flight.id,
        task: flight.task
      )
    }

    let flightID = UUID()
    let task = Task.detached { [self] in
      try await performPersonalizedFeedbackRequest(
        resourceKey: resourceKey,
        flightID: flightID,
        request: request
      )
    }
    personalizedFeedbackFlights[resourceKey] = TiebaPersonalizedFeedbackFlight(
      id: flightID,
      identity: identity,
      task: task,
      stage: .queued
    )
    Task {
      await finishPersonalizedFeedbackFlight(
        resourceKey: resourceKey,
        flightID: flightID,
        task: task
      )
    }
    try await waitForPersonalizedFeedbackFlight(
      resourceKey: resourceKey,
      flightID: flightID,
      task: task
    )
  }

  public func getPersonalizedThreads(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    page: Int = 1
  ) async throws -> TiebaPersonalizedPage {
    let request = try requestFactory.personalizedThreads(
      credential: credential,
      expectedUserID: expectedUserID,
      page: page
    )
    let response: PersonalizedResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.personalizedResponseMaximumBytes
    )
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    return TiebaProtoMapper.personalizedPage(
      response.data,
      requestedPage: page,
      pageSize: TiebaRequestFactory.personalizedPageSize
    )
  }

  private func performPersonalizedFeedbackRequest(
    resourceKey: TiebaPersonalizedFeedbackResourceKey,
    flightID: UUID,
    request: URLRequest
  ) async throws {
    try beginPersonalizedFeedbackPreflight(
      resourceKey: resourceKey,
      flightID: flightID
    )
    try beginPersonalizedFeedbackWrite(
      resourceKey: resourceKey,
      flightID: flightID
    )
    let body: Data
    do {
      body = try await send(
        request,
        maximumBodyBytes: Self.personalizedFeedbackResponseMaximumBytes
      )
    } catch is CancellationError {
      throw TiebaClientError.personalizedFeedbackOutcomeUnknown
    } catch {
      throw TiebaClientError.personalizedFeedbackOutcomeUnknown
    }

    do {
      try TiebaAuthenticatedDecoder.checkPersonalizedFeedbackResponse(body)
    } catch let error as TiebaClientError {
      if case .server = error { throw error }
      throw TiebaClientError.personalizedFeedbackOutcomeUnknown
    } catch {
      throw TiebaClientError.personalizedFeedbackOutcomeUnknown
    }
  }

  private func waitForPersonalizedFeedbackFlight(
    resourceKey: TiebaPersonalizedFeedbackResourceKey,
    flightID: UUID,
    task: Task<Void, Swift.Error>
  ) async throws {
    if Task.isCancelled {
      cancelUnregisteredPersonalizedFeedbackWaiter(
        resourceKey: resourceKey,
        flightID: flightID
      )
      throw CancellationError()
    }
    guard personalizedFeedbackFlights[resourceKey]?.id == flightID else {
      return try await task.value
    }
    let waiterID = UUID()
    let outcome: TiebaPersonalizedFeedbackWaitOutcome = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard
          !Task.isCancelled,
          personalizedFeedbackFlights[resourceKey]?.id == flightID
        else {
          if Task.isCancelled {
            cancelUnregisteredPersonalizedFeedbackWaiter(
              resourceKey: resourceKey,
              flightID: flightID
            )
          }
          continuation.resume(
            returning: Task.isCancelled ? .cancelled : .completed
          )
          return
        }
        personalizedFeedbackWaiters[resourceKey, default: [:]][waiterID] = continuation
        personalizedFeedbackSharedWaiterIDs[resourceKey, default: []].insert(waiterID)
      }
    } onCancel: {
      Task {
        await self.cancelPersonalizedFeedbackWaiter(
          resourceKey: resourceKey,
          flightID: flightID,
          waiterID: waiterID
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    try Task.checkCancellation()
    try await task.value
  }

  private func cancelPersonalizedFeedbackWaiter(
    resourceKey: TiebaPersonalizedFeedbackResourceKey,
    flightID: UUID,
    waiterID: UUID
  ) {
    guard personalizedFeedbackFlights[resourceKey]?.id == flightID else { return }
    guard var waiters = personalizedFeedbackWaiters[resourceKey] else {
      cancelUnregisteredPersonalizedFeedbackWaiter(
        resourceKey: resourceKey,
        flightID: flightID
      )
      return
    }
    let continuation = waiters.removeValue(forKey: waiterID)
    if var sharedWaiterIDs = personalizedFeedbackSharedWaiterIDs[resourceKey] {
      sharedWaiterIDs.remove(waiterID)
      if sharedWaiterIDs.isEmpty {
        personalizedFeedbackSharedWaiterIDs.removeValue(forKey: resourceKey)
      } else {
        personalizedFeedbackSharedWaiterIDs[resourceKey] = sharedWaiterIDs
      }
    }
    if waiters.isEmpty {
      personalizedFeedbackWaiters.removeValue(forKey: resourceKey)
    } else {
      personalizedFeedbackWaiters[resourceKey] = waiters
    }
    if personalizedFeedbackSharedWaiterIDs[resourceKey]?.isEmpty != false,
      let flight = personalizedFeedbackFlights[resourceKey],
      flight.stage == .queued || flight.stage == .preflight
    {
      flight.task.cancel()
    }
    continuation?.resume(returning: .cancelled)
  }

  private func cancelUnregisteredPersonalizedFeedbackWaiter(
    resourceKey: TiebaPersonalizedFeedbackResourceKey,
    flightID: UUID
  ) {
    guard
      personalizedFeedbackSharedWaiterIDs[resourceKey]?.isEmpty != false,
      let flight = personalizedFeedbackFlights[resourceKey],
      flight.id == flightID,
      flight.stage == .queued || flight.stage == .preflight
    else { return }
    flight.task.cancel()
  }

  private func beginPersonalizedFeedbackPreflight(
    resourceKey: TiebaPersonalizedFeedbackResourceKey,
    flightID: UUID
  ) throws {
    try Task.checkCancellation()
    guard var flight = personalizedFeedbackFlights[resourceKey],
      flight.id == flightID,
      flight.stage == .queued
    else { throw CancellationError() }
    flight.stage = .preflight
    personalizedFeedbackFlights[resourceKey] = flight
  }

  private func beginPersonalizedFeedbackWrite(
    resourceKey: TiebaPersonalizedFeedbackResourceKey,
    flightID: UUID
  ) throws {
    try Task.checkCancellation()
    guard var flight = personalizedFeedbackFlights[resourceKey],
      flight.id == flightID,
      flight.stage == .preflight
    else { throw CancellationError() }
    flight.stage = .writeDispatched
    personalizedFeedbackFlights[resourceKey] = flight
  }

  private func finishPersonalizedFeedbackFlight(
    resourceKey: TiebaPersonalizedFeedbackResourceKey,
    flightID: UUID,
    task: Task<Void, Swift.Error>
  ) async {
    _ = await task.result
    guard var flight = personalizedFeedbackFlights[resourceKey], flight.id == flightID else {
      return
    }
    flight.stage = .completed
    personalizedFeedbackFlights[resourceKey] = flight
    personalizedFeedbackFlights.removeValue(forKey: resourceKey)
    let waiters = personalizedFeedbackWaiters.removeValue(forKey: resourceKey) ?? [:]
    personalizedFeedbackSharedWaiterIDs.removeValue(forKey: resourceKey)
    for continuation in waiters.values {
      continuation.resume(returning: .completed)
    }
  }

  func personalizedFeedbackWaiterCount(
    expectedUserID: Int64,
    threadID: Int64
  ) -> Int {
    personalizedFeedbackWaiters[
      TiebaPersonalizedFeedbackResourceKey(
        userID: expectedUserID,
        threadID: threadID
      )
    ]?.count ?? 0
  }

  public func getSelfProfile(
    credential: TiebaSessionCredential,
    expectedUserID: Int64
  ) async throws -> TiebaSelfProfileSummary {
    let request = try requestFactory.selfProfile(
      credential: credential,
      expectedUserID: expectedUserID
    )
    let response: ProfileResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.selfProfileResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.selfProfile(
      from: response,
      expectedUserID: expectedUserID
    )
  }

  public func getOwnFollowing(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    page: Int = 1
  ) async throws -> TiebaUserRelationPage {
    let request = try requestFactory.ownFollowing(
      credential: credential,
      expectedUserID: expectedUserID,
      page: page
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.ownFollowingResponseMaximumBytes
    )
    return try TiebaPublicSocialDecoder.page(
      from: body,
      requestedUserID: expectedUserID,
      kind: .following,
      requestedPage: page
    )
  }

  public func getUserRelationship(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64
  ) async throws -> TiebaUserRelationship {
    try await getUserRelationshipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID
    ).relationship
  }

  public func setUserFollowState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64,
    isFollowed: Bool
  ) async throws -> TiebaUserRelationship {
    try Task.checkCancellation()
    let resourceKey = TiebaUserFollowResourceKey(
      userID: expectedUserID,
      targetUserID: targetUserID
    )
    let identity = TiebaUserFollowIdentity(credential: credential)

    let permissionsKey = TiebaUserInteractionPermissionsResourceKey(
      userID: expectedUserID,
      targetUserID: targetUserID
    )
    if let permissionsFlight = userInteractionPermissionsFlights[permissionsKey] {
      try await waitForUserInteractionPermissionsFlightCompletion(
        resourceKey: permissionsKey,
        flightID: permissionsFlight.id,
        keepsWriteAlive: false
      )
      return try await getUserRelationship(
        credential: credential,
        expectedUserID: expectedUserID,
        targetUserID: targetUserID
      )
    }

    if let flight = userFollowFlights[resourceKey] {
      if flight.identity == identity, flight.isFollowed == isFollowed {
        return try await waitForUserFollowFlight(
          resourceKey: resourceKey,
          flightID: flight.id,
          task: flight.task
        )
      }
      try await waitForUserFollowFlightCompletion(
        resourceKey: resourceKey,
        flightID: flight.id
      )
      return try await getUserRelationship(
        credential: credential,
        expectedUserID: expectedUserID,
        targetUserID: targetUserID
      )
    }

    let flightID = UUID()
    let task: Task<TiebaUserRelationship, Swift.Error> = Task.detached { [self] in
      try await performUserFollowWrite(
        credential: credential,
        expectedUserID: expectedUserID,
        targetUserID: targetUserID,
        isFollowed: isFollowed
      )
    }
    userFollowFlights[resourceKey] = TiebaUserFollowFlight(
      id: flightID,
      identity: identity,
      isFollowed: isFollowed,
      task: task
    )
    Task {
      await finishUserFollowFlight(
        resourceKey: resourceKey,
        flightID: flightID,
        task: task
      )
    }
    return try await waitForUserFollowFlight(
      resourceKey: resourceKey,
      flightID: flightID,
      task: task
    )
  }

  public func getUserInteractionPermissionState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64
  ) async throws -> TiebaUserInteractionPermissionState {
    _ = try await getUserRelationshipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID
    )
    try Task.checkCancellation()
    return try await getRawUserInteractionPermissionState(
      credential: credential,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID
    )
  }

  public func setUserInteractionPermissions(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64,
    permissions: TiebaUserInteractionPermissions
  ) async throws -> TiebaUserInteractionPermissionState {
    try Task.checkCancellation()
    let resourceKey = TiebaUserInteractionPermissionsResourceKey(
      userID: expectedUserID,
      targetUserID: targetUserID
    )
    let followKey = TiebaUserFollowResourceKey(
      userID: expectedUserID,
      targetUserID: targetUserID
    )
    if let followFlight = userFollowFlights[followKey] {
      try await waitForUserFollowFlightCompletion(
        resourceKey: followKey,
        flightID: followFlight.id
      )
      return try await getUserInteractionPermissionState(
        credential: credential,
        expectedUserID: expectedUserID,
        targetUserID: targetUserID
      )
    }

    let identity = TiebaUserInteractionPermissionsIdentity(credential: credential)
    if let flight = userInteractionPermissionsFlights[resourceKey] {
      if flight.identity == identity, flight.permissions == permissions {
        return try await waitForUserInteractionPermissionsFlight(
          resourceKey: resourceKey,
          flightID: flight.id,
          task: flight.task
        )
      }
      try await waitForUserInteractionPermissionsFlightCompletion(
        resourceKey: resourceKey,
        flightID: flight.id,
        keepsWriteAlive: false
      )
      return try await getUserInteractionPermissionState(
        credential: credential,
        expectedUserID: expectedUserID,
        targetUserID: targetUserID
      )
    }

    let flightID = UUID()
    let task: Task<TiebaUserInteractionPermissionState, Swift.Error> = Task.detached { [self] in
      try await performUserInteractionPermissionsWrite(
        resourceKey: resourceKey,
        flightID: flightID,
        credential: credential,
        expectedUserID: expectedUserID,
        targetUserID: targetUserID,
        permissions: permissions
      )
    }
    userInteractionPermissionsFlights[resourceKey] = TiebaUserInteractionPermissionsFlight(
      id: flightID,
      identity: identity,
      permissions: permissions,
      task: task,
      stage: .queued
    )
    Task {
      await finishUserInteractionPermissionsFlight(
        resourceKey: resourceKey,
        flightID: flightID,
        task: task
      )
    }
    return try await waitForUserInteractionPermissionsFlight(
      resourceKey: resourceKey,
      flightID: flightID,
      task: task
    )
  }

  public func getPollState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) async throws -> TiebaPollState {
    let request = try requestFactory.pollState(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
    let response: PbPageResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.pollStateResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.pollState(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
  }

  public func submitPollVote(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    selectedOptionIDs: [Int32]
  ) async throws -> TiebaPollState {
    try Task.checkCancellation()
    let canonicalOptionIDs = try requestFactory.validatePollVoteArguments(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      selectedOptionIDs: selectedOptionIDs
    )
    let resourceKey = TiebaPollResourceKey(
      userID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
    let identity = TiebaPollFlightIdentity(credential: credential)

    if let flight = pollFlights[resourceKey] {
      if flight.identity == identity, flight.selectedOptionIDs == canonicalOptionIDs {
        return try await waitForPollFlight(
          resourceKey: resourceKey,
          flightID: flight.id,
          task: flight.task
        )
      }
      try await waitForPollFlightCompletion(
        resourceKey: resourceKey,
        flightID: flight.id,
        keepsWriteAlive: false
      )
      return try await getPollState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID
      )
    }

    let flightID = UUID()
    let task: Task<TiebaPollState, Swift.Error> = Task.detached { [self] in
      try await performPollVoteWrite(
        resourceKey: resourceKey,
        flightID: flightID,
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        selectedOptionIDs: canonicalOptionIDs
      )
    }
    pollFlights[resourceKey] = TiebaPollFlight(
      id: flightID,
      identity: identity,
      selectedOptionIDs: canonicalOptionIDs,
      task: task,
      stage: .queued
    )
    Task {
      await finishPollFlight(
        resourceKey: resourceKey,
        flightID: flightID,
        task: task
      )
    }
    return try await waitForPollFlight(
      resourceKey: resourceKey,
      flightID: flightID,
      task: task
    )
  }

  public func getCloudFavorites(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    offset: Int = 0,
    pageSize: Int = 20
  ) async throws -> TiebaCloudFavoritePage {
    let request = try requestFactory.cloudFavorites(
      credential: credential,
      expectedUserID: expectedUserID,
      offset: offset,
      pageSize: pageSize
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.cloudFavoritesResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.cloudFavorites(
      from: body,
      expectedUserID: expectedUserID,
      offset: offset,
      pageSize: pageSize
    )
  }

  public func getThreadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) async throws -> TiebaThreadCloudFavoriteState {
    try await getThreadCloudFavoriteContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    ).state
  }

  public func setThreadCloudFavoriteState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    markedPostID: Int64?
  ) async throws -> TiebaThreadCloudFavoriteState {
    try Task.checkCancellation()
    try requestFactory.validateThreadCloudFavoriteWriteArguments(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      markedPostID: markedPostID
    )

    let resourceKey = TiebaThreadCloudFavoriteResourceKey(
      userID: expectedUserID,
      threadID: threadID
    )
    let identity = TiebaThreadCloudFavoriteIdentity(
      credential: credential,
      forumID: forumID
    )
    if let flight = threadCloudFavoriteFlights[resourceKey] {
      if flight.identity == identity, flight.markedPostID == markedPostID {
        try await waitForSharedThreadCloudFavoriteFlight(
          resourceKey: resourceKey,
          flightID: flight.id
        )
        return try await flight.task.value
      }

      try await waitForConflictingThreadCloudFavoriteFlight(
        resourceKey: resourceKey,
        flightID: flight.id
      )
      return try await getThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID
      )
    }

    try Task.checkCancellation()
    let flightID = UUID()
    let task: Task<TiebaThreadCloudFavoriteState, Swift.Error> = Task.detached { [self] in
      try await performThreadCloudFavoriteWrite(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        markedPostID: markedPostID
      )
    }
    threadCloudFavoriteFlights[resourceKey] = TiebaThreadCloudFavoriteFlight(
      id: flightID,
      identity: identity,
      markedPostID: markedPostID,
      task: task
    )
    defer { clearThreadCloudFavoriteFlight(resourceKey: resourceKey, flightID: flightID) }
    return try await task.value
  }

  public func submitTextReply(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission
  ) async throws -> TiebaTextReplyResult {
    try Task.checkCancellation()
    let normalizedForumName = try requestFactory.validateTextReplyArguments(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission
    )
    let identity = TiebaTextReplyFlightIdentity(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission,
      normalizedForumName: normalizedForumName
    )
    if let flight = textReplyFlights[submission.submissionID] {
      guard flight.identity == identity else {
        throw TiebaClientError.replySubmissionIDConflict
      }
      return try await waitForTextReplyFlight(
        submissionID: submission.submissionID,
        task: flight.task
      )
    }

    let predecessor = textReplyAccountTails[expectedUserID]?.task
    let task: Task<TiebaTextReplyResult, Swift.Error> = Task.detached { [self] in
      if let predecessor {
        await predecessor.value
      }
      try Task.checkCancellation()
      return try await performTextReplySubmission(
        credential: credential,
        expectedUserID: expectedUserID,
        submission: submission,
        normalizedForumName: normalizedForumName
      )
    }
    textReplyFlights[submission.submissionID] = TiebaTextReplyFlight(
      identity: identity,
      task: task,
      stage: .queued
    )
    textReplyFlightOrder.append(submission.submissionID)

    let tail = Task.detached { [self] in
      await finishTextReplyFlight(
        submissionID: submission.submissionID,
        expectedUserID: expectedUserID,
        task: task
      )
    }
    textReplyAccountTails[expectedUserID] = TiebaTextReplyAccountTail(
      submissionID: submission.submissionID,
      task: tail
    )
    return try await waitForTextReplyFlight(
      submissionID: submission.submissionID,
      task: task
    )
  }

  public func submitNewThread(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaNewThreadSubmission
  ) async throws -> TiebaNewThreadResult {
    try Task.checkCancellation()
    let normalizedForumName = try requestFactory.validateNewThreadArguments(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission
    )
    let identity = TiebaNewThreadFlightIdentity(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission,
      normalizedForumName: normalizedForumName
    )
    if let flight = newThreadFlights[submission.submissionID] {
      guard flight.identity == identity else {
        throw TiebaClientError.newThreadSubmissionIDConflict
      }
      return try await waitForNewThreadFlight(
        submissionID: submission.submissionID,
        task: flight.task
      )
    }

    let predecessor = newThreadAccountTails[expectedUserID]?.task
    let task: Task<TiebaNewThreadResult, Swift.Error> = Task.detached { [self] in
      if let predecessor {
        await predecessor.value
      }
      try Task.checkCancellation()
      return try await performNewThreadSubmission(
        credential: credential,
        expectedUserID: expectedUserID,
        submission: submission,
        normalizedForumName: normalizedForumName
      )
    }
    newThreadFlights[submission.submissionID] = TiebaNewThreadFlight(
      identity: identity,
      task: task,
      stage: .queued
    )
    newThreadFlightOrder.append(submission.submissionID)

    let tail = Task.detached { [self] in
      await finishNewThreadFlight(
        submissionID: submission.submissionID,
        expectedUserID: expectedUserID,
        task: task
      )
    }
    newThreadAccountTails[expectedUserID] = TiebaNewThreadAccountTail(
      submissionID: submission.submissionID,
      task: tail
    )
    return try await waitForNewThreadFlight(
      submissionID: submission.submissionID,
      task: task
    )
  }

  public func uploadStaticImage(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    upload: TiebaStaticImageUpload
  ) async throws -> TiebaStaticImageUploadReceipt {
    try Task.checkCancellation()
    let plan = try requestFactory.validateStaticImageUploadArguments(
      credential: credential,
      expectedUserID: expectedUserID,
      upload: upload
    )
    let identity = TiebaStaticImageUploadFlightIdentity(
      credential: credential,
      expectedUserID: expectedUserID,
      plan: plan
    )
    if let flight = staticImageUploadFlights[upload.uploadID] {
      guard flight.identity == identity else {
        throw TiebaClientError.staticImageUploadIDConflict
      }
      return try await waitForStaticImageUploadFlight(
        uploadID: upload.uploadID,
        task: flight.task
      )
    }

    let flightID = UUID()
    let task: Task<TiebaStaticImageUploadReceipt, Swift.Error> = Task.detached { [self] in
      try await runStaticImageUploadWithAccountLease(
        credential: credential,
        expectedUserID: expectedUserID,
        plan: plan,
        flightID: flightID
      )
    }
    staticImageUploadFlights[upload.uploadID] = TiebaStaticImageUploadFlight(
      id: flightID,
      identity: identity,
      task: task,
      stage: .queued
    )
    staticImageUploadFlightOrder.append(upload.uploadID)

    _ = Task.detached { [self] in
      await finishStaticImageUploadFlight(
        uploadID: upload.uploadID,
        flightID: flightID,
        task: task
      )
    }
    return try await waitForStaticImageUploadFlight(
      uploadID: upload.uploadID,
      task: task
    )
  }

  public func verifyNewThreadVisibility(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaNewThreadSubmission,
    receipt: TiebaNewThreadReceipt
  ) async throws -> TiebaNewThreadReceipt? {
    try Task.checkCancellation()
    let normalizedForumName = try requestFactory.validateNewThreadArguments(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission
    )
    guard receipt.isValid else {
      throw TiebaClientError.invalidArgument(
        "New-thread receipt identifiers must be positive."
      )
    }
    let context = try await getNewThreadContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      forumName: normalizedForumName
    )
    try Task.checkCancellation()
    return try await verifiedNewThread(
      credential: credential,
      expectedUserID: expectedUserID,
      context: context,
      submission: submission,
      receipt: receipt
    )
  }

  public func getConcernFeed(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    pageTag: String? = nil,
    lastRequestUnix: UInt64 = 0
  ) async throws -> TiebaConcernPage {
    let request = try requestFactory.concernFeed(
      credential: credential,
      expectedUserID: expectedUserID,
      pageTag: pageTag,
      lastRequestUnix: lastRequestUnix
    )
    let response: UserLikeResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.concernResponseMaximumBytes
    )
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    let page = try TiebaProtoMapper.concernPage(
      response.data,
      expectedUserID: expectedUserID,
      requestedPageTag: pageTag
    )
    guard Self.concernResponseRequestsSessionValidation(response.data, page: page) else {
      return page
    }

    do {
      let account = try await validateSession(credential: credential)
      guard account.userID == expectedUserID else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      return page
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TiebaClientError {
      switch error {
      case .server, .invalidAuthenticatedResponse:
        throw TiebaClientError.invalidAuthenticatedResponse
      default:
        throw error
      }
    }
  }

  public func getFollowedForums(
    credential: TiebaBDUSSCredential,
    userID: Int64,
    page: Int = 1,
    pageSize: Int = 50
  ) async throws -> TiebaFollowedForumPage {
    try await getLikedForums(
      credential: credential,
      accountUserID: userID,
      targetUserID: userID,
      page: page,
      pageSize: pageSize
    )
  }

  public func getLikedForums(
    credential: TiebaBDUSSCredential,
    accountUserID: Int64,
    targetUserID: Int64,
    page: Int = 1,
    pageSize: Int = 50
  ) async throws -> TiebaFollowedForumPage {
    let request = try requestFactory.likedForums(
      credential: credential,
      accountUserID: accountUserID,
      targetUserID: targetUserID,
      page: page,
      pageSize: pageSize
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.followedForumsResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.followedForums(
      from: body,
      page: page,
      pageSize: pageSize,
      accountUserID: accountUserID,
      targetUserID: targetUserID
    )
  }

  public func getNotifications(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    kind: TiebaNotificationKind,
    page: Int = 1
  ) async throws -> TiebaNotificationPage {
    let request = try requestFactory.notifications(
      credential: credential,
      expectedUserID: expectedUserID,
      kind: kind,
      page: page
    )
    switch kind {
    case .replies:
      let response: ReplyMeResIdl = try await sendProtobuf(
        request,
        maximumBodyBytes: Self.notificationResponseMaximumBytes
      )
      return try TiebaNotificationDecoder.replyPage(
        from: response,
        expectedUserID: expectedUserID,
        requestedPage: page
      )
    case .mentions:
      let body = try await send(
        request,
        maximumBodyBytes: Self.notificationResponseMaximumBytes
      )
      return try TiebaNotificationDecoder.mentionPage(
        from: body,
        expectedUserID: expectedUserID,
        requestedPage: page
      )
    }
  }

  public func getInboxUnreadSummary(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64
  ) async throws -> TiebaInboxUnreadSummary {
    let request = try requestFactory.inboxUnreadSummary(
      credential: credential,
      expectedUserID: expectedUserID
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.inboxUnreadSummaryResponseMaximumBytes
    )
    return try TiebaInboxUnreadSummaryDecoder.summary(
      from: body,
      expectedUserID: expectedUserID
    )
  }

  public func getOfficialCheckInCatalog(
    credential: TiebaSessionCredential,
    expectedUserID: Int64
  ) async throws -> TiebaOfficialCheckInCatalog {
    try await getOfficialCheckInCatalogContext(
      credential: credential,
      expectedUserID: expectedUserID
    ).catalog
  }

  public func performOfficialBatchCheckIn(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    authorizedTargets: [TiebaOfficialBatchCheckInTarget]
  ) async throws -> TiebaOfficialBatchCheckInResult {
    try Task.checkCancellation()
    let authorizedTargets = try canonicalOfficialBatchCheckInTargets(authorizedTargets)
    let identity = TiebaOfficialBatchCheckInIdentity(
      credential: credential,
      authorizedTargets: authorizedTargets
    )
    gate: while true {
      if let flight = officialBatchCheckInFlights[expectedUserID] {
        if flight.identity == identity {
          return try await waitForOfficialBatchCheckInFlight(
            expectedUserID: expectedUserID,
            flightID: flight.id,
            task: flight.task
          )
        }
        try await waitForOfficialBatchCheckInFlightCompletion(
          expectedUserID: expectedUserID,
          flightID: flight.id,
          keepsWriteAlive: false
        )
        try Task.checkCancellation()
        continue gate
      }
      break gate
    }
    try Task.checkCancellation()
    let flightID = UUID()
    let task = Task.detached { [self] in
      try await executeOfficialBatchCheckInAfterCurrentForumCheckIns(
        flightID: flightID,
        credential: credential,
        expectedUserID: expectedUserID,
        authorizedTargets: authorizedTargets
      )
    }
    officialBatchCheckInFlights[expectedUserID] = TiebaOfficialBatchCheckInFlight(
      id: flightID,
      identity: identity,
      task: task,
      stage: .queued
    )
    Task {
      await finishOfficialBatchCheckInFlight(
        expectedUserID: expectedUserID,
        flightID: flightID,
        task: task
      )
    }
    return try await waitForOfficialBatchCheckInFlight(
      expectedUserID: expectedUserID,
      flightID: flightID,
      task: task
    )
  }

  public func joinOfficialBatchCheckInIfInFlight(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    authorizedTargets: [TiebaOfficialBatchCheckInTarget]
  ) async throws -> TiebaOfficialBatchCheckInResult? {
    try Task.checkCancellation()
    let authorizedTargets = try canonicalOfficialBatchCheckInTargets(authorizedTargets)
    let identity = TiebaOfficialBatchCheckInIdentity(
      credential: credential,
      authorizedTargets: authorizedTargets
    )
    guard
      let flight = officialBatchCheckInFlights[expectedUserID],
      flight.identity == identity
    else { return nil }
    return try await waitForOfficialBatchCheckInFlight(
      expectedUserID: expectedUserID,
      flightID: flight.id,
      task: flight.task
    )
  }

  public func getForumMembership(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumMembership {
    try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: false
    ).membership
  }

  public func getForumAccountState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: true
    ).state
  }

  public func setForumFollowState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> TiebaForumMembership {
    let context = try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: false
    )
    guard context.membership.isFollowed != isFollowed else {
      return context.membership
    }

    let request = try requestFactory.setForumFollowState(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: context.membership.forumName,
      tbs: context.tbs,
      isFollowed: isFollowed
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.forumFollowWriteResponseMaximumBytes
    )
    try TiebaAuthenticatedDecoder.checkForumFollowWriteResponse(body)
    return TiebaForumMembership(
      userID: context.membership.userID,
      forumID: context.membership.forumID,
      forumName: context.membership.forumName,
      isFollowed: isFollowed
    )
  }

  public func checkInToForum(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    try Task.checkCancellation()
    let forumName = try requestFactory.normalizedForumName(forumName)
    let resourceKey = TiebaForumCheckInResourceKey(
      userID: expectedUserID,
      forumID: forumID
    )
    let identity = TiebaForumCheckInIdentity(
      credential: credential,
      forumName: forumName
    )

    gate: while true {
      while let batchFlight = officialBatchCheckInFlights[expectedUserID] {
        try await waitForOfficialBatchCheckInFlightCompletion(
          expectedUserID: expectedUserID,
          flightID: batchFlight.id,
          keepsWriteAlive: false
        )
        try Task.checkCancellation()
      }
      if let flight = forumCheckInFlights[resourceKey] {
        if flight.identity == identity {
          registerSharedForumCheckInWaiter(flightID: flight.id)
          defer { unregisterSharedForumCheckInWaiter(flightID: flight.id) }
          return try await flight.task.value
        }
        try await waitForForumCheckInFlight(
          resourceKey: resourceKey,
          flightID: flight.id
        )
        continue gate
      }
      break gate
    }

    try Task.checkCancellation()
    let flightID = UUID()
    let task: Task<TiebaForumAccountState, Swift.Error> = Task.detached { [self] in
      try await performForumCheckIn(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName
      )
    }
    forumCheckInFlights[resourceKey] = TiebaForumCheckInFlight(
      id: flightID,
      identity: identity,
      task: task
    )
    defer { clearForumCheckInFlight(resourceKey: resourceKey, flightID: flightID) }
    return try await task.value
  }

  public func getThreadAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64
  ) async throws -> TiebaThreadAgreement {
    let agreement = try await getAgreement(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: .thread(firstPostID: firstPostID)
    )
    return TiebaThreadAgreement(
      userID: agreement.userID,
      forumID: agreement.forumID,
      threadID: agreement.threadID,
      firstPostID: firstPostID,
      isAgreed: agreement.isAgreed,
      agreeScore: agreement.agreeScore
    )
  }

  public func getAgreement(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaAgreementTarget
  ) async throws -> TiebaAgreementState {
    switch target {
    case .thread(let firstPostID):
      let page = try await awaitAgreementPage(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        location: .postID(firstPostID)
      )
      return try uniqueAgreement(target, in: page)
    case .post(let postID):
      let page = try await awaitAgreementPage(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        location: .postID(postID)
      )
      return try uniqueAgreement(target, in: page)
    case .subpost(let parentPostID, let subpostID):
      let page = try await getSubpostAgreementPage(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        parentPostID: parentPostID,
        aroundSubpostID: subpostID,
        page: 1
      )
      return try uniqueAgreement(target, in: page)
    }
  }

  public func getAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    page: Int = 1,
    pageSize: Int = 30,
    sort: TiebaPostSort = .ascending,
    onlyThreadAuthor: Bool = false,
    location: TiebaPostLocation? = nil,
    includeSubposts: Bool = true,
    subpostsSortedByAgree: Bool = true,
    subpostPageSize: Int = 4
  ) async throws -> TiebaAgreementPage {
    let request = try requestFactory.agreementPage(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      page: page,
      pageSize: pageSize,
      sort: sort,
      onlyThreadAuthor: onlyThreadAuthor,
      location: location,
      includeSubposts: includeSubposts,
      subpostsSortedByAgree: subpostsSortedByAgree,
      subpostPageSize: subpostPageSize
    )
    let response: PbPageResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.agreementPageResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.agreementPage(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
  }

  public func getSubpostAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    parentPostID: Int64,
    aroundSubpostID: Int64? = nil,
    page: Int = 1
  ) async throws -> TiebaAgreementPage {
    let parentProbe = try await awaitAgreementPage(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      location: .postID(parentPostID)
    )
    let matchingParentTargets = parentProbe.agreements.compactMap { agreement in
      switch agreement.target {
      case .thread(let firstPostID) where firstPostID == parentPostID:
        agreement.target
      case .post(let postID) where postID == parentPostID:
        agreement.target
      default:
        nil
      }
    }
    guard matchingParentTargets.count == 1, let parentTarget = matchingParentTargets.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let request = try requestFactory.subpostAgreementPage(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      parentPostID: parentPostID,
      aroundSubpostID: aroundSubpostID,
      page: page
    )
    let response: PbFloorResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.subpostAgreementPageResponseMaximumBytes
    )
    let page = try TiebaAuthenticatedDecoder.subpostAgreementPage(
      from: response,
      validatedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      parentPostID: parentPostID,
      requiredSubpostID: aroundSubpostID
    )
    guard page.agreements.lazy.filter({ $0.target == parentTarget }).count == 1 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return page
  }

  public func setThreadAgreementState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64,
    isAgreed: Bool
  ) async throws -> TiebaThreadAgreement {
    let agreement = try await setAgreementState(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      threadID: threadID,
      target: .thread(firstPostID: firstPostID),
      isAgreed: isAgreed
    )
    return TiebaThreadAgreement(
      userID: agreement.userID,
      forumID: agreement.forumID,
      threadID: agreement.threadID,
      firstPostID: firstPostID,
      isAgreed: agreement.isAgreed,
      agreeScore: agreement.agreeScore
    )
  }

  public func setAgreementState(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaAgreementTarget,
    isAgreed: Bool
  ) async throws -> TiebaAgreementState {
    try Task.checkCancellation()
    let forumName = try requestFactory.normalizedForumName(forumName)
    let resourceKey = TiebaAgreementResourceKey(
      userID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: target
    )
    let identity = TiebaAgreementIdentity(
      credential: credential,
      forumID: forumID,
      forumName: forumName
    )

    if let flight = agreementFlights[resourceKey] {
      if flight.identity == identity, flight.targetAgreed == isAgreed {
        registerSharedAgreementWaiter(flightID: flight.id)
        defer { unregisterSharedAgreementWaiter(flightID: flight.id) }
        return try await flight.task.value
      }

      registerConflictingAgreementWaiter(resourceKey: resourceKey)
      defer { unregisterConflictingAgreementWaiter(resourceKey: resourceKey) }
      _ = await flight.task.result
      try Task.checkCancellation()
      return try await getAgreement(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        target: target
      )
    }

    try Task.checkCancellation()
    let flightID = UUID()
    let predecessor = agreementAccountTails[expectedUserID]?.task
    let task: Task<TiebaAgreementState, Swift.Error> = Task.detached { [self] in
      await predecessor?.value
      return try await performAgreementWrite(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName,
        threadID: threadID,
        target: target,
        isAgreed: isAgreed
      )
    }
    agreementFlights[resourceKey] = TiebaAgreementFlight(
      id: flightID,
      identity: identity,
      targetAgreed: isAgreed,
      task: task
    )
    let tailID = UUID()
    let tailTask = Task.detached { _ = await task.result }
    agreementAccountTails[expectedUserID] = TiebaAgreementAccountTail(id: tailID, task: tailTask)
    defer {
      clearAgreementFlight(
        resourceKey: resourceKey,
        flightID: flightID,
        userID: expectedUserID,
        tailID: tailID
      )
    }
    return try await task.value
  }

  private func performAgreementWrite(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    target: TiebaAgreementTarget,
    isAgreed: Bool
  ) async throws -> TiebaAgreementState {
    let current = try await getAgreement(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: target
    )
    guard current.isAgreed != isAgreed else { return current }
    let forumContext = try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: false
    )
    let request = try requestFactory.setAgreement(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: target,
      tbs: forumContext.tbs,
      isAgreed: isAgreed
    )
    do {
      let body = try await send(
        request,
        maximumBodyBytes: Self.threadAgreementWriteResponseMaximumBytes
      )
      let responseScore = try TiebaAuthenticatedDecoder.agreementWriteScore(from: body)
      return TiebaAgreementState(
        userID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        target: target,
        isAgreed: isAgreed,
        agreeScore: responseScore
          ?? adjustedAgreementScore(current.agreeScore, isAgreed: isAgreed)
      )
    } catch {
      guard isUncertainAgreementWriteError(error) else { throw error }
      if let reconciled = try? await getAgreement(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID,
        target: target
      ), reconciled.isAgreed == isAgreed {
        return reconciled
      }
      throw error
    }
  }

  private func performThreadCloudFavoriteWrite(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    markedPostID: Int64?
  ) async throws -> TiebaThreadCloudFavoriteState {
    let current = try await getThreadCloudFavoriteContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
    guard current.state.markedPostID != markedPostID else { return current.state }

    let request = try requestFactory.setThreadCloudFavoriteState(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      tbs: current.tbs,
      markedPostID: markedPostID
    )
    do {
      let body = try await send(
        request,
        maximumBodyBytes: Self.threadCloudFavoriteWriteResponseMaximumBytes
      )
      try TiebaAuthenticatedDecoder.checkThreadCloudFavoriteWriteResponse(body)
    } catch {
      guard isUncertainThreadCloudFavoriteWriteError(error) else { throw error }
      if let reconciled = try? await getThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID
      ), reconciled.markedPostID == markedPostID {
        return reconciled
      }
      throw TiebaClientError.threadCloudFavoriteOutcomeUnknown
    }

    do {
      let reconciled = try await getThreadCloudFavoriteState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID
      )
      guard reconciled.markedPostID == markedPostID else {
        throw TiebaClientError.threadCloudFavoriteOutcomeUnknown
      }
      return reconciled
    } catch {
      throw TiebaClientError.threadCloudFavoriteOutcomeUnknown
    }
  }

  private func performUserFollowWrite(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64,
    isFollowed: Bool
  ) async throws -> TiebaUserRelationship {
    let current = try await getUserRelationshipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID
    )
    guard current.relationship.isFollowed != isFollowed else {
      return current.relationship
    }

    let request = try requestFactory.setUserFollowState(
      credential: credential,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID,
      targetPortrait: current.portrait,
      tbs: current.tbs,
      isFollowed: isFollowed
    )
    var writeError: Swift.Error?
    do {
      let body = try await send(
        request,
        maximumBodyBytes: Self.userFollowWriteResponseMaximumBytes
      )
      try TiebaAuthenticatedDecoder.checkUserFollowWriteResponse(body)
    } catch {
      writeError = error
    }

    let reconciled: TiebaUserRelationship
    do {
      reconciled = try await getUserRelationship(
        credential: credential,
        expectedUserID: expectedUserID,
        targetUserID: targetUserID
      )
    } catch {
      throw writeError ?? error
    }
    // The acknowledgement does not bind a target or state. A successful
    // authenticated readback is therefore the only mutation result we expose.
    return reconciled
  }

  private func performUserInteractionPermissionsWrite(
    resourceKey: TiebaUserInteractionPermissionsResourceKey,
    flightID: UUID,
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64,
    permissions: TiebaUserInteractionPermissions
  ) async throws -> TiebaUserInteractionPermissionState {
    try beginUserInteractionPermissionsPreflight(
      resourceKey: resourceKey,
      flightID: flightID
    )
    let current = try await getUserInteractionPermissionState(
      credential: credential,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID
    )
    guard current.permissions != permissions else { return current }

    let freshContext = try await getUserRelationshipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID
    )
    let request = try requestFactory.setUserInteractionPermissions(
      credential: credential,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID,
      tbs: freshContext.tbs,
      permissions: permissions
    )
    try beginUserInteractionPermissionsWrite(
      resourceKey: resourceKey,
      flightID: flightID
    )
    do {
      let body = try await send(
        request,
        maximumBodyBytes: Self.userInteractionPermissionsWriteResponseMaximumBytes
      )
      try TiebaAuthenticatedDecoder.checkUserInteractionPermissionsWriteResponse(body)
    } catch {
      // The write is one-shot. Its acknowledgement is not authoritative, so
      // every dispatched attempt is reconciled by the same raw read below.
    }

    do {
      let reconciled = try await getRawUserInteractionPermissionState(
        credential: credential,
        expectedUserID: expectedUserID,
        targetUserID: targetUserID
      )
      guard reconciled.permissions == permissions else {
        throw TiebaClientError.userInteractionPermissionsOutcomeUnknown
      }
      return reconciled
    } catch {
      throw TiebaClientError.userInteractionPermissionsOutcomeUnknown
    }
  }

  private func performPollVoteWrite(
    resourceKey: TiebaPollResourceKey,
    flightID: UUID,
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    selectedOptionIDs: [Int32]
  ) async throws -> TiebaPollState {
    try beginPollPreflight(resourceKey: resourceKey, flightID: flightID)
    let current = try await getPollState(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
    let selection = Set(selectedOptionIDs)
    if current.poll.isPolled, current.poll.selectedOptionIDs == selection {
      return current
    }
    guard !current.poll.isPolled else {
      throw TiebaClientError.invalidArgument("This account has already voted in the poll.")
    }
    guard !current.poll.isClosed() else {
      throw TiebaClientError.invalidArgument("This poll is closed.")
    }
    let availableOptionIDs = Set(current.poll.options.map(\.id))
    guard selection.isSubset(of: availableOptionIDs) else {
      throw TiebaClientError.invalidArgument("The poll selection contains an unknown option.")
    }
    guard current.poll.isMultipleChoice || selectedOptionIDs.count == 1 else {
      throw TiebaClientError.invalidArgument("This poll accepts only one option.")
    }

    let request = try requestFactory.submitPollVote(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      selectedOptionIDs: selectedOptionIDs
    )
    try beginPollWrite(resourceKey: resourceKey, flightID: flightID)
    do {
      let response: AddPollPostResIdl = try await sendProtobuf(
        request,
        maximumBodyBytes: Self.pollWriteResponseMaximumBytes
      )
      try TiebaAuthenticatedDecoder.checkPollWriteResponse(response)
    } catch {
      // A dispatched one-shot vote is never automatically replayed. The same
      // authoritative readback below decides whether its result is publishable.
    }

    do {
      let reconciled = try await getPollState(
        credential: credential,
        expectedUserID: expectedUserID,
        forumID: forumID,
        threadID: threadID
      )
      guard
        reconciled.poll.isPolled,
        reconciled.poll.selectedOptionIDs == selection
      else {
        throw TiebaClientError.pollOutcomeUnknown
      }
      return reconciled
    } catch {
      throw TiebaClientError.pollOutcomeUnknown
    }
  }

  private func performTextReplySubmission(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission,
    normalizedForumName: String
  ) async throws -> TiebaTextReplyResult {
    setTextReplyFlightStage(submissionID: submission.submissionID, stage: .preflight)
    let context = try await getTextReplyContext(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission,
      normalizedForumName: normalizedForumName
    )
    try Task.checkCancellation()
    let request = try requestFactory.textReply(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission,
      normalizedForumName: normalizedForumName,
      tbs: context.tbs,
      accountDisplayName: context.accountDisplayName,
      replyUserID: context.replyUserID,
      replyUserDisplayName: context.replyUserDisplayName,
      replyUserPortrait: context.replyUserPortrait
    )
    try Task.checkCancellation()
    setTextReplyFlightStage(submissionID: submission.submissionID, stage: .writeDispatched)

    let body: Data
    do {
      body = try await send(
        request,
        maximumBodyBytes: Self.textReplyWriteResponseMaximumBytes
      )
    } catch {
      throw TiebaClientError.replyOutcomeUnknown
    }

    let receipt: TiebaTextReplyReceipt
    do {
      receipt = try TiebaAuthenticatedDecoder.textReplyReceipt(
        from: body,
        submission: submission
      )
    } catch let error as TiebaClientError {
      switch error {
      case .replyChallengeRequired, .server:
        throw error
      default:
        throw TiebaClientError.replyOutcomeUnknown
      }
    } catch {
      throw TiebaClientError.replyOutcomeUnknown
    }

    let outcome: TiebaTextReplyOutcome
    do {
      if let created = try await verifiedTextReply(
        credential: credential,
        expectedUserID: expectedUserID,
        context: context,
        submission: submission,
        receipt: receipt
      ) {
        outcome = .confirmed(created)
      } else {
        outcome = .acceptedAwaitingVisibility(receipt)
      }
    } catch {
      throw TiebaClientError.replyOutcomeUnknown
    }
    return TiebaTextReplyResult(
      submissionID: submission.submissionID,
      userID: expectedUserID,
      forumID: submission.forumID,
      threadID: submission.threadID,
      target: submission.target,
      outcome: outcome
    )
  }

  private func performNewThreadSubmission(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaNewThreadSubmission,
    normalizedForumName: String
  ) async throws -> TiebaNewThreadResult {
    setNewThreadFlightStage(submissionID: submission.submissionID, stage: .preflight)
    let context = try await getNewThreadContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      forumName: normalizedForumName
    )
    try Task.checkCancellation()
    let request = try requestFactory.newThread(
      credential: credential,
      expectedUserID: expectedUserID,
      submission: submission,
      normalizedForumName: normalizedForumName,
      tbs: context.tbs,
      accountDisplayName: context.accountDisplayName
    )
    try Task.checkCancellation()
    setNewThreadFlightStage(submissionID: submission.submissionID, stage: .writeDispatched)

    let body: Data
    do {
      body = try await send(
        request,
        maximumBodyBytes: Self.newThreadWriteResponseMaximumBytes
      )
    } catch {
      throw TiebaClientError.newThreadOutcomeUnknown
    }

    let receipt: TiebaNewThreadReceipt
    do {
      receipt = try TiebaAuthenticatedDecoder.newThreadReceipt(
        from: body,
        submission: submission
      )
    } catch let error as TiebaClientError {
      switch error {
      case .newThreadChallengeRequired, .server:
        throw error
      default:
        throw TiebaClientError.newThreadOutcomeUnknown
      }
    } catch {
      throw TiebaClientError.newThreadOutcomeUnknown
    }

    let outcome: TiebaNewThreadOutcome
    do {
      if let confirmed = try await verifiedNewThread(
        credential: credential,
        expectedUserID: expectedUserID,
        context: context,
        submission: submission,
        receipt: receipt
      ) {
        outcome = .confirmed(confirmed)
      } else {
        outcome = .acceptedAwaitingVisibility(receipt)
      }
    } catch {
      throw TiebaClientError.newThreadOutcomeUnknown
    }
    return TiebaNewThreadResult(
      submissionID: submission.submissionID,
      userID: expectedUserID,
      forumID: submission.forumID,
      forumName: normalizedForumName,
      outcome: outcome
    )
  }

  private func runStaticImageUploadWithAccountLease(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    plan: TiebaStaticImageUploadPlan,
    flightID: UUID
  ) async throws -> TiebaStaticImageUploadReceipt {
    try await acquireStaticImageUploadLease(
      expectedUserID: expectedUserID,
      uploadID: plan.upload.uploadID,
      flightID: flightID
    )
    defer {
      releaseStaticImageUploadLease(
        expectedUserID: expectedUserID,
        flightID: flightID
      )
    }
    try Task.checkCancellation()
    return try await performStaticImageUpload(
      credential: credential,
      expectedUserID: expectedUserID,
      plan: plan
    )
  }

  private func acquireStaticImageUploadLease(
    expectedUserID: Int64,
    uploadID: UUID,
    flightID: UUID
  ) async throws {
    try Task.checkCancellation()
    guard
      let flight = staticImageUploadFlights[uploadID],
      flight.id == flightID,
      flight.stage == .queued
    else { throw CancellationError() }
    if staticImageUploadLeaseOwners[expectedUserID] == nil {
      staticImageUploadLeaseOwners[expectedUserID] = flightID
      try await confirmStaticImageUploadLeaseAcquisition(
        expectedUserID: expectedUserID,
        uploadID: uploadID,
        flightID: flightID
      )
      return
    }

    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<TiebaStaticImageUploadLeaseOutcome, Never>) in
        guard
          !Task.isCancelled,
          let currentFlight = staticImageUploadFlights[uploadID],
          currentFlight.id == flightID,
          currentFlight.stage == .queued
        else {
          continuation.resume(returning: .cancelled)
          return
        }
        if staticImageUploadLeaseOwners[expectedUserID] == nil {
          staticImageUploadLeaseOwners[expectedUserID] = flightID
          continuation.resume(returning: .acquired)
          return
        }
        staticImageUploadLeaseWaiters[expectedUserID, default: []].append(
          TiebaStaticImageUploadLeaseWaiter(
            uploadID: uploadID,
            flightID: flightID,
            continuation: continuation
          )
        )
      }
    } onCancel: {
      Task {
        await self.cancelStaticImageUploadLeaseWaiter(
          expectedUserID: expectedUserID,
          uploadID: uploadID,
          flightID: flightID
        )
      }
    }
    guard outcome == .acquired else { throw CancellationError() }
    try await confirmStaticImageUploadLeaseAcquisition(
      expectedUserID: expectedUserID,
      uploadID: uploadID,
      flightID: flightID
    )
  }

  private func confirmStaticImageUploadLeaseAcquisition(
    expectedUserID: Int64,
    uploadID: UUID,
    flightID: UUID
  ) async throws {
    do {
      if let staticImageUploadLeaseAcquired {
        await staticImageUploadLeaseAcquired(uploadID)
      }
      try Task.checkCancellation()
    } catch {
      releaseStaticImageUploadLease(
        expectedUserID: expectedUserID,
        flightID: flightID
      )
      throw error
    }
  }

  private func releaseStaticImageUploadLease(
    expectedUserID: Int64,
    flightID: UUID
  ) {
    guard staticImageUploadLeaseOwners[expectedUserID] == flightID else { return }
    staticImageUploadLeaseOwners.removeValue(forKey: expectedUserID)

    var waiters = staticImageUploadLeaseWaiters.removeValue(forKey: expectedUserID) ?? []
    while !waiters.isEmpty {
      let waiter = waiters.removeFirst()
      guard
        let flight = staticImageUploadFlights[waiter.uploadID],
        flight.id == waiter.flightID,
        flight.stage == .queued
      else {
        waiter.continuation.resume(returning: .cancelled)
        continue
      }
      staticImageUploadLeaseOwners[expectedUserID] = waiter.flightID
      if !waiters.isEmpty {
        staticImageUploadLeaseWaiters[expectedUserID] = waiters
      }
      waiter.continuation.resume(returning: .acquired)
      return
    }
  }

  private func cancelStaticImageUploadLeaseWaiter(
    expectedUserID: Int64,
    uploadID: UUID,
    flightID: UUID
  ) {
    guard var waiters = staticImageUploadLeaseWaiters[expectedUserID] else { return }
    guard
      let index = waiters.firstIndex(where: {
        $0.uploadID == uploadID && $0.flightID == flightID
      })
    else { return }
    let waiter = waiters.remove(at: index)
    if waiters.isEmpty {
      staticImageUploadLeaseWaiters.removeValue(forKey: expectedUserID)
    } else {
      staticImageUploadLeaseWaiters[expectedUserID] = waiters
    }
    waiter.continuation.resume(returning: .cancelled)
  }

  private func performStaticImageUpload(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    plan: TiebaStaticImageUploadPlan
  ) async throws -> TiebaStaticImageUploadReceipt {
    try Task.checkCancellation()
    setStaticImageUploadFlightStage(
      uploadID: plan.upload.uploadID,
      stage: .preflight
    )
    let account = try await validateSession(credential: credential)
    guard account.userID == expectedUserID else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    try Task.checkCancellation()

    var receipt: TiebaStaticImageUploadReceipt?
    for chunkNumber in 1...plan.chunkCount {
      let request = try requestFactory.staticImageUploadChunk(
        credential: credential,
        expectedUserID: expectedUserID,
        plan: plan,
        chunkNumber: chunkNumber
      )
      try Task.checkCancellation()
      setStaticImageUploadFlightStage(
        uploadID: plan.upload.uploadID,
        stage: .chunkDispatched(chunkNumber)
      )

      let result: TiebaStaticImageChunkDecodeResult
      do {
        let body = try await send(
          request,
          maximumBodyBytes: Self.staticImageUploadResponseMaximumBytes
        )
        result = try TiebaStaticImageUploadDecoder.decodeChunkResponse(
          from: body,
          plan: plan,
          chunkNumber: chunkNumber
        )
      } catch let error as TiebaClientError {
        if case .server = error {
          throw error
        }
        throw TiebaClientError.staticImageUploadOutcomeUnknown(
          uploadID: plan.upload.uploadID,
          dispatchedChunk: chunkNumber
        )
      } catch {
        throw TiebaClientError.staticImageUploadOutcomeUnknown(
          uploadID: plan.upload.uploadID,
          dispatchedChunk: chunkNumber
        )
      }

      switch result {
      case .accepted:
        guard chunkNumber < plan.chunkCount else {
          throw TiebaClientError.staticImageUploadOutcomeUnknown(
            uploadID: plan.upload.uploadID,
            dispatchedChunk: chunkNumber
          )
        }
      case .completed(let completedReceipt):
        guard chunkNumber == plan.chunkCount else {
          throw TiebaClientError.staticImageUploadOutcomeUnknown(
            uploadID: plan.upload.uploadID,
            dispatchedChunk: chunkNumber
          )
        }
        receipt = completedReceipt
      }
    }
    guard let receipt else {
      throw TiebaClientError.staticImageUploadOutcomeUnknown(
        uploadID: plan.upload.uploadID,
        dispatchedChunk: plan.chunkCount
      )
    }
    return receipt
  }

  private func performForumCheckIn(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaForumAccountState {
    let context = try await getForumMembershipContext(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName,
      validatesCheckInMetadata: true
    )
    guard context.state.membership.isFollowed else {
      throw TiebaClientError.forumNotFollowed
    }
    guard let currentCheckIn = context.state.checkIn else {
      throw TiebaClientError.forumCheckInUnavailable
    }
    guard !currentCheckIn.isCheckedIn else {
      return context.state
    }

    let request = try requestFactory.checkInToForum(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: context.state.membership.forumName,
      tbs: context.tbs
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.forumCheckInResponseMaximumBytes
    )
    let checkIn = try TiebaAuthenticatedDecoder.forumCheckIn(
      from: body,
      expectedUserID: expectedUserID
    )
    return TiebaForumAccountState(
      membership: context.state.membership,
      checkIn: checkIn
    )
  }

  private func awaitAgreementPage(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    location: TiebaPostLocation
  ) async throws -> TiebaAgreementPage {
    try await getAgreementPage(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      page: 1,
      pageSize: 2,
      location: location,
      includeSubposts: false
    )
  }

  private func uniqueAgreement(
    _ target: TiebaAgreementTarget,
    in page: TiebaAgreementPage
  ) throws -> TiebaAgreementState {
    let matches = page.agreements.filter { $0.target == target }
    guard matches.count == 1, let agreement = matches.first else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return agreement
  }

  private func sendProtobuf<Message: SwiftProtobuf.Message>(
    _ request: URLRequest,
    maximumBodyBytes: Int
  ) async throws -> Message {
    let body = try await send(request, maximumBodyBytes: maximumBodyBytes)
    do {
      return try Message(serializedBytes: body)
    } catch {
      throw TiebaClientError.invalidProtobuf
    }
  }

  private static func concernResponseRequestsSessionValidation(
    _ data: UserLikeResIdl.DataRes,
    page: TiebaConcernPage
  ) -> Bool {
    guard
      page.threads.isEmpty,
      !page.hasMore,
      data.userTipsType == 1
    else { return false }
    let tip = data.userTips.trimmingCharacters(in: .whitespacesAndNewlines)
    return tip.contains("登录") || tip.lowercased().contains("login")
  }

  private func isUncertainThreadCloudFavoriteWriteError(_ error: Swift.Error) -> Bool {
    if error is CancellationError { return true }
    guard let error = error as? TiebaClientError else { return true }
    switch error {
    case .invalidArgument, .invalidEndpoint, .server:
      return false
    default:
      return true
    }
  }

  func threadCloudFavoriteWaiterCounts(
    expectedUserID: Int64,
    threadID: Int64
  ) -> (shared: Int, conflict: Int) {
    let resourceKey = TiebaThreadCloudFavoriteResourceKey(
      userID: expectedUserID,
      threadID: threadID
    )
    let shared = threadCloudFavoriteFlights[resourceKey].flatMap {
      threadCloudFavoriteSharedWaiters[$0.id]?.count
    } ?? 0
    return (
      shared: shared,
      conflict: threadCloudFavoriteConflictWaiters[resourceKey]?.count ?? 0
    )
  }

  private func waitForSharedThreadCloudFavoriteFlight(
    resourceKey: TiebaThreadCloudFavoriteResourceKey,
    flightID: UUID
  ) async throws {
    try Task.checkCancellation()
    let waiterID = UUID()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard
          !Task.isCancelled,
          threadCloudFavoriteFlights[resourceKey]?.id == flightID
        else {
          continuation.resume(
            returning: Task.isCancelled
              ? TiebaThreadCloudFavoriteWaitOutcome.cancelled
              : TiebaThreadCloudFavoriteWaitOutcome.completed
          )
          return
        }
        threadCloudFavoriteSharedWaiters[flightID, default: [:]][waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelSharedThreadCloudFavoriteWaiter(
          flightID: flightID,
          waiterID: waiterID
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    try Task.checkCancellation()
  }

  private func waitForConflictingThreadCloudFavoriteFlight(
    resourceKey: TiebaThreadCloudFavoriteResourceKey,
    flightID: UUID
  ) async throws {
    try Task.checkCancellation()
    let waiterID = UUID()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard
          !Task.isCancelled,
          threadCloudFavoriteFlights[resourceKey]?.id == flightID
        else {
          continuation.resume(
            returning: Task.isCancelled
              ? TiebaThreadCloudFavoriteWaitOutcome.cancelled
              : TiebaThreadCloudFavoriteWaitOutcome.completed
          )
          return
        }
        threadCloudFavoriteConflictWaiters[resourceKey, default: [:]][waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelConflictingThreadCloudFavoriteWaiter(
          resourceKey: resourceKey,
          waiterID: waiterID
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    try Task.checkCancellation()
  }

  private func cancelSharedThreadCloudFavoriteWaiter(
    flightID: UUID,
    waiterID: UUID
  ) {
    guard var waiters = threadCloudFavoriteSharedWaiters[flightID] else { return }
    let continuation = waiters.removeValue(forKey: waiterID)
    if waiters.isEmpty {
      threadCloudFavoriteSharedWaiters.removeValue(forKey: flightID)
    } else {
      threadCloudFavoriteSharedWaiters[flightID] = waiters
    }
    continuation?.resume(returning: .cancelled)
  }

  private func cancelConflictingThreadCloudFavoriteWaiter(
    resourceKey: TiebaThreadCloudFavoriteResourceKey,
    waiterID: UUID
  ) {
    guard var waiters = threadCloudFavoriteConflictWaiters[resourceKey] else { return }
    let continuation = waiters.removeValue(forKey: waiterID)
    if waiters.isEmpty {
      threadCloudFavoriteConflictWaiters.removeValue(forKey: resourceKey)
    } else {
      threadCloudFavoriteConflictWaiters[resourceKey] = waiters
    }
    continuation?.resume(returning: .cancelled)
  }

  private func clearThreadCloudFavoriteFlight(
    resourceKey: TiebaThreadCloudFavoriteResourceKey,
    flightID: UUID
  ) {
    guard threadCloudFavoriteFlights[resourceKey]?.id == flightID else { return }
    threadCloudFavoriteFlights.removeValue(forKey: resourceKey)
    let sharedWaiters = threadCloudFavoriteSharedWaiters.removeValue(forKey: flightID) ?? [:]
    let conflictWaiters =
      threadCloudFavoriteConflictWaiters.removeValue(forKey: resourceKey) ?? [:]
    for continuation in sharedWaiters.values {
      continuation.resume(returning: .completed)
    }
    for continuation in conflictWaiters.values {
      continuation.resume(returning: .completed)
    }
  }

  private func waitForTextReplyFlight(
    submissionID: UUID,
    task: Task<TiebaTextReplyResult, Swift.Error>
  ) async throws -> TiebaTextReplyResult {
    try Task.checkCancellation()
    if textReplyFlights[submissionID]?.isCompleted != false {
      return try await task.value
    }

    let waiterID = UUID()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard
          !Task.isCancelled,
          textReplyFlights[submissionID]?.isCompleted == false
        else {
          continuation.resume(
            returning: Task.isCancelled
              ? TiebaTextReplyWaitOutcome.cancelled
              : TiebaTextReplyWaitOutcome.completed
          )
          return
        }
        textReplyWaiters[submissionID, default: [:]][waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelTextReplyWaiter(
          submissionID: submissionID,
          waiterID: waiterID
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    return try await task.value
  }

  private func cancelTextReplyWaiter(
    submissionID: UUID,
    waiterID: UUID
  ) {
    guard var waiters = textReplyWaiters[submissionID] else { return }
    let continuation = waiters.removeValue(forKey: waiterID)
    if waiters.isEmpty {
      textReplyWaiters.removeValue(forKey: submissionID)
      if let flight = textReplyFlights[submissionID],
        flight.stage == .queued || flight.stage == .preflight
      {
        flight.task.cancel()
      }
    } else {
      textReplyWaiters[submissionID] = waiters
    }
    continuation?.resume(returning: .cancelled)
  }

  private func finishTextReplyFlight(
    submissionID: UUID,
    expectedUserID: Int64,
    task: Task<TiebaTextReplyResult, Swift.Error>
  ) async {
    let result = await task.result
    guard var flight = textReplyFlights[submissionID] else { return }
    flight.stage = .completed

    let retainsSubmission: Bool
    switch result {
    case .success:
      retainsSubmission = true
    case .failure(let error):
      retainsSubmission = (error as? TiebaClientError) == .replyOutcomeUnknown
    }
    if retainsSubmission {
      textReplyFlights[submissionID] = flight
    } else {
      textReplyFlights.removeValue(forKey: submissionID)
      textReplyFlightOrder.removeAll { $0 == submissionID }
    }
    if textReplyAccountTails[expectedUserID]?.submissionID == submissionID {
      textReplyAccountTails.removeValue(forKey: expectedUserID)
    }

    let waiters = textReplyWaiters.removeValue(forKey: submissionID) ?? [:]
    for continuation in waiters.values {
      continuation.resume(returning: .completed)
    }
    pruneRetainedTextReplyFlights()
  }

  private func pruneRetainedTextReplyFlights() {
    var completedCount = textReplyFlights.values.lazy.filter(\.isCompleted).count
    guard completedCount > Self.retainedTextReplySubmissionLimit else { return }
    var retainedOrder = [UUID]()
    retainedOrder.reserveCapacity(textReplyFlightOrder.count)
    for submissionID in textReplyFlightOrder {
      if completedCount > Self.retainedTextReplySubmissionLimit,
        textReplyFlights[submissionID]?.isCompleted == true
      {
        textReplyFlights.removeValue(forKey: submissionID)
        completedCount -= 1
      } else if textReplyFlights[submissionID] != nil {
        retainedOrder.append(submissionID)
      }
    }
    textReplyFlightOrder = retainedOrder
  }

  private func setTextReplyFlightStage(
    submissionID: UUID,
    stage: TiebaTextReplyFlightStage
  ) {
    guard var flight = textReplyFlights[submissionID], !flight.isCompleted else { return }
    flight.stage = stage
    textReplyFlights[submissionID] = flight
  }

  func textReplyWaiterCount(submissionID: UUID) -> Int {
    textReplyWaiters[submissionID]?.count ?? 0
  }

  func textReplyWaiterCountForTests() -> Int {
    textReplyWaiters.values.reduce(0) { $0 + $1.count }
  }

  private func waitForNewThreadFlight(
    submissionID: UUID,
    task: Task<TiebaNewThreadResult, Swift.Error>
  ) async throws -> TiebaNewThreadResult {
    try Task.checkCancellation()
    if newThreadFlights[submissionID]?.isCompleted != false {
      return try await task.value
    }

    let waiterID = UUID()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard
          !Task.isCancelled,
          newThreadFlights[submissionID]?.isCompleted == false
        else {
          continuation.resume(
            returning: Task.isCancelled
              ? TiebaNewThreadWaitOutcome.cancelled
              : TiebaNewThreadWaitOutcome.completed
          )
          return
        }
        newThreadWaiters[submissionID, default: [:]][waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelNewThreadWaiter(
          submissionID: submissionID,
          waiterID: waiterID
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    return try await task.value
  }

  private func cancelNewThreadWaiter(
    submissionID: UUID,
    waiterID: UUID
  ) {
    guard var waiters = newThreadWaiters[submissionID] else { return }
    let continuation = waiters.removeValue(forKey: waiterID)
    if waiters.isEmpty {
      newThreadWaiters.removeValue(forKey: submissionID)
      if let flight = newThreadFlights[submissionID],
        flight.stage == .queued || flight.stage == .preflight
      {
        flight.task.cancel()
      }
    } else {
      newThreadWaiters[submissionID] = waiters
    }
    continuation?.resume(returning: .cancelled)
  }

  private func finishNewThreadFlight(
    submissionID: UUID,
    expectedUserID: Int64,
    task: Task<TiebaNewThreadResult, Swift.Error>
  ) async {
    let result = await task.result
    guard var flight = newThreadFlights[submissionID] else { return }
    flight.stage = .completed

    let retainsSubmission: Bool
    switch result {
    case .success:
      retainsSubmission = true
    case .failure(let error):
      retainsSubmission = (error as? TiebaClientError) == .newThreadOutcomeUnknown
    }
    if retainsSubmission {
      newThreadFlights[submissionID] = flight
    } else {
      newThreadFlights.removeValue(forKey: submissionID)
      newThreadFlightOrder.removeAll { $0 == submissionID }
    }
    if newThreadAccountTails[expectedUserID]?.submissionID == submissionID {
      newThreadAccountTails.removeValue(forKey: expectedUserID)
    }

    let waiters = newThreadWaiters.removeValue(forKey: submissionID) ?? [:]
    for continuation in waiters.values {
      continuation.resume(returning: .completed)
    }
    pruneRetainedNewThreadFlights()
  }

  private func pruneRetainedNewThreadFlights() {
    var completedCount = newThreadFlights.values.lazy.filter(\.isCompleted).count
    guard completedCount > Self.retainedNewThreadSubmissionLimit else { return }
    var retainedOrder = [UUID]()
    retainedOrder.reserveCapacity(newThreadFlightOrder.count)
    for submissionID in newThreadFlightOrder {
      if completedCount > Self.retainedNewThreadSubmissionLimit,
        newThreadFlights[submissionID]?.isCompleted == true
      {
        newThreadFlights.removeValue(forKey: submissionID)
        completedCount -= 1
      } else if newThreadFlights[submissionID] != nil {
        retainedOrder.append(submissionID)
      }
    }
    newThreadFlightOrder = retainedOrder
  }

  private func setNewThreadFlightStage(
    submissionID: UUID,
    stage: TiebaNewThreadFlightStage
  ) {
    guard var flight = newThreadFlights[submissionID], !flight.isCompleted else { return }
    flight.stage = stage
    newThreadFlights[submissionID] = flight
  }

  func newThreadWaiterCount(submissionID: UUID) -> Int {
    newThreadWaiters[submissionID]?.count ?? 0
  }

  func newThreadWaiterCountForTests() -> Int {
    newThreadWaiters.values.reduce(0) { $0 + $1.count }
  }

  func newThreadRetainedFlightCountForTests() -> Int {
    newThreadFlights.values.lazy.filter(\.isCompleted).count
  }

  private func waitForStaticImageUploadFlight(
    uploadID: UUID,
    task: Task<TiebaStaticImageUploadReceipt, Swift.Error>
  ) async throws -> TiebaStaticImageUploadReceipt {
    guard !Task.isCancelled else {
      cancelStaticImageUploadOwnerIfPreDispatchAndUnobserved(uploadID: uploadID)
      throw CancellationError()
    }
    if staticImageUploadFlights[uploadID]?.isCompleted != false {
      return try await task.value
    }

    let waiterID = UUID()
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<TiebaStaticImageUploadWaitOutcome, Never>) in
        if Task.isCancelled {
          cancelStaticImageUploadOwnerIfPreDispatchAndUnobserved(uploadID: uploadID)
          continuation.resume(returning: .cancelled)
          return
        }
        guard staticImageUploadFlights[uploadID]?.isCompleted == false else {
          continuation.resume(
            returning: .completed
          )
          return
        }
        staticImageUploadWaiters[uploadID, default: [:]][waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelStaticImageUploadWaiter(uploadID: uploadID, waiterID: waiterID)
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    return try await task.value
  }

  private func cancelStaticImageUploadOwnerIfPreDispatchAndUnobserved(uploadID: UUID) {
    guard
      staticImageUploadWaiters[uploadID]?.isEmpty ?? true,
      let flight = staticImageUploadFlights[uploadID],
      flight.stage == .queued || flight.stage == .preflight
    else { return }
    flight.task.cancel()
    if flight.stage == .queued {
      cancelStaticImageUploadLeaseWaiter(
        expectedUserID: flight.identity.expectedUserID,
        uploadID: uploadID,
        flightID: flight.id
      )
    }
    staticImageUploadFlights.removeValue(forKey: uploadID)
    staticImageUploadFlightOrder.removeAll { $0 == uploadID }
  }

  private func cancelStaticImageUploadWaiter(uploadID: UUID, waiterID: UUID) {
    guard var waiters = staticImageUploadWaiters[uploadID] else { return }
    let continuation = waiters.removeValue(forKey: waiterID)
    if waiters.isEmpty {
      staticImageUploadWaiters.removeValue(forKey: uploadID)
      cancelStaticImageUploadOwnerIfPreDispatchAndUnobserved(uploadID: uploadID)
    } else {
      staticImageUploadWaiters[uploadID] = waiters
    }
    continuation?.resume(returning: .cancelled)
  }

  private func finishStaticImageUploadFlight(
    uploadID: UUID,
    flightID: UUID,
    task: Task<TiebaStaticImageUploadReceipt, Swift.Error>
  ) async {
    let result = await task.result
    guard
      var flight = staticImageUploadFlights[uploadID],
      flight.id == flightID
    else { return }
    flight.stage = .completed

    let retainsUpload: Bool
    switch result {
    case .success:
      retainsUpload = true
    case .failure(let error):
      if let error = error as? TiebaClientError,
        case .staticImageUploadOutcomeUnknown = error
      {
        retainsUpload = true
      } else {
        retainsUpload = false
      }
    }
    if retainsUpload {
      staticImageUploadFlights[uploadID] = flight
    } else {
      staticImageUploadFlights.removeValue(forKey: uploadID)
      staticImageUploadFlightOrder.removeAll { $0 == uploadID }
    }
    let waiters = staticImageUploadWaiters.removeValue(forKey: uploadID) ?? [:]
    for continuation in waiters.values {
      continuation.resume(returning: .completed)
    }
    pruneRetainedStaticImageUploadFlights()
  }

  private func pruneRetainedStaticImageUploadFlights() {
    var completedCount = staticImageUploadFlights.values.lazy.filter(\.isCompleted).count
    guard completedCount > Self.retainedStaticImageUploadLimit else { return }
    var retainedOrder = [UUID]()
    retainedOrder.reserveCapacity(staticImageUploadFlightOrder.count)
    for uploadID in staticImageUploadFlightOrder {
      if completedCount > Self.retainedStaticImageUploadLimit,
        staticImageUploadFlights[uploadID]?.isCompleted == true
      {
        staticImageUploadFlights.removeValue(forKey: uploadID)
        completedCount -= 1
      } else if staticImageUploadFlights[uploadID] != nil {
        retainedOrder.append(uploadID)
      }
    }
    staticImageUploadFlightOrder = retainedOrder
  }

  private func setStaticImageUploadFlightStage(
    uploadID: UUID,
    stage: TiebaStaticImageUploadFlightStage
  ) {
    guard var flight = staticImageUploadFlights[uploadID], !flight.isCompleted else { return }
    flight.stage = stage
    staticImageUploadFlights[uploadID] = flight
  }

  func staticImageUploadWaiterCount(uploadID: UUID) -> Int {
    staticImageUploadWaiters[uploadID]?.count ?? 0
  }

  func staticImageUploadRetainedFlightCountForTests() -> Int {
    staticImageUploadFlights.values.lazy.filter(\.isCompleted).count
  }

  func staticImageUploadQueuedLeaseCountForTests() -> Int {
    staticImageUploadLeaseWaiters.values.reduce(0) { $0 + $1.count }
  }

  func staticImageUploadActiveFlightCountForTests() -> Int {
    staticImageUploadFlights.values.lazy.filter { !$0.isCompleted }.count
  }

  func staticImageUploadActiveFlightByteCountForTests() -> Int {
    staticImageUploadFlights.values.lazy.filter { !$0.isCompleted }
      .reduce(0) { $0 + $1.identity.byteCount }
  }

  private func adjustedAgreementScore(_ score: Int, isAgreed: Bool) -> Int {
    let delta = isAgreed ? 1 : -1
    let (adjusted, overflow) = score.addingReportingOverflow(delta)
    guard !overflow else { return isAgreed ? Int.max : Int.min }
    return adjusted
  }

  private func isUncertainAgreementWriteError(_ error: Swift.Error) -> Bool {
    if error is CancellationError { return true }
    guard let error = error as? TiebaClientError else { return true }
    switch error {
    case .invalidArgument, .invalidEndpoint, .server:
      return false
    default:
      return true
    }
  }

  func threadAgreementWaiterCounts(
    expectedUserID: Int64,
    threadID: Int64,
    firstPostID: Int64
  ) -> (shared: Int, conflict: Int) {
    let target = TiebaAgreementTarget.thread(firstPostID: firstPostID)
    let keys = agreementFlights.keys.filter {
      $0.userID == expectedUserID && $0.threadID == threadID && $0.target == target
    }
    return keys.reduce(into: (shared: 0, conflict: 0)) { result, key in
      if let flightID = agreementFlights[key]?.id {
        result.shared += agreementSharedWaiterCounts[flightID] ?? 0
      }
      result.conflict += agreementConflictWaiterCounts[key] ?? 0
    }
  }

  func agreementWaiterCounts(
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64,
    target: TiebaAgreementTarget
  ) -> (shared: Int, conflict: Int) {
    let resourceKey = TiebaAgreementResourceKey(
      userID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      target: target
    )
    let shared = agreementFlights[resourceKey].flatMap {
      agreementSharedWaiterCounts[$0.id]
    } ?? 0
    return (shared, agreementConflictWaiterCounts[resourceKey] ?? 0)
  }

  private func registerSharedAgreementWaiter(flightID: UUID) {
    agreementSharedWaiterCounts[flightID, default: 0] += 1
  }

  private func unregisterSharedAgreementWaiter(flightID: UUID) {
    guard let count = agreementSharedWaiterCounts[flightID] else { return }
    if count <= 1 {
      agreementSharedWaiterCounts.removeValue(forKey: flightID)
    } else {
      agreementSharedWaiterCounts[flightID] = count - 1
    }
  }

  private func registerConflictingAgreementWaiter(
    resourceKey: TiebaAgreementResourceKey
  ) {
    agreementConflictWaiterCounts[resourceKey, default: 0] += 1
  }

  private func unregisterConflictingAgreementWaiter(
    resourceKey: TiebaAgreementResourceKey
  ) {
    guard let count = agreementConflictWaiterCounts[resourceKey] else { return }
    if count <= 1 {
      agreementConflictWaiterCounts.removeValue(forKey: resourceKey)
    } else {
      agreementConflictWaiterCounts[resourceKey] = count - 1
    }
  }

  private func clearAgreementFlight(
    resourceKey: TiebaAgreementResourceKey,
    flightID: UUID,
    userID: Int64,
    tailID: UUID
  ) {
    if agreementFlights[resourceKey]?.id == flightID {
      agreementFlights.removeValue(forKey: resourceKey)
      agreementSharedWaiterCounts.removeValue(forKey: flightID)
    }
    if agreementAccountTails[userID]?.id == tailID {
      agreementAccountTails.removeValue(forKey: userID)
    }
  }

  private func getThreadCloudFavoriteContext(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) async throws -> TiebaThreadCloudFavoriteContext {
    let request = try requestFactory.threadCloudFavoriteState(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
    let response: PbPageResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.threadCloudFavoriteStateResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.threadCloudFavoriteContext(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      threadID: threadID
    )
  }

  private func getNewThreadContext(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String
  ) async throws -> TiebaNewThreadContext {
    let request = try requestFactory.forumMembership(
      credential: credential.bdussCredential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName
    )
    let response: FrsPageResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.forumMembershipResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.newThreadContext(
      from: response,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName
    )
  }

  private func verifiedNewThread(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    context: TiebaNewThreadContext,
    submission: TiebaNewThreadSubmission,
    receipt: TiebaNewThreadReceipt
  ) async throws -> TiebaNewThreadReceipt? {
    guard expectedUserID == context.userID else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let request = try requestFactory.agreementPage(
      credential: credential.bdussCredential,
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      threadID: receipt.threadID,
      page: 1,
      pageSize: 2,
      sort: .ascending,
      onlyThreadAuthor: false,
      location: .postID(receipt.firstPostID),
      includeSubposts: false,
      subpostsSortedByAgree: true,
      subpostPageSize: 4
    )
    let response: PbPageResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.agreementPageResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.verifiedNewThread(
      from: response,
      context: context,
      submission: submission,
      receipt: receipt
    )
  }

  private func getTextReplyContext(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaTextReplySubmission,
    normalizedForumName: String
  ) async throws -> TiebaTextReplyContext {
    let parentPostID: Int64
    switch submission.target {
    case .thread(let firstPostID):
      parentPostID = firstPostID
    case .post(let postID):
      parentPostID = postID
    case .subpost(let postID, _):
      parentPostID = postID
    }
    let pageRequest = try requestFactory.agreementPage(
      credential: credential.bdussCredential,
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      threadID: submission.threadID,
      page: 1,
      pageSize: 2,
      sort: .ascending,
      onlyThreadAuthor: false,
      location: .postID(parentPostID),
      includeSubposts: false,
      subpostsSortedByAgree: true,
      subpostPageSize: 4
    )
    let pageResponse: PbPageResIdl = try await sendProtobuf(
      pageRequest,
      maximumBodyBytes: Self.agreementPageResponseMaximumBytes
    )
    let parentContext = try TiebaAuthenticatedDecoder.textReplyPageContext(
      from: pageResponse,
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      forumName: normalizedForumName,
      threadID: submission.threadID,
      target: submission.target
    )
    guard case .subpost(let targetParentPostID, let subpostID) = submission.target else {
      return parentContext
    }

    try Task.checkCancellation()
    let floorRequest = try requestFactory.subpostAgreementPage(
      credential: credential.bdussCredential,
      expectedUserID: expectedUserID,
      forumID: submission.forumID,
      threadID: submission.threadID,
      parentPostID: targetParentPostID,
      aroundSubpostID: subpostID,
      page: 1
    )
    let floorResponse: PbFloorResIdl = try await sendProtobuf(
      floorRequest,
      maximumBodyBytes: Self.subpostAgreementPageResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.textReplySubpostContext(
      from: floorResponse,
      parentContext: parentContext,
      subpostID: subpostID
    )
  }

  private func verifiedTextReply(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    context: TiebaTextReplyContext,
    submission: TiebaTextReplySubmission,
    receipt: TiebaTextReplyReceipt
  ) async throws -> TiebaCreatedReply? {
    switch receipt {
    case .post(let postID):
      guard case .thread = submission.target else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      let request = try requestFactory.agreementPage(
        credential: credential.bdussCredential,
        expectedUserID: expectedUserID,
        forumID: submission.forumID,
        threadID: submission.threadID,
        page: 1,
        pageSize: 2,
        sort: .ascending,
        onlyThreadAuthor: false,
        location: .postID(postID),
        includeSubposts: false,
        subpostsSortedByAgree: true,
        subpostPageSize: 4
      )
      let response: PbPageResIdl = try await sendProtobuf(
        request,
        maximumBodyBytes: Self.agreementPageResponseMaximumBytes
      )
      return try TiebaAuthenticatedDecoder.verifiedTextReplyPost(
        from: response,
        expectedUserID: expectedUserID,
        forumID: submission.forumID,
        forumName: context.forumName,
        threadID: submission.threadID,
        postID: postID,
        submission: submission
      )
    case .subpost(let parentPostID, let subpostID):
      switch submission.target {
      case .post(let targetPostID) where targetPostID == parentPostID:
        break
      case .subpost(let targetPostID, _) where targetPostID == parentPostID:
        break
      default:
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      let request = try requestFactory.subpostAgreementPage(
        credential: credential.bdussCredential,
        expectedUserID: expectedUserID,
        forumID: submission.forumID,
        threadID: submission.threadID,
        parentPostID: parentPostID,
        aroundSubpostID: subpostID,
        page: 1
      )
      let response: PbFloorResIdl = try await sendProtobuf(
        request,
        maximumBodyBytes: Self.subpostAgreementPageResponseMaximumBytes
      )
      return try TiebaAuthenticatedDecoder.verifiedTextReplySubpost(
        from: response,
        context: context,
        newSubpostID: subpostID,
        content: submission.content
      )
    }
  }

  private func getForumMembershipContext(
    credential: TiebaBDUSSCredential,
    expectedUserID: Int64,
    forumID: Int64,
    forumName: String,
    validatesCheckInMetadata: Bool
  ) async throws -> TiebaForumMembershipContext {
    let request = try requestFactory.forumMembership(
      credential: credential,
      expectedUserID: expectedUserID,
      forumID: forumID,
      forumName: forumName
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.forumMembershipResponseMaximumBytes
    )
    let response: FrsPageResIdl
    do {
      response = try FrsPageResIdl(serializedBytes: body)
    } catch {
      throw TiebaClientError.invalidProtobuf
    }
    if validatesCheckInMetadata {
      return try TiebaAuthenticatedDecoder.forumAccountState(
        from: response,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName
      )
    } else {
      return try TiebaAuthenticatedDecoder.forumMembership(
        from: response,
        expectedUserID: expectedUserID,
        forumID: forumID,
        forumName: forumName
      )
    }
  }

  private func getOfficialCheckInCatalogContext(
    credential: TiebaSessionCredential,
    expectedUserID: Int64
  ) async throws -> TiebaOfficialCheckInCatalogContext {
    let sessionRequest = try requestFactory.validateSessionApp(credential: credential)
    let sessionBody = try await send(
      sessionRequest,
      maximumBodyBytes: Self.officialCheckInSessionResponseMaximumBytes
    )
    let session = try TiebaOfficialCheckInDecoder.sessionContext(
      from: sessionBody,
      expectedUserID: expectedUserID
    )
    try Task.checkCancellation()

    let eligibilityRequest = try requestFactory.officialCheckInEligibility(
      credential: credential,
      expectedUserID: expectedUserID
    )
    let eligibilityBody = try await send(
      eligibilityRequest,
      maximumBodyBytes: Self.officialCheckInEligibilityResponseMaximumBytes
    )
    let eligibility = try TiebaOfficialCheckInDecoder.eligibility(from: eligibilityBody)
    try Task.checkCancellation()

    let pageSize = 50
    var page = 1
    var forums = [TiebaOfficialCheckInForum]()
    var seen = Set<Int64>()
    var guideAllowsBatchCheckIn = true
    var guideMinimumLevel = 0
    while true {
      let request = try requestFactory.officialCheckInGuide(
        credential: credential,
        expectedUserID: expectedUserID,
        tbs: session.tbs,
        page: page,
        pageSize: pageSize
      )
      let body = try await send(
        request,
        maximumBodyBytes: Self.officialCheckInGuideResponseMaximumBytes
      )
      let result = try TiebaOfficialCheckInDecoder.guidePage(
        from: body,
        expectedUserID: expectedUserID,
        requestedPage: page,
        pageSize: pageSize
      )
      guard page == 1 || result.advertisedMinimumLevel == guideMinimumLevel else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      if page == 1 { guideMinimumLevel = result.advertisedMinimumLevel }
      guideAllowsBatchCheckIn = guideAllowsBatchCheckIn && result.isBatchCheckInAvailable
      for forum in result.forums {
        guard seen.insert(forum.id).inserted else {
          throw TiebaClientError.invalidAuthenticatedResponse
        }
        forums.append(forum)
      }
      guard forums.count <= TiebaOfficialCheckInDecoder.maximumForumCount else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      guard result.hasMore else { break }
      guard !result.forums.isEmpty else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      page += 1
    }

    let minimumLevel = max(eligibility.minimumLevel, guideMinimumLevel)
    let catalog = TiebaOfficialCheckInCatalog(
      userID: expectedUserID,
      forums: forums,
      minimumBatchLevel: minimumLevel,
      maximumBatchCount: eligibility.maximumCount,
      isBatchCheckInAvailable: eligibility.isAvailable && guideAllowsBatchCheckIn
    )
    return TiebaOfficialCheckInCatalogContext(catalog: catalog, tbs: session.tbs)
  }

  private func executeOfficialBatchCheckIn(
    flightID: UUID,
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    authorizedTargets: [TiebaOfficialBatchCheckInTarget]
  ) async throws -> TiebaOfficialBatchCheckInResult {
    let context = try await getOfficialCheckInCatalogContext(
      credential: credential,
      expectedUserID: expectedUserID
    )
    let authorizedByID = Dictionary(
      uniqueKeysWithValues: authorizedTargets.map { ($0.forumID, $0.canonicalForumName) }
    )
    for forum in context.catalog.forums {
      if let authorizedName = authorizedByID[forum.id], authorizedName != forum.name {
        throw TiebaClientError.officialBatchCheckInAuthorizationChanged
      }
    }
    let targets = context.catalog.batchEligibleForums.filter {
      authorizedByID[$0.id] == $0.name
    }
    guard !targets.isEmpty else {
      return TiebaOfficialBatchCheckInResult(userID: expectedUserID, items: [])
    }
    try Task.checkCancellation()
    let request = try requestFactory.officialBatchCheckIn(
      credential: credential,
      expectedUserID: expectedUserID,
      tbs: context.tbs,
      forumIDs: targets.map(\.id)
    )
    let dispatchedTargets = targets.map {
      TiebaOfficialBatchCheckInTarget(forumID: $0.id, canonicalForumName: $0.name)
    }
    try beginOfficialBatchCheckInWrite(
      expectedUserID: expectedUserID,
      flightID: flightID
    )
    do {
      let body = try await send(
        request,
        maximumBodyBytes: Self.officialBatchCheckInResponseMaximumBytes
      )
      return try TiebaOfficialCheckInDecoder.batchResult(
        from: body,
        expectedUserID: expectedUserID,
        requestedForums: targets
      )
    } catch {
      throw TiebaClientError.officialBatchCheckInOutcomeUnknown(
        dispatchedTargets: dispatchedTargets
      )
    }
  }

  private func executeOfficialBatchCheckInAfterCurrentForumCheckIns(
    flightID: UUID,
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    authorizedTargets: [TiebaOfficialBatchCheckInTarget]
  ) async throws -> TiebaOfficialBatchCheckInResult {
    while let entry = forumCheckInFlights.first(where: { $0.key.userID == expectedUserID }) {
      _ = await entry.value.task.result
      clearForumCheckInFlight(resourceKey: entry.key, flightID: entry.value.id)
      try Task.checkCancellation()
    }
    try beginOfficialBatchCheckInPreflight(
      expectedUserID: expectedUserID,
      flightID: flightID
    )
    return try await executeOfficialBatchCheckIn(
      flightID: flightID,
      credential: credential,
      expectedUserID: expectedUserID,
      authorizedTargets: authorizedTargets
    )
  }

  private func getUserRelationshipContext(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64
  ) async throws -> TiebaUserRelationshipContext {
    let request = try requestFactory.userRelationship(
      credential: credential,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID
    )
    let response: ProfileResIdl = try await sendProtobuf(
      request,
      maximumBodyBytes: Self.userRelationshipResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.userRelationship(
      from: response,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID
    )
  }

  private func getRawUserInteractionPermissionState(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    targetUserID: Int64
  ) async throws -> TiebaUserInteractionPermissionState {
    let request = try requestFactory.userInteractionPermissions(
      credential: credential,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID
    )
    let body = try await send(
      request,
      maximumBodyBytes: Self.userInteractionPermissionsResponseMaximumBytes
    )
    return try TiebaAuthenticatedDecoder.userInteractionPermissions(
      from: body,
      expectedUserID: expectedUserID,
      targetUserID: targetUserID
    )
  }

  private func waitForUserFollowFlight(
    resourceKey: TiebaUserFollowResourceKey,
    flightID: UUID,
    task: Task<TiebaUserRelationship, Swift.Error>
  ) async throws -> TiebaUserRelationship {
    try await waitForUserFollowFlightCompletion(
      resourceKey: resourceKey,
      flightID: flightID
    )
    try Task.checkCancellation()
    return try await task.value
  }

  private func waitForUserFollowFlightCompletion(
    resourceKey: TiebaUserFollowResourceKey,
    flightID: UUID
  ) async throws {
    try Task.checkCancellation()
    guard userFollowFlights[resourceKey]?.id == flightID else { return }
    let waiterID = UUID()
    let outcome: TiebaUserFollowWaitOutcome = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<TiebaUserFollowWaitOutcome, Never>) in
        guard
          !Task.isCancelled,
          userFollowFlights[resourceKey]?.id == flightID
        else {
          continuation.resume(
            returning: Task.isCancelled ? .cancelled : .completed
          )
          return
        }
        userFollowWaiters[resourceKey, default: [:]][waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelUserFollowWaiter(
          resourceKey: resourceKey,
          waiterID: waiterID
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    try Task.checkCancellation()
  }

  private func cancelUserFollowWaiter(
    resourceKey: TiebaUserFollowResourceKey,
    waiterID: UUID
  ) {
    guard var waiters = userFollowWaiters[resourceKey] else { return }
    let continuation = waiters.removeValue(forKey: waiterID)
    if waiters.isEmpty {
      userFollowWaiters.removeValue(forKey: resourceKey)
    } else {
      userFollowWaiters[resourceKey] = waiters
    }
    continuation?.resume(returning: .cancelled)
  }

  func userFollowWaiterCount(
    expectedUserID: Int64,
    targetUserID: Int64
  ) -> Int {
    let resourceKey = TiebaUserFollowResourceKey(
      userID: expectedUserID,
      targetUserID: targetUserID
    )
    return userFollowWaiters[resourceKey]?.count ?? 0
  }

  private func finishUserFollowFlight(
    resourceKey: TiebaUserFollowResourceKey,
    flightID: UUID,
    task: Task<TiebaUserRelationship, Swift.Error>
  ) async {
    _ = await task.result
    guard userFollowFlights[resourceKey]?.id == flightID else { return }
    userFollowFlights.removeValue(forKey: resourceKey)
    let waiters = userFollowWaiters.removeValue(forKey: resourceKey) ?? [:]
    for continuation in waiters.values {
      continuation.resume(returning: .completed)
    }
  }

  private func waitForUserInteractionPermissionsFlight(
    resourceKey: TiebaUserInteractionPermissionsResourceKey,
    flightID: UUID,
    task: Task<TiebaUserInteractionPermissionState, Swift.Error>
  ) async throws -> TiebaUserInteractionPermissionState {
    try await waitForUserInteractionPermissionsFlightCompletion(
      resourceKey: resourceKey,
      flightID: flightID
    )
    try Task.checkCancellation()
    return try await task.value
  }

  private func waitForUserInteractionPermissionsFlightCompletion(
    resourceKey: TiebaUserInteractionPermissionsResourceKey,
    flightID: UUID,
    keepsWriteAlive: Bool = true
  ) async throws {
    if Task.isCancelled {
      cancelUnregisteredUserInteractionPermissionsWaiter(
        resourceKey: resourceKey,
        flightID: flightID,
        keepsWriteAlive: keepsWriteAlive
      )
      throw CancellationError()
    }
    guard userInteractionPermissionsFlights[resourceKey]?.id == flightID else { return }
    let waiterID = UUID()
    let outcome: TiebaUserInteractionPermissionsWaitOutcome = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<TiebaUserInteractionPermissionsWaitOutcome, Never>) in
        guard
          !Task.isCancelled,
          userInteractionPermissionsFlights[resourceKey]?.id == flightID
        else {
          if Task.isCancelled {
            cancelUnregisteredUserInteractionPermissionsWaiter(
              resourceKey: resourceKey,
              flightID: flightID,
              keepsWriteAlive: keepsWriteAlive
            )
          }
          continuation.resume(returning: Task.isCancelled ? .cancelled : .completed)
          return
        }
        userInteractionPermissionsWaiters[resourceKey, default: [:]][waiterID] = continuation
        if keepsWriteAlive {
          userInteractionPermissionsSharedWaiterIDs[resourceKey, default: []].insert(waiterID)
        }
      }
    } onCancel: {
      Task {
        await self.cancelUserInteractionPermissionsWaiter(
          resourceKey: resourceKey,
          flightID: flightID,
          waiterID: waiterID,
          keepsWriteAlive: keepsWriteAlive
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    try Task.checkCancellation()
  }

  private func cancelUserInteractionPermissionsWaiter(
    resourceKey: TiebaUserInteractionPermissionsResourceKey,
    flightID: UUID,
    waiterID: UUID,
    keepsWriteAlive: Bool
  ) {
    guard userInteractionPermissionsFlights[resourceKey]?.id == flightID else { return }
    guard var waiters = userInteractionPermissionsWaiters[resourceKey] else {
      cancelUnregisteredUserInteractionPermissionsWaiter(
        resourceKey: resourceKey,
        flightID: flightID,
        keepsWriteAlive: keepsWriteAlive
      )
      return
    }
    let continuation = waiters.removeValue(forKey: waiterID)
    if var sharedWaiterIDs = userInteractionPermissionsSharedWaiterIDs[resourceKey] {
      sharedWaiterIDs.remove(waiterID)
      if sharedWaiterIDs.isEmpty {
        userInteractionPermissionsSharedWaiterIDs.removeValue(forKey: resourceKey)
      } else {
        userInteractionPermissionsSharedWaiterIDs[resourceKey] = sharedWaiterIDs
      }
    }
    if waiters.isEmpty {
      userInteractionPermissionsWaiters.removeValue(forKey: resourceKey)
    } else {
      userInteractionPermissionsWaiters[resourceKey] = waiters
    }
    if keepsWriteAlive,
      userInteractionPermissionsSharedWaiterIDs[resourceKey]?.isEmpty != false,
      let flight = userInteractionPermissionsFlights[resourceKey],
      flight.stage == .queued || flight.stage == .preflight
    {
      flight.task.cancel()
    }
    continuation?.resume(returning: .cancelled)
  }

  private func cancelUnregisteredUserInteractionPermissionsWaiter(
    resourceKey: TiebaUserInteractionPermissionsResourceKey,
    flightID: UUID,
    keepsWriteAlive: Bool
  ) {
    guard
      keepsWriteAlive,
      userInteractionPermissionsSharedWaiterIDs[resourceKey]?.isEmpty != false,
      let flight = userInteractionPermissionsFlights[resourceKey],
      flight.id == flightID,
      flight.stage == .queued || flight.stage == .preflight
    else { return }
    flight.task.cancel()
  }

  private func finishUserInteractionPermissionsFlight(
    resourceKey: TiebaUserInteractionPermissionsResourceKey,
    flightID: UUID,
    task: Task<TiebaUserInteractionPermissionState, Swift.Error>
  ) async {
    _ = await task.result
    guard var flight = userInteractionPermissionsFlights[resourceKey], flight.id == flightID else {
      return
    }
    flight.stage = .completed
    userInteractionPermissionsFlights[resourceKey] = flight
    userInteractionPermissionsFlights.removeValue(forKey: resourceKey)
    let waiters = userInteractionPermissionsWaiters.removeValue(forKey: resourceKey) ?? [:]
    userInteractionPermissionsSharedWaiterIDs.removeValue(forKey: resourceKey)
    for continuation in waiters.values {
      continuation.resume(returning: .completed)
    }
  }

  func userInteractionPermissionsWaiterCount(
    expectedUserID: Int64,
    targetUserID: Int64
  ) -> Int {
    userInteractionPermissionsWaiters[
      TiebaUserInteractionPermissionsResourceKey(
        userID: expectedUserID,
        targetUserID: targetUserID
      )
    ]?.count ?? 0
  }

  func userInteractionPermissionsFlightExists(
    expectedUserID: Int64,
    targetUserID: Int64
  ) -> Bool {
    userInteractionPermissionsFlights[
      TiebaUserInteractionPermissionsResourceKey(
        userID: expectedUserID,
        targetUserID: targetUserID
      )
    ] != nil
  }

  private func beginUserInteractionPermissionsPreflight(
    resourceKey: TiebaUserInteractionPermissionsResourceKey,
    flightID: UUID
  ) throws {
    try Task.checkCancellation()
    guard
      var flight = userInteractionPermissionsFlights[resourceKey],
      flight.id == flightID,
      flight.stage == .queued
    else { throw CancellationError() }
    flight.stage = .preflight
    userInteractionPermissionsFlights[resourceKey] = flight
  }

  private func beginUserInteractionPermissionsWrite(
    resourceKey: TiebaUserInteractionPermissionsResourceKey,
    flightID: UUID
  ) throws {
    try Task.checkCancellation()
    guard
      var flight = userInteractionPermissionsFlights[resourceKey],
      flight.id == flightID,
      flight.stage == .preflight
    else { throw CancellationError() }
    flight.stage = .writeDispatched
    userInteractionPermissionsFlights[resourceKey] = flight
  }

  private func waitForPollFlight(
    resourceKey: TiebaPollResourceKey,
    flightID: UUID,
    task: Task<TiebaPollState, Swift.Error>
  ) async throws -> TiebaPollState {
    try await waitForPollFlightCompletion(resourceKey: resourceKey, flightID: flightID)
    try Task.checkCancellation()
    return try await task.value
  }

  private func waitForPollFlightCompletion(
    resourceKey: TiebaPollResourceKey,
    flightID: UUID,
    keepsWriteAlive: Bool = true
  ) async throws {
    if Task.isCancelled {
      cancelUnregisteredPollWaiter(
        resourceKey: resourceKey,
        flightID: flightID,
        keepsWriteAlive: keepsWriteAlive
      )
      throw CancellationError()
    }
    guard pollFlights[resourceKey]?.id == flightID else { return }
    let waiterID = UUID()
    let outcome: TiebaPollWaitOutcome = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<TiebaPollWaitOutcome, Never>) in
        guard !Task.isCancelled, pollFlights[resourceKey]?.id == flightID else {
          if Task.isCancelled {
            cancelUnregisteredPollWaiter(
              resourceKey: resourceKey,
              flightID: flightID,
              keepsWriteAlive: keepsWriteAlive
            )
          }
          continuation.resume(returning: Task.isCancelled ? .cancelled : .completed)
          return
        }
        pollWaiters[resourceKey, default: [:]][waiterID] = continuation
        if keepsWriteAlive {
          pollSharedWaiterIDs[resourceKey, default: []].insert(waiterID)
        }
      }
    } onCancel: {
      Task {
        await self.cancelPollWaiter(
          resourceKey: resourceKey,
          flightID: flightID,
          waiterID: waiterID,
          keepsWriteAlive: keepsWriteAlive
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
    try Task.checkCancellation()
  }

  private func cancelPollWaiter(
    resourceKey: TiebaPollResourceKey,
    flightID: UUID,
    waiterID: UUID,
    keepsWriteAlive: Bool
  ) {
    guard pollFlights[resourceKey]?.id == flightID else { return }
    guard var waiters = pollWaiters[resourceKey] else {
      cancelUnregisteredPollWaiter(
        resourceKey: resourceKey,
        flightID: flightID,
        keepsWriteAlive: keepsWriteAlive
      )
      return
    }
    let continuation = waiters.removeValue(forKey: waiterID)
    if var sharedWaiterIDs = pollSharedWaiterIDs[resourceKey] {
      sharedWaiterIDs.remove(waiterID)
      if sharedWaiterIDs.isEmpty {
        pollSharedWaiterIDs.removeValue(forKey: resourceKey)
      } else {
        pollSharedWaiterIDs[resourceKey] = sharedWaiterIDs
      }
    }
    if waiters.isEmpty {
      pollWaiters.removeValue(forKey: resourceKey)
    } else {
      pollWaiters[resourceKey] = waiters
    }
    if keepsWriteAlive,
      pollSharedWaiterIDs[resourceKey]?.isEmpty != false,
      let flight = pollFlights[resourceKey],
      flight.stage == .queued || flight.stage == .preflight
    {
      flight.task.cancel()
    }
    continuation?.resume(returning: .cancelled)
  }

  private func cancelUnregisteredPollWaiter(
    resourceKey: TiebaPollResourceKey,
    flightID: UUID,
    keepsWriteAlive: Bool
  ) {
    guard
      keepsWriteAlive,
      pollSharedWaiterIDs[resourceKey]?.isEmpty != false,
      let flight = pollFlights[resourceKey],
      flight.id == flightID,
      flight.stage == .queued || flight.stage == .preflight
    else { return }
    flight.task.cancel()
  }

  func pollWaiterCount(
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) -> Int {
    pollWaiters[
      TiebaPollResourceKey(userID: expectedUserID, forumID: forumID, threadID: threadID)
    ]?.count ?? 0
  }

  private func finishPollFlight(
    resourceKey: TiebaPollResourceKey,
    flightID: UUID,
    task: Task<TiebaPollState, Swift.Error>
  ) async {
    _ = await task.result
    guard var flight = pollFlights[resourceKey], flight.id == flightID else { return }
    flight.stage = .completed
    pollFlights[resourceKey] = flight
    pollFlights.removeValue(forKey: resourceKey)
    let waiters = pollWaiters.removeValue(forKey: resourceKey) ?? [:]
    pollSharedWaiterIDs.removeValue(forKey: resourceKey)
    for continuation in waiters.values {
      continuation.resume(returning: .completed)
    }
  }

  func pollFlightExists(
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) -> Bool {
    pollFlights[
      TiebaPollResourceKey(userID: expectedUserID, forumID: forumID, threadID: threadID)
    ] != nil
  }

  private func beginPollPreflight(
    resourceKey: TiebaPollResourceKey,
    flightID: UUID
  ) throws {
    try Task.checkCancellation()
    guard var flight = pollFlights[resourceKey], flight.id == flightID else {
      throw CancellationError()
    }
    guard flight.stage == .queued else { throw CancellationError() }
    flight.stage = .preflight
    pollFlights[resourceKey] = flight
  }

  private func beginPollWrite(
    resourceKey: TiebaPollResourceKey,
    flightID: UUID
  ) throws {
    try Task.checkCancellation()
    guard var flight = pollFlights[resourceKey], flight.id == flightID else {
      throw CancellationError()
    }
    guard flight.stage == .preflight else { throw CancellationError() }
    flight.stage = .writeDispatched
    pollFlights[resourceKey] = flight
  }

  private func waitForForumCheckInFlight(
    resourceKey: TiebaForumCheckInResourceKey,
    flightID: UUID
  ) async throws {
    try Task.checkCancellation()
    let waiterID = UUID()
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        guard
          !Task.isCancelled,
          forumCheckInFlights[resourceKey]?.id == flightID
        else {
          continuation.resume()
          return
        }
        forumCheckInConflictWaiters[resourceKey, default: [:]][waiterID] = continuation
      }
    } onCancel: {
      Task {
        await self.cancelForumCheckInWaiter(
          resourceKey: resourceKey,
          waiterID: waiterID
        )
      }
    }
    try Task.checkCancellation()
  }

  func forumCheckInWaiterCounts(
    expectedUserID: Int64,
    forumID: Int64
  ) -> (shared: Int, conflict: Int) {
    let resourceKey = TiebaForumCheckInResourceKey(
      userID: expectedUserID,
      forumID: forumID
    )
    let shared: Int
    if let flightID = forumCheckInFlights[resourceKey]?.id {
      shared = forumCheckInSharedWaiterCounts[flightID] ?? 0
    } else {
      shared = 0
    }
    return (
      shared: shared,
      conflict: forumCheckInConflictWaiters[resourceKey]?.count ?? 0
    )
  }

  func officialBatchCheckInFlightExists(expectedUserID: Int64) -> Bool {
    officialBatchCheckInFlights[expectedUserID] != nil
  }

  func officialBatchCheckInWaiterCount(expectedUserID: Int64) -> Int {
    officialBatchCheckInWaiters[expectedUserID]?.count ?? 0
  }

  func officialBatchCheckInFlightStageName(expectedUserID: Int64) -> String? {
    officialBatchCheckInFlights[expectedUserID].map { String(describing: $0.stage) }
  }

  private func canonicalOfficialBatchCheckInTargets(
    _ targets: [TiebaOfficialBatchCheckInTarget]
  ) throws -> [TiebaOfficialBatchCheckInTarget] {
    guard targets.count <= TiebaOfficialCheckInDecoder.maximumForumCount else {
      throw TiebaClientError.invalidArgument("Too many batch check-in authorization targets.")
    }
    var seen = Set<Int64>()
    return try targets.map { target in
      guard target.forumID > 0, seen.insert(target.forumID).inserted else {
        throw TiebaClientError.invalidArgument(
          "Batch check-in authorization targets must have distinct positive forum IDs."
        )
      }
      return TiebaOfficialBatchCheckInTarget(
        forumID: target.forumID,
        canonicalForumName: try TiebaOfficialCheckInDecoder.canonicalForumName(
          target.canonicalForumName
        )
      )
    }
  }

  private func waitForOfficialBatchCheckInFlight(
    expectedUserID: Int64,
    flightID: UUID,
    task: Task<TiebaOfficialBatchCheckInResult, Swift.Error>
  ) async throws -> TiebaOfficialBatchCheckInResult {
    try await waitForOfficialBatchCheckInFlightCompletion(
      expectedUserID: expectedUserID,
      flightID: flightID
    )
    return try await task.value
  }

  private func waitForOfficialBatchCheckInFlightCompletion(
    expectedUserID: Int64,
    flightID: UUID,
    keepsWriteAlive: Bool = true
  ) async throws {
    if Task.isCancelled,
      let flight = officialBatchCheckInFlights[expectedUserID],
      flight.id == flightID,
      flight.stage == .queued || flight.stage == .preflight,
      !keepsWriteAlive
        || officialBatchCheckInSharedWaiterIDs[expectedUserID]?.isEmpty != false
    {
      cancelUnregisteredOfficialBatchCheckInWaiter(
        expectedUserID: expectedUserID,
        flightID: flightID,
        keepsWriteAlive: keepsWriteAlive
      )
      throw CancellationError()
    }
    guard officialBatchCheckInFlights[expectedUserID]?.isCompleted == false else { return }
    let waiterID = UUID()
    let outcome: TiebaOfficialBatchCheckInWaitOutcome = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<TiebaOfficialBatchCheckInWaitOutcome, Never>) in
        guard let flight = officialBatchCheckInFlights[expectedUserID], flight.id == flightID,
          !flight.isCompleted
        else {
          continuation.resume(returning: .completed)
          return
        }
        if Task.isCancelled,
          flight.stage == .queued || flight.stage == .preflight
        {
          if keepsWriteAlive {
            cancelUnregisteredOfficialBatchCheckInWaiter(
              expectedUserID: expectedUserID,
              flightID: flightID,
              keepsWriteAlive: keepsWriteAlive
            )
          }
          continuation.resume(returning: .cancelled)
          return
        }
        officialBatchCheckInWaiters[expectedUserID, default: [:]][waiterID] = continuation
        if keepsWriteAlive {
          officialBatchCheckInSharedWaiterIDs[expectedUserID, default: []].insert(waiterID)
        }
      }
    } onCancel: {
      Task {
        await self.cancelOfficialBatchCheckInWaiter(
          expectedUserID: expectedUserID,
          flightID: flightID,
          waiterID: waiterID,
          keepsWriteAlive: keepsWriteAlive
        )
      }
    }
    guard outcome == .completed else { throw CancellationError() }
  }

  private func cancelOfficialBatchCheckInWaiter(
    expectedUserID: Int64,
    flightID: UUID,
    waiterID: UUID,
    keepsWriteAlive: Bool
  ) {
    guard let flight = officialBatchCheckInFlights[expectedUserID], flight.id == flightID else {
      return
    }
    if flight.stage == .writeDispatched || flight.stage == .completed {
      return
    }
    guard var waiters = officialBatchCheckInWaiters[expectedUserID] else {
      cancelUnregisteredOfficialBatchCheckInWaiter(
        expectedUserID: expectedUserID,
        flightID: flightID,
        keepsWriteAlive: keepsWriteAlive
      )
      return
    }
    let continuation = waiters.removeValue(forKey: waiterID)
    if var sharedWaiterIDs = officialBatchCheckInSharedWaiterIDs[expectedUserID] {
      sharedWaiterIDs.remove(waiterID)
      if sharedWaiterIDs.isEmpty {
        officialBatchCheckInSharedWaiterIDs.removeValue(forKey: expectedUserID)
      } else {
        officialBatchCheckInSharedWaiterIDs[expectedUserID] = sharedWaiterIDs
      }
    }
    if waiters.isEmpty {
      officialBatchCheckInWaiters.removeValue(forKey: expectedUserID)
    } else {
      officialBatchCheckInWaiters[expectedUserID] = waiters
    }
    cancelOfficialBatchCheckInOwnerIfUnobservedBeforeDispatch(
      expectedUserID: expectedUserID,
      flightID: flightID,
      keepsWriteAlive: keepsWriteAlive
    )
    continuation?.resume(returning: .cancelled)
  }

  private func cancelUnregisteredOfficialBatchCheckInWaiter(
    expectedUserID: Int64,
    flightID: UUID,
    keepsWriteAlive: Bool
  ) {
    cancelOfficialBatchCheckInOwnerIfUnobservedBeforeDispatch(
      expectedUserID: expectedUserID,
      flightID: flightID,
      keepsWriteAlive: keepsWriteAlive
    )
  }

  private func cancelOfficialBatchCheckInOwnerIfUnobservedBeforeDispatch(
    expectedUserID: Int64,
    flightID: UUID,
    keepsWriteAlive: Bool
  ) {
    guard
      keepsWriteAlive,
      officialBatchCheckInSharedWaiterIDs[expectedUserID]?.isEmpty != false,
      let flight = officialBatchCheckInFlights[expectedUserID],
      flight.id == flightID,
      flight.stage == .queued || flight.stage == .preflight
    else { return }
    flight.task.cancel()
  }

  private func finishOfficialBatchCheckInFlight(
    expectedUserID: Int64,
    flightID: UUID,
    task: Task<TiebaOfficialBatchCheckInResult, Swift.Error>
  ) async {
    let result = await task.result
    guard
      var flight = officialBatchCheckInFlights[expectedUserID],
      flight.id == flightID
    else { return }
    flight.stage = .completed
    _ = result
    officialBatchCheckInFlights.removeValue(forKey: expectedUserID)
    let waiters = officialBatchCheckInWaiters.removeValue(forKey: expectedUserID) ?? [:]
    officialBatchCheckInSharedWaiterIDs.removeValue(forKey: expectedUserID)
    for continuation in waiters.values {
      continuation.resume(returning: .completed)
    }
  }

  private func beginOfficialBatchCheckInPreflight(
    expectedUserID: Int64,
    flightID: UUID
  ) throws {
    try Task.checkCancellation()
    guard
      var flight = officialBatchCheckInFlights[expectedUserID],
      flight.id == flightID,
      flight.stage == .queued
    else { throw CancellationError() }
    flight.stage = .preflight
    officialBatchCheckInFlights[expectedUserID] = flight
  }

  private func beginOfficialBatchCheckInWrite(
    expectedUserID: Int64,
    flightID: UUID
  ) throws {
    try Task.checkCancellation()
    guard
      var flight = officialBatchCheckInFlights[expectedUserID],
      flight.id == flightID,
      flight.stage == .preflight
    else { throw CancellationError() }
    flight.stage = .writeDispatched
    officialBatchCheckInFlights[expectedUserID] = flight
  }

  private func registerSharedForumCheckInWaiter(flightID: UUID) {
    forumCheckInSharedWaiterCounts[flightID, default: 0] += 1
  }

  private func unregisterSharedForumCheckInWaiter(flightID: UUID) {
    guard let count = forumCheckInSharedWaiterCounts[flightID] else { return }
    if count <= 1 {
      forumCheckInSharedWaiterCounts.removeValue(forKey: flightID)
    } else {
      forumCheckInSharedWaiterCounts[flightID] = count - 1
    }
  }

  private func cancelForumCheckInWaiter(
    resourceKey: TiebaForumCheckInResourceKey,
    waiterID: UUID
  ) {
    guard var waiters = forumCheckInConflictWaiters[resourceKey] else { return }
    let continuation = waiters.removeValue(forKey: waiterID)
    if waiters.isEmpty {
      forumCheckInConflictWaiters.removeValue(forKey: resourceKey)
    } else {
      forumCheckInConflictWaiters[resourceKey] = waiters
    }
    continuation?.resume()
  }

  private func clearForumCheckInFlight(
    resourceKey: TiebaForumCheckInResourceKey,
    flightID: UUID
  ) {
    guard forumCheckInFlights[resourceKey]?.id == flightID else { return }
    forumCheckInFlights.removeValue(forKey: resourceKey)
    let waiters = forumCheckInConflictWaiters.removeValue(forKey: resourceKey) ?? [:]
    for continuation in waiters.values {
      continuation.resume()
    }
  }

  private func send(_ request: URLRequest, maximumBodyBytes: Int) async throws -> Data {
    let response: TiebaHTTPResponse
    do {
      response = try await transport.send(
        request,
        maximumBodyBytes: maximumBodyBytes
      )
    } catch let error as TiebaClientError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch let error as URLError {
      throw TiebaClientError.network(code: error.errorCode)
    } catch {
      throw TiebaClientError.transportFailure
    }

    guard (200..<300).contains(response.statusCode) else {
      throw TiebaClientError.httpStatus(response.statusCode)
    }
    guard response.body.count <= maximumBodyBytes else {
      throw TiebaClientError.responseTooLarge(maximumBytes: maximumBodyBytes)
    }
    return response.body
  }
}
