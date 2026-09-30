import SwiftUI

enum ThreadSummaryAgreementPolicy {
  static func target(for thread: BrowseThread) -> ContentAgreementTarget? {
    guard thread.localVisibility == .visible, !thread.isServerHidden else { return nil }
    // A summary's image/search-result PID may belong to another floor. Only
    // the explicitly supplied first-floor identity can identify a topic vote.
    return ContentAgreementTarget(
      kind: .topic,
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      objectID: thread.firstPostID
    )
  }

  static func offeredStates(for state: ContentAgreementEntryState) -> [Bool] {
    switch state {
    case .ready(let snapshot): [!snapshot.isAgreed]
    case .unknown: [true, false]
    case .signedOut, .loading, .mutating, .reconciling, .failed: []
    }
  }

  static func showsSecondaryMetrics(
    snapshot: ContentAgreementSnapshot?,
    fallbackScore: Int,
    shareCount: Int
  ) -> Bool {
    snapshot != nil || fallbackScore > 0 || shareCount > 0
  }
}

@MainActor
enum ThreadSummaryAgreementAction {
  static func perform(
    isAgreed: Bool,
    target: ContentAgreementTarget,
    access: AccountAccess,
    store: ContentAgreementStore
  ) async throws {
    // Bind the user's explicit action before the first network read. The
    // recommendation persona is deliberately not an input to this operation.
    guard let expectedSession = try await access.vault.activeSession() else {
      throw BrowseError.unavailable("请先登录账户，再使用长按菜单点赞。")
    }
    try Task.checkCancellation()
    try await store.reload(target)
    try Task.checkCancellation()
    guard
      let currentSession = try await access.vault.activeSession(),
      currentSession.id == expectedSession.id,
      currentSession.sessionRevision == expectedSession.sessionRevision
    else {
      throw BrowseError.unavailable("当前账户已经变化，请重新长按帖子选择点赞操作。")
    }
    // setAgreed is idempotent against the freshly read state, verifies the
    // session again, and owns write deduplication and authoritative readback.
    _ = try await store.setAgreed(isAgreed, for: target, expectedSession: expectedSession)
  }
}

private struct ThreadSummaryAgreementMenuModifier: ViewModifier {
  let thread: BrowseThread

  @Environment(\.accountAccess) private var accountAccess
  @Environment(\.contentAgreementStore) private var store
  @State private var errorMessage: String?

  @ViewBuilder
  func body(content: Content) -> some View {
    if let target = ThreadSummaryAgreementPolicy.target(for: thread),
      let store, let accountAccess
    {
      content
        .contextMenu {
          ThreadSummaryAgreementMenu(
            entry: store.entry(for: target),
            perform: { isAgreed in
              run {
                try await ThreadSummaryAgreementAction.perform(
                  isAgreed: isAgreed,
                  target: target,
                  access: accountAccess,
                  store: store
                )
              }
            },
            reload: {
              run { try await store.reload(target) }
            }
          )
        }
        .alert("无法更新点赞状态", isPresented: errorIsPresented) {
          Button("好", role: .cancel) { errorMessage = nil }
        } message: {
          Text(errorMessage ?? "请重新长按帖子后再试。")
        }
    } else {
      content
    }
  }

  private func run(_ operation: @escaping @MainActor () async throws -> Void) {
    Task { @MainActor in
      do {
        try await operation()
      } catch is CancellationError {
        // An overlapping read or a departing account invalidated this action.
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )
  }
}

private struct ThreadSummaryAgreementMenu: View {
  @ObservedObject var entry: ContentAgreementEntry
  let perform: (Bool) -> Void
  let reload: () -> Void

  var body: some View {
    Section("使用当前登录账户") {
      switch entry.state {
      case .signedOut:
        Label("登录后可点赞", systemImage: "person.crop.circle")
      case .loading:
        Label("正在读取点赞状态", systemImage: "hourglass")
      case .mutating:
        Label("正在更新点赞", systemImage: "hourglass")
      case .reconciling:
        Label("正在确认服务器点赞状态", systemImage: "hourglass")
      case .failed:
        Button(action: reload) {
          Label("重新读取点赞状态", systemImage: "arrow.clockwise")
        }
        .accessibilityIdentifier("thread-summary-agreement-reload-\(entry.target.threadID)")
      case .unknown, .ready:
        ForEach(ThreadSummaryAgreementPolicy.offeredStates(for: entry.state), id: \.self) {
          isAgreed in
          Button {
            perform(isAgreed)
          } label: {
            Label(
              isAgreed ? "点赞" : "取消点赞",
              systemImage: isAgreed ? "hand.thumbsup" : "hand.thumbsup.fill"
            )
          }
          .accessibilityIdentifier(
            "thread-summary-agreement-\(isAgreed ? "add" : "remove")-\(entry.target.threadID)"
          )
        }
      }
    }
  }
}

struct ThreadSummaryAgreementMetricsObserver<Content: View>: View {
  @ObservedObject var entry: ContentAgreementEntry
  @ViewBuilder var content: (ContentAgreementSnapshot?) -> Content

  var body: some View {
    content(entry.displayedSnapshot)
  }
}

extension View {
  func threadSummaryAgreementMenu(thread: BrowseThread) -> some View {
    modifier(ThreadSummaryAgreementMenuModifier(thread: thread))
  }
}
