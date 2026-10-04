import Combine
import Foundation

enum ForumSectionID: Hashable, Identifiable, Sendable {
  case latest
  case featured
  case channel(Int)

  var id: Self { self }
}

struct ForumSection: Identifiable, Hashable, Sendable {
  let id: ForumSectionID
  let title: String
}

/// Published as one value after a complete FRS response has been applied. A
/// separate forum/channels subscription could temporarily pair new metadata
/// with an old channel catalog and incorrectly remove a retained page.
struct ForumMetadataSnapshot: Equatable, Sendable {
  let forum: BrowseForum
  let channels: [BrowseForumChannel]
}

@MainActor
final class ForumSectionsViewModel: ObservableObject {
  @Published private(set) var selectedSectionID: ForumSectionID = .latest
  @Published private(set) var metadata: ForumMetadataSnapshot

  let forumName: String
  private let service: any BrowseService
  private let initialSort: ForumThreadSort
  private var models: [ForumSectionID: ForumViewModel] = [:]
  private var currentModelObservation: AnyCancellable?
  private(set) var isActive = false

  init(
    forumName: String,
    service: any BrowseService,
    options: ForumBrowseOptions = ForumBrowseOptions()
  ) {
    self.forumName = forumName
    self.service = service
    self.initialSort = options.sort
    metadata = ForumMetadataSnapshot(forum: .placeholder(name: forumName), channels: [])
    models[.latest] = makeModel(for: .latest)
    observeCurrentModel()
  }

  var forum: BrowseForum { metadata.forum }
  var channels: [BrowseForumChannel] { metadata.channels }

  var sections: [ForumSection] {
    [ForumSection(id: .latest, title: "最新"), ForumSection(id: .featured, title: "精华")]
      + channels.map { ForumSection(id: .channel($0.id), title: $0.name) }
  }

  var currentModel: ForumViewModel {
    // Latest exists from initialization; selection only accepts advertised IDs
    // and creates their model before publishing the selected identity.
    models[selectedSectionID]!
  }

  /// Constructing a neighboring pager page must never start its network load.
  func model(for sectionID: ForumSectionID) -> ForumViewModel? {
    guard sections.contains(where: { $0.id == sectionID }) else { return nil }
    if let existing = models[sectionID] { return existing }
    let model = makeModel(for: sectionID)
    models[sectionID] = model
    return model
  }

  func activate() {
    isActive = true
    currentModel.loadIfNeeded()
  }

  func deactivate() {
    isActive = false
    for model in models.values { model.cancel() }
  }

  func select(_ sectionID: ForumSectionID) {
    guard sectionID != selectedSectionID, let next = model(for: sectionID) else { return }
    currentModel.cancel()
    currentModelObservation = nil
    selectedSectionID = sectionID
    observeCurrentModel()
    if isActive { next.loadIfNeeded() }
  }

  func reload() {
    if isActive {
      currentModel.reload()
    } else {
      currentModel.invalidateContents()
    }
  }

  func refresh() async {
    guard isActive else { return }
    await currentModel.refresh()
  }

  func invalidateContentFilters() {
    invalidateContents()
  }

  func invalidateContents() {
    // Keep options and metadata, but never revive a cached pre-filter row on a
    // later selection (or rows cached before creating a thread). Only the
    // visible page may issue the replacement read.
    for model in models.values { model.invalidateContents() }
    if isActive { currentModel.loadIfNeeded() }
  }

  private func makeModel(for sectionID: ForumSectionID) -> ForumViewModel {
    let model = ForumViewModel(
      forumName: forumName, service: service,
      options: ForumBrowseOptions(sort: initialSort),
      sectionID: sectionID, metadata: metadata)
    if sectionID == .latest {
      model.onMetadataLoaded = { [weak self, weak model] snapshot in
        guard let self, let model, self.models[.latest] === model else { return }
        self.applyMetadata(snapshot)
      }
    }
    return model
  }

  private func applyMetadata(_ snapshot: ForumMetadataSnapshot) {
    // Latest's FRS catalog is authoritative. Featured responses may omit tabs;
    // they must not erase the directory or change another section's options.
    var seen = Set<Int>()
    let channels = snapshot.channels.filter { seen.insert($0.id).inserted }
    let snapshot = ForumMetadataSnapshot(forum: snapshot.forum, channels: channels)
    let validIDs = Set(channels.map { ForumSectionID.channel($0.id) })
      .union([.latest, .featured])
    if !validIDs.contains(selectedSectionID) {
      // Keep the old model alive while willChange subscribers still read the
      // old selection; only remove it after the selection has been reconciled.
      currentModelObservation = nil
      selectedSectionID = .latest
      observeCurrentModel()
    }
    for id in Array(models.keys) where !validIDs.contains(id) {
      models.removeValue(forKey: id)?.cancel()
    }
    metadata = snapshot
    for model in models.values { model.synchronizeMetadata(snapshot) }

    if isActive { currentModel.loadIfNeeded() }
  }

  private func observeCurrentModel() {
    currentModelObservation = currentModel.objectWillChange.sink { [weak self] _ in
      // Every model mutation is MainActor-isolated; this synchronous forward
      // keeps toolbar state current without observing offscreen pagination.
      MainActor.assumeIsolated { self?.objectWillChange.send() }
    }
  }
}
