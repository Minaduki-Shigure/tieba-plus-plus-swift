import Foundation
import TiebaCore

struct PersonalizedFeedbackSubmission: Hashable, Sendable {
  static let maximumReasonCount = 16

  let threadID: Int64
  let forumID: Int64
  let reasons: [PersonalizedFeedbackReason]
  let clickTimeMilliseconds: Int64

  init?(
    item: PersonalizedFeedItem,
    selectedReasonIDs: Set<UInt32>,
    clickTimeMilliseconds: Int64
  ) {
    guard
      item.thread.id > 0,
      item.thread.forumID > 0,
      clickTimeMilliseconds > 0,
      !selectedReasonIDs.isEmpty,
      selectedReasonIDs.count <= Self.maximumReasonCount
    else { return nil }

    var seen = Set<UInt32>()
    let reasons = item.feedbackReasons.filter { reason in
      reason.id > 0
        && selectedReasonIDs.contains(reason.id)
        && seen.insert(reason.id).inserted
    }
    guard reasons.count == selectedReasonIDs.count else { return nil }

    self.threadID = item.thread.id
    self.forumID = item.thread.forumID
    self.reasons = reasons
    self.clickTimeMilliseconds = clickTimeMilliseconds
  }
}

enum PersonalizedFeedbackSubmissionError: LocalizedError, Equatable, Sendable {
  case fullCredentialsRequired
  case outcomeUnknown
  case unavailable(String)

  var errorDescription: String? {
    switch self {
    case .fullCredentialsRequired:
      "此账户需要重新登录，才能安全提交推荐反馈。"
    case .outcomeUnknown:
      "推荐反馈可能已经提交，本次列表已隐藏该帖子，应用不会自动重试。"
    case .unavailable(let message):
      message
    }
  }
}

enum PersonalizedFeedbackFailure: Equatable, Sendable {
  case loginRequired
  case invalidSelection
  case fullCredentialsRequired
  case outcomeUnknown
  case unavailable(String)

  var title: String {
    switch self {
    case .loginRequired, .fullCredentialsRequired:
      "需要登录"
    case .invalidSelection:
      "无法提交反馈"
    case .outcomeUnknown:
      "反馈结果待确认"
    case .unavailable:
      "反馈提交失败"
    }
  }

  var message: String {
    switch self {
    case .loginRequired:
      "请先登录账户，再重新选择不感兴趣的原因。"
    case .invalidSelection:
      "推荐帖子或所选原因已经变化，请重新选择。"
    case .fullCredentialsRequired:
      PersonalizedFeedbackSubmissionError.fullCredentialsRequired.localizedDescription
    case .outcomeUnknown:
      PersonalizedFeedbackSubmissionError.outcomeUnknown.localizedDescription
    case .unavailable(let message):
      message
    }
  }

  var offersLogin: Bool {
    switch self {
    case .loginRequired, .fullCredentialsRequired:
      true
    case .invalidSelection, .outcomeUnknown, .unavailable:
      false
    }
  }
}

struct PersonalizedFeedbackSessionLease: Equatable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }

  func matches(_ session: StoredAccountSession?) -> Bool {
    guard let session else { return false }
    return userID == session.id && sessionRevision == session.sessionRevision
  }
}

protocol PersonalizedFeedbackService: Sendable {
  func submitPersonalizedFeedback(
    session: StoredAccountSession,
    submission: PersonalizedFeedbackSubmission
  ) async throws
}

protocol TiebaPersonalizedFeedbackClient: Sendable {
  func submitPersonalizedFeedback(
    credential: TiebaSessionCredential,
    expectedUserID: Int64,
    submission: TiebaPersonalizedFeedbackSubmission
  ) async throws
}

extension TiebaAuthenticatedClient: TiebaPersonalizedFeedbackClient {}

struct TiebaCorePersonalizedFeedbackService: PersonalizedFeedbackService {
  private let client: any TiebaPersonalizedFeedbackClient

  init(client: any TiebaPersonalizedFeedbackClient) {
    self.client = client
  }

  func submitPersonalizedFeedback(
    session: StoredAccountSession,
    submission: PersonalizedFeedbackSubmission
  ) async throws {
    guard session.id > 0, let credentials = session.credentials else {
      throw PersonalizedFeedbackSubmissionError.fullCredentialsRequired
    }
    let cookieName: TiebaBDUSSCookieName
    switch credentials.bdussCookieName {
    case .bduss:
      cookieName = .bduss
    case .bdussBFESS:
      cookieName = .bdussBFESS
    }
    let coreSubmission = TiebaPersonalizedFeedbackSubmission(
      threadID: submission.threadID,
      forumID: submission.forumID,
      reasonIDs: submission.reasons.map(\.id),
      reasonExtras: submission.reasons.map(\.extra),
      clickTimeMilliseconds: submission.clickTimeMilliseconds
    )
    do {
      try await client.submitPersonalizedFeedback(
        credential: TiebaSessionCredential(
          bduss: credentials.bduss,
          stoken: credentials.stoken,
          bdussCookieName: cookieName
        ),
        expectedUserID: session.id,
        submission: coreSubmission
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as TiebaClientError where error == .personalizedFeedbackOutcomeUnknown {
      throw PersonalizedFeedbackSubmissionError.outcomeUnknown
    } catch let error as TiebaClientError where error == .personalizedFeedbackWriteConflict {
      throw PersonalizedFeedbackSubmissionError.unavailable(
        "该帖已有另一项推荐反馈正在提交，请等待其结束。"
      )
    } catch {
      let mapped = TiebaCoreAccountService.accountError(error)
      throw PersonalizedFeedbackSubmissionError.unavailable(
        mapped.errorDescription ?? "推荐反馈提交失败，请稍后重试。"
      )
    }
  }
}
