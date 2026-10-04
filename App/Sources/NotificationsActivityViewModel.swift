import Combine
import Foundation

/// Owns two retained inbox pages. Mounting a neighboring native list must never
/// read that account's other message channel or change its server unread state.
@MainActor
final class NotificationsActivityViewModel: ObservableObject {
  @Published private(set) var selectedKind: InboxKind
  @Published private(set) var isActive = false

  let repliesModel: NotificationsViewModel
  let mentionsModel: NotificationsViewModel

  init(
    service: any AccountService,
    vault: any AccountVault,
    contentFilterRepository: any ContentFilterRepository = EmptyContentFilterRepository(),
    selectedKind: InboxKind = .replies,
    onValidatedFirstPage: @escaping @MainActor (UUID) -> Void = { _ in }
  ) {
    self.selectedKind = selectedKind
    repliesModel = NotificationsViewModel(
      service: service, vault: vault, contentFilterRepository: contentFilterRepository,
      selectedKind: .replies, onValidatedFirstPage: onValidatedFirstPage
    )
    mentionsModel = NotificationsViewModel(
      service: service, vault: vault, contentFilterRepository: contentFilterRepository,
      selectedKind: .mentions, onValidatedFirstPage: onValidatedFirstPage
    )
  }

  func model(for kind: InboxKind) -> NotificationsViewModel {
    switch kind {
    case .replies: repliesModel
    case .mentions: mentionsModel
    }
  }

  func isActive(_ kind: InboxKind) -> Bool { isActive && selectedKind == kind }

  func activate() {
    guard !Task.isCancelled, !isActive else { return }
    isActive = true
    model(for: selectedKind).loadIfNeeded()
  }

  func deactivate() {
    isActive = false
    repliesModel.cancel()
    mentionsModel.cancel()
  }

  func select(_ kind: InboxKind) {
    guard kind != selectedKind else { return }
    model(for: selectedKind).cancel()
    selectedKind = kind
    if isActive { model(for: kind).loadIfNeeded() }
  }

  func refresh(kind: InboxKind) async {
    guard isActive(kind), !Task.isCancelled else { return }
    await model(for: kind).refresh()
  }

  func accountSessionDidChange() {
    // Revoke both cached leases synchronously before permitting any new read.
    repliesModel.accountSessionDidChange(loadImmediately: false)
    mentionsModel.accountSessionDidChange(loadImmediately: false)
    if isActive { model(for: selectedKind).loadIfNeeded() }
  }

  func contentFilterDidChange() {
    // These are local repository reads only. Filtering cannot fetch a hidden
    // channel, advance either raw cursor, or infer a new unread count.
    repliesModel.contentFilterDidChange()
    mentionsModel.contentFilterDidChange()
  }
}
