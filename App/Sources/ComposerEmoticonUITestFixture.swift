#if DEBUG
  import Combine
  import Foundation
  import SwiftUI
  import UIKit

  /// A separate DEBUG App keeps production Keychain, transports and background
  /// runtimes out of these tests. The editors, picker and file stores are real.
  @MainActor
  struct ComposerEmoticonUITestApp: App {
    @StateObject private var dependencies = ComposerEmoticonUITestDependencies()

    var body: some Scene {
      WindowGroup {
        ComposerEmoticonUITestRoot(dependencies: dependencies, probe: dependencies.probe)
      }
    }
  }

  @MainActor
  private struct ComposerEmoticonUITestRoot: View {
    @ObservedObject var dependencies: ComposerEmoticonUITestDependencies
    @ObservedObject var probe: ComposerEmoticonUITestProbe

    var body: some View {
      NavigationStack {
        List {
          if dependencies.isReady {
            NavigationLink("编辑主题草稿") {
              NewThreadComposerView(target: dependencies.threadTarget) { _, _, _ in
                probe.unexpectedCalls += 1
              }
              .safeAreaInset(edge: .top) {
                ComposerEmoticonUITestUndoControls(editorID: "new-thread-content")
                  .frame(height: 44)
              }
            }
            .accessibilityIdentifier("composer-fixture-new-thread")
            NavigationLink("编辑回复草稿") {
              ReplyComposerView(
                context: dependencies.replyContext,
                verifyVisibility: { _, _, _ in
                  probe.unexpectedCalls += 1
                  throw ComposerEmoticonUITestError.unexpectedServiceCall
                },
                onConfirmed: { _ in probe.unexpectedCalls += 1 }
              )
              .safeAreaInset(edge: .top) {
                ComposerEmoticonUITestUndoControls(editorID: "reply-composer-editor")
                  .frame(height: 44)
              }
            }
            .accessibilityIdentifier("composer-fixture-reply")
          }
          Text(probe.threadDraft)
            .accessibilityIdentifier("composer-fixture-thread-disk")
          Text(probe.replyDraft)
            .accessibilityIdentifier("composer-fixture-reply-disk")
          Text("unexpected=\(probe.unexpectedCalls)")
            .accessibilityIdentifier("composer-fixture-service-counts")
          if let error = dependencies.error { Text(error) }
        }
        .navigationTitle("表情编辑测试")
      }
      .environment(\.newThreadSubmissionStore, dependencies.threadStore)
      .environment(\.textReplySubmissionStore, dependencies.replyStore)
      .environment(\.contentMediaLoadPolicy, .tapToLoad)
      .environment(\.contentMediaLoadBehavior, .userInitiated)
      .task { await dependencies.prepare() }
    }
  }

  /// Test affordances only invoke the actual mounted UITextView's UndoManager.
  /// They never replace text, selection, bindings or a production controller.
  @MainActor
  private struct ComposerEmoticonUITestUndoControls: UIViewRepresentable {
    let editorID: String

    func makeUIView(context: Context) -> ComposerEmoticonUITestUndoBar {
      ComposerEmoticonUITestUndoBar(editorID: editorID)
    }

    func updateUIView(_ uiView: ComposerEmoticonUITestUndoBar, context: Context) {}
  }

  @MainActor
  private final class ComposerEmoticonUITestUndoBar: UIStackView {
    private let editorID: String
    private let state = UILabel()

    init(editorID: String) {
      self.editorID = editorID
      super.init(frame: .zero)
      axis = .horizontal
      distribution = .fillEqually
      spacing = 6
      addButton("撤销", id: "composer-fixture-undo") { $0.undoManager?.undo() }
      addButton("重做", id: "composer-fixture-redo") { $0.undoManager?.redo() }
      addButton("编辑状态", id: "composer-fixture-inspect") { _ in }
      state.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
      state.adjustsFontSizeToFitWidth = true
      state.accessibilityIdentifier = "composer-fixture-undo-state"
      state.text = "unchecked"
      addArrangedSubview(state)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addButton(
      _ title: String, id: String, action: @escaping @MainActor (UITextView) -> Void
    ) {
      let button = UIButton(type: .system)
      button.setTitle(title, for: .normal)
      button.accessibilityIdentifier = id
      button.addAction(
        UIAction { [weak self] _ in
          guard let self, let window, let editor = findEditor(in: window) else { return }
          action(editor)
          state.text =
            "undo=\(editor.undoManager?.canUndo == true ? 1 : 0) "
            + "redo=\(editor.undoManager?.canRedo == true ? 1 : 0)"
        }, for: .touchUpInside)
      addArrangedSubview(button)
    }

    private func findEditor(in view: UIView) -> UITextView? {
      if let editor = view as? UITextView,
        editor.accessibilityIdentifier == editorID, editor.window != nil
      {
        return editor
      }
      for child in view.subviews {
        if let editor = findEditor(in: child) { return editor }
      }
      return nil
    }
  }

  @MainActor
  private final class ComposerEmoticonUITestProbe: ObservableObject {
    @Published var threadDraft = ""
    @Published var replyDraft = ""
    @Published var unexpectedCalls = 0
  }

  @MainActor
  private final class ComposerEmoticonUITestDependencies: ObservableObject {
    let probe: ComposerEmoticonUITestProbe
    let threadTarget: NewThreadTarget
    let replyContext: TextReplyComposerContext
    let threadStore: NewThreadSubmissionStore
    let replyStore: TextReplySubmissionStore
    private let threadDrafts: ComposerEmoticonUITestThreadDrafts
    private let replyDrafts: ComposerEmoticonUITestReplyDrafts
    @Published private(set) var isReady = false
    @Published private(set) var error: String?

    init() {
      let probe = ComposerEmoticonUITestProbe()
      self.probe = probe
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ComposerEmoticonUITest-\(UUID().uuidString)", isDirectory: true)
      threadDrafts = ComposerEmoticonUITestThreadDrafts(
        store: FileNewThreadDraftStore(fileURL: directory.appendingPathComponent("thread.json")),
        probe: probe)
      replyDrafts = ComposerEmoticonUITestReplyDrafts(
        store: FileTextReplyDraftStore(fileURL: directory.appendingPathComponent("reply.json")),
        probe: probe)
      let access = AccountAccess(
        vault: ComposerEmoticonUITestVault(), service: ComposerEmoticonUITestService(probe: probe))
      threadStore = NewThreadSubmissionStore(
        access: access, drafts: threadDrafts, observesAccountSessionChanges: false)
      replyStore = TextReplySubmissionStore(
        access: access, drafts: replyDrafts, observesAccountSessionChanges: false)
      threadTarget = NewThreadTarget(forumID: 7, forumName: "离线编辑")!
      let thread = BrowseThread(
        id: 70, forumID: 7, forumName: "离线编辑", title: "表情回复测试",
        excerpt: "", authorName: "测试作者", replyCount: 0, viewCount: 0,
        createdAt: nil, lastReplyAt: nil, contents: [], firstPostID: 700)
      let parent = CommentParentPostContext(
        id: 700, threadID: 70, floor: 1, authorID: 8, authorName: "测试作者",
        authorPortraitURL: nil, createdAt: nil, isThreadAuthor: true, contents: [])
      replyContext = TextReplyComposerContext(thread: thread, parentPost: parent)!
    }

    func prepare() async {
      guard !isReady, error == nil else { return }
      do {
        let source = "中文👍🏽 "
        try await threadDrafts.save(
          NewThreadDraft(
            key: NewThreadDraftKey(userID: 7, target: threadTarget)!,
            title: "离线草稿", content: source)!)
        try await replyDrafts.save(
          TextReplyDraft(
            key: TextReplyDraftKey(userID: 7, target: replyContext.target)!, content: source)!)
        isReady = true
      } catch {
        self.error = String(describing: error)
      }
    }
  }

  /// Publish only a fresh file-store read after the real durable write completes.
  private actor ComposerEmoticonUITestThreadDrafts: NewThreadDraftRepository {
    let store: FileNewThreadDraftStore
    let probe: ComposerEmoticonUITestProbe
    init(store: FileNewThreadDraftStore, probe: ComposerEmoticonUITestProbe) {
      self.store = store
      self.probe = probe
    }
    func draft(for key: NewThreadDraftKey) async throws -> NewThreadDraft? {
      try await store.draft(for: key)
    }
    func save(_ draft: NewThreadDraft) async throws {
      try await store.save(draft)
      let source = try await store.draft(for: draft.key)?.content ?? ""
      await MainActor.run { probe.threadDraft = source }
    }
    func delete(for key: NewThreadDraftKey) async throws { try await store.delete(for: key) }
    func deleteAll() async throws { try await store.deleteAll() }
  }

  private actor ComposerEmoticonUITestReplyDrafts: TextReplyDraftRepository {
    let store: FileTextReplyDraftStore
    let probe: ComposerEmoticonUITestProbe
    init(store: FileTextReplyDraftStore, probe: ComposerEmoticonUITestProbe) {
      self.store = store
      self.probe = probe
    }
    func draft(for key: TextReplyDraftKey) async throws -> TextReplyDraft? {
      try await store.draft(for: key)
    }
    func save(_ draft: TextReplyDraft) async throws {
      try await store.save(draft)
      let source = try await store.draft(for: draft.key)?.content ?? ""
      await MainActor.run { probe.replyDraft = source }
    }
    func delete(for key: TextReplyDraftKey) async throws { try await store.delete(for: key) }
    func deleteAll() async throws { try await store.deleteAll() }
  }

  private enum ComposerEmoticonUITestError: Error { case unexpectedServiceCall }

  private actor ComposerEmoticonUITestVault: AccountVault {
    private let session = StoredAccountSession(
      id: 7, username: "offline-editor", displayName: "离线编辑账户", portrait: "",
      bduss: String(repeating: "b", count: AccountCredentialFormat.bdussLength),
      stoken: String(repeating: "s", count: AccountCredentialFormat.stokenLength),
      createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 1))
    func activeSession() async throws -> StoredAccountSession? { session }
    func accountSummaries() async throws -> [AccountSummary] { [] }
    func upsert(_ session: StoredAccountSession) async throws {
      throw ComposerEmoticonUITestError.unexpectedServiceCall
    }
    func switchActive(to userID: Int64) async throws {
      throw ComposerEmoticonUITestError.unexpectedServiceCall
    }
    func remove(userID: Int64) async throws {
      throw ComposerEmoticonUITestError.unexpectedServiceCall
    }
    func removeAll() async throws { throw ComposerEmoticonUITestError.unexpectedServiceCall }
  }

  private actor ComposerEmoticonUITestService: AccountService {
    let probe: ComposerEmoticonUITestProbe
    init(probe: ComposerEmoticonUITestProbe) { self.probe = probe }
    private func reject<T>() async throws -> T {
      await MainActor.run { probe.unexpectedCalls += 1 }
      throw ComposerEmoticonUITestError.unexpectedServiceCall
    }
    func validate(credential: AccountCredentials) async throws -> ValidatedAccount {
      try await reject()
    }
    func followedForums(
      session: StoredAccountSession, page: Int, pageSize: Int
    ) async throws -> FollowedForumPageData { try await reject() }
    func forumMembership(
      session: StoredAccountSession, forumID: Int64, forumName: String
    ) async throws -> ForumMembershipData { try await reject() }
    func forumAccountState(
      session: StoredAccountSession, forumID: Int64, forumName: String
    ) async throws -> ForumAccountStateData { try await reject() }
    func setForumFollowed(
      session: StoredAccountSession, forumID: Int64, forumName: String, isFollowed: Bool
    ) async throws -> ForumMembershipData { try await reject() }
    func checkInToForum(
      session: StoredAccountSession, forumID: Int64, forumName: String
    ) async throws -> ForumAccountStateData { try await reject() }
    func submitTextReply(
      session: StoredAccountSession, submission: TextReplySubmission
    ) async throws -> TextReplyResult { try await reject() }
    func submitNewThread(
      session: StoredAccountSession, submission: NewThreadSubmission
    ) async throws -> NewThreadResult { try await reject() }
  }
#endif
