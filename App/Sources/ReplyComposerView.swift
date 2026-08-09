import Foundation
import SwiftUI

struct ReplyComposerView: View {
  @Environment(\.textReplySubmissionStore) private var submissionStore

  let context: TextReplyComposerContext
  let verifyVisibility:
    @MainActor (TextReplyReceipt) async throws -> TextReplyVisibilityConfirmation?
  let onConfirmed: @MainActor (CreatedTextReply) -> Void

  @State private var scopeID = UUID()

  var body: some View {
    Group {
      if let submissionStore {
        ReplyComposerContentView(
          context: context,
          store: submissionStore,
          entry: submissionStore.entry(for: context.target),
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
    @MainActor (TextReplyReceipt) async throws -> TextReplyVisibilityConfirmation?
  let onConfirmed: @MainActor (CreatedTextReply) -> Void

  @State private var text = ""
  @State private var didHydrateDraft = false
  @State private var isSendConfirmationPresented = false
  @State private var isDiscardConfirmationPresented = false
  @State private var isLaunchingSubmission = false
  @State private var isCheckingVisibility = false
  @State private var errorMessage: String?
  @State private var lifecycleGate = ReplyComposerLifecycleGate()
  @FocusState private var editorIsFocused: Bool

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
          isDiscardConfirmationPresented = true
        } label: {
          Image(systemName: "trash")
        }
        .disabled(!canDiscardDraft)
        .accessibilityLabel("丢弃草稿")
        .help("丢弃草稿")

        Button {
          isSendConfirmationPresented = true
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
      "发送这条回复？",
      isPresented: $isSendConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("发送") { submitConfirmed() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("回复会立即提交到贴吧。网络中断时结果可能无法确定；为避免重复回复，应用不会自动重发。")
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
    .task {
      let currentLifecycleID = lifecycleGate.beginAppearance()
      await store.activate(context.target, for: scopeID)
      guard lifecycleGate.isCurrent(currentLifecycleID) else { return }
      hydrateDraftIfNeeded()
      if presentation.allowsEditing {
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

      TextEditor(text: $text)
        .focused($editorIsFocused)
        .scrollContentBackground(.hidden)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .disabled(!presentation.allowsEditing)
        .accessibilityLabel(context.composerTitle)
        .accessibilityIdentifier("reply-composer-editor")
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .onTapGesture { editorIsFocused = presentation.allowsEditing }
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
      && !isSendConfirmationPresented
  }

  private var submissionIsAllowed: Bool {
    didHydrateDraft
      && presentation.allowsSubmission
      && TextReplyContentPolicy.isValid(text)
      && !isLaunchingSubmission
      && !isCheckingVisibility
  }

  private var canDiscardDraft: Bool {
    didHydrateDraft
      && presentation.allowsEditing
      && !text.isEmpty
      && !isLaunchingSubmission
      && !isCheckingVisibility
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
      shouldSave: didHydrateDraft && presentation.allowsEditing
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
      didHydrateDraft = true
    }
  }

  private func submitConfirmed() {
    guard submissionIsAllowed else { return }
    isSendConfirmationPresented = false
    isLaunchingSubmission = true
    editorIsFocused = false
    let submissionID = UUID()
    let submittedText = text

    Task { @MainActor in
      defer { isLaunchingSubmission = false }
      do {
        let result = try await store.submit(
          submittedText,
          for: context.target,
          submissionID: submissionID
        )
        guard result.submissionID == submissionID, result.target == context.target else {
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

  private func checkVisibility() {
    guard
      !isCheckingVisibility,
      case .acceptedAwaitingVisibility(let receipt) = entry.state
    else { return }
    isCheckingVisibility = true

    Task { @MainActor in
      defer { isCheckingVisibility = false }
      do {
        guard let confirmation = try await verifyVisibility(receipt) else {
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
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
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
  static func exactPlainText(from contents: [BrowseContent]) -> String? {
    var result = ""
    for content in contents {
      guard case .text(let fragment) = content else { return nil }
      result.append(contentsOf: fragment)
    }
    return TextReplyContentPolicy.isValid(result) ? result : nil
  }

  static func exactNestedReplyBody(
    from comment: BrowseComment,
    expectedReplyToUserID: Int64
  ) -> String? {
    guard
      expectedReplyToUserID > 0,
      comment.replyToUserID == expectedReplyToUserID,
      comment.contents.count >= 3,
      case .text("回复 ") = comment.contents[0],
      case .mention(let name, let userID) = comment.contents[1],
      !name.isEmpty,
      userID == expectedReplyToUserID
    else { return nil }

    var suffix = ""
    for content in comment.contents.dropFirst(2) {
      guard case .text(let fragment) = content else { return nil }
      suffix.append(contentsOf: fragment)
    }
    if suffix.hasPrefix(" :") {
      suffix.removeFirst(2)
    } else if suffix.hasPrefix(":") {
      suffix.removeFirst()
    } else {
      return nil
    }
    return TextReplyContentPolicy.isValid(suffix) ? suffix : nil
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
