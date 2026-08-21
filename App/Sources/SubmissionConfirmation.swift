import Foundation
import TiebaCore

struct SubmissionConfirmationCopy: Equatable, Sendable {
  let title: String
  let actionTitle: String
  let message: String

  static let reply = Self(
    title: "发送这条回复？",
    actionTitle: "发送",
    message: "回复会立即提交到贴吧。网络中断时结果可能无法确定；为避免重复回复，应用不会自动重发。"
  )

  static let newThread = Self(
    title: "发布这个主题？",
    actionTitle: "发布",
    message: "主题会立即提交到贴吧。网络中断时结果可能无法确定；为避免重复发帖，应用不会自动重发。"
  )
}

struct ComposerEntryRiskNoticeCopy: Equatable, Sendable {
  static let standard = Self()

  let title = "建议使用官方途径发布"
  let message = "使用本应用发帖或回复可能遇到提交失败、需要验证码或账号限制，严重时可能导致账号封禁。"
    + "建议通过贴吧官方途径发布。"
  let continueTitle = "继续编辑"
  let leaveTitle = "返回"
}

struct ComposerEntryRiskNoticeGate: Equatable, Sendable {
  enum State: Equatable, Sendable {
    case awaitingReadiness
    case presenting
    case implicitDismissalPending
    case resolved
  }

  private(set) var state: State = .awaitingReadiness

  var isPresented: Bool { state == .presenting }
  var implicitDismissalIsPending: Bool { state == .implicitDismissalPending }
  var isResolved: Bool { state == .resolved }

  @discardableResult
  mutating func composerBecameReady(showsNotice: Bool) -> Bool {
    guard state == .awaitingReadiness else { return false }
    state = showsNotice ? .presenting : .resolved
    return state == .presenting
  }

  mutating func resolve() {
    state = .resolved
  }

  mutating func beginImplicitDismissal() {
    guard state == .presenting else { return }
    state = .implicitDismissalPending
  }
}

struct SubmissionConfirmationPreparationGate: Equatable, Sendable {
  private(set) var id: UUID?
  private(set) var lifecycleID: UUID?

  var isPreparing: Bool { id != nil }

  mutating func begin(lifecycleID: UUID, id: UUID = UUID()) -> UUID? {
    guard self.id == nil else { return nil }
    self.id = id
    self.lifecycleID = lifecycleID
    return id
  }

  func isCurrent(_ candidate: UUID, lifecycleID: UUID) -> Bool {
    id == candidate && self.lifecycleID == lifecycleID
  }

  @discardableResult
  mutating func finish(_ candidate: UUID) -> Bool {
    guard id == candidate else { return false }
    id = nil
    lifecycleID = nil
    return true
  }

  mutating func cancel() {
    id = nil
    lifecycleID = nil
  }
}

enum SubmissionConfirmationPolicy {
  static func present<Snapshot>(
    _ snapshot: Snapshot,
    pending: inout Snapshot?
  ) -> Bool {
    guard pending == nil else { return false }
    pending = snapshot
    return true
  }

  static func consume<Snapshot: Equatable>(
    _ expected: Snapshot,
    pending: inout Snapshot?
  ) -> Snapshot? {
    guard pending == expected else { return nil }
    pending = nil
    return expected
  }

  static func textReplySnapshot(
    id: UUID = UUID(),
    target: TextReplyTarget,
    content: String,
    attachments: [ComposerImageAttachment] = [],
    imageWatermark: TiebaStaticImageWatermark = .forumName,
    submissionAllowed: Bool
  ) -> TextReplySubmission? {
    guard submissionAllowed else { return nil }
    return TextReplySubmission(
      id: id,
      target: target,
      content: content,
      attachments: attachments,
      imageWatermark: imageWatermark
    )
  }

  static func textReplySnapshotIsCurrent(
    _ snapshot: TextReplySubmission,
    target: TextReplyTarget,
    content: String,
    attachments: [ComposerImageAttachment] = [],
    imageWatermark: TiebaStaticImageWatermark = .forumName,
    submissionAllowed: Bool
  ) -> Bool {
    guard submissionAllowed else { return false }
    return TextReplySubmission(
      id: snapshot.id,
      target: target,
      content: content,
      attachments: attachments,
      imageWatermark: imageWatermark
    ) == snapshot
  }

  static func newThreadSnapshot(
    id: UUID = UUID(),
    target: NewThreadTarget,
    title: String?,
    content: String,
    attachments: [ComposerImageAttachment] = [],
    imageWatermark: TiebaStaticImageWatermark = .forumName,
    submissionAllowed: Bool
  ) -> NewThreadSubmission? {
    guard submissionAllowed else { return nil }
    return NewThreadSubmission(
      id: id,
      target: target,
      title: title,
      content: content,
      attachments: attachments,
      imageWatermark: imageWatermark
    )
  }

  static func newThreadSnapshotIsCurrent(
    _ snapshot: NewThreadSubmission,
    target: NewThreadTarget,
    title: String?,
    content: String,
    attachments: [ComposerImageAttachment] = [],
    imageWatermark: TiebaStaticImageWatermark = .forumName,
    submissionAllowed: Bool
  ) -> Bool {
    guard submissionAllowed else { return false }
    return NewThreadSubmission(
      id: snapshot.id,
      target: target,
      title: title,
      content: content,
      attachments: attachments,
      imageWatermark: imageWatermark
    ) == snapshot
  }
}
