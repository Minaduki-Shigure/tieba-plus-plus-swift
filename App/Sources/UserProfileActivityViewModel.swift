import Combine
import Foundation

enum UserProfileActivitySection: String, CaseIterable, Identifiable, Sendable {
  case threads
  case replies

  var id: Self { self }

  var title: String {
    switch self {
    case .threads: "公开主题"
    case .replies: "公开回复"
    }
  }
}

/// Retains each public activity page while keeping shared profile reads
/// independent of selection. Only the visible page may start content reads.
@MainActor
final class UserProfileActivityViewModel: ObservableObject {
  @Published private(set) var selectedSection: UserProfileActivitySection = .threads
  @Published private(set) var isActive = false

  let profileModel: UserProfileViewModel
  let repliesModel: UserRepliesViewModel

  private var observations: Set<AnyCancellable> = []

  init(userID: Int64, service: any UserProfileService) {
    profileModel = UserProfileViewModel(userID: userID, service: service)
    repliesModel = UserRepliesViewModel(userID: userID, service: service)

    // The profile model also owns shared header state, so its publications are
    // relevant from either page. Inactive replies never invalidate the parent.
    profileModel.objectWillChange.sink { [weak self] _ in
      MainActor.assumeIsolated { self?.objectWillChange.send() }
    }.store(in: &observations)
    repliesModel.objectWillChange.sink { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.selectedSection == .replies else { return }
        self.objectWillChange.send()
      }
    }.store(in: &observations)
  }

  func activate() {
    isActive = true
    profileModel.loadProfileIfNeeded()
    loadSelectedSectionIfNeeded()
  }

  func deactivate() {
    isActive = false
    profileModel.cancel()
    repliesModel.cancel()
  }

  func select(_ section: UserProfileActivitySection) {
    guard section != selectedSection else { return }
    switch selectedSection {
    case .threads: profileModel.cancelThreads()
    case .replies: repliesModel.cancel()
    }
    selectedSection = section
    if isActive { loadSelectedSectionIfNeeded() }
  }

  func refresh() async {
    guard isActive, !Task.isCancelled else { return }
    // Capture and start both tasks before suspending. A later selection cancels
    // only this content task; awaiting the profile must not start a hidden page.
    let section = selectedSection
    let profileTask = profileModel.beginProfileRefresh()
    let contentTask: Task<Void, Never>
    switch section {
    case .threads: contentTask = profileModel.beginThreadsRefresh()
    case .replies: contentTask = repliesModel.beginRefresh()
    }
    await profileTask.value
    await contentTask.value
  }

  func invalidateContentFilters() {
    profileModel.invalidateThreads()
    repliesModel.invalidateContents()
    if isActive { loadSelectedSectionIfNeeded() }
  }

  func retryProfile() {
    guard isActive else { return }
    profileModel.beginProfileRefresh()
  }

  private func loadSelectedSectionIfNeeded() {
    switch selectedSection {
    case .threads: profileModel.loadThreadsIfNeeded()
    case .replies: repliesModel.loadIfNeeded()
    }
  }
}
