import Foundation
import SwiftUI

struct ReplyComposerView: View {
  @Environment(\.textReplySubmissionStore) private var submissionStore

  let context: TextReplyComposerContext
  let verifyVisibility:
    @MainActor (TextReplyReceipt, String) async throws -> TextReplyVisibilityConfirmation?
  let onConfirmed: @MainActor (CreatedTextReply) -> Void

  @State private var scopeID = UUID()

  var body: some View {
    Group {
      if let submissionStore {
        ReplyComposerContentView(
          entry: submissionStore.entry(for: context.target),
          context: context,
          store: submissionStore,
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
  @ObservedObject var entry: TextReplySubmissionEntry

  let context: TextReplyComposerContext
  let store: TextReplySubmissionStore
  let scopeID: UUID
  let verifyVisibility:
    @MainActor (TextReplyReceipt, String) async throws -> TextReplyVisibilityConfirmation?
  let onConfirmed: @MainActor (CreatedTextReply) -> Void

  @State private var text = ""
  @State private var textSelection = ComposerTextSelection.start
  @State private var didHydrateDraft = false
  @State private var pendingSubmission: TextReplySubmission?
  @State private var isDiscardConfirmationPresented = false
  @State private var isLaunchingSubmission = false
  @State private var isCheckingVisibility = false
  @State private var errorMessage: String?
  @State private var isEmoticonPickerPresented = false
  @State private var lifecycleGate = ReplyComposerLifecycleGate()
  @State private var entryRiskNoticeGate = ComposerEntryRiskNoticeGate()
  @State private var confirmationPreparationGate = SubmissionConfirmationPreparationGate()
  @AppStorage(AppPreferenceKey.showsPostAndReplyRiskNotice)
  private var showsPostAndReplyRiskNotice = AppPreferenceDefaults.showsPostAndReplyRiskNotice
  @State private var editorIsFocused = false

  var body: some View {
    VStack(spacing: 0) {
      editor

      Divider()

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
          }

          VStack(alignment: .leading, spacing: 10) {
            statusLabel(status)
            if presentation.allowsVisibilityCheck {
              visibilityCheckButton
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
        _ = try await store.saveDraft(text, for: context.target)
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
    .onChange(of: text) { value in
      if
        let pendingSubmission,
        !pendingSubmission.content.utf8.elementsEqual(value.utf8)
      {
        self.pendingSubmission = nil
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      confirmationPreparationGate.cancel()
      pendingSubmission = nil
      isEmoticonPickerPresented = false
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
      .disabled(isCheckingVisibility)
  }

  private var presentation: TextReplyComposerPresentation {
    TextReplyComposerPresentation(state: entry.state)
  }

  private var contentIsWithinLimits: Bool {
    text.count <= TextReplyContentPolicy.maximumCharacterCount
      && text.utf8.count <= TextReplyContentPolicy.maximumUTF8ByteCount
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
      && TextReplyContentPolicy.isValid(text)
      && !isLaunchingSubmission
      && !isCheckingVisibility
  }

  private var canDiscardDraft: Bool {
    didHydrateDraft
      && presentation.allowsEditing
      && entryRiskNoticeGate.isResolved
      && !text.isEmpty
      && !isLaunchingSubmission
      && !isCheckingVisibility
      && !confirmationPreparationGate.isPreparing
      && pendingSubmission == nil
  }

  private var editorAllowsEditing: Bool {
    presentation.allowsEditing
      && entryRiskNoticeGate.isResolved
      && !confirmationPreparationGate.isPreparing
      && pendingSubmission == nil
  }

  private var submissionConfirmationCopy: SubmissionConfirmationCopy {
    .reply
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
      shouldSave: didHydrateDraft
        && presentation.allowsEditing
        && entryRiskNoticeGate.isResolved
        && !confirmationPreparationGate.isPreparing
        && pendingSubmission == nil
        && !isLaunchingSubmission
        && !isCheckingVisibility
    )
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
      let expectedContent = entry.draft?.content
    else { return }
    isCheckingVisibility = true

    Task { @MainActor in
      defer { isCheckingVisibility = false }
      do {
        guard let confirmation = try await verifyVisibility(receipt, expectedContent) else {
          errorMessage = "贴吧返回的内容仍不足以确认这条回复；草稿会继续保留，请勿重复发送。"
          return
        }
        let result = try await store.confirmVisibility(
          confirmation,
          matching: receipt,
          for: context.target
        )
        guard case .confirmed(let created) = result.outcome else {
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

  private func discardDraft() {
    guard canDiscardDraft else { return }
    Task { @MainActor in
      do {
        try await store.discardDraft(for: context.target)
        text = ""
        textSelection = .start
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
      result.text.count <= TextReplyContentPolicy.maximumCharacterCount,
      result.text.utf8.count <= TextReplyContentPolicy.maximumUTF8ByteCount
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
    let capturedText = text
    let shouldSave = didHydrateDraft && presentation.allowsEditing
    Task { @MainActor in
      if shouldSave {
        _ = try? await store.saveDraft(capturedText, for: context.target)
      }
      // A cancelled interactive pop starts a new lifecycle before this save can finish.
      guard lifecycleGate.isCurrent(disappearingLifecycleID) else { return }
      store.deactivate(scopeID)
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
      let expectedTokens = TiebaClassicEmoticonTokenizer.submissionTokens(
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
  ) -> [TiebaClassicEmoticonContentToken]? {
    var result = [TiebaClassicEmoticonContentToken]()
    for content in contents {
      switch content {
      case .text(let fragment):
        appendTextToken(fragment, to: &result)
      case .emoticon(let name, _):
        guard TiebaClassicEmoticonCatalog.token(for: name) != nil else { return nil }
        result.append(.emoticon(name))
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
    to tokens: inout [TiebaClassicEmoticonContentToken]
  ) {
    guard !value.isEmpty else { return }
    if case .text(let previous)? = tokens.last {
      tokens[tokens.count - 1] = .text(previous + value)
    } else {
      tokens.append(.text(value))
    }
  }
}

struct TextReplyComposerPresentation: Equatable {
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
  let status: Status?

  init(state: TextReplySubmissionState) {
    switch state {
    case .inactive, .loading:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      status = Status(message: "正在读取草稿…", systemImage: "clock", tintKind: .secondary)
    case .signedOut:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      status = Status(
        message: TextReplySubmissionError.signedOut.localizedDescription,
        systemImage: "person.crop.circle.badge.exclamationmark",
        tintKind: .warning
      )
    case .ready:
      allowsEditing = true
      allowsSubmission = true
      allowsVisibilityCheck = false
      status = nil
    case .submitting:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      status = Status(message: "正在发送回复…", systemImage: "paperplane", tintKind: .secondary)
    case .challengeRequired:
      allowsEditing = true
      allowsSubmission = false
      allowsVisibilityCheck = false
      status = Status(
        message: TextReplySubmissionError.challengeRequired.localizedDescription,
        systemImage: "exclamationmark.shield",
        tintKind: .warning
      )
    case .outcomeUnknown:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      status = Status(
        message: TextReplySubmissionError.outcomeUnknown.localizedDescription,
        systemImage: "questionmark.circle",
        tintKind: .warning
      )
    case .acceptedAwaitingVisibility:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = true
      status = Status(
        message: "贴吧已受理请求，但尚未确认回复可见。草稿已保留，请勿重复发送。",
        systemImage: "clock.badge.checkmark",
        tintKind: .warning
      )
    case .confirmed:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      status = Status(message: "回复已确认。", systemImage: "checkmark.circle", tintKind: .success)
    case .failed(let error):
      allowsEditing = true
      allowsSubmission = Self.failureAllowsSubmission(error)
      allowsVisibilityCheck = false
      status = Status(
        message: error.localizedDescription,
        systemImage: "exclamationmark.circle",
        tintKind: .warning
      )
    case .accountChanged:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
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

private struct ReplyComposerAutosaveTaskID: Hashable {
  let text: String
  let shouldSave: Bool
}
