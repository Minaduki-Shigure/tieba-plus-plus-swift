import Foundation
import SwiftUI

struct NewThreadComposerView: View {
  @Environment(\.newThreadSubmissionStore) private var submissionStore

  let target: NewThreadTarget
  let verifyVisibility:
    @MainActor (NewThreadSubmission, NewThreadReceipt) async throws
      -> NewThreadVisibilityConfirmation?
  let onConfirmed: @MainActor (NewThreadReceipt, String?, String) -> Void

  @State private var scopeID = UUID()

  var body: some View {
    Group {
      if let submissionStore {
        NewThreadComposerContentView(
          entry: submissionStore.entry(for: target),
          target: target,
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
  @ObservedObject var entry: NewThreadSubmissionEntry

  let target: NewThreadTarget
  let store: NewThreadSubmissionStore
  let scopeID: UUID
  let verifyVisibility:
    @MainActor (NewThreadSubmission, NewThreadReceipt) async throws
      -> NewThreadVisibilityConfirmation?
  let onConfirmed: @MainActor (NewThreadReceipt, String?, String) -> Void

  @State private var title = ""
  @State private var content = ""
  @State private var didHydrateDraft = false
  @State private var isPublishConfirmationPresented = false
  @State private var isDiscardConfirmationPresented = false
  @State private var isConfirmedResetConfirmationPresented = false
  @State private var isLaunchingSubmission = false
  @State private var isCheckingVisibility = false
  @State private var errorMessage: String?
  @State private var pendingConfirmedReceipt: NewThreadReceipt?
  @State private var deliveredReceipt: NewThreadReceipt?
  @State private var lifecycleGate = ReplyComposerLifecycleGate()
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
        .disabled(!presentation.allowsEditing)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityIdentifier("new-thread-title")
        .onChange(of: title) { value in
          if value.count > NewThreadTitlePolicy.maximumCharacterCount {
            title = String(value.prefix(NewThreadTitlePolicy.maximumCharacterCount))
          }
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

        TextEditor(text: $content)
          .focused($focusedField, equals: .content)
          .scrollContentBackground(.hidden)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .disabled(!presentation.allowsEditing)
          .accessibilityLabel("主题正文")
          .accessibilityIdentifier("new-thread-content")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .onTapGesture {
        if presentation.allowsEditing { focusedField = .content }
      }

      Divider()

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
          isDiscardConfirmationPresented = true
        } label: {
          Image(systemName: "trash")
        }
        .disabled(!canDiscardDraft)
        .accessibilityLabel("丢弃发帖草稿")
        .help("丢弃发帖草稿")

        Button {
          isPublishConfirmationPresented = true
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
      "发布这个主题？",
      isPresented: $isPublishConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("发布") { publishConfirmed() }
      Button("取消", role: .cancel) {}
    } message: {
      Text("主题会立即提交到贴吧。网络中断时结果可能无法确定；为避免重复发帖，应用不会自动重发。")
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
    .task {
      let currentLifecycleID = lifecycleGate.beginAppearance()
      deliverPendingConfirmedThreadIfActive()
      guard deliveredReceipt == nil else { return }
      await store.activate(target, for: scopeID)
      guard lifecycleGate.isCurrent(currentLifecycleID) else { return }
      hydrateDraftIfNeeded()
      deliverPendingConfirmedThreadIfActive()
      guard deliveredReceipt == nil else { return }
      if presentation.allowsEditing {
        focusedField = title.isEmpty ? .title : .content
      }
    }
    .task(id: autosaveTaskID) {
      guard autosaveTaskID.shouldSave else { return }
      do {
        try await Task.sleep(nanoseconds: 450_000_000)
        try Task.checkCancellation()
        _ = try await store.saveDraft(
          title: title,
          content: content,
          for: target,
          at: Date()
        )
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

  private var titleIsWithinLimits: Bool {
    NewThreadTitlePolicy.isValid(title)
  }

  private var contentIsWithinLimits: Bool {
    content.count <= NewThreadContentPolicy.maximumCharacterCount
      && content.utf8.count <= NewThreadContentPolicy.maximumUTF8ByteCount
  }

  private var canRequestSubmission: Bool {
    submissionIsAllowed
      && !isPublishConfirmationPresented
  }

  private var submissionIsAllowed: Bool {
    didHydrateDraft
      && presentation.allowsSubmission
      && NewThreadTitlePolicy.isValid(title)
      && NewThreadContentPolicy.isValid(content)
      && !isLaunchingSubmission
      && !isCheckingVisibility
  }

  private var canDiscardDraft: Bool {
    didHydrateDraft
      && presentation.allowsEditing
      && (!title.isEmpty || !content.isEmpty)
      && !isLaunchingSubmission
      && !isCheckingVisibility
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
    "\(content.utf8.count.formatted()) / \(NewThreadContentPolicy.maximumUTF8ByteCount.formatted()) B"
  }

  private var autosaveTaskID: NewThreadComposerAutosaveTaskID {
    NewThreadComposerAutosaveTaskID(
      title: title,
      content: content,
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
      title = entry.draft?.title ?? ""
      content = entry.draft?.content ?? ""
      didHydrateDraft = true
    }
  }

  private func publishConfirmed() {
    isPublishConfirmationPresented = false
    guard submissionIsAllowed else { return }
    isLaunchingSubmission = true
    focusedField = nil
    let submissionID = UUID()
    let submittedTitle = title
    let submittedContent = content

    Task { @MainActor in
      defer { isLaunchingSubmission = false }
      do {
        let result = try await store.submit(
          title: submittedTitle,
          content: submittedContent,
          for: target,
          submissionID: submissionID
        )
        guard result.submissionID == submissionID, result.target == target else {
          throw NewThreadSubmissionError.submissionConflict
        }
        if case .confirmed(let receipt) = result.outcome {
          pendingConfirmedReceipt = receipt
          deliverPendingConfirmedThreadIfActive(
            title: submittedTitle,
            content: submittedContent
          )
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
      case .acceptedAwaitingVisibility(let receipt) = entry.state,
      let draft = entry.draft,
      case .acceptedAwaitingVisibility(let submissionID, let draftReceipt) = draft.disposition,
      draftReceipt == receipt,
      let submission = NewThreadSubmission(
        id: submissionID,
        target: target,
        title: draft.title,
        content: draft.content
      )
    else { return }
    isCheckingVisibility = true

    Task { @MainActor in
      defer { isCheckingVisibility = false }
      do {
        guard let confirmation = try await verifyVisibility(submission, receipt) else {
          errorMessage = "贴吧返回的内容仍不足以确认这个主题；草稿会继续保留，请勿重复发布。"
          return
        }
        let result = try await store.confirmVisibility(
          confirmation,
          matching: receipt,
          for: target
        )
        guard case .confirmed(let confirmedReceipt) = result.outcome else {
          throw NewThreadSubmissionError.outcomeUnknown
        }
        pendingConfirmedReceipt = confirmedReceipt
        deliverPendingConfirmedThreadIfActive(
          title: submission.title ?? "",
          content: submission.content
        )
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
        try await store.discardDraft(for: target)
        title = ""
        content = ""
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func startNewThreadConfirmed() {
    guard case .confirmed = entry.state else { return }
    Task { @MainActor in
      do {
        try await store.discardDraft(for: target)
        title = ""
        content = ""
        pendingConfirmedReceipt = nil
        deliveredReceipt = nil
        focusedField = .title
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

  private func persistAndDeactivate() {
    guard let disappearingLifecycleID = lifecycleGate.scheduleDeactivation() else { return }
    let capturedTitle = title
    let capturedContent = content
    let shouldSave = didHydrateDraft && presentation.allowsEditing
    Task { @MainActor in
      if shouldSave {
        _ = try? await store.saveDraft(
          title: capturedTitle,
          content: capturedContent,
          for: target,
          at: Date()
        )
      }
      guard lifecycleGate.isCurrent(disappearingLifecycleID) else { return }
      store.deactivate(scopeID)
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
  let shouldSave: Bool
}

struct NewThreadComposerPresentation: Equatable {
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
      status = Status(message: "正在读取草稿…", systemImage: "clock", tintKind: .secondary)
    case .signedOut:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      status = Status(
        message: NewThreadSubmissionError.signedOut.localizedDescription,
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
      status = Status(message: "正在发布主题…", systemImage: "paperplane", tintKind: .secondary)
    case .challengeRequired:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      status = Status(
        message: NewThreadSubmissionError.challengeRequired.localizedDescription,
        systemImage: "exclamationmark.shield",
        tintKind: .warning
      )
    case .outcomeUnknown:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      status = Status(
        message: NewThreadSubmissionError.outcomeUnknown.localizedDescription,
        systemImage: "questionmark.circle",
        tintKind: .warning
      )
    case .acceptedAwaitingVisibility:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = true
      status = Status(
        message: "贴吧已受理请求，但尚未确认主题可见。草稿已保留，请勿重复发布。",
        systemImage: "clock.badge.checkmark",
        tintKind: .warning
      )
    case .confirmed:
      allowsEditing = false
      allowsSubmission = false
      allowsVisibilityCheck = false
      status = Status(
        message: "上一个主题已确认。可以打开它，或清除确认记录后开始新主题。",
        systemImage: "checkmark.circle",
        tintKind: .success
      )
    case .failed(let error):
      allowsEditing = true
      allowsSubmission = error != .fullCredentialsRequired
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
        message: NewThreadSubmissionError.accountChanged.localizedDescription,
        systemImage: "person.crop.circle.badge.exclamationmark",
        tintKind: .warning
      )
    }
  }
}
