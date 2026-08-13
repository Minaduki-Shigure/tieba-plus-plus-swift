import Combine
import Foundation
import SwiftUI
import UIKit

enum ContentReportKind: Hashable, Sendable {
  case topic
  case post
  case subpost

  var localizedObjectName: String {
    switch self {
    case .topic:
      "主题"
    case .post:
      "楼层"
    case .subpost:
      "楼中楼回复"
    }
  }
}

struct ContentReportTarget: Hashable, Sendable {
  let kind: ContentReportKind
  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let parentPostID: Int64?
  let postID: Int64

  init?(
    kind: ContentReportKind,
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    parentPostID: Int64? = nil,
    postID: Int64
  ) {
    let forumName = forumName.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    guard
      forumID > 0,
      !forumName.isEmpty,
      threadID > 0,
      postID > 0
    else { return nil }
    switch kind {
    case .topic, .post:
      guard parentPostID == nil else { return nil }
    case .subpost:
      guard let parentPostID, parentPostID > 0, parentPostID != postID else { return nil }
    }
    self.kind = kind
    self.forumID = forumID
    self.forumName = forumName
    self.threadID = threadID
    self.parentPostID = parentPostID
    self.postID = postID
  }

  init?(thread: BrowseThread, post: BrowsePost) {
    guard
      thread.localVisibility == .visible,
      post.localVisibility == .visible,
      post.threadID == thread.id
    else { return nil }
    let kind: ContentReportKind
    if
      thread.firstPostID > 0,
      post.id == thread.firstPostID,
      post.floor == 1
    {
      kind = .topic
    } else {
      guard post.floor > 1, post.id != thread.firstPostID else { return nil }
      kind = .post
    }
    self.init(
      kind: kind,
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      postID: post.id
    )
  }

  init?(thread: BrowseThread, parentPost: CommentParentPostContext) {
    guard
      thread.localVisibility == .visible,
      parentPost.localVisibility == .visible,
      parentPost.threadID == thread.id
    else { return nil }
    let kind: ContentReportKind
    if
      thread.firstPostID > 0,
      parentPost.id == thread.firstPostID,
      parentPost.floor == 1
    {
      kind = .topic
    } else {
      guard parentPost.floor > 1, parentPost.id != thread.firstPostID else { return nil }
      kind = .post
    }
    self.init(
      kind: kind,
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      postID: parentPost.id
    )
  }

  init?(thread: BrowseThread, parentPostID: Int64, comment: BrowseComment) {
    guard
      thread.localVisibility == .visible,
      comment.localVisibility == .visible,
      comment.threadID == thread.id,
      comment.parentPostID == parentPostID
    else { return nil }
    self.init(
      kind: .subpost,
      forumID: thread.forumID,
      forumName: thread.forumName,
      threadID: thread.id,
      parentPostID: parentPostID,
      postID: comment.id
    )
  }

  var actionTitle: String {
    switch kind {
    case .topic:
      "举报主题"
    case .post:
      "举报本楼"
    case .subpost:
      "举报此条回复"
    }
  }
}

protocol ContentReportService: Sendable {
  func reportPageURL(postID: Int64) async throws -> URL
}

enum ContentReportDisclosure {
  static let confirmationMessage =
    "App 不会把保存在 Keychain 中的登录凭据交给浏览器。Safari 可能未登录，也可能已登录另一个百度账号；请在官方页面核对账号。只有你在页面提交后，举报才会发送。"
}

enum ContentReportCoordinatorState: Equatable {
  case resolvingSession
  case resolvingPage(ContentReportTarget)
  case ready
  case signedOut
  case failed(String)
}

private struct ContentReportSessionLease: Hashable, Sendable {
  let userID: Int64
  let sessionRevision: UUID

  init(_ session: StoredAccountSession) {
    userID = session.id
    sessionRevision = session.sessionRevision
  }
}

private enum ContentReportCoordinatorError: Error {
  case accountChanged
  case invalidReportURL
  case presentationFailed
}

@MainActor
final class ContentReportCoordinator: ObservableObject {
  @Published private(set) var state: ContentReportCoordinatorState = .resolvingSession
  @Published private(set) var pendingTarget: ContentReportTarget?

  private let vault: any AccountVault
  private let service: any ContentReportService
  private let presentation: ExternalWebPresentationModel
  private var activeSessionLease: ContentReportSessionLease?
  private var pendingScopeID: UUID?
  private var activeScopeID: UUID?
  private var ownedPage: ExternalWebPage?
  private var task: Task<Void, Never>?
  private var generation: UInt64 = 0
  private var sessionChangeCancellable: AnyCancellable?
  private var presentationPageCancellable: AnyCancellable?

  init(
    vault: any AccountVault,
    service: any ContentReportService,
    presentation: ExternalWebPresentationModel,
    observesAccountSessionChanges: Bool = true,
    observesPresentationChanges: Bool = true
  ) {
    self.vault = vault
    self.service = service
    self.presentation = presentation
    if observesPresentationChanges {
      presentationPageCancellable = presentation.$page
        .dropFirst()
        .sink { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.presentationPageDidChange()
          }
        }
    }
    if observesAccountSessionChanges {
      sessionChangeCancellable = NotificationCenter.default.publisher(for: .accountSessionDidChange)
        .sink { [weak self] _ in
          Task { @MainActor [weak self] in
            self?.accountSessionDidChange()
          }
        }
    }
    refreshSessionAvailability()
  }

  var isAvailable: Bool {
    if
      case .ready = state,
      presentation.page == nil,
      ownedPage == nil,
      activeScopeID == nil
    { return true }
    return false
  }

  var isResolvingPage: Bool {
    if case .resolvingPage = state { return true }
    return false
  }

  var isPresentingReportPage: Bool {
    guard let ownedPage else { return false }
    return presentation.page?.id == ownedPage.id
  }

  var errorMessage: String? {
    if case .failed(let message) = state { return message }
    return nil
  }

  func request(_ target: ContentReportTarget, scopeID: UUID) {
    guard
      isAvailable,
      task == nil,
      pendingTarget == nil,
      Self.isInternallyConsistent(target)
    else { return }
    pendingTarget = target
    pendingScopeID = scopeID
  }

  func cancelPendingRequest() {
    pendingTarget = nil
    pendingScopeID = nil
  }

  func confirmPendingRequest() {
    guard let target = pendingTarget, let scopeID = pendingScopeID else { return }
    pendingTarget = nil
    pendingScopeID = nil
    openReportPage(for: target, scopeID: scopeID)
  }

  func dismissError() {
    guard errorMessage != nil else { return }
    if activeSessionLease == nil {
      refreshSessionAvailability()
    } else {
      state = .ready
    }
  }

  func accountSessionDidChange() {
    dismissOwnedPage()
    generation &+= 1
    task?.cancel()
    task = nil
    pendingTarget = nil
    pendingScopeID = nil
    activeScopeID = nil
    activeSessionLease = nil
    refreshSessionAvailability()
  }

  func dismissReportPage() {
    dismissOwnedPage()
  }

  func invalidate(scopeID: UUID) {
    let invalidatesPending = pendingScopeID == scopeID
    let invalidatesActive = activeScopeID == scopeID
    guard invalidatesPending || invalidatesActive else { return }
    generation &+= 1
    task?.cancel()
    task = nil
    if invalidatesPending {
      pendingTarget = nil
      pendingScopeID = nil
    }
    if invalidatesActive {
      activeScopeID = nil
      dismissOwnedPage()
    }
    state = activeSessionLease == nil ? .signedOut : .ready
  }

  private func refreshSessionAvailability() {
    generation &+= 1
    let currentGeneration = generation
    state = .resolvingSession
    task?.cancel()
    let vault = vault
    task = Task { [weak self, vault] in
      do {
        let session = try await vault.activeSession()
        try Task.checkCancellation()
        guard let self, self.generation == currentGeneration else { return }
        self.task = nil
        guard
          let session,
          session.id > 0,
          session.credentials != nil
        else {
          self.activeSessionLease = nil
          self.state = .signedOut
          return
        }
        self.activeSessionLease = ContentReportSessionLease(session)
        self.state = .ready
      } catch is CancellationError {
        return
      } catch {
        guard let self, self.generation == currentGeneration else { return }
        self.task = nil
        self.activeSessionLease = nil
        self.state = .failed("未能确认当前登录账户，请稍后重试。")
      }
    }
  }

  private func openReportPage(for target: ContentReportTarget, scopeID: UUID) {
    guard
      let lease = activeSessionLease,
      task == nil,
      Self.isInternallyConsistent(target)
    else { return }
    generation &+= 1
    let currentGeneration = generation
    activeScopeID = scopeID
    state = .resolvingPage(target)
    let vault = vault
    let service = service
    task = Task { [weak self, vault, service] in
      do {
        guard let sessionBefore = try await vault.activeSession() else {
          throw ContentReportCoordinatorError.accountChanged
        }
        try Task.checkCancellation()
        guard ContentReportSessionLease(sessionBefore) == lease else {
          throw ContentReportCoordinatorError.accountChanged
        }

        let url = try await service.reportPageURL(postID: target.postID)
        try Task.checkCancellation()
        guard let sessionAfter = try await vault.activeSession() else {
          throw ContentReportCoordinatorError.accountChanged
        }
        try Task.checkCancellation()
        guard let self else { return }
        guard self.generation == currentGeneration, self.activeScopeID == scopeID else {
          return
        }
        guard
          ContentReportSessionLease(sessionAfter) == lease
        else {
          throw ContentReportCoordinatorError.accountChanged
        }
        guard
          ContentReportPresentationURLPolicy.allows(url, expectedPostID: target.postID)
        else {
          throw ContentReportCoordinatorError.invalidReportURL
        }
        guard self.presentation.page == nil else {
          throw ContentReportCoordinatorError.presentationFailed
        }
        let didRequestPresentation = self.presentation.requestPresentation(for: url)
        guard
          didRequestPresentation,
          let presentedPage = self.presentation.page,
          presentedPage.url == url
        else {
          throw ContentReportCoordinatorError.presentationFailed
        }
        self.ownedPage = presentedPage
        self.task = nil
        self.state = .ready
      } catch is CancellationError {
        return
      } catch ContentReportCoordinatorError.accountChanged {
        guard
          let self,
          self.generation == currentGeneration,
          self.activeScopeID == scopeID
        else { return }
        self.task = nil
        self.activeScopeID = nil
        self.activeSessionLease = nil
        self.state = .failed("当前账户已变化，未打开举报页面。")
      } catch ContentReportCoordinatorError.invalidReportURL {
        guard
          let self,
          self.generation == currentGeneration,
          self.activeScopeID == scopeID
        else { return }
        self.task = nil
        self.activeScopeID = nil
        self.state = .failed("贴吧返回了无法验证的举报页面地址。")
      } catch ContentReportCoordinatorError.presentationFailed {
        guard
          let self,
          self.generation == currentGeneration,
          self.activeScopeID == scopeID
        else { return }
        self.task = nil
        self.activeScopeID = nil
        self.state = .failed("无法安全地打开贴吧官方举报页面。")
      } catch {
        guard
          let self,
          self.generation == currentGeneration,
          self.activeScopeID == scopeID
        else { return }
        self.task = nil
        self.activeScopeID = nil
        self.state = .failed(error.localizedDescription)
      }
    }
  }

  private func dismissOwnedPage() {
    guard let ownedPage else { return }
    if presentation.page?.id == ownedPage.id {
      presentation.dismiss(id: ownedPage.id)
    }
    self.ownedPage = nil
    activeScopeID = nil
  }

  private func presentationPageDidChange() {
    if let ownedPage, presentation.page?.id != ownedPage.id {
      self.ownedPage = nil
      activeScopeID = nil
    }
    objectWillChange.send()
  }

  private static func isInternallyConsistent(_ target: ContentReportTarget) -> Bool {
    guard
      target.forumID > 0,
      !target.forumName.isEmpty,
      target.threadID > 0,
      target.postID > 0
    else { return false }
    switch target.kind {
    case .topic, .post:
      return target.parentPostID == nil
    case .subpost:
      guard let parentPostID = target.parentPostID else { return false }
      return parentPostID > 0 && parentPostID != target.postID
    }
  }

}

private enum ContentReportPresentationURLPolicy {
  static func allows(_ url: URL, expectedPostID: Int64) -> Bool {
    guard expectedPostID > 0 else { return false }
    var components = URLComponents()
    components.scheme = "https"
    components.host = "tieba.baidu.com"
    components.path = "/tpl/wise-bawu-core/report"
    components.queryItems = [
      URLQueryItem(name: "type", value: "2"),
      URLQueryItem(name: "post_id", value: String(expectedPostID)),
      URLQueryItem(name: "from", value: "threadPost"),
      URLQueryItem(name: "noshare", value: "1"),
      URLQueryItem(name: "loadingSignal", value: "1"),
    ]
    return components.url?.absoluteString == url.absoluteString
  }
}

private struct ContentReportCoordinatorEnvironmentKey: EnvironmentKey {
  static let defaultValue: ContentReportCoordinator? = nil
}

private struct ContentReportScopeIDEnvironmentKey: EnvironmentKey {
  static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
  var contentReportCoordinator: ContentReportCoordinator? {
    get { self[ContentReportCoordinatorEnvironmentKey.self] }
    set { self[ContentReportCoordinatorEnvironmentKey.self] = newValue }
  }

  var contentReportScopeID: UUID? {
    get { self[ContentReportScopeIDEnvironmentKey.self] }
    set { self[ContentReportScopeIDEnvironmentKey.self] = newValue }
  }
}

struct ContentReportMenuItem: View {
  let target: ContentReportTarget?
  let title: String?
  let accessibilityIdentifier: String

  @Environment(\.contentReportCoordinator) private var coordinator
  @Environment(\.contentReportScopeID) private var scopeID

  init(
    target: ContentReportTarget?,
    title: String? = nil,
    accessibilityIdentifier: String
  ) {
    self.target = target
    self.title = title
    self.accessibilityIdentifier = accessibilityIdentifier
  }

  var body: some View {
    if let coordinator, let target {
      ContentReportObservedMenuItem(
        coordinator: coordinator,
        target: target,
        title: title ?? target.actionTitle,
        accessibilityIdentifier: accessibilityIdentifier,
        scopeID: scopeID
      )
    }
  }
}

private struct ContentReportObservedMenuItem: View {
  @ObservedObject var coordinator: ContentReportCoordinator
  let target: ContentReportTarget
  let title: String
  let accessibilityIdentifier: String
  let scopeID: UUID?

  var body: some View {
    if coordinator.isAvailable, let scopeID {
      Button {
        coordinator.request(target, scopeID: scopeID)
      } label: {
        Label(title, systemImage: "exclamationmark.bubble")
      }
      .accessibilityIdentifier(accessibilityIdentifier)
    }
  }
}

struct ContentReportTopicMenu: View {
  let target: ContentReportTarget?

  @Environment(\.contentReportCoordinator) private var coordinator
  @Environment(\.contentReportScopeID) private var scopeID

  var body: some View {
    if let coordinator, let target {
      ContentReportObservedTopicMenu(
        coordinator: coordinator,
        target: target,
        scopeID: scopeID
      )
    }
  }
}

private struct ContentReportObservedTopicMenu: View {
  @ObservedObject var coordinator: ContentReportCoordinator
  let target: ContentReportTarget
  let scopeID: UUID?

  var body: some View {
    if coordinator.isAvailable, let scopeID {
      Menu {
        Button {
          coordinator.request(target, scopeID: scopeID)
        } label: {
          Label("举报主题", systemImage: "exclamationmark.bubble")
        }
        .accessibilityIdentifier("thread-report-topic")
      } label: {
        Image(systemName: "ellipsis.circle")
      }
      .accessibilityLabel("更多帖子操作")
      .help("更多帖子操作")
    }
  }
}

private struct ContentReportPresentationModifier: ViewModifier {
  @ObservedObject var coordinator: ContentReportCoordinator

  func body(content: Content) -> some View {
    content
      .confirmationDialog(
        "打开贴吧官方举报页？",
        isPresented: pendingConfirmationIsPresented,
        titleVisibility: .visible
      ) {
        Button("继续") {
          coordinator.confirmPendingRequest()
        }
        Button("取消", role: .cancel) {
          coordinator.cancelPendingRequest()
        }
      } message: {
        Text(ContentReportDisclosure.confirmationMessage)
      }
      .alert("无法打开举报页面", isPresented: errorIsPresented) {
        Button("好", role: .cancel) {
          coordinator.dismissError()
        }
      } message: {
        Text(coordinator.errorMessage ?? "无法打开贴吧官方举报页面。")
      }
      .onChange(of: coordinator.isPresentingReportPage) { isPresenting in
        if isPresenting {
          UIAccessibility.post(notification: .screenChanged, argument: "贴吧官方举报页面")
        }
      }
      .overlay(alignment: .top) {
        if case .resolvingPage(let target) = coordinator.state {
          HStack(spacing: 10) {
            ProgressView()
            Text("正在打开\(target.kind.localizedObjectName)的官方举报页")
              .font(.footnote)
              .lineLimit(2)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 14)
          .frame(minHeight: 44)
          .background(.regularMaterial)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("正在打开\(target.kind.localizedObjectName)的官方举报页面")
        }
      }
  }

  private var pendingConfirmationIsPresented: Binding<Bool> {
    Binding(
      get: { coordinator.pendingTarget != nil },
      set: { isPresented in
        if !isPresented { coordinator.cancelPendingRequest() }
      }
    )
  }

  private var errorIsPresented: Binding<Bool> {
    Binding(
      get: { coordinator.errorMessage != nil },
      set: { isPresented in
        if !isPresented { coordinator.dismissError() }
      }
    )
  }
}

extension View {
  func contentReportPresentation(_ coordinator: ContentReportCoordinator) -> some View {
    modifier(ContentReportPresentationModifier(coordinator: coordinator))
  }
}
