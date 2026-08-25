import Foundation
import SwiftUI
import TiebaCore

struct ReplyComposerView: View {
  @Environment(\.textReplySubmissionStore) private var submissionStore
  @Environment(\.composerImageAttachmentStore) private var attachmentStore

  let context: TextReplyComposerContext
  let verifyVisibility:
    @MainActor (
      TextReplySubmission,
      TextReplyReceipt,
      [ComposerImageUploadResult]
    ) async throws -> TextReplyVisibilityConfirmation?
  let onConfirmed: @MainActor (CreatedTextReply) -> Void

  @State private var scopeID = UUID()

  var body: some View {
    Group {
      if let submissionStore {
        ReplyComposerContentView(
          entry: submissionStore.entry(for: context.target),
          context: context,
          store: submissionStore,
          attachmentStore: attachmentStore,
          scopeID: scopeID,
          verifyVisibility: verifyVisibility,
          onConfirmed: onConfirmed
        )
      } else {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("回复服务不可用")
            .font(.headline)
          Text("当前运行环境未提供安全的账户发送服务。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(24)
      }
    }
    .navigationTitle(context.composerTitle)
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct ReplyComposerContentView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.openURL) private var openURL
  @ObservedObject var entry: TextReplySubmissionEntry

  let context: TextReplyComposerContext
  let store: TextReplySubmissionStore
  let attachmentStore: ComposerImageAttachmentStore?
  let scopeID: UUID
  let verifyVisibility:
    @MainActor (
      TextReplySubmission,
      TextReplyReceipt,
      [ComposerImageUploadResult]
    ) async throws -> TextReplyVisibilityConfirmation?
  let onConfirmed: @MainActor (CreatedTextReply) -> Void

  @State private var text = ""
  @State private var attachments: [ComposerImageAttachment] = []
  @State private var imageQuality = ComposerImageAttachmentQuality.standard
  @State private var imageWatermark = TiebaStaticImageWatermark.forumName
  @State private var textSelection = ComposerTextSelection.start
  @State private var didHydrateDraft = false
  @State private var pendingSubmission: TextReplySubmission?
  @State private var isDiscardConfirmationPresented = false
  @State private var isLaunchingSubmission = false
  @State private var isCheckingVisibility = false
  @State private var isImportingImages = false
  @State private var imageImportCancellationController =
    ComposerImageImportCancellationController()
  @State private var imageCleanupCandidates = ComposerImageCleanupCandidates()
  @State private var attachmentOwnerUserID: Int64?
  @State private var errorMessage: String?
  @State private var isEmoticonPickerPresented = false
  @State private var lifecycleGate = ReplyComposerLifecycleGate()
  @State private var entryRiskNoticeGate = ComposerEntryRiskNoticeGate()
  @State private var officialHandoffOpenGate = OfficialTiebaReplyHandoffOpenGate()
  @State private var confirmationPreparationGate = SubmissionConfirmationPreparationGate()
  @AppStorage(AppPreferenceKey.showsPostAndReplyRiskNotice)
  private var showsPostAndReplyRiskNotice = AppPreferenceDefaults.showsPostAndReplyRiskNotice
  @AppStorage(AppPreferenceKey.defaultImageWatermark)
  private var defaultImageWatermark = ComposerImageWatermarkPreference.defaultValue.rawValue
  @State private var editorIsFocused = false

  var body: some View {
    VStack(spacing: 0) {
      editor

      Divider()

      if let attachmentStore,
        shouldShowImagePicker
      {
        ComposerImagePickerView(
          attachments: $attachments,
          quality: $imageQuality,
          watermark: $imageWatermark,
          attachmentStore: attachmentStore,
          importCancellationController: imageImportCancellationController,
          isEnabled: imageEditorAllowsEditing && attachmentOwnerUserID != nil,
          importIsBusy: $isImportingImages,
          errorMessage: $errorMessage,
          onAttachmentImported: { attachment in
            if let attachmentOwnerUserID {
              imageCleanupCandidates.observe(attachment, userID: attachmentOwnerUserID)
            }
          },
          onAttachmentRemovalRequested: { removedAttachment, remainingAttachments in
            guard let attachmentOwnerUserID else {
              throw TextReplySubmissionError.unavailable
            }
            imageCleanupCandidates.observe(
              removedAttachment,
              userID: attachmentOwnerUserID
            )
            try await ComposerImageRemovalCoordinator.persistRemovalThenCleanCandidate(
              removedAttachment: removedAttachment,
              remainingAttachments: remainingAttachments,
              persist: { remainingAttachments in
                let draft = try await store.saveDraft(
                  text,
                  attachments: remainingAttachments,
                  imageWatermark: imageWatermark,
                  for: context.target
                )
                imageCleanupCandidates.markPersisted(
                  draft?.attachments ?? [],
                  userID: attachmentOwnerUserID
                )
              },
              cleanCandidate: { candidates in
                await store.removeUnreferencedAttachments(
                  candidates,
                  userID: attachmentOwnerUserID,
                  for: context.target
                )
              }
            )
          }
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: attachments) { value in
          invalidatePendingSubmissionIfNeeded(
            content: text,
            attachments: value,
            imageWatermark: imageWatermark
          )
        }
        .onChange(of: imageWatermark) { value in
          invalidatePendingSubmissionIfNeeded(
            content: text,
            attachments: attachments,
            imageWatermark: value
          )
        }

        Divider()
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(characterCountLabel)
          Spacer(minLength: 0)
          Text(byteCountLabel)
        }

        VStack(alignment: .leading, spacing: 3) {
          Text(characterCountLabel)
          Text(byteCountLabel)
        }
      }
      .font(.caption.monospacedDigit())
      .foregroundStyle(contentIsWithinLimits ? Color.secondary : Color.red)
      .padding(.horizontal, 16)
      .padding(.vertical, 9)

      if let status = presentation.status {
        Divider()
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 10) {
            statusLabel(status)
            if presentation.allowsVisibilityCheck {
              visibilityCheckButton
            }
            if let recoveryAction = presentation.imageRecoveryAction {
              imageRecoveryButton(recoveryAction)
            }
          }

          VStack(alignment: .leading, spacing: 10) {
            statusLabel(status)
            if presentation.allowsVisibilityCheck {
              visibilityCheckButton
            }
            if let recoveryAction = presentation.imageRecoveryAction {
              imageRecoveryButton(recoveryAction)
            }
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      }
    }
    .background(Color(uiColor: .systemBackground))
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Button {
          editorIsFocused = false
          isEmoticonPickerPresented = true
        } label: {
          Image(systemName: "face.smiling")
        }
        .disabled(!editorAllowsEditing)
        .accessibilityLabel("插入经典表情")
        .help("插入经典表情")
        .accessibilityIdentifier("reply-composer-emoticon")

        Button {
          isDiscardConfirmationPresented = true
        } label: {
          Image(systemName: "trash")
        }
        .disabled(!canDiscardDraft)
        .accessibilityLabel("丢弃草稿")
        .help("丢弃草稿")

        Button {
          requestSubmissionConfirmation()
        } label: {
          if entry.isSubmitting || isLaunchingSubmission {
            ProgressView()
              .frame(width: 20, height: 20)
          } else {
            Image(systemName: "paperplane")
              .frame(width: 20, height: 20)
          }
        }
        .disabled(!canRequestSubmission)
        .accessibilityLabel("发送回复")
        .help("发送回复")
        .accessibilityIdentifier("reply-composer-send")
      }

      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("完成") { editorIsFocused = false }
      }
    }
    .confirmationDialog(
      ComposerEntryRiskNoticeCopy.standard.title,
      isPresented: entryRiskNoticeIsPresented,
      titleVisibility: .visible
    ) {
      if officialTiebaReplyHandoff != nil {
        Button(OfficialTiebaReplyHandoffCopy.actionTitle) {
          openOfficialTiebaClientFromEntryRiskNotice()
        }
        .disabled(officialHandoffOpenGate.isOpening)
        .accessibilityIdentifier("reply-composer-official-handoff")
      }
      Button(ComposerEntryRiskNoticeCopy.standard.continueTitle) {
        continueAfterEntryRiskNotice()
      }
      Button(ComposerEntryRiskNoticeCopy.standard.leaveTitle, role: .cancel) {
        leaveFromEntryRiskNotice()
      }
    } message: {
      Text(entryRiskNoticeMessage)
    }
    .confirmationDialog(
      submissionConfirmationCopy.title,
      isPresented: submissionConfirmationIsPresented,
      titleVisibility: .visible,
      presenting: pendingSubmission
    ) { submission in
      Button(submissionConfirmationCopy.actionTitle) { submitConfirmed(submission) }
      Button("取消", role: .cancel) { pendingSubmission = nil }
    } message: { _ in
      Text(submissionConfirmationCopy.message)
    }
    .confirmationDialog(
      "丢弃草稿？",
      isPresented: $isDiscardConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("丢弃", role: .destructive) { discardDraft() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("此操作会删除当前账户在这个回复位置保存的草稿。")
    }
    .alert("无法完成回复操作", isPresented: errorIsPresented) {
      Button("好", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "回复操作失败。")
    }
    .sheet(isPresented: $isEmoticonPickerPresented, onDismiss: restoreEditorFocus) {
      ClassicEmoticonPicker(onSelect: insertClassicEmoticon)
        .presentationDetents([.medium, .large])
    }
    .task {
      let currentLifecycleID = lifecycleGate.beginAppearance()
      await store.activate(context.target, for: scopeID)
      guard lifecycleGate.isCurrent(currentLifecycleID) else { return }
      let activatedOwnerUserID = store.draftOwnerUserID(for: context.target)
      if let attachmentOwnerUserID, activatedOwnerUserID != attachmentOwnerUserID {
        imageImportCancellationController.cancel()
        confirmationPreparationGate.cancel()
        pendingSubmission = nil
        isEmoticonPickerPresented = false
        didHydrateDraft = false
        text = ""
        attachments = []
        imageQuality = .standard
        imageWatermark = preferredImageWatermark
        textSelection = .start
        _ = lifecycleGate.scheduleDeactivation()
        await cleanAllImageCandidatesNow()
        store.deactivate(scopeID)
        dismiss()
        return
      }
      attachmentOwnerUserID = activatedOwnerUserID
      hydrateDraftIfNeeded()
      resolveEntryRiskNoticeIfNeeded()
      if editorAllowsEditing {
        editorIsFocused = true
      }
    }
    .task(id: autosaveTaskID) {
      guard autosaveTaskID.shouldSave else { return }
      do {
        try await Task.sleep(nanoseconds: 450_000_000)
        try Task.checkCancellation()
        let draft = try await store.saveDraft(
          text,
          attachments: attachments,
          imageWatermark: imageWatermark,
          for: context.target
        )
        if let attachmentOwnerUserID {
          imageCleanupCandidates.markPersisted(
            draft?.attachments ?? [],
            userID: attachmentOwnerUserID
          )
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        errorMessage = error.localizedDescription
      }
    }
    .onChange(of: entry.state) { _ in
      hydrateDraftIfNeeded()
      if !presentation.allowsSubmission {
        confirmationPreparationGate.cancel()
        pendingSubmission = nil
      }
      if !presentation.allowsEditing {
        isEmoticonPickerPresented = false
        officialHandoffOpenGate.cancel()
      }
      resolveEntryRiskNoticeIfNeeded()
    }
    .onChange(of: text) { value in
      invalidatePendingSubmissionIfNeeded(
        content: value,
        attachments: attachments,
        imageWatermark: imageWatermark
      )
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      let cleanupOwnerUserID = attachmentOwnerUserID
      let cleanupCandidates = cleanupOwnerUserID.map {
        imageCleanupCandidates.attachments(for: $0)
      } ?? []
      imageImportCancellationController.cancel()
      if let cleanupOwnerUserID {
        cleanImageCandidates(
          cleanupCandidates,
          userID: cleanupOwnerUserID
        )
      }
      confirmationPreparationGate.cancel()
      officialHandoffOpenGate.cancel()
      pendingSubmission = nil
      errorMessage = nil
      isEmoticonPickerPresented = false
      didHydrateDraft = false
      attachmentOwnerUserID = nil
      text = ""
      attachments = []
      imageQuality = .standard
      imageWatermark = preferredImageWatermark
      textSelection = .start
    }
    .onChange(of: showsPostAndReplyRiskNotice) { isEnabled in
      if !isEnabled, entryRiskNoticeGate.isPresented {
        continueAfterEntryRiskNotice()
      } else {
        resolveEntryRiskNoticeIfNeeded()
      }
    }
    .onDisappear(perform: persistAndDeactivate)
  }

  private var editor: some View {
    ZStack(alignment: .topLeading) {
      if text.isEmpty {
        Text(context.placeholder)
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 20)
          .padding(.vertical, 18)
          .allowsHitTesting(false)
      }

      ComposerTextEditor(
        text: $text,
        selection: $textSelection,
        isFocused: $editorIsFocused,
        isEditable: editorAllowsEditing,
        accessibilityLabel: context.composerTitle,
        accessibilityIdentifier: "reply-composer-editor"
      )
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture { editorIsFocused = editorAllowsEditing }
  }

  private func statusLabel(_ status: TextReplyComposerPresentation.Status) -> some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: status.systemImage)
        .foregroundStyle(status.tint)
        .frame(width: 18)
      Text(status.message)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var visibilityCheckButton: some View {
    Button("重新核对", action: checkVisibility)
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(isCheckingVisibility || officialHandoffOpenGate.isOpening)
  }

  private func imageRecoveryButton(
    _ action: TextReplyComposerPresentation.ImageRecoveryAction
  ) -> some View {
    Button(action.title, action: resumeImageSubmission)
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .disabled(
        isLaunchingSubmission
          || isCheckingVisibility
          || isImportingImages
          || officialHandoffOpenGate.isOpening
      )
      .accessibilityIdentifier("reply-composer-\(action.accessibilityIdentifier)")
  }

  private var presentation: TextReplyComposerPresentation {
    TextReplyComposerPresentation(state: entry.state)
  }

  private var contentIsWithinLimits: Bool {
    ReplyComposerContentAdmissionPolicy.accepts(
      content: text,
      attachmentCount: attachments.count,
      target: context.target
    )
  }

  private var canRequestSubmission: Bool {
    submissionIsAllowed
      && !confirmationPreparationGate.isPreparing
      && pendingSubmission == nil
  }

  private var submissionIsAllowed: Bool {
    didHydrateDraft
      && presentation.allowsSubmission
      && entryRiskNoticeGate.isResolved
      && contentIsWithinLimits
      && !isLaunchingSubmission
      && !isCheckingVisibility
      && !isImportingImages
      && !officialHandoffOpenGate.isOpening
  }

  private var canDiscardDraft: Bool {
    didHydrateDraft
      && presentation.allowsEditing
      && entryRiskNoticeGate.isResolved
      && (!text.isEmpty || !attachments.isEmpty)
      && !isLaunchingSubmission
      && !isCheckingVisibility
      && !isImportingImages
      && !confirmationPreparationGate.isPreparing
      && pendingSubmission == nil
      && !officialHandoffOpenGate.isOpening
  }

  private var editorAllowsEditing: Bool {
    presentation.allowsEditing
      && entryRiskNoticeGate.isResolved
      && !confirmationPreparationGate.isPreparing
      && pendingSubmission == nil
      && !isImportingImages
      && !officialHandoffOpenGate.isOpening
  }

  private var imageEditorAllowsEditing: Bool {
    editorAllowsEditing && imageAttachmentsAreAllowedByState
  }

  private var shouldShowImagePicker: Bool {
    didHydrateDraft
      && ReplyComposerImagePolicy.allowsAttachments(for: context.target)
      && imageAttachmentsAreAllowedByState
      && (presentation.allowsEditing || !attachments.isEmpty)
  }

  private var imageAttachmentsAreAllowedByState: Bool {
    switch entry.state {
    case .challengeRequired, .confirmed:
      return false
    default:
      return true
    }
  }

  private var submissionConfirmationCopy: SubmissionConfirmationCopy {
    .reply
  }

  private var officialTiebaReplyHandoff: OfficialTiebaReplyHandoff? {
    OfficialTiebaReplyHandoff(target: context.target)
  }

  private var entryRiskNoticeMessage: String {
    guard let handoff = officialTiebaReplyHandoff else {
      return ComposerEntryRiskNoticeCopy.standard.message
    }
    return ComposerEntryRiskNoticeCopy.standard.message
      + "\n"
      + OfficialTiebaReplyHandoffCopy.disclosureMessage(for: handoff)
  }

  private var entryRiskNoticeIsPresented: Binding<Bool> {
    Binding(
      get: { entryRiskNoticeGate.isPresented },
      set: { isPresented in
        if !isPresented, entryRiskNoticeGate.isPresented {
          deferImplicitEntryRiskNoticeDismissal()
        }
      }
    )
  }

  private var submissionConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { pendingSubmission != nil },
      set: { isPresented in
        if !isPresented { pendingSubmission = nil }
      }
    )
  }

  private var characterCountLabel: String {
    "\(text.count.formatted()) / \(TextReplyContentPolicy.maximumCharacterCount.formatted()) 字"
  }

  private var byteCountLabel: String {
    "\(text.utf8.count.formatted()) / \(TextReplyContentPolicy.maximumUTF8ByteCount.formatted()) B"
  }

  private var autosaveTaskID: ReplyComposerAutosaveTaskID {
    ReplyComposerAutosaveTaskID(
      text: text,
      attachments: attachments,
      imageWatermark: imageWatermark,
      shouldSave: didHydrateDraft
        && presentation.allowsEditing
        && entryRiskNoticeGate.isResolved
        && !confirmationPreparationGate.isPreparing
        && pendingSubmission == nil
        && !isLaunchingSubmission
        && !isCheckingVisibility
        && !isImportingImages
        && !officialHandoffOpenGate.isOpening
    )
  }

  private var preferredImageWatermark: TiebaStaticImageWatermark {
    ComposerImageWatermarkPreference.resolved(defaultImageWatermark).watermark
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { isPresented in
        if !isPresented { errorMessage = nil }
      }
    )
  }

  private func hydrateDraftIfNeeded() {
    guard !didHydrateDraft else { return }
    switch entry.state {
    case .inactive, .loading:
      return
    default:
      text = entry.draft?.content ?? ""
      attachments = ReplyComposerImagePolicy.allowsAttachments(for: context.target)
        ? entry.draft?.attachments ?? []
        : []
      imageQuality = attachments.last?.quality ?? .standard
      imageWatermark = ComposerImageWatermarkPolicy.initialValue(
        preference: ComposerImageWatermarkPreference.resolved(defaultImageWatermark),
        hasImageDraft: !attachments.isEmpty,
        draftWatermark: entry.draft?.imageWatermark
      )
      textSelection = ComposerTextSelection(location: text.utf16.count, length: 0)
      didHydrateDraft = true
    }
  }

  private func requestSubmissionConfirmation() {
    let preparationLifecycleID = lifecycleGate.lifecycleID
    guard
      canRequestSubmission,
      let preparationID = confirmationPreparationGate.begin(
        lifecycleID: preparationLifecycleID
      )
    else {
      return
    }
    editorIsFocused = false

    Task { @MainActor in
      await Task.yield()
      guard
        lifecycleGate.isActive,
        lifecycleGate.isCurrent(preparationLifecycleID),
        confirmationPreparationGate.isCurrent(
          preparationID,
          lifecycleID: preparationLifecycleID
        ),
        pendingSubmission == nil,
        let submission = SubmissionConfirmationPolicy.textReplySnapshot(
          id: preparationID,
          target: context.target,
          content: text,
          attachments: attachments,
          imageWatermark: imageWatermark,
          submissionAllowed: submissionIsAllowed
        ),
        confirmationPreparationGate.finish(preparationID),
        SubmissionConfirmationPolicy.present(submission, pending: &pendingSubmission)
      else {
        _ = confirmationPreparationGate.finish(preparationID)
        return
      }
    }
  }

  private func invalidatePendingSubmissionIfNeeded(
    content: String,
    attachments: [ComposerImageAttachment],
    imageWatermark: TiebaStaticImageWatermark
  ) {
    guard let pendingSubmission else { return }
    if !SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
      pendingSubmission,
      target: context.target,
      content: content,
      attachments: attachments,
      imageWatermark: imageWatermark,
      submissionAllowed: submissionIsAllowed
    ) {
      self.pendingSubmission = nil
    }
  }

  private func submitConfirmed(_ submission: TextReplySubmission) {
    guard
      lifecycleGate.isActive,
      let submission = SubmissionConfirmationPolicy.consume(
        submission,
        pending: &pendingSubmission
      )
    else { return }
    guard
      SubmissionConfirmationPolicy.textReplySnapshotIsCurrent(
        submission,
        target: context.target,
        content: text,
        attachments: attachments,
        imageWatermark: imageWatermark,
        submissionAllowed: submissionIsAllowed
      )
    else { return }
    isLaunchingSubmission = true
    editorIsFocused = false

    Task { @MainActor in
      defer { isLaunchingSubmission = false }
      do {
        let result = try await store.submit(
          submission.content,
          attachments: submission.attachments,
          imageWatermark: submission.imageWatermark,
          for: submission.target,
          submissionID: submission.id
        )
        guard result.submissionID == submission.id, result.target == submission.target else {
          throw TextReplySubmissionError.submissionConflict
        }
        if case .confirmed(let created) = result.outcome {
          onConfirmed(created)
          dismiss()
        }
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func resolveEntryRiskNoticeIfNeeded() {
    guard didHydrateDraft, presentation.allowsEditing else { return }
    _ = entryRiskNoticeGate.composerBecameReady(
      showsNotice: showsPostAndReplyRiskNotice
    )
  }

  private func continueAfterEntryRiskNotice() {
    entryRiskNoticeGate.resolve()
    if presentation.allowsEditing {
      editorIsFocused = true
    }
  }

  private func leaveFromEntryRiskNotice() {
    entryRiskNoticeGate.resolve()
    editorIsFocused = false
    dismiss()
  }

  private func openOfficialTiebaClientFromEntryRiskNotice() {
    guard
      lifecycleGate.isActive,
      let handoff = officialTiebaReplyHandoff
    else { return }
    guard entryRiskNoticeGate.resolveForExternalHandoff() else { return }
    guard
      let request = officialHandoffOpenGate.begin(
        handoff: handoff,
        lifecycleID: lifecycleGate.lifecycleID
      )
    else { return }
    editorIsFocused = false
    OfficialTiebaReplyHandoffSystemDispatch.open(
      request,
      using: openURL
    ) { request, accepted in
      completeOfficialTiebaReplyHandoff(request, accepted: accepted)
    }
  }

  @MainActor
  private func completeOfficialTiebaReplyHandoff(
    _ request: OfficialTiebaReplyHandoffOpenRequest,
    accepted: Bool
  ) {
    guard
      lifecycleGate.isActive,
      lifecycleGate.isCurrent(request.lifecycleID),
      let outcome = officialHandoffOpenGate.complete(request, accepted: accepted)
    else { return }
    if outcome == .unavailable {
      errorMessage = OfficialTiebaReplyHandoffCopy.unavailableMessage
    }
  }

  private func deferImplicitEntryRiskNoticeDismissal() {
    entryRiskNoticeGate.beginImplicitDismissal()
    Task { @MainActor in
      await Task.yield()
      guard entryRiskNoticeGate.implicitDismissalIsPending else { return }
      leaveFromEntryRiskNotice()
    }
  }

  private func checkVisibility() {
    guard
      !isCheckingVisibility,
      case .acceptedAwaitingVisibility(let receipt) = entry.state,
      let draft = entry.draft
    else { return }
    let submission: TextReplySubmission
    switch draft.disposition {
    case .acceptedAwaitingVisibility(let submissionID, let draftReceipt):
      guard
        draftReceipt == receipt,
        let value = TextReplySubmission(
          id: submissionID,
          target: context.target,
          content: draft.content
        )
      else { return }
      submission = value
    case .imageAcceptedAwaitingVisibility(let reference, let draftReceipt):
      guard
        draftReceipt == receipt,
        let value = TextReplySubmission(
          id: reference.submissionID,
          target: context.target,
          content: draft.content,
          attachments: draft.attachments,
          imageWatermark: draft.imageWatermark
        )
      else { return }
      submission = value
    default:
      return
    }
    isCheckingVisibility = true

    Task { @MainActor in
      defer { isCheckingVisibility = false }
      do {
        let uploads: [ComposerImageUploadResult]
        if submission.attachments.isEmpty {
          uploads = []
        } else {
          uploads = try await store.visibilityImageUploads(for: context.target)
        }
        guard let confirmation = try await verifyVisibility(submission, receipt, uploads) else {
          errorMessage = "贴吧返回的内容仍不足以确认这条回复；草稿会继续保留，请勿重复发送。"
          return
        }
        let result = try await store.confirmVisibility(
          confirmation,
          matching: receipt,
          for: context.target
        )
        guard
          result.submissionID == submission.id,
          result.target == submission.target,
          case .confirmed(let created) = result.outcome
        else {
          throw TextReplySubmissionError.outcomeUnknown
        }
        onConfirmed(created)
        dismiss()
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func resumeImageSubmission() {
    guard
      presentation.imageRecoveryAction != nil,
      case .imageRecovery(let recoveryState) = entry.state,
      !isLaunchingSubmission,
      !isCheckingVisibility,
      !isImportingImages
    else { return }
    let expectedSubmissionID = recoveryState.reference.submissionID
    isLaunchingSubmission = true
    editorIsFocused = false

    Task { @MainActor in
      defer { isLaunchingSubmission = false }
      do {
        let result = try await store.resumeImageSubmission(for: context.target)
        guard
          result.submissionID == expectedSubmissionID,
          result.target == context.target
        else { throw TextReplySubmissionError.submissionConflict }
        if case .confirmed(let created) = result.outcome {
          onConfirmed(created)
          dismiss()
        }
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func discardDraft() {
    guard canDiscardDraft else { return }
    let discardedAttachments = attachments
    let attachmentOwnerUserID = attachmentOwnerUserID
    if let attachmentOwnerUserID {
      for attachment in discardedAttachments {
        imageCleanupCandidates.observe(attachment, userID: attachmentOwnerUserID)
      }
    }
    Task { @MainActor in
      do {
        try await store.discardDraft(for: context.target)
        text = ""
        attachments = []
        imageQuality = .standard
        imageWatermark = preferredImageWatermark
        textSelection = .start
        if let attachmentOwnerUserID {
          await ComposerImageRemovalCoordinator.cleanCandidatesBestEffort(
            discardedAttachments,
            cleanCandidates: { candidates in
              await store.removeUnreferencedAttachments(
                candidates,
                userID: attachmentOwnerUserID,
                for: context.target
              )
            }
          )
        }
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func insertClassicEmoticon(_ token: String) {
    guard
      editorAllowsEditing,
      let result = ComposerTextInsertionPolicy.replacingSelection(
        in: text,
        selection: textSelection,
        with: token
      ),
      ReplyComposerContentAdmissionPolicy.accepts(
        content: result.text,
        attachmentCount: attachments.count,
        target: context.target
      )
    else { return }
    text = result.text
    textSelection = result.selection
  }

  private func restoreEditorFocus() {
    if editorAllowsEditing {
      editorIsFocused = true
    }
  }

  private func persistAndDeactivate() {
    guard let disappearingLifecycleID = lifecycleGate.scheduleDeactivation() else { return }
    imageImportCancellationController.cancel()
    officialHandoffOpenGate.cancel()
    Task { @MainActor in
      await Task.yield()
      var completedPollCount = 0
      while ComposerImageImportDrainPolicy.shouldContinueWaiting(
        isBusy: isImportingImages,
        completedPollCount: completedPollCount
      ) {
        guard lifecycleGate.isCurrent(disappearingLifecycleID) else { return }
        try? await Task.sleep(
          nanoseconds: ComposerImageImportDrainPolicy.pollIntervalNanoseconds
        )
        completedPollCount += 1
      }
      guard lifecycleGate.isCurrent(disappearingLifecycleID) else { return }
      let shouldSave = didHydrateDraft && presentation.allowsEditing
      if shouldSave {
        do {
          let draft = try await store.saveDraft(
            text,
            attachments: attachments,
            imageWatermark: imageWatermark,
            for: context.target
          )
          if let attachmentOwnerUserID {
            imageCleanupCandidates.markPersisted(
              draft?.attachments ?? [],
              userID: attachmentOwnerUserID
            )
          }
        } catch {
          // Keep attachment files when persistence fails. A cancelled interactive
          // pop can immediately reactivate this same editor state.
        }
      }
      guard lifecycleGate.isCurrent(disappearingLifecycleID) else { return }
      store.deactivate(scopeID)
    }
  }

  private func cleanImageCandidates(
    _ candidates: [ComposerImageAttachment],
    userID: Int64
  ) {
    guard !candidates.isEmpty else { return }
    Task { @MainActor in
      await store.removeUnreferencedAttachments(
        candidates,
        userID: userID,
        for: context.target
      )
    }
  }

  private func cleanAllImageCandidatesNow() async {
    for userID in imageCleanupCandidates.userIDs {
      await store.removeUnreferencedAttachments(
        imageCleanupCandidates.attachments(for: userID),
        userID: userID,
        for: context.target
      )
    }
  }
}

struct ReplyComposerLifecycleGate {
  private(set) var lifecycleID = UUID()
  private(set) var deactivationIsScheduled = false

  mutating func beginAppearance() -> UUID {
    lifecycleID = UUID()
    deactivationIsScheduled = false
    return lifecycleID
  }

  mutating func scheduleDeactivation() -> UUID? {
    guard !deactivationIsScheduled else { return nil }
    deactivationIsScheduled = true
    return lifecycleID
  }

  func isCurrent(_ candidate: UUID) -> Bool {
    lifecycleID == candidate
  }

  var isActive: Bool {
    !deactivationIsScheduled
  }
}

extension TextReplyComposerContext {
  var composerTitle: String {
    switch kind {
    case .thread:
      return "回复主题"
    case .post:
      if let floor, floor > 0 { return "回复第 \(floor) 楼" }
      return "回复楼层"
    case .subpost:
      if let replyingToName { return "回复 \(replyingToName)" }
      return "回复楼中楼"
    }
  }

  var placeholder: String {
    switch kind {
    case .thread:
      return "写下对主题的回复"
    case .post:
      return "写下对本楼的回复"
    case .subpost:
      return replyingToName.map { "回复 \($0)" } ?? "写下回复"
    }
  }
}

enum TextReplyVisibilityProof {
  static func exactPlainText(
    from contents: [BrowseContent],
    matching expectedContent: String,
    allowsMentions: Bool = true
  ) -> String? {
    guard
      TextReplyContentPolicy.isValid(expectedContent),
      let expectedTokens = TiebaClassicEmoticonTokenizer.submissionProofTokens(
        in: expectedContent
      ),
      let observedTokens = contentTokens(from: contents, allowsMentions: allowsMentions),
      observedTokens == expectedTokens
    else { return nil }
    return expectedContent
  }

  private static func contentTokens(
    from contents: [BrowseContent],
    allowsMentions: Bool
  ) -> [[UInt8]]? {
    var result = [[UInt8]]()
    for content in contents {
      switch content {
      case .text(let fragment):
        appendTextToken(fragment, to: &result)
      case .emoticon(let name, _):
        guard TiebaClassicEmoticonCatalog.token(for: name) != nil else { return nil }
        result.append([UInt8(1)] + Array(name.utf8))
      case .mention(let name, _) where allowsMentions:
        appendTextToken(name.hasPrefix("@") ? name : "@\(name)", to: &result)
      case .mention:
        return nil
      case .link, .image, .video, .voice, .unsupported:
        return nil
      }
    }
    return result
  }

  static func exactNestedReplyBody(
    from comment: BrowseComment,
    expectedReplyToUserID: Int64,
    matching expectedContent: String
  ) -> String? {
    guard
      expectedReplyToUserID > 0,
      comment.replyToUserID == expectedReplyToUserID,
      comment.contents.count >= 3,
      case .text(let prefix) = comment.contents[0],
      prefix.utf8.elementsEqual("回复".utf8)
        || prefix.utf8.elementsEqual("回复 ".utf8),
      case .mention(let name, let userID) = comment.contents[1],
      !name.isEmpty,
      userID == expectedReplyToUserID
    else { return nil }

    var bodyContents = Array(comment.contents.dropFirst(2))
    guard case .text(var separatorAndText)? = bodyContents.first else { return nil }
    if separatorAndText.hasPrefix(" :") {
      separatorAndText.removeFirst(2)
    } else if separatorAndText.hasPrefix(":") {
      separatorAndText.removeFirst()
    } else { return nil }
    if separatorAndText.isEmpty {
      bodyContents.removeFirst()
    } else {
      bodyContents[0] = .text(separatorAndText)
    }
    return exactPlainText(
      from: bodyContents,
      matching: expectedContent,
      allowsMentions: false
    )
  }

  private static func appendTextToken(
    _ value: String,
    to tokens: inout [[UInt8]]
  ) {
    guard !value.isEmpty else { return }
    if tokens.last?.first == 0 {
      tokens[tokens.count - 1].append(contentsOf: value.utf8)
    } else {
      tokens.append([UInt8(0)] + Array(value.utf8))
    }
  }
}

struct TextReplyComposerPresentation: Equatable {
  enum ImageRecoveryAction: Equatable {
    case continueUpload
    case continuePublication

    var title: String {
      switch self {
      case .continueUpload: "继续上传"
      case .continuePublication: "继续发布"
      }
    }

    var accessibilityIdentifier: String {
      switch self {
      case .continueUpload: "continue-image-upload"
      case .continuePublication: "continue-image-publication"
      }
    }
  }

  struct Status: Equatable {
    enum Tint: Equatable {
      case secondary
      case warning
      case success
    }

    let message: String
    let systemImage: String
    let tintKind: Tint

    var tint: Color {
      switch tintKind {
      case .secondary:
        return .secondary
      case .warning:
        return .orange
      case .success:
        return .green
      }
    }
  }

  let allowsEditing: Bool
  let allowsSubmission: Bool
  let allowsVisibilityCheck: Bool
  let imageRecoveryAction: ImageRecoveryAction?
  let status: Status?

  init(state: TextReplySubmissionState) {
    switch state {
    case .inactive, .loading:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(message: "正在读取草稿…", systemImage: "clock", tintKind: .secondary)
    case .signedOut:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(
        message: TextReplySubmissionError.signedOut.localizedDescription,
        systemImage: "person.crop.circle.badge.exclamationmark",
        tintKind: .warning
      )
    case .ready:
      allowsEditing = true
      allowsSubmission = true
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = nil
    case .submitting:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(message: "正在发送回复…", systemImage: "paperplane", tintKind: .secondary)
    case .imageRecovery(let recoveryState):
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      switch recoveryState {
      case .uploadResumeRequired(_, let successfulUploadCount, let totalAttachmentCount):
        imageRecoveryAction = .continueUpload
        status = Status(
          message: "已安全记录 \(successfulUploadCount)/\(totalAttachmentCount) 张图片，等待您继续上传。",
          systemImage: "arrow.up.circle",
          tintKind: .warning
        )
      case .finalSubmissionResumeRequired:
        imageRecoveryAction = .continuePublication
        status = Status(
          message: "图片已上传，回复正文尚未发布。应用不会自动继续。",
          systemImage: "paperplane.circle",
          tintKind: .warning
        )
      case .locked(_, let operation):
        imageRecoveryAction = nil
        let message: String = switch operation {
        case .attachment:
          "一张图片的上传结果无法确认，草稿已锁定；应用不会自动重试。"
        case .finalSubmission:
          "回复发布请求的结果无法确认，草稿已锁定；请勿重复发送。"
        }
        status = Status(
          message: message,
          systemImage: "questionmark.circle",
          tintKind: .warning
        )
      case .completed:
        imageRecoveryAction = nil
        status = Status(
          message: "图片回复记录已完成，但本地状态无法安全收尾；应用不会自动操作。",
          systemImage: "exclamationmark.triangle",
          tintKind: .warning
        )
      }
    case .imageRecoveryUnavailable:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(
        message: "无法安全读取图片回复恢复记录。草稿已锁定，应用不会自动重试。",
        systemImage: "exclamationmark.triangle",
        tintKind: .warning
      )
    case .challengeRequired:
      allowsEditing = true
      allowsSubmission = false
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(
        message: TextReplySubmissionError.challengeRequired.localizedDescription,
        systemImage: "exclamationmark.shield",
        tintKind: .warning
      )
    case .outcomeUnknown:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(
        message: TextReplySubmissionError.outcomeUnknown.localizedDescription,
        systemImage: "questionmark.circle",
        tintKind: .warning
      )
    case .acceptedAwaitingVisibility:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = true
      imageRecoveryAction = nil
      status = Status(
        message: "贴吧已受理请求，但尚未确认回复可见。草稿已保留，请勿重复发送。",
        systemImage: "clock.badge.checkmark",
        tintKind: .warning
      )
    case .confirmed:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(message: "回复已确认。", systemImage: "checkmark.circle", tintKind: .success)
    case .failed(let error):
      allowsEditing = true
      allowsSubmission = Self.failureAllowsSubmission(error)
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(
        message: error.localizedDescription,
        systemImage: "exclamationmark.circle",
        tintKind: .warning
      )
    case .accountChanged:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(
        message: TextReplySubmissionError.accountChanged.localizedDescription,
        systemImage: "person.crop.circle.badge.exclamationmark",
        tintKind: .warning
      )
    }
  }

  private static func failureAllowsSubmission(_ error: TextReplySubmissionError) -> Bool {
    switch error {
    case .fullCredentialsRequired, .signedOut, .challengeRequired, .outcomeUnknown,
      .accountChanged, .submissionInProgress:
      return false
    case .invalidSubmission, .submissionConflict, .server, .unavailable:
      return true
    }
  }
}

enum ReplyComposerImagePolicy {
  static func allowsAttachments(for target: TextReplyTarget) -> Bool {
    if case .thread = target.destination { return true }
    return false
  }
}

enum ReplyComposerContentAdmissionPolicy {
  static func accepts(
    content: String,
    attachmentCount: Int,
    target: TextReplyTarget
  ) -> Bool {
    guard attachmentCount == 0 || ReplyComposerImagePolicy.allowsAttachments(for: target) else {
      return false
    }
    return TiebaStaticImageContentPolicy.canCompileWithinLimits(
      userContent: content,
      imageCount: attachmentCount,
      maximumCharacterCount: TextReplyContentPolicy.maximumCharacterCount,
      maximumUTF8ByteCount: TextReplyContentPolicy.maximumUTF8ByteCount
    )
  }
}

struct ReplyComposerAutosaveTaskID: Hashable {
  let text: String
  let attachments: [ComposerImageAttachment]
  let imageWatermark: TiebaStaticImageWatermark
  let shouldSave: Bool
}
