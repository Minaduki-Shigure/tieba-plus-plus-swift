import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class AccountProfileEditViewModelTests: XCTestCase {
  func testLoadBindsEditableFieldsToValidatedSessionLease() async {
    let active = session(userID: 7, revision: uuid(1))
    let loaded = profile(
      userID: 7,
      displayName: "公开昵称",
      biography: "公开简介",
      editableBiography: "可编辑简介",
      sex: .female
    )
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(readScripts: [.value(loaded)])
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )

    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.state, .ready)
    XCTAssertEqual(viewModel.summary, loaded)
    XCTAssertEqual(
      viewModel.draft,
      AccountProfileEditDraft(
        displayName: "公开昵称",
        biography: "可编辑简介",
        sex: .female
      )
    )
    XCTAssertTrue(viewModel.isEditingEnabled)
    XCTAssertFalse(viewModel.hasUnsavedChanges)
    XCTAssertFalse(viewModel.requiresNavigationInterception)
    XCTAssertFalse(viewModel.canSave)
    let requests = await service.readRequestsSnapshot()
    XCTAssertEqual(requests, [AccountProfileEditRequest(userID: 7, revision: uuid(1))])
    let activeReads = await vault.activeSessionReadCount()
    XCTAssertEqual(activeReads, 2)
  }

  func testValidationNormalizesLineEndingsAndEnforcesEveryBoundary() throws {
    XCTAssertEqual(AccountProfileSex.userSelectableCases, [.male, .female])
    XCTAssertFalse(AccountProfileSex.userSelectableCases.contains(.unspecified))

    let normalized = try AccountProfileEditPolicy.validatedSubmission(
      displayName: "  昵称  ",
      biography: "  第一行\r\n第二行  ",
      sex: .unspecified
    )
    XCTAssertEqual(normalized.displayName, "昵称")
    XCTAssertEqual(normalized.biography, "第一行\n第二行")
    XCTAssertEqual(normalized.description, "AccountProfileEditSubmission(redacted)")
    XCTAssertFalse(normalized.debugDescription.contains("昵称"))
    XCTAssertFalse(normalized.debugDescription.contains("第一行"))
    XCTAssertEqual(
      AccountProfileEditPolicy.nonWhitespaceCharacterCount(in: " 一 \n 二 "),
      2
    )

    XCTAssertThrowsError(
      try AccountProfileEditPolicy.validatedSubmission(
        displayName: " \n ", biography: "", sex: .male
      )
    ) { XCTAssertEqual($0 as? AccountProfileEditValidationError, .displayNameRequired) }
    XCTAssertThrowsError(
      try AccountProfileEditPolicy.validatedSubmission(
        displayName: String(repeating: "a", count: 65), biography: "", sex: .male
      )
    ) { XCTAssertEqual($0 as? AccountProfileEditValidationError, .displayNameTooLong) }
    XCTAssertThrowsError(
      try AccountProfileEditPolicy.validatedSubmission(
        displayName: "bad\u{0}", biography: "", sex: .male
      )
    ) {
      XCTAssertEqual(
        $0 as? AccountProfileEditValidationError,
        .displayNameContainsControlCharacters
      )
    }
    XCTAssertThrowsError(
      try AccountProfileEditPolicy.validatedSubmission(
        displayName: "昵称\u{2028}换行", biography: "", sex: .male
      )
    ) {
      XCTAssertEqual(
        $0 as? AccountProfileEditValidationError,
        .displayNameContainsControlCharacters
      )
    }
    XCTAssertThrowsError(
      try AccountProfileEditPolicy.validatedSubmission(
        displayName: "昵称",
        biography: String(repeating: "字 ", count: 501),
        sex: .female
      )
    ) { XCTAssertEqual($0 as? AccountProfileEditValidationError, .biographyTooLong) }
    XCTAssertThrowsError(
      try AccountProfileEditPolicy.validatedSubmission(
        displayName: "昵称",
        biography: "a" + String(repeating: " ", count: 4_096) + "b",
        sex: .female
      )
    ) {
      XCTAssertEqual($0 as? AccountProfileEditValidationError, .biographyPayloadTooLarge)
    }
    XCTAssertThrowsError(
      try AccountProfileEditPolicy.validatedSubmission(
        displayName: "昵称", biography: "不支持\t制表符", sex: .female
      )
    ) {
      XCTAssertEqual(
        $0 as? AccountProfileEditValidationError,
        .biographyContainsControlCharacters
      )
    }
  }

  func testProfileModelsRedactDraftAndServerOnlyFieldsFromDiagnostics() {
    let privateBirthday = AccountProfileBirthday(
      timeMilliseconds: 631_123_200_000,
      showsConstellationOnly: true
    )
    let summary = AccountProfileSummary(
      userID: 7,
      username: "private-username-sentinel",
      displayName: "private-display-name-sentinel",
      portraitURL: URL(string: "https://example.invalid/private-portrait-sentinel"),
      biography: "private-public-biography-sentinel",
      followingCount: 1,
      followerCount: 2,
      postCount: 3,
      editableBiography: "private-editable-biography-sentinel",
      sex: .female,
      birthday: privateBirthday,
      isNicknameEditing: true,
      editingNickname: "private-pending-nickname-sentinel"
    )
    let draft = AccountProfileEditDraft(
      displayName: "private-draft-name-sentinel",
      biography: "private-draft-biography-sentinel",
      sex: .female
    )

    let diagnosticValues = [
      String(describing: summary),
      String(reflecting: summary),
      String(describing: draft),
      String(reflecting: draft),
    ]
    for value in diagnosticValues {
      XCTAssertFalse(value.contains("private-"))
      XCTAssertFalse(value.contains("631123200000"))
    }
    let reflectedValues = Array(summary.customMirror.children)
      + Array(draft.customMirror.children)
    let reflectedLabels = reflectedValues.compactMap(\.label)
    XCTAssertFalse(
      reflectedValues.contains { String(reflecting: $0.value).contains("private-") }
    )
    XCTAssertFalse(
      reflectedValues.contains { String(reflecting: $0.value).contains("631123200000") }
    )
    XCTAssertFalse(reflectedLabels.contains("sex"))
    XCTAssertEqual(String(describing: privateBirthday), "AccountProfileBirthday(redacted)")
    XCTAssertTrue(Array(privateBirthday.customMirror.children).isEmpty)
  }

  func testSaveSubmitsNormalizedDraftAndPublishesConfirmedReadback() async throws {
    let active = session(userID: 7, revision: uuid(2))
    let baseline = profile(userID: 7)
    let confirmed = profile(
      userID: 7,
      displayName: "新昵称",
      biography: "新简介",
      editableBiography: "新简介",
      sex: .female
    )
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(
      readScripts: [.value(baseline)],
      saveScripts: [.value(confirmed)]
    )
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()
    viewModel.setDisplayName("  新昵称  ")
    viewModel.setBiography("  新简介  ")
    viewModel.setSex(.female)

    let result = await viewModel.save()

    XCTAssertEqual(result, confirmed)
    XCTAssertEqual(viewModel.state, .ready)
    XCTAssertEqual(viewModel.summary, confirmed)
    XCTAssertEqual(viewModel.draft.displayName, "新昵称")
    XCTAssertEqual(viewModel.draft.biography, "新简介")
    XCTAssertFalse(viewModel.hasUnsavedChanges)
    let requests = await service.saveRequestsSnapshot()
    XCTAssertEqual(
      requests,
      [
        AccountProfileEditSaveRequest(
          userID: 7,
          revision: uuid(2),
          submission: AccountProfileEditSubmission(
            displayName: "新昵称",
            biography: "新简介",
            sex: .female
          )
        )
      ]
    )
    let activeReads = await vault.activeSessionReadCount()
    XCTAssertEqual(activeReads, 4)
  }

  func testSaveAcceptsNicknameReviewStateAndThenLocksFurtherEditing() async {
    let active = session(userID: 7, revision: uuid(3))
    let baseline = profile(userID: 7)
    let pending = profile(
      userID: 7,
      displayName: "旧昵称",
      biography: "原简介",
      editableBiography: "原简介",
      sex: .male,
      isNicknameEditing: true,
      editingNickname: "待审核昵称"
    )
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(
      readScripts: [.value(baseline)],
      saveScripts: [.value(pending)]
    )
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()
    viewModel.setDisplayName("待审核昵称")

    let result = await viewModel.save()

    XCTAssertEqual(result, pending)
    XCTAssertEqual(viewModel.draft.displayName, "待审核昵称")
    XCTAssertFalse(viewModel.isEditingEnabled)
    XCTAssertFalse(viewModel.canSave)
    XCTAssertTrue(viewModel.validationMessage?.contains("待审核昵称") == true)
    XCTAssertFalse(AccountProfileEditCompletionPolicy.dismissesEditor(after: pending))
    XCTAssertTrue(AccountProfileEditCompletionPolicy.dismissesEditor(after: baseline))
  }

  func testSaveDoesNothingWhenDraftHasNoSemanticChange() async {
    let active = session(userID: 7, revision: uuid(4))
    let baseline = profile(userID: 7)
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(readScripts: [.value(baseline)])
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()

    let result = await viewModel.save()

    XCTAssertNil(result)
    XCTAssertEqual(viewModel.state, .ready)
    let saves = await service.saveRequestsSnapshot()
    XCTAssertTrue(saves.isEmpty)
  }

  func testUnspecifiedSexIsPreservedUntilAUserSelectionAndCannotBeRestoredByPicker() async {
    let active = session(userID: 7, revision: uuid(21))
    let baseline = profile(userID: 7, sex: .unspecified)
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(readScripts: [.value(baseline)])
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()

    XCTAssertEqual(viewModel.draft.sex, .unspecified)
    viewModel.setBiography("只修改简介")
    XCTAssertEqual(viewModel.draft.sex, .unspecified)

    viewModel.setSex(.female)
    XCTAssertEqual(viewModel.draft.sex, .female)
    viewModel.setSex(.unspecified)
    XCTAssertEqual(viewModel.draft.sex, .female)
  }

  func testInvalidLegacyBaselineCanBeRepairedByAValidDraft() async {
    let active = session(userID: 7, revision: uuid(22))
    let legacy = profile(userID: 7, displayName: "")
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(readScripts: [.value(legacy)])
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()

    XCTAssertFalse(viewModel.canSave)
    viewModel.setDisplayName("修正后的昵称")

    XCTAssertNil(viewModel.validationMessage)
    XCTAssertTrue(viewModel.canSave)
  }

  func testAccountSwitchBeforeSaveDiscardsDraftWithoutDispatch() async {
    let original = session(userID: 7, revision: uuid(5))
    let vault = AccountProfileEditVaultSpy(session: original)
    let service = AccountProfileEditServiceSpy(readScripts: [.value(profile(userID: 7))])
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()
    viewModel.setBiography("尚未保存")
    await vault.replaceActive(with: session(userID: 8, revision: uuid(6)))

    let result = await viewModel.save()

    XCTAssertNil(result)
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.summary)
    XCTAssertEqual(viewModel.draft, AccountProfileEditDraft())
    let saves = await service.saveRequestsSnapshot()
    XCTAssertTrue(saves.isEmpty)
  }

  func testSameUIDCredentialRotationBeforeSaveDiscardsDraftWithoutDispatch() async {
    let original = session(userID: 7, revision: uuid(7))
    let vault = AccountProfileEditVaultSpy(session: original)
    let service = AccountProfileEditServiceSpy(readScripts: [.value(profile(userID: 7))])
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()
    viewModel.setSex(.female)
    await vault.replaceActive(with: session(userID: 7, revision: uuid(8)))

    let result = await viewModel.save()

    XCTAssertNil(result)
    XCTAssertEqual(viewModel.state, .idle)
    let saves = await service.saveRequestsSnapshot()
    XCTAssertTrue(saves.isEmpty)
  }

  func testCloseCancellationKeepsDraftAndConfirmedDiscardRestoresBaseline() async {
    let active = session(userID: 7, revision: uuid(9))
    let baseline = profile(userID: 7)
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(readScripts: [.value(baseline)])
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()
    viewModel.setBiography("草稿")

    XCTAssertTrue(viewModel.requiresNavigationInterception)
    XCTAssertFalse(viewModel.requestClose())
    XCTAssertTrue(viewModel.showsDiscardConfirmation)
    viewModel.cancelDiscard()
    XCTAssertFalse(viewModel.showsDiscardConfirmation)
    XCTAssertEqual(viewModel.draft.biography, "草稿")

    XCTAssertFalse(viewModel.requestClose())
    XCTAssertTrue(viewModel.confirmDiscard())
    XCTAssertEqual(viewModel.draft.biography, baseline.editableBiography)
    XCTAssertFalse(viewModel.hasUnsavedChanges)
    XCTAssertFalse(viewModel.requiresNavigationInterception)
    XCTAssertTrue(viewModel.requestClose())
  }

  func testTemporaryNavigationDisappearancePreservesDirtyDraft() async {
    let active = session(userID: 7, revision: uuid(23))
    let baseline = profile(userID: 7)
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(readScripts: [.value(baseline)])
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()
    viewModel.setBiography("切换标签时保留")
    XCTAssertFalse(viewModel.requestClose())

    viewModel.presentationBecameInactive()

    XCTAssertEqual(viewModel.state, .ready)
    XCTAssertEqual(viewModel.summary, baseline)
    XCTAssertEqual(viewModel.draft.biography, "切换标签时保留")
    XCTAssertTrue(viewModel.hasUnsavedChanges)
    XCTAssertTrue(viewModel.requiresNavigationInterception)
    XCTAssertFalse(viewModel.showsDiscardConfirmation)
  }

  func testChangedSessionDiscardsSuspendedLoadResult() async throws {
    let original = session(userID: 7, revision: uuid(10))
    let vault = AccountProfileEditVaultSpy(session: original)
    let service = AccountProfileEditServiceSpy(
      readScripts: [.suspended(id: 1, value: profile(userID: 7))]
    )
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )

    let loadTask = Task { await viewModel.loadIfNeeded() }
    try await waitForAccountProfileEditTest { await service.suspendedReadCount() == 1 }
    await vault.replaceActive(with: session(userID: 8, revision: uuid(11)))
    await service.releaseRead(id: 1)
    await loadTask.value

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.summary)
  }

  func testChangedRevisionDiscardsSuspendedSaveResult() async throws {
    let original = session(userID: 7, revision: uuid(12))
    let baseline = profile(userID: 7)
    let confirmed = profile(
      userID: 7,
      displayName: baseline.displayName,
      biography: "已保存",
      editableBiography: "已保存"
    )
    let vault = AccountProfileEditVaultSpy(session: original)
    let service = AccountProfileEditServiceSpy(
      readScripts: [.value(baseline)],
      saveScripts: [.suspended(id: 2, value: confirmed)]
    )
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()
    viewModel.setBiography("已保存")

    let saveTask = Task { await viewModel.save() }
    try await waitForAccountProfileEditTest { await service.suspendedSaveCount() == 1 }
    await vault.replaceActive(with: session(userID: 7, revision: uuid(13)))
    await service.releaseSave(id: 2)
    let result = await saveTask.value

    XCTAssertNil(result)
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.summary)
  }

  func testInvalidationCancelsAttributionOfOlderResult() async throws {
    let active = session(userID: 7, revision: uuid(14))
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(
      readScripts: [.suspended(id: 3, value: profile(userID: 7))]
    )
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )

    let loadTask = Task { await viewModel.loadIfNeeded() }
    try await waitForAccountProfileEditTest { await service.suspendedReadCount() == 1 }
    viewModel.invalidateForAccountSessionChange()
    await service.releaseRead(id: 3)
    await loadTask.value

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.summary)
  }

  func testCallerCancellationDuringSavePreflightPreventsWriteDispatch() async throws {
    let active = session(userID: 7, revision: uuid(18))
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(readScripts: [.value(profile(userID: 7))])
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()
    viewModel.setBiography("不应派发")
    await vault.suspendActiveRead(number: 3)

    let saveTask = Task { await viewModel.save() }
    try await waitForAccountProfileEditTest { await vault.suspendedActiveReadCount() == 1 }
    saveTask.cancel()
    await vault.releaseActiveRead(number: 3)
    let result = await saveTask.value

    XCTAssertNil(result)
    XCTAssertEqual(viewModel.state, .ready)
    XCTAssertEqual(viewModel.draft.biography, "不应派发")
    let saves = await service.saveRequestsSnapshot()
    XCTAssertTrue(saves.isEmpty)
  }

  func testSaveFailurePreservesDraftAndRequiresExplicitRetry() async {
    let active = session(userID: 7, revision: uuid(15))
    let baseline = profile(userID: 7)
    let confirmed = profile(
      userID: 7,
      displayName: baseline.displayName,
      biography: "保留草稿",
      editableBiography: "保留草稿"
    )
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(
      readScripts: [.value(baseline)],
      saveScripts: [.failure("网络中断"), .value(confirmed)]
    )
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()
    viewModel.setBiography("保留草稿")

    let firstResult = await viewModel.save()

    XCTAssertNil(firstResult)
    XCTAssertEqual(viewModel.state, .ready)
    XCTAssertEqual(viewModel.draft.biography, "保留草稿")
    XCTAssertEqual(viewModel.errorMessage, "网络中断")
    let firstRequests = await service.saveRequestsSnapshot()
    XCTAssertEqual(firstRequests.count, 1)

    let secondResult = await viewModel.save()

    XCTAssertEqual(secondResult, confirmed)
    let secondRequests = await service.saveRequestsSnapshot()
    XCTAssertEqual(secondRequests.count, 2)
  }

  func testPostDispatchVaultFailureKeepsDraftAndPublishesOutcomeUnknown() async {
    let active = session(userID: 7, revision: uuid(19))
    let baseline = profile(userID: 7)
    let confirmed = profile(
      userID: 7,
      displayName: baseline.displayName,
      biography: "等待确认",
      editableBiography: "等待确认"
    )
    let vault = AccountProfileEditVaultSpy(session: active)
    let service = AccountProfileEditServiceSpy(
      readScripts: [.value(baseline)],
      saveScripts: [.value(confirmed)]
    )
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()
    viewModel.setBiography("等待确认")
    await vault.failActiveRead(number: 4)

    let result = await viewModel.save()

    XCTAssertNil(result)
    XCTAssertEqual(viewModel.state, .ready)
    XCTAssertEqual(viewModel.summary, baseline)
    XCTAssertEqual(viewModel.draft.biography, "等待确认")
    XCTAssertEqual(
      viewModel.errorMessage,
      "无法确认个人资料是否已保存；请检查资料后再明确保存。"
    )
    let saves = await service.saveRequestsSnapshot()
    XCTAssertEqual(saves.count, 1)
  }

  func testMissingBirthdayAndPendingNicknameDisableAllEditsAndSave() async {
    let missingBirthday = profile(userID: 7, birthday: nil)
    let pendingNickname = profile(
      userID: 7,
      isNicknameEditing: true,
      editingNickname: "审核中的昵称"
    )

    let missingBirthdayViewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: AccountProfileEditServiceSpy(readScripts: [.value(missingBirthday)]),
      vault: AccountProfileEditVaultSpy(session: session(userID: 7, revision: uuid(16)))
    )
    await missingBirthdayViewModel.loadIfNeeded()
    XCTAssertFalse(missingBirthdayViewModel.isEditingEnabled)
    XCTAssertFalse(missingBirthdayViewModel.canSave)
    XCTAssertTrue(missingBirthdayViewModel.validationMessage?.contains("生日信息") == true)
    missingBirthdayViewModel.setBiography("不会写入草稿")
    XCTAssertEqual(
      missingBirthdayViewModel.draft.biography,
      missingBirthday.editableBiography
    )

    let pendingViewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: AccountProfileEditServiceSpy(readScripts: [.value(pendingNickname)]),
      vault: AccountProfileEditVaultSpy(session: session(userID: 7, revision: uuid(17)))
    )
    await pendingViewModel.loadIfNeeded()
    XCTAssertEqual(pendingViewModel.draft.displayName, "审核中的昵称")
    XCTAssertFalse(pendingViewModel.isEditingEnabled)
    XCTAssertFalse(pendingViewModel.canSave)

    let genericPending = profile(userID: 7, isNicknameEditing: true)
    let genericPendingViewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: AccountProfileEditServiceSpy(readScripts: [.value(genericPending)]),
      vault: AccountProfileEditVaultSpy(session: session(userID: 7, revision: uuid(20)))
    )
    await genericPendingViewModel.loadIfNeeded()
    XCTAssertEqual(genericPendingViewModel.state, .ready)
    XCTAssertEqual(genericPendingViewModel.draft.displayName, genericPending.displayName)
    XCTAssertEqual(
      genericPendingViewModel.validationMessage,
      "昵称正在审核，暂时不能再次修改个人资料。"
    )
  }

  func testAvatarPermissionIsIndependentFromTextEditRestrictions() async {
    let restricted = profile(
      userID: 7,
      birthday: nil,
      isNicknameEditing: true,
      editingNickname: "审核中的昵称",
      canModifyAvatar: true
    )
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: AccountProfileEditServiceSpy(readScripts: [.value(restricted)]),
      vault: AccountProfileEditVaultSpy(session: session(userID: 7, revision: uuid(24)))
    )

    await viewModel.loadIfNeeded()

    XCTAssertFalse(viewModel.isEditingEnabled)
    XCTAssertFalse(viewModel.canSave)
    XCTAssertTrue(viewModel.canUploadAvatar)
    XCTAssertNil(viewModel.avatarStatusMessage)
  }

  func testAvatarUploadPreservesDirtyTextDraftAndPublishesDisposition() async throws {
    let active = session(userID: 7, revision: uuid(25))
    let baseline = profile(userID: 7, canModifyAvatar: true)
    let refreshed = profile(
      userID: 7,
      displayName: "服务端的新昵称",
      canModifyAvatar: true
    )
    let expectedResult = AccountProfileAvatarUploadResult(
      profile: refreshed,
      disposition: .acceptedPendingReview(message: "头像正在审核")
    )
    let service = AccountProfileEditServiceSpy(
      readScripts: [.value(baseline)],
      avatarScripts: [.value(expectedResult)]
    )
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: AccountProfileEditVaultSpy(session: active)
    )
    await viewModel.loadIfNeeded()
    viewModel.setBiography("尚未保存的简介")
    let upload = try XCTUnwrap(avatarUpload(26))

    let result = await viewModel.uploadAvatar(upload)

    XCTAssertEqual(result?.profile, refreshed)
    XCTAssertEqual(result?.disposition, expectedResult.disposition)
    XCTAssertEqual(viewModel.summary, refreshed)
    XCTAssertEqual(viewModel.draft.biography, "尚未保存的简介")
    XCTAssertEqual(viewModel.draft.displayName, baseline.displayName)
    XCTAssertTrue(viewModel.hasUnsavedChanges)
    XCTAssertEqual(viewModel.avatarState, .acceptedPendingReview("头像正在审核"))
    XCTAssertEqual(viewModel.avatarStatusMessage, "头像正在审核")
    let requests = await service.avatarRequestsSnapshot()
    XCTAssertEqual(
      requests,
      [
        AccountProfileAvatarRequest(
          userID: 7,
          revision: uuid(25),
          uploadID: upload.uploadID,
          byteCount: upload.jpegData.count,
          pixelSize: upload.pixelSize
        )
      ]
    )
  }

  func testAvatarUploadBeforeDispatchRejectsChangedLease() async throws {
    let original = session(userID: 7, revision: uuid(27))
    let vault = AccountProfileEditVaultSpy(session: original)
    let service = AccountProfileEditServiceSpy(
      readScripts: [.value(profile(userID: 7, canModifyAvatar: true))]
    )
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()
    await vault.replaceActive(with: session(userID: 7, revision: uuid(28)))

    let result = await viewModel.uploadAvatar(try XCTUnwrap(avatarUpload(29)))

    XCTAssertNil(result)
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.summary)
    let requests = await service.avatarRequestsSnapshot()
    XCTAssertTrue(requests.isEmpty)
  }

  func testChangedLeaseDiscardsSuspendedAvatarResult() async throws {
    let original = session(userID: 7, revision: uuid(30))
    let baseline = profile(userID: 7, canModifyAvatar: true)
    let confirmed = AccountProfileAvatarUploadResult(
      profile: profile(userID: 7, canModifyAvatar: true),
      disposition: .confirmed
    )
    let vault = AccountProfileEditVaultSpy(session: original)
    let service = AccountProfileEditServiceSpy(
      readScripts: [.value(baseline)],
      avatarScripts: [.suspended(id: 4, value: confirmed)]
    )
    let viewModel = AccountProfileEditViewModel(
      expectedUserID: 7,
      service: service,
      vault: vault
    )
    await viewModel.loadIfNeeded()

    let task = Task { await viewModel.uploadAvatar(try! XCTUnwrap(avatarUpload(31))) }
    try await waitForAccountProfileEditTest { await service.suspendedAvatarCount() == 1 }
    XCTAssertTrue(viewModel.isUploadingAvatar)
    XCTAssertFalse(viewModel.canSave)
    XCTAssertFalse(viewModel.requestClose())
    await vault.replaceActive(with: session(userID: 8, revision: uuid(32)))
    await service.releaseAvatar(id: 4)
    let result = await task.value

    XCTAssertNil(result)
    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertEqual(viewModel.avatarState, .idle)
    XCTAssertNil(viewModel.summary)
  }

  private func session(userID: Int64, revision: UUID) -> StoredAccountSession {
    StoredAccountSession(
      id: userID,
      username: "user-\(userID)",
      displayName: "User \(userID)",
      portrait: "portrait-\(userID)",
      bduss: String(repeating: "b", count: AccountCredentialFormat.bdussLength),
      stoken: String(repeating: "s", count: AccountCredentialFormat.stokenLength),
      createdAt: Date(timeIntervalSince1970: 1),
      updatedAt: Date(timeIntervalSince1970: 2),
      sessionRevision: revision
    )
  }

  private func profile(
    userID: Int64,
    displayName: String = "原昵称",
    biography: String = "原简介",
    editableBiography: String? = nil,
    sex: AccountProfileSex = .male,
    birthday: AccountProfileBirthday? = AccountProfileBirthday(
      timeMilliseconds: 631_123_200_000,
      showsConstellationOnly: true
    ),
    isNicknameEditing: Bool = false,
    editingNickname: String = "",
    canModifyAvatar: Bool = false,
    avatarModificationDescription: String = ""
  ) -> AccountProfileSummary {
    AccountProfileSummary(
      userID: userID,
      username: "user-\(userID)",
      displayName: displayName,
      portraitURL: URL(string: "https://himg.bdimg.com/sys/portraitn/item/portrait-\(userID)"),
      biography: biography,
      followingCount: 3,
      followerCount: 4,
      postCount: 5,
      editableBiography: editableBiography,
      sex: sex,
      birthday: birthday,
      isNicknameEditing: isNicknameEditing,
      editingNickname: editingNickname,
      canModifyAvatar: canModifyAvatar,
      avatarModificationDescription: avatarModificationDescription
    )
  }

  private func avatarUpload(_ value: UInt8) -> AccountProfileAvatarUpload? {
    AccountProfileAvatarUpload(
      uploadID: uuid(value),
      jpegData: Data([0xFF, 0xD8, value, 0xFF, 0xD9]),
      pixelSize: 960
    )
  }

  private func uuid(_ value: UInt8) -> UUID {
    UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
  }
}

private struct AccountProfileEditRequest: Equatable, Sendable {
  let userID: Int64
  let revision: UUID
}

private struct AccountProfileEditSaveRequest: Equatable, Sendable {
  let userID: Int64
  let revision: UUID
  let submission: AccountProfileEditSubmission
}

private struct AccountProfileAvatarRequest: Equatable, Sendable {
  let userID: Int64
  let revision: UUID
  let uploadID: UUID
  let byteCount: Int
  let pixelSize: Int
}

private enum AccountProfileEditScript: Sendable {
  case value(AccountProfileSummary)
  case failure(String)
  case suspended(id: Int, value: AccountProfileSummary)
}

private enum AccountProfileAvatarScript: Sendable {
  case value(AccountProfileAvatarUploadResult)
  case failure(String)
  case suspended(id: Int, value: AccountProfileAvatarUploadResult)
}

private struct AccountProfileEditTestError: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private actor AccountProfileEditServiceSpy: AccountService {
  private var readScripts: [AccountProfileEditScript]
  private var saveScripts: [AccountProfileEditScript]
  private var avatarScripts: [AccountProfileAvatarScript]
  private var readRequests: [AccountProfileEditRequest] = []
  private var saveRequests: [AccountProfileEditSaveRequest] = []
  private var avatarRequests: [AccountProfileAvatarRequest] = []
  private var suspendedReads:
    [Int: (CheckedContinuation<AccountProfileSummary, Never>, AccountProfileSummary)] = [:]
  private var suspendedSaves:
    [Int: (CheckedContinuation<AccountProfileSummary, Never>, AccountProfileSummary)] = [:]
  private var suspendedAvatars:
    [
      Int: (
        CheckedContinuation<AccountProfileAvatarUploadResult, Never>,
        AccountProfileAvatarUploadResult
      )
    ] = [:]

  init(
    readScripts: [AccountProfileEditScript],
    saveScripts: [AccountProfileEditScript] = [],
    avatarScripts: [AccountProfileAvatarScript] = []
  ) {
    self.readScripts = readScripts
    self.saveScripts = saveScripts
    self.avatarScripts = avatarScripts
  }

  func selfProfile(session: StoredAccountSession) async throws -> AccountProfileSummary {
    readRequests.append(
      AccountProfileEditRequest(userID: session.id, revision: session.sessionRevision)
    )
    guard !readScripts.isEmpty else {
      throw AccountProfileEditTestError(message: "Missing read script")
    }
    let script = readScripts.removeFirst()
    switch script {
    case .value(let value):
      return value
    case .failure(let message):
      throw AccountProfileEditTestError(message: message)
    case .suspended(let id, let value):
      return await withCheckedContinuation { suspendedReads[id] = ($0, value) }
    }
  }

  func updateSelfProfile(
    session: StoredAccountSession,
    edit: AccountProfileEditSubmission
  ) async throws -> AccountProfileSummary {
    saveRequests.append(
      AccountProfileEditSaveRequest(
        userID: session.id,
        revision: session.sessionRevision,
        submission: edit
      )
    )
    guard !saveScripts.isEmpty else {
      throw AccountProfileEditTestError(message: "Missing save script")
    }
    let script = saveScripts.removeFirst()
    switch script {
    case .value(let value):
      return value
    case .failure(let message):
      throw AccountProfileEditTestError(message: message)
    case .suspended(let id, let value):
      return await withCheckedContinuation { suspendedSaves[id] = ($0, value) }
    }
  }

  func uploadSelfProfileAvatar(
    session: StoredAccountSession,
    upload: AccountProfileAvatarUpload
  ) async throws -> AccountProfileAvatarUploadResult {
    avatarRequests.append(
      AccountProfileAvatarRequest(
        userID: session.id,
        revision: session.sessionRevision,
        uploadID: upload.uploadID,
        byteCount: upload.jpegData.count,
        pixelSize: upload.pixelSize
      )
    )
    guard !avatarScripts.isEmpty else {
      throw AccountProfileEditTestError(message: "Missing avatar script")
    }
    let script = avatarScripts.removeFirst()
    switch script {
    case .value(let value):
      return value
    case .failure(let message):
      throw AccountProfileEditTestError(message: message)
    case .suspended(let id, let value):
      return await withCheckedContinuation { suspendedAvatars[id] = ($0, value) }
    }
  }

  func releaseRead(id: Int) {
    guard let (continuation, value) = suspendedReads.removeValue(forKey: id) else { return }
    continuation.resume(returning: value)
  }

  func releaseSave(id: Int) {
    guard let (continuation, value) = suspendedSaves.removeValue(forKey: id) else { return }
    continuation.resume(returning: value)
  }

  func releaseAvatar(id: Int) {
    guard let (continuation, value) = suspendedAvatars.removeValue(forKey: id) else { return }
    continuation.resume(returning: value)
  }

  func suspendedReadCount() -> Int { suspendedReads.count }
  func suspendedSaveCount() -> Int { suspendedSaves.count }
  func suspendedAvatarCount() -> Int { suspendedAvatars.count }
  func readRequestsSnapshot() -> [AccountProfileEditRequest] { readRequests }
  func saveRequestsSnapshot() -> [AccountProfileEditSaveRequest] { saveRequests }
  func avatarRequestsSnapshot() -> [AccountProfileAvatarRequest] { avatarRequests }

  func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
    throw AccountProfileEditTestError(message: "Unexpected validation")
  }

  func followedForums(
    session: StoredAccountSession,
    page: Int,
    pageSize: Int
  ) async throws -> FollowedForumPageData {
    throw AccountProfileEditTestError(message: "Unexpected followed forums request")
  }

  func forumMembership(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumMembershipData {
    throw AccountProfileEditTestError(message: "Unexpected membership request")
  }

  func forumAccountState(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw AccountProfileEditTestError(message: "Unexpected account-state request")
  }

  func setForumFollowed(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String,
    isFollowed: Bool
  ) async throws -> ForumMembershipData {
    throw AccountProfileEditTestError(message: "Unexpected membership mutation")
  }

  func checkInToForum(
    session: StoredAccountSession,
    forumID: Int64,
    forumName: String
  ) async throws -> ForumAccountStateData {
    throw AccountProfileEditTestError(message: "Unexpected check-in request")
  }
}

private actor AccountProfileEditVaultSpy: AccountVault {
  private var session: StoredAccountSession?
  private var activeReads = 0
  private var failingReadNumbers: Set<Int> = []
  private var suspendedReadNumbers: Set<Int> = []
  private var suspendedReads:
    [Int: (CheckedContinuation<StoredAccountSession?, Never>, StoredAccountSession?)] = [:]

  init(session: StoredAccountSession?) {
    self.session = session
  }

  func replaceActive(with session: StoredAccountSession?) {
    self.session = session
  }

  func suspendActiveRead(number: Int) {
    suspendedReadNumbers.insert(number)
  }

  func failActiveRead(number: Int) {
    failingReadNumbers.insert(number)
  }

  func activeSession() async throws -> StoredAccountSession? {
    activeReads += 1
    let readNumber = activeReads
    if failingReadNumbers.remove(readNumber) != nil {
      throw AccountProfileEditTestError(message: "Vault unavailable")
    }
    if suspendedReadNumbers.remove(readNumber) != nil {
      let capturedSession = session
      return await withCheckedContinuation {
        suspendedReads[readNumber] = ($0, capturedSession)
      }
    }
    return session
  }

  func activeSessionReadCount() -> Int { activeReads }
  func suspendedActiveReadCount() -> Int { suspendedReads.count }

  func releaseActiveRead(number: Int) {
    guard let (continuation, value) = suspendedReads.removeValue(forKey: number) else { return }
    continuation.resume(returning: value)
  }

  func accountSummaries() async throws -> [AccountSummary] {
    throw AccountProfileEditTestError(message: "Unexpected account summary request")
  }

  func upsert(_ session: StoredAccountSession) async throws {
    throw AccountProfileEditTestError(message: "Unexpected account mutation")
  }

  func switchActive(to userID: Int64) async throws {
    throw AccountProfileEditTestError(message: "Unexpected account mutation")
  }

  func remove(userID: Int64) async throws {
    throw AccountProfileEditTestError(message: "Unexpected account mutation")
  }

  func removeAll() async throws {
    throw AccountProfileEditTestError(message: "Unexpected account mutation")
  }
}

@MainActor
private func waitForAccountProfileEditTest(
  timeout: TimeInterval = 2,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    if Date() >= deadline {
      XCTFail("Timed out waiting for account-profile edit state")
      throw AccountProfileEditTestError(message: "Timed out waiting for account-profile edit state")
    }
    await Task.yield()
  }
}
