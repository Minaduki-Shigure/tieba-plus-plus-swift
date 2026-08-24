import Foundation
import SwiftUI
import TiebaCore

struct NewThreadComposerView: View {
  @Environment(\.newThreadSubmissionStore) private var submissionStore
  @Environment(\.composerImageAttachmentStore) private var attachmentStore

  let target: NewThreadTarget
  let onConfirmed: @MainActor (NewThreadReceipt, String?, String) -> Void

  @State private var scopeID = UUID()

  var body: some View {
    Group {
      if let submissionStore {
        NewThreadComposerContentView(
          entry: submissionStore.entry(for: target),
          target: target,
          store: submissionStore,
          attachmentStore: attachmentStore,
          scopeID: scopeID,
          onConfirmed: onConfirmed
        )
      } else {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle")
            .font(.title2)
            .foregroundStyle(.secondary)
          Text("发帖服务不可用")
            .font(.headline)
          Text("当前运行环境未提供安全的账户发送服务。")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding(24)
      }
    }
    .navigationTitle("发布主题")
    .navigationBarTitleDisplayMode(.inline)
  }
}

private struct NewThreadComposerContentView: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var entry: NewThreadSubmissionEntry

  let target: NewThreadTarget
  let store: NewThreadSubmissionStore
  let attachmentStore: ComposerImageAttachmentStore?
  let scopeID: UUID
  let onConfirmed: @MainActor (NewThreadReceipt, String?, String) -> Void

  @State private var title = ""
  @State private var content = ""
  @State private var attachments: [ComposerImageAttachment] = []
  @State private var imageQuality = ComposerImageAttachmentQuality.standard
  @State private var imageWatermark = TiebaStaticImageWatermark.forumName
  @State private var contentSelection = ComposerTextSelection.start
  @State private var didHydrateDraft = false
  @State private var pendingSubmission: NewThreadSubmission?
  @State private var isDiscardConfirmationPresented = false
  @State private var isConfirmedResetConfirmationPresented = false
  @State private var isLaunchingSubmission = false
  @State private var isCheckingVisibility = false
  @State private var isImportingImages = false
  @State private var imageImportCancellationController =
    ComposerImageImportCancellationController()
  @State private var imageCleanupCandidates = ComposerImageCleanupCandidates()
  @State private var attachmentOwnerUserID: Int64?
  @State private var errorMessage: String?
  @State private var isEmoticonPickerPresented = false
  @State private var pendingConfirmedReceipt: NewThreadReceipt?
  @State private var deliveredReceipt: NewThreadReceipt?
  @State private var lifecycleGate = ReplyComposerLifecycleGate()
  @State private var entryRiskNoticeGate = ComposerEntryRiskNoticeGate()
  @State private var confirmationPreparationGate = SubmissionConfirmationPreparationGate()
  @AppStorage(AppPreferenceKey.showsPostAndReplyRiskNotice)
  private var showsPostAndReplyRiskNotice = AppPreferenceDefaults.showsPostAndReplyRiskNotice
  @AppStorage(AppPreferenceKey.defaultImageWatermark)
  private var defaultImageWatermark = ComposerImageWatermarkPreference.defaultValue.rawValue
  @FocusState private var focusedField: FocusedField?

  private enum FocusedField: Hashable {
    case title
    case content
  }

  var body: some View {
    VStack(spacing: 0) {
      TextField("标题（可选）", text: $title, axis: .vertical)
        .focused($focusedField, equals: .title)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .lineLimit(1)
        .disabled(!editorAllowsEditing)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("new-thread-title")
        .onChange(of: title) { value in
          if value.count > NewThreadTitlePolicy.maximumCharacterCount {
            title = String(value.prefix(NewThreadTitlePolicy.maximumCharacterCount))
          }
          invalidatePendingSubmissionIfNeeded(
            title: value,
            content: content,
            attachments: attachments,
            imageWatermark: imageWatermark
          )
        }

      HStack {
        Spacer(minLength: 0)
        Text(titleCountLabel)
          .font(.caption.monospacedDigit())
          .foregroundStyle(titleIsWithinLimits ? Color.secondary : Color.red)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 9)

      Divider()

      ZStack(alignment: .topLeading) {
        if content.isEmpty {
          Text("写下主题正文")
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .allowsHitTesting(false)
        }

        ComposerTextEditor(
          text: $content,
          selection: $contentSelection,
          isFocused: contentEditorIsFocused,
          isEditable: editorAllowsEditing,
          accessibilityLabel: "主题正文",
          accessibilityIdentifier: "new-thread-content"
        )
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .onTapGesture {
        if editorAllowsEditing { focusedField = .content }
      }
      .onChange(of: content) { value in
        invalidatePendingSubmissionIfNeeded(
          title: title,
          content: value,
          attachments: attachments,
          imageWatermark: imageWatermark
        )
      }

      Divider()

      if let attachmentStore,
        didHydrateDraft,
        !presentation.allowsStartingNewThread,
        presentation.allowsEditing || !attachments.isEmpty
      {
        ComposerImagePickerView(
          attachments: $attachments,
          quality: $imageQuality,
          watermark: $imageWatermark,
          attachmentStore: attachmentStore,
          importCancellationController: imageImportCancellationController,
          isEnabled: editorAllowsEditing && attachmentOwnerUserID != nil,
          importIsBusy: $isImportingImages,
          errorMessage: $errorMessage,
          onAttachmentImported: { attachment in
            if let attachmentOwnerUserID {
              imageCleanupCandidates.observe(attachment, userID: attachmentOwnerUserID)
            }
          },
          onAttachmentRemovalRequested: { removedAttachment, remainingAttachments in
            guard let attachmentOwnerUserID else {
              throw NewThreadSubmissionError.unavailable
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
                  title: title,
                  content: content,
                  attachments: remainingAttachments,
                  imageWatermark: imageWatermark,
                  for: target,
                  at: Date()
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
                  for: target
                )
              }
            )
          }
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: attachments) { value in
          invalidatePendingSubmissionIfNeeded(
            title: title,
            content: content,
            attachments: value,
            imageWatermark: imageWatermark
          )
        }
        .onChange(of: imageWatermark) { value in
          invalidatePendingSubmissionIfNeeded(
            title: title,
            content: content,
            attachments: attachments,
            imageWatermark: value
          )
        }

        Divider()
      }

      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(contentCharacterCountLabel)
          Spacer(minLength: 0)
          Text(contentByteCountLabel)
        }

        VStack(alignment: .leading, spacing: 3) {
          Text(contentCharacterCountLabel)
          Text(contentByteCountLabel)
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
            if presentation.allowsStartingNewThread {
              openConfirmedThreadButton
              startNewThreadButton
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
            if presentation.allowsStartingNewThread {
              openConfirmedThreadButton
              startNewThreadButton
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
          focusedField = nil
          isEmoticonPickerPresented = true
        } label: {
          Image(systemName: "face.smiling")
        }
        .disabled(!editorAllowsEditing)
        .accessibilityLabel("插入经典表情")
        .help("插入经典表情")
        .accessibilityIdentifier("new-thread-emoticon")

        Button {
          isDiscardConfirmationPresented = true
        } label: {
          Image(systemName: "trash")
        }
        .disabled(!canDiscardDraft)
        .accessibilityLabel("丢弃发帖草稿")
        .help("丢弃发帖草稿")

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
        .accessibilityLabel("发布主题")
        .help("发布主题")
        .accessibilityIdentifier("new-thread-publish")
      }

      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("完成") { focusedField = nil }
      }
    }
    .confirmationDialog(
      ComposerEntryRiskNoticeCopy.standard.title,
      isPresented: entryRiskNoticeIsPresented,
      titleVisibility: .visible
    ) {
      Button(ComposerEntryRiskNoticeCopy.standard.continueTitle) {
        continueAfterEntryRiskNotice()
      }
      Button(ComposerEntryRiskNoticeCopy.standard.leaveTitle, role: .cancel) {
        leaveFromEntryRiskNotice()
      }
    } message: {
      Text(ComposerEntryRiskNoticeCopy.standard.message)
    }
    .confirmationDialog(
      submissionConfirmationCopy.title,
      isPresented: submissionConfirmationIsPresented,
      titleVisibility: .visible,
      presenting: pendingSubmission
    ) { submission in
      Button(submissionConfirmationCopy.actionTitle) { publishConfirmed(submission) }
      Button("取消", role: .cancel) { pendingSubmission = nil }
    } message: { _ in
      Text(submissionConfirmationCopy.message)
    }
    .confirmationDialog(
      "丢弃发帖草稿？",
      isPresented: $isDiscardConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("丢弃", role: .destructive) { discardDraft() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("此操作会删除当前账户在这个贴吧保存的发帖草稿。")
    }
    .confirmationDialog(
      "开始新的主题？",
      isPresented: $isConfirmedResetConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("开始新主题", role: .destructive) { startNewThreadConfirmed() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("这会清除上一个已确认主题的本地记录和正文，但不会删除贴吧中的主题。")
    }
    .alert("无法完成发帖操作", isPresented: errorIsPresented) {
      Button("好", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "发帖操作失败。")
    }
    .sheet(isPresented: $isEmoticonPickerPresented, onDismiss: restoreContentEditorFocus) {
      ClassicEmoticonPicker(onSelect: insertClassicEmoticon)
        .presentationDetents([.medium, .large])
    }
    .task {
      let currentLifecycleID = lifecycleGate.beginAppearance()
      deliverPendingConfirmedThreadIfActive()
      guard deliveredReceipt == nil else { return }
      await store.activate(target, for: scopeID)
      guard lifecycleGate.isCurrent(currentLifecycleID) else { return }
      let activatedOwnerUserID = store.draftOwnerUserID(for: target)
      if let attachmentOwnerUserID, activatedOwnerUserID != attachmentOwnerUserID {
        imageImportCancellationController.cancel()
        confirmationPreparationGate.cancel()
        pendingSubmission = nil
        isEmoticonPickerPresented = false
        didHydrateDraft = false
        title = ""
        content = ""
        attachments = []
        imageQuality = .standard
        imageWatermark = preferredImageWatermark
        contentSelection = .start
        pendingConfirmedReceipt = nil
        deliveredReceipt = nil
        _ = lifecycleGate.scheduleDeactivation()
        await cleanAllImageCandidatesNow()
        store.deactivate(scopeID)
        dismiss()
        return
      }
      attachmentOwnerUserID = activatedOwnerUserID
      hydrateDraftIfNeeded()
      deliverPendingConfirmedThreadIfActive()
      guard deliveredReceipt == nil else { return }
      resolveEntryRiskNoticeIfNeeded()
      if editorAllowsEditing {
        focusedField = title.isEmpty ? .title : .content
      }
    }
    .task(id: autosaveTaskID) {
      guard autosaveTaskID.shouldSave else { return }
      do {
        try await Task.sleep(nanoseconds: 450_000_000)
        try Task.checkCancellation()
        let draft = try await store.saveDraft(
          title: title,
          content: content,
          attachments: attachments,
          imageWatermark: imageWatermark,
          for: target,
          at: Date()
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
      }
      resolveEntryRiskNoticeIfNeeded()
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
      pendingSubmission = nil
      isEmoticonPickerPresented = false
      didHydrateDraft = false
      attachmentOwnerUserID = nil
      title = ""
      content = ""
      attachments = []
      imageQuality = .standard
      imageWatermark = preferredImageWatermark
      contentSelection = .start
      pendingConfirmedReceipt = nil
      deliveredReceipt = nil
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

  private func statusLabel(_ status: NewThreadComposerPresentation.Status) -> some View {
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
      .disabled(isCheckingVisibility)
  }

  private func imageRecoveryButton(
    _ action: NewThreadComposerPresentation.ImageRecoveryAction
  ) -> some View {
    Button(action.title, action: resumeImageSubmission)
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .disabled(isLaunchingSubmission || isCheckingVisibility || isImportingImages)
      .accessibilityIdentifier("new-thread-\(action.accessibilityIdentifier)")
  }

  private var startNewThreadButton: some View {
    Button("开始新主题") {
      isConfirmedResetConfirmationPresented = true
    }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityIdentifier("new-thread-reset-confirmed")
  }

  private var openConfirmedThreadButton: some View {
    Button("打开主题", action: openConfirmedThread)
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(!didHydrateDraft)
      .accessibilityIdentifier("new-thread-open-confirmed")
  }

  private var presentation: NewThreadComposerPresentation {
    NewThreadComposerPresentation(state: entry.state)
  }

  private var contentEditorIsFocused: Binding<Bool> {
    Binding(
      get: { focusedField == .content },
      set: { isFocused in
        if isFocused {
          focusedField = .content
        } else if focusedField == .content {
          focusedField = nil
        }
      }
    )
  }

  private var titleIsWithinLimits: Bool {
    NewThreadTitlePolicy.isValid(title)
  }

  private var contentIsWithinLimits: Bool {
    NewThreadComposerContentAdmissionPolicy.accepts(
      content: content,
      attachmentCount: attachments.count
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
      && NewThreadTitlePolicy.isValid(title)
      && contentIsWithinLimits
      && !isLaunchingSubmission
      && !isCheckingVisibility
      && !isImportingImages
  }

  private var canDiscardDraft: Bool {
    didHydrateDraft
      && presentation.allowsEditing
      && entryRiskNoticeGate.isResolved
      && (!title.isEmpty || !content.isEmpty || !attachments.isEmpty)
      && !isLaunchingSubmission
      && !isCheckingVisibility
      && !isImportingImages
      && !confirmationPreparationGate.isPreparing
      && pendingSubmission == nil
  }

  private var editorAllowsEditing: Bool {
    presentation.allowsEditing
      && entryRiskNoticeGate.isResolved
      && !confirmationPreparationGate.isPreparing
      && pendingSubmission == nil
      && !isImportingImages
  }

  private var submissionConfirmationCopy: SubmissionConfirmationCopy {
    .newThread
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

  private var titleCountLabel: String {
    "\(title.count.formatted()) / \(NewThreadTitlePolicy.maximumCharacterCount.formatted()) 字 · "
      + "\(title.utf8.count.formatted()) / "
      + "\(NewThreadTitlePolicy.maximumUTF8ByteCount.formatted()) B"
  }

  private var contentCharacterCountLabel: String {
    "\(content.count.formatted()) / \(NewThreadContentPolicy.maximumCharacterCount.formatted()) 字"
  }

  private var contentByteCountLabel: String {
    "\(content.utf8.count.formatted()) / "
      + "\(NewThreadContentPolicy.maximumUTF8ByteCount.formatted()) B"
  }

  private var autosaveTaskID: NewThreadComposerAutosaveTaskID {
    NewThreadComposerAutosaveTaskID(
      title: title,
      content: content,
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
      title = entry.draft?.title ?? ""
      content = entry.draft?.content ?? ""
      attachments = entry.draft?.attachments ?? []
      imageQuality = entry.draft?.attachments.last?.quality ?? .standard
      imageWatermark = ComposerImageWatermarkPolicy.initialValue(
        preference: ComposerImageWatermarkPreference.resolved(defaultImageWatermark),
        hasImageDraft: !attachments.isEmpty,
        draftWatermark: entry.draft?.imageWatermark
      )
      contentSelection = ComposerTextSelection(location: content.utf16.count, length: 0)
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
    focusedField = nil

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
        let submission = SubmissionConfirmationPolicy.newThreadSnapshot(
          id: preparationID,
          target: target,
          title: title,
          content: content,
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
    title: String?,
    content: String,
    attachments: [ComposerImageAttachment],
    imageWatermark: TiebaStaticImageWatermark
  ) {
    guard let pendingSubmission else { return }
    if !SubmissionConfirmationPolicy.newThreadSnapshotIsCurrent(
      pendingSubmission,
      target: target,
      title: title,
      content: content,
      attachments: attachments,
      imageWatermark: imageWatermark,
      submissionAllowed: submissionIsAllowed
    ) {
      self.pendingSubmission = nil
    }
  }

  private func publishConfirmed(_ submission: NewThreadSubmission) {
    guard
      lifecycleGate.isActive,
      let submission = SubmissionConfirmationPolicy.consume(
        submission,
        pending: &pendingSubmission
      )
    else { return }
    guard
      SubmissionConfirmationPolicy.newThreadSnapshotIsCurrent(
        submission,
        target: target,
        title: title,
        content: content,
        attachments: attachments,
        imageWatermark: imageWatermark,
        submissionAllowed: submissionIsAllowed
      )
    else { return }
    isLaunchingSubmission = true
    focusedField = nil

    Task { @MainActor in
      defer { isLaunchingSubmission = false }
      do {
        let result = try await store.submit(
          title: submission.title,
          content: submission.content,
          attachments: submission.attachments,
          imageWatermark: submission.imageWatermark,
          for: submission.target,
          submissionID: submission.id
        )
        guard result.submissionID == submission.id, result.target == submission.target else {
          throw NewThreadSubmissionError.submissionConflict
        }
        if case .confirmed(let receipt) = result.outcome {
          pendingConfirmedReceipt = receipt
          deliverPendingConfirmedThreadIfActive(
            title: submission.title ?? "",
            content: submission.content
          )
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
      focusedField = title.isEmpty ? .title : .content
    }
  }

  private func leaveFromEntryRiskNotice() {
    entryRiskNoticeGate.resolve()
    focusedField = nil
    dismiss()
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
    let expectedSubmissionID: UUID
    switch draft.disposition {
    case .acceptedAwaitingVisibility(let submissionID, let draftReceipt):
      guard draftReceipt == receipt else { return }
      expectedSubmissionID = submissionID
    case .imageAcceptedAwaitingVisibility(let reference, let draftReceipt):
      guard draftReceipt == receipt else { return }
      expectedSubmissionID = reference.submissionID
    default:
      return
    }
    let expectedTitle = draft.title
    let expectedContent = draft.content
    isCheckingVisibility = true

    Task { @MainActor in
      defer { isCheckingVisibility = false }
      do {
        guard let result = try await store.verifyVisibility(for: target) else {
          errorMessage = "贴吧返回的内容仍不足以确认这个主题；草稿会继续保留，请勿重复发布。"
          return
        }
        guard
          result.target == target,
          result.submissionID == expectedSubmissionID,
          case .confirmed(let confirmedReceipt) = result.outcome,
          confirmedReceipt == receipt
        else {
          throw NewThreadSubmissionError.outcomeUnknown
        }
        pendingConfirmedReceipt = confirmedReceipt
        deliverPendingConfirmedThreadIfActive(
          title: expectedTitle ?? "",
          content: expectedContent
        )
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
      !isLaunchingSubmission,
      !isCheckingVisibility,
      !isImportingImages,
      let draft = entry.draft,
      case .imageRecovery(let recoveryState) = entry.state
    else { return }
    let expectedSubmissionID = recoveryState.reference.submissionID
    let expectedTitle = draft.title
    let expectedContent = draft.content
    isLaunchingSubmission = true
    focusedField = nil

    Task { @MainActor in
      defer { isLaunchingSubmission = false }
      do {
        let result = try await store.resumeImageSubmission(for: target)
        guard
          result.target == target,
          result.submissionID == expectedSubmissionID
        else {
          throw NewThreadSubmissionError.submissionConflict
        }
        if case .confirmed(let receipt) = result.outcome {
          pendingConfirmedReceipt = receipt
          deliverPendingConfirmedThreadIfActive(
            title: expectedTitle ?? "",
            content: expectedContent
          )
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
        try await store.discardDraft(for: target)
        title = ""
        content = ""
        attachments = []
        imageQuality = .standard
        imageWatermark = preferredImageWatermark
        contentSelection = .start
        if let attachmentOwnerUserID {
          await ComposerImageRemovalCoordinator.cleanCandidatesBestEffort(
            discardedAttachments,
            cleanCandidates: { candidates in
              await store.removeUnreferencedAttachments(
                candidates,
                userID: attachmentOwnerUserID,
                for: target
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

  private func startNewThreadConfirmed() {
    guard case .confirmed = entry.state else { return }
    let discardedAttachments = attachments
    let attachmentOwnerUserID = attachmentOwnerUserID
    if let attachmentOwnerUserID {
      for attachment in discardedAttachments {
        imageCleanupCandidates.observe(attachment, userID: attachmentOwnerUserID)
      }
    }
    Task { @MainActor in
      do {
        try await store.discardDraft(for: target)
        title = ""
        content = ""
        attachments = []
        imageQuality = .standard
        imageWatermark = preferredImageWatermark
        contentSelection = .start
        pendingConfirmedReceipt = nil
        deliveredReceipt = nil
        focusedField = .title
        if let attachmentOwnerUserID {
          await ComposerImageRemovalCoordinator.cleanCandidatesBestEffort(
            discardedAttachments,
            cleanCandidates: { candidates in
              await store.removeUnreferencedAttachments(
                candidates,
                userID: attachmentOwnerUserID,
                for: target
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

  private func openConfirmedThread() {
    guard case .confirmed(let receipt) = entry.state, didHydrateDraft else { return }
    pendingConfirmedReceipt = receipt
    deliverPendingConfirmedThreadIfActive()
  }

  private func insertClassicEmoticon(_ token: String) {
    guard
      editorAllowsEditing,
      let result = ComposerTextInsertionPolicy.replacingSelection(
        in: content,
        selection: contentSelection,
        with: token
      ),
      NewThreadComposerContentAdmissionPolicy.accepts(
        content: result.text,
        attachmentCount: attachments.count
      )
    else { return }
    content = result.text
    contentSelection = result.selection
  }

  private func restoreContentEditorFocus() {
    if editorAllowsEditing {
      focusedField = .content
    }
  }

  private func persistAndDeactivate() {
    guard let disappearingLifecycleID = lifecycleGate.scheduleDeactivation() else { return }
    imageImportCancellationController.cancel()
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
            title: title,
            content: content,
            attachments: attachments,
            imageWatermark: imageWatermark,
            for: target,
            at: Date()
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
        for: target
      )
    }
  }

  private func cleanAllImageCandidatesNow() async {
    for userID in imageCleanupCandidates.userIDs {
      await store.removeUnreferencedAttachments(
        imageCleanupCandidates.attachments(for: userID),
        userID: userID,
        for: target
      )
    }
  }

  private func deliverPendingConfirmedThreadIfActive() {
    deliverPendingConfirmedThreadIfActive(title: title, content: content)
  }

  private func deliverPendingConfirmedThreadIfActive(
    title: String,
    content: String
  ) {
    guard
      let receipt = pendingConfirmedReceipt,
      lifecycleGate.isActive,
      deliveredReceipt != receipt
    else { return }
    deliveredReceipt = receipt
    pendingConfirmedReceipt = nil
    onConfirmed(receipt, NewThreadTitlePolicy.normalized(title), content)
  }
}

struct NewThreadComposerAutosaveTaskID: Hashable {
  let title: String
  let content: String
  let attachments: [ComposerImageAttachment]
  let imageWatermark: TiebaStaticImageWatermark
  let shouldSave: Bool
}

enum NewThreadComposerContentAdmissionPolicy {
  static func accepts(content: String, attachmentCount: Int) -> Bool {
    TiebaStaticImageContentPolicy.canCompileWithinLimits(
      userContent: content,
      imageCount: attachmentCount,
      maximumCharacterCount: NewThreadContentPolicy.maximumCharacterCount,
      maximumUTF8ByteCount: NewThreadContentPolicy.maximumUTF8ByteCount
    )
  }
}

struct NewThreadComposerPresentation: Equatable {
  enum ImageRecoveryAction: Equatable {
    case continueUpload
    case continuePublication

    var title: String {
      switch self {
      case .continueUpload:
        "继续上传"
      case .continuePublication:
        "继续发布"
      }
    }

    var accessibilityIdentifier: String {
      switch self {
      case .continueUpload:
        "continue-image-upload"
      case .continuePublication:
        "continue-image-publication"
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
      case .secondary: .secondary
      case .warning: .orange
      case .success: .green
      }
    }
  }

  let allowsEditing: Bool
  let allowsSubmission: Bool
  let allowsVisibilityCheck: Bool
  let allowsStartingNewThread: Bool
  let imageRecoveryAction: ImageRecoveryAction?
  let status: Status?

  init(state: NewThreadSubmissionState) {
    if case .confirmed = state {
      allowsStartingNewThread = true
    } else {
      allowsStartingNewThread = false
    }
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
        message: NewThreadSubmissionError.signedOut.localizedDescription,
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
      status = Status(message: "正在发布主题…", systemImage: "paperplane", tintKind: .secondary)
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
          message: "图片已上传，主题正文尚未发布。应用不会自动继续。",
          systemImage: "paperplane.circle",
          tintKind: .warning
        )
      case .locked(_, let operation):
        imageRecoveryAction = nil
        let message: String = switch operation {
        case .attachment:
          "一张图片的上传结果无法确认，草稿已锁定；应用不会自动重试。"
        case .finalSubmission:
          "主题发布请求的结果无法确认，草稿已锁定；请勿重复发布。"
        }
        status = Status(
          message: message,
          systemImage: "questionmark.circle",
          tintKind: .warning
        )
      case .completed:
        imageRecoveryAction = nil
        status = Status(
          message: "图片发布记录已完成，但本地状态无法安全收尾；应用不会自动操作。",
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
        message: "无法安全读取图片发布恢复记录。草稿已锁定，应用不会自动重试。",
        systemImage: "exclamationmark.triangle",
        tintKind: .warning
      )
    case .challengeRequired:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(
        message: NewThreadSubmissionError.challengeRequired.localizedDescription,
        systemImage: "exclamationmark.shield",
        tintKind: .warning
      )
    case .outcomeUnknown:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(
        message: NewThreadSubmissionError.outcomeUnknown.localizedDescription,
        systemImage: "questionmark.circle",
        tintKind: .warning
      )
    case .acceptedAwaitingVisibility:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = true
      imageRecoveryAction = nil
      status = Status(
        message: "贴吧已受理请求，但尚未确认主题可见。草稿已保留，请勿重复发布。",
        systemImage: "clock.badge.checkmark",
        tintKind: .warning
      )
    case .confirmed:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      imageRecoveryAction = nil
      status = Status(
        message: "上一个主题已确认。可以打开它，或清除确认记录后开始新主题。",
        systemImage: "checkmark.circle",
        tintKind: .success
      )
    case .failed(let error):
      allowsEditing = true
      allowsSubmission = error != .fullCredentialsRequired
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
        message: NewThreadSubmissionError.accountChanged.localizedDescription,
        systemImage: "person.crop.circle.badge.exclamationmark",
        tintKind: .warning
      )
    }
  }
}
