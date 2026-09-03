import Combine
import Foundation

enum AccountProfileEditState: Equatable {
  case idle
  case loading
  case ready
  case saving
  case failed
}

enum AccountProfileAvatarState: Equatable {
  case idle
  case uploading
  case confirmed
  case acceptedPendingReview(String)
}

struct AccountProfileEditDraft:
  Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
  var displayName = ""
  var biography = ""
  var sex: AccountProfileSex = .unspecified

  var description: String { "AccountProfileEditDraft(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "displayNameUTF8ByteCount": displayName.utf8.count,
        "biographyUTF8ByteCount": biography.utf8.count,
      ],
      displayStyle: .struct
    )
  }
}

enum AccountProfileEditCompletionPolicy {
  static func dismissesEditor(after summary: AccountProfileSummary) -> Bool {
    !summary.isNicknameEditing
  }
}

@MainActor
final class AccountProfileEditViewModel: ObservableObject {
  @Published private(set) var state: AccountProfileEditState = .idle
  @Published private(set) var summary: AccountProfileSummary?
  @Published private(set) var draft = AccountProfileEditDraft()
  @Published private(set) var avatarState: AccountProfileAvatarState = .idle
  @Published private(set) var errorMessage: String?
  @Published private(set) var showsDiscardConfirmation = false

  let expectedUserID: Int64

  private let service: any AccountService
  private let vault: any AccountVault
  private var lease: AccountProfileEditSessionLease?
  private var generation = 0

  init(
    expectedUserID: Int64,
    service: any AccountService,
    vault: any AccountVault
  ) {
    self.expectedUserID = expectedUserID
    self.service = service
    self.vault = vault
  }

  var isSaving: Bool { state == .saving }

  var isUploadingAvatar: Bool { avatarState == .uploading }

  var requiresNavigationInterception: Bool {
    isSaving || isUploadingAvatar || hasUnsavedChanges
  }

  var isEditingEnabled: Bool {
    state == .ready
      && !isUploadingAvatar
      && lease != nil
      && summary?.birthday != nil
      && summary?.isNicknameEditing == false
  }

  var hasUnsavedChanges: Bool {
    guard let baseline = summary.map(Self.draft(for:)) else { return false }
    return draft != baseline
  }

  var biographyNonWhitespaceCharacterCount: Int {
    AccountProfileEditPolicy.nonWhitespaceCharacterCount(in: draft.biography)
  }

  var validationMessage: String? {
    guard let summary else { return nil }
    if summary.isNicknameEditing {
      let pendingName = summary.editingNickname
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return pendingName.isEmpty
        ? "昵称正在审核，暂时不能再次修改个人资料。"
        : "昵称“\(pendingName)”正在审核，暂时不能再次修改个人资料。"
    }
    guard summary.birthday != nil else {
      return "贴吧未返回可安全保留的生日信息，暂时不能修改个人资料。"
    }
    do {
      _ = try validatedDraft()
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  var canSave: Bool {
    guard isEditingEnabled, !isUploadingAvatar, hasUnsavedChanges else { return false }
    guard
      let baseline = summary.map(Self.draft(for:)),
      let requested = try? validatedDraft()
    else { return false }
    return requested.displayName != baseline.displayName
      || requested.biography != baseline.biography
      || requested.sex != baseline.sex
  }

  var canUploadAvatar: Bool {
    state == .ready
      && !isSaving
      && !isUploadingAvatar
      && lease != nil
      && summary?.canModifyAvatar == true
  }

  var avatarStatusMessage: String? {
    switch avatarState {
    case .idle:
      guard summary?.canModifyAvatar == false else { return nil }
      let reason = summary?.avatarModificationDescription
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return reason.isEmpty ? "当前账户暂不能修改头像。" : reason
    case .uploading:
      return "正在上传头像，请保持此页面打开。"
    case .confirmed:
      return "贴吧已确认头像更新。"
    case .acceptedPendingReview(let message):
      return message.isEmpty
        ? "贴吧已受理头像，可能需要审核或等待缓存刷新。"
        : message
    }
  }

  func setDisplayName(_ value: String) {
    guard isEditingEnabled else { return }
    draft.displayName = value
  }

  func setBiography(_ value: String) {
    guard isEditingEnabled else { return }
    draft.biography = value
  }

  func setSex(_ value: AccountProfileSex) {
    guard isEditingEnabled, AccountProfileSex.userSelectableCases.contains(value) else {
      return
    }
    draft.sex = value
  }

  func loadIfNeeded() async {
    guard state == .idle else { return }
    await reload()
  }

  func reload() async {
    guard state != .saving else { return }
    generation &+= 1
    let requestGeneration = generation
    clearSnapshot()
    state = .loading

    do {
      guard let sessionBeforeRequest = try await vault.activeSession() else {
        guard requestGeneration == generation else { return }
        state = .failed
        errorMessage = "当前没有已登录的贴吧账户。"
        return
      }
      guard requestGeneration == generation else { return }
      let requestLease = AccountProfileEditSessionLease(sessionBeforeRequest)
      guard
        sessionBeforeRequest.id == expectedUserID,
        sessionBeforeRequest.credentials != nil
      else {
        state = .failed
        errorMessage = "账户状态已变化，请返回后重新打开个人资料编辑。"
        return
      }
      try Task.checkCancellation()

      let outcome: AccountProfileEditRequestOutcome
      do {
        outcome = .success(try await service.selfProfile(session: sessionBeforeRequest))
      } catch {
        outcome = .failure(error.localizedDescription)
      }
      try Task.checkCancellation()

      let sessionAfterRequest = try await vault.activeSession()
      try Task.checkCancellation()
      guard requestGeneration == generation else { return }
      guard let sessionAfterRequest, requestLease.matches(sessionAfterRequest) else {
        discardForChangedSession()
        return
      }

      switch outcome {
      case .success(let response):
        try Self.validateLoadedSummary(response, expectedUserID: expectedUserID)
        lease = requestLease
        summary = response
        draft = Self.draft(for: response)
        state = .ready
      case .failure(let message):
        state = .failed
        errorMessage = message
      }
    } catch is CancellationError {
      guard requestGeneration == generation else { return }
      clearSnapshot()
      state = .idle
    } catch {
      guard requestGeneration == generation, !Task.isCancelled else { return }
      clearSnapshot()
      state = .failed
      errorMessage = error.localizedDescription
    }
  }

  func save() async -> AccountProfileSummary? {
    guard
      state == .ready,
      let baseline = summary,
      let operationLease = lease,
      canSave,
      let requested = try? validatedDraft()
    else { return nil }

    generation &+= 1
    let requestGeneration = generation
    state = .saving
    errorMessage = nil

    let session: StoredAccountSession
    do {
      guard let activeSession = try await vault.activeSession() else {
        discardForChangedSession()
        return nil
      }
      guard requestGeneration == generation else { return nil }
      guard operationLease.matches(activeSession), activeSession.credentials != nil else {
        discardForChangedSession()
        return nil
      }
      try Task.checkCancellation()
      session = activeSession
    } catch is CancellationError {
      guard requestGeneration == generation else { return nil }
      state = .ready
      errorMessage = "保存尚未开始；请明确再次点按保存。"
      return nil
    } catch {
      guard requestGeneration == generation else { return nil }
      state = .ready
      errorMessage = "无法读取当前账户，保存尚未开始；请明确再次点按保存。"
      return nil
    }

    let outcome: AccountProfileEditRequestOutcome
    do {
      outcome = .success(
        try await service.updateSelfProfile(session: session, edit: requested)
      )
    } catch {
      outcome = .failure(error.localizedDescription)
    }

    let sessionAfterRequest: StoredAccountSession?
    do {
      sessionAfterRequest = try await vault.activeSession()
    } catch {
      guard requestGeneration == generation else { return nil }
      state = .ready
      errorMessage = "无法确认个人资料是否已保存；请检查资料后再明确保存。"
      return nil
    }
    guard requestGeneration == generation else { return nil }
    guard let sessionAfterRequest, operationLease.matches(sessionAfterRequest) else {
      discardForChangedSession()
      return nil
    }

    switch outcome {
    case .success(let response):
      do {
        try Self.validateSavedSummary(
          response,
          expectedUserID: expectedUserID,
          requested: requested,
          baseline: baseline
        )
        lease = operationLease
        summary = response
        draft = Self.draft(for: response)
        state = .ready
        return response
      } catch {
        state = .ready
        errorMessage = error.localizedDescription
        return nil
      }
    case .failure(let message):
      state = .ready
      errorMessage = message
      return nil
    }
  }

  func uploadAvatar(_ upload: AccountProfileAvatarUpload) async
    -> AccountProfileAvatarUploadResult?
  {
    guard
      state == .ready,
      canUploadAvatar,
      let baseline = summary,
      let operationLease = lease
    else { return nil }

    generation &+= 1
    let requestGeneration = generation
    avatarState = .uploading
    errorMessage = nil
    let draftWasModified = draft != Self.draft(for: baseline)

    let session: StoredAccountSession
    do {
      guard let activeSession = try await vault.activeSession() else {
        discardForChangedSession()
        return nil
      }
      guard requestGeneration == generation else { return nil }
      guard operationLease.matches(activeSession), activeSession.credentials != nil else {
        discardForChangedSession()
        return nil
      }
      try Task.checkCancellation()
      session = activeSession
    } catch is CancellationError {
      guard requestGeneration == generation else { return nil }
      avatarState = .idle
      errorMessage = "头像上传尚未开始；请明确重新选择并上传。"
      return nil
    } catch {
      guard requestGeneration == generation else { return nil }
      avatarState = .idle
      errorMessage = "无法读取当前账户，头像上传尚未开始。"
      return nil
    }

    let outcome: AccountProfileAvatarRequestOutcome
    do {
      outcome = .success(
        try await service.uploadSelfProfileAvatar(session: session, upload: upload)
      )
    } catch {
      outcome = .failure(error.localizedDescription)
    }

    let sessionAfterRequest: StoredAccountSession?
    do {
      sessionAfterRequest = try await vault.activeSession()
    } catch {
      guard requestGeneration == generation else { return nil }
      avatarState = .idle
      errorMessage =
        "无法确认头像上传属于当前账户；请重新读取本人资料，应用不会自动重发请求。"
      return nil
    }
    guard requestGeneration == generation else { return nil }
    guard let sessionAfterRequest, operationLease.matches(sessionAfterRequest) else {
      discardForChangedSession()
      return nil
    }

    switch outcome {
    case .success(let result):
      guard result.profile.userID == expectedUserID else {
        avatarState = .idle
        errorMessage = "贴吧返回了不匹配的本人资料，请重新加载后再试。"
        return nil
      }
      lease = operationLease
      summary = result.profile
      if !draftWasModified {
        draft = Self.draft(for: result.profile)
      }
      switch result.disposition {
      case .confirmed:
        avatarState = .confirmed
      case .acceptedPendingReview(let message):
        avatarState = .acceptedPendingReview(message)
      }
      return result
    case .failure(let message):
      avatarState = .idle
      errorMessage = message
      return nil
    }
  }

  func requestClose() -> Bool {
    guard !isSaving, !isUploadingAvatar else { return false }
    guard hasUnsavedChanges else { return true }
    showsDiscardConfirmation = true
    return false
  }

  func cancelDiscard() {
    showsDiscardConfirmation = false
  }

  func confirmDiscard() -> Bool {
    guard !isSaving, !isUploadingAvatar else { return false }
    showsDiscardConfirmation = false
    if let summary { draft = Self.draft(for: summary) }
    return true
  }

  func dismissError() {
    errorMessage = nil
  }

  func invalidateForAccountSessionChange() {
    generation &+= 1
    clearSnapshot()
    state = .idle
  }

  func presentationBecameInactive() {
    // Switching tabs also triggers onDisappear. Keep the draft and any in-flight
    // request alive, but do not restore a stale confirmation dialog on return.
    showsDiscardConfirmation = false
  }

  private func validatedDraft() throws -> AccountProfileEditSubmission {
    try AccountProfileEditPolicy.validatedSubmission(
      displayName: draft.displayName,
      biography: draft.biography,
      sex: draft.sex
    )
  }

  private func discardForChangedSession() {
    generation &+= 1
    clearSnapshot()
    state = .idle
  }

  private func clearSnapshot() {
    lease = nil
    summary = nil
    draft = AccountProfileEditDraft()
    avatarState = .idle
    errorMessage = nil
    showsDiscardConfirmation = false
  }

  private static func draft(for summary: AccountProfileSummary) -> AccountProfileEditDraft {
    let pendingNickname = summary.editingNickname
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return AccountProfileEditDraft(
      displayName: summary.isNicknameEditing && !pendingNickname.isEmpty
        ? pendingNickname
        : summary.displayName,
      biography: summary.editableBiography,
      sex: summary.sex
    )
  }

  private static func validateLoadedSummary(
    _ summary: AccountProfileSummary,
    expectedUserID: Int64
  ) throws {
    guard summary.userID == expectedUserID else {
      throw BrowseError.unavailable("贴吧返回了不匹配的本人资料，请返回后重试。")
    }
  }

  private static func validateSavedSummary(
    _ summary: AccountProfileSummary,
    expectedUserID: Int64,
    requested: AccountProfileEditSubmission,
    baseline: AccountProfileSummary
  ) throws {
    try validateLoadedSummary(summary, expectedUserID: expectedUserID)
    guard
      summary.birthday == baseline.birthday,
      summary.editableBiography == requested.biography,
      summary.sex == requested.sex
    else {
      throw BrowseError.unavailable("贴吧没有确认完整的个人资料修改，请检查后再试。")
    }

    let confirmedNickname: String
    if summary.isNicknameEditing {
      confirmedNickname = summary.editingNickname
    } else {
      confirmedNickname = summary.displayName
    }
    let normalizedNickname = try AccountProfileEditPolicy.validatedSubmission(
      displayName: confirmedNickname,
      biography: requested.biography,
      sex: requested.sex
    ).displayName
    guard normalizedNickname == requested.displayName else {
      throw BrowseError.unavailable("贴吧没有确认昵称修改，请检查后再试。")
    }
  }
}

private struct AccountProfileEditSessionLease: Equatable, Sendable {
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

private enum AccountProfileEditRequestOutcome: Sendable {
  case success(AccountProfileSummary)
  case failure(String)
}

private enum AccountProfileAvatarRequestOutcome: Sendable {
  case success(AccountProfileAvatarUploadResult)
  case failure(String)
}
