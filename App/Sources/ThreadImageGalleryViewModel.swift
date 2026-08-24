import Combine
import Foundation

enum ThreadPictureOccurrenceID: Hashable, Sendable {
  case local(postID: Int64, contentOffset: Int)
  case remote(overallIndex: Int, pictureID: String, postID: Int64)
}

struct ThreadPictureOccurrence: Identifiable, Equatable, Sendable {
  let id: ThreadPictureOccurrenceID
  let pictureID: String
  let postID: Int64
  let url: URL
  let width: Int
  let height: Int
  let imageOrdinal: Int?

  init(
    localURL: URL,
    pictureID: String,
    postID: Int64,
    contentOffset: Int,
    width: Int = 0,
    height: Int = 0,
    imageOrdinal: Int? = nil
  ) {
    id = .local(postID: postID, contentOffset: contentOffset)
    self.pictureID = pictureID
    self.postID = postID
    url = localURL
    self.width = width
    self.height = height
    self.imageOrdinal = imageOrdinal
  }

  init(
    remoteURL: URL,
    pictureID: String,
    postID: Int64,
    overallIndex: Int,
    width: Int = 0,
    height: Int = 0
  ) {
    id = .remote(overallIndex: overallIndex, pictureID: pictureID, postID: postID)
    self.pictureID = pictureID
    self.postID = postID
    url = remoteURL
    self.width = width
    self.height = height
    imageOrdinal = nil
  }

  var overallIndex: Int? {
    guard case .remote(let overallIndex, _, _) = id else { return nil }
    return overallIndex
  }
}

struct ThreadPictureGalleryContext: Equatable, Sendable {
  enum Source: Equatable, Sendable {
    case post
    case forum
    case index
  }

  let forumID: Int64
  let forumName: String
  let threadID: Int64
  let onlyThreadAuthor: Bool
  let source: Source

  init(
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    onlyThreadAuthor: Bool = false,
    source: Source = .post
  ) {
    self.forumID = forumID
    self.forumName = forumName
    self.threadID = threadID
    self.onlyThreadAuthor = onlyThreadAuthor
    self.source = source
  }

  fileprivate var canRequestRemotePictures: Bool {
    forumID > 0
      && threadID > 0
      && !forumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

enum ThreadPicturePageDirection: Equatable, Sendable {
  case bootstrap
  case previous
  case next
}

struct ThreadPicturePageRequest: Equatable, Sendable {
  let context: ThreadPictureGalleryContext
  let direction: ThreadPicturePageDirection
  let anchorPictureID: String
  let anchorPostID: Int64
  let anchorIndex: Int
  let anchorURL: URL
}

struct ThreadPicturePage: Equatable, Sendable {
  let occurrences: [ThreadPictureOccurrence]
  let totalCount: Int

  init(occurrences: [ThreadPictureOccurrence], totalCount: Int) {
    self.occurrences = occurrences
    self.totalCount = totalCount
  }
}

protocol ThreadPictureGalleryService: Sendable {
  func pictureIdentifier(for imageURL: URL) -> String?
  func picturePage(for request: ThreadPicturePageRequest) async throws -> ThreadPicturePage
}

extension ThreadPictureGalleryService {
  func pictureIdentifier(for imageURL: URL) -> String? { nil }
}

struct ThreadPictureGalleryState: Equatable, Sendable {
  let occurrences: [ThreadPictureOccurrence]
  let selectedID: ThreadPictureOccurrenceID?
  let totalCount: Int
  let localToRemoteIDMigrations: [ThreadPictureOccurrenceID: ThreadPictureOccurrenceID]
  let viewerContextRevision: UInt64
}

@MainActor
final class ThreadImageGalleryViewModel: ObservableObject {
  @Published private(set) var context: ThreadPictureGalleryContext
  @Published private(set) var galleryState: ThreadPictureGalleryState
  @Published private(set) var isRemoteLoadingEnabled: Bool
  @Published private(set) var isBootstrapping = false
  @Published private(set) var isLoadingPrevious = false
  @Published private(set) var isLoadingNext = false
  @Published private(set) var bootstrapError: String?
  @Published private(set) var previousError: String?
  @Published private(set) var nextError: String?
  @Published private(set) var canLoadPrevious = false
  @Published private(set) var canLoadNext = false

  private let service: any ThreadPictureGalleryService
  private var localOccurrences: [ThreadPictureOccurrence]
  private var preferredLocalSelectionID: ThreadPictureOccurrenceID?
  private var hasBootstrapped = false
  private var previousStalled = false
  private var nextStalled = false
  private var viewerContextRevision: UInt64 = 0
  private var generation = 0
  private var bootstrapToken = 0
  private var previousToken = 0
  private var nextToken = 0
  private var bootstrapTask: Task<Void, Never>?
  private var previousTask: Task<Void, Never>?
  private var nextTask: Task<Void, Never>?

  init(
    context: ThreadPictureGalleryContext,
    localOccurrences: [ThreadPictureOccurrence],
    selectedID: ThreadPictureOccurrenceID?,
    isRemoteLoadingEnabled: Bool = true,
    service: any ThreadPictureGalleryService
  ) {
    let localOccurrences = Self.normalizedLocalOccurrences(localOccurrences)
    let selectedID = Self.validSelection(selectedID, in: localOccurrences)

    self.context = context
    self.localOccurrences = localOccurrences
    galleryState = ThreadPictureGalleryState(
      occurrences: localOccurrences,
      selectedID: selectedID,
      totalCount: localOccurrences.count,
      localToRemoteIDMigrations: [:],
      viewerContextRevision: 0
    )
    preferredLocalSelectionID = selectedID
    self.isRemoteLoadingEnabled = isRemoteLoadingEnabled
    self.service = service

    if isRemoteLoadingEnabled {
      startBootstrapIfNeeded()
    }
  }

  var occurrences: [ThreadPictureOccurrence] { galleryState.occurrences }

  var selectedID: ThreadPictureOccurrenceID? {
    get { galleryState.selectedID }
    set { select(newValue) }
  }

  var totalCount: Int { galleryState.totalCount }

  var selectedOccurrence: ThreadPictureOccurrence? {
    guard let selectedID else { return nil }
    return occurrences.first(where: { $0.id == selectedID })
  }

  var selectedURL: URL? { selectedOccurrence?.url }

  var selectedIndex: Int? {
    guard let selectedID else { return nil }
    return occurrences.firstIndex(where: { $0.id == selectedID })
  }

  var selectedDisplayIndex: Int? {
    if let overallIndex = selectedOccurrence?.overallIndex {
      return overallIndex
    }
    return selectedIndex.map { $0 + 1 }
  }

  func loadIfNeeded() {
    guard isRemoteLoadingEnabled else { return }
    if hasBootstrapped {
      loadAtSelectedEdgeIfNeeded()
    } else {
      startBootstrapIfNeeded()
    }
  }

  func select(_ id: ThreadPictureOccurrenceID?) {
    guard
      let id,
      occurrences.contains(where: { $0.id == id }),
      id != selectedID
    else { return }
    let oldValue = selectedID
    setSelectedIDInternally(id)
    selectionDidChange(from: oldValue)
  }

  func retryBootstrap() {
    guard bootstrapError != nil, !isBootstrapping, isRemoteLoadingEnabled else { return }
    bootstrapError = nil
    startBootstrapIfNeeded()
  }

  func retryPrevious() {
    guard
      previousError != nil,
      canLoadPrevious,
      !isLoadingPrevious,
      isRemoteLoadingEnabled,
      hasBootstrapped
    else { return }
    previousError = nil
    startPreviousLoad(requiresSelectedEdge: false)
  }

  func retryNext() {
    guard
      nextError != nil,
      canLoadNext,
      !isLoadingNext,
      isRemoteLoadingEnabled,
      hasBootstrapped
    else { return }
    nextError = nil
    startNextLoad(requiresSelectedEdge: false)
  }

  func setRemoteLoadingEnabled(_ enabled: Bool) {
    guard isRemoteLoadingEnabled != enabled else { return }
    invalidateAllLoads()
    restoreLocalSnapshot(resetsViewerContext: !enabled)
    isRemoteLoadingEnabled = enabled
    if enabled {
      startBootstrapIfNeeded()
    }
  }

  func updateContext(
    _ context: ThreadPictureGalleryContext,
    localOccurrences: [ThreadPictureOccurrence],
    selectedID: ThreadPictureOccurrenceID?
  ) {
    let localOccurrences = Self.normalizedLocalOccurrences(localOccurrences)
    let selectedID = Self.validSelection(selectedID, in: localOccurrences)
    guard
      self.context != context
        || self.localOccurrences != localOccurrences
        || preferredLocalSelectionID != selectedID
    else { return }

    invalidateAllLoads()
    self.context = context
    self.localOccurrences = localOccurrences
    preferredLocalSelectionID = selectedID
    restoreLocalSnapshot(selection: selectedID)
    if isRemoteLoadingEnabled {
      startBootstrapIfNeeded()
    }
  }

  func cancel() {
    let wasBootstrapping = isBootstrapping
    invalidateAllLoads()
    if wasBootstrapping {
      hasBootstrapped = false
    }
  }

  func waitForCurrentLoads() async {
    while true {
      if let bootstrapTask {
        await bootstrapTask.value
      } else if let previousTask {
        await previousTask.value
      } else if let nextTask {
        await nextTask.value
      } else {
        return
      }
    }
  }

  private func selectionDidChange(from oldValue: ThreadPictureOccurrenceID?) {
    guard let selectedID else { return }

    if case .local = selectedID {
      preferredLocalSelectionID = selectedID
    } else if let localID = localID(migratedTo: selectedID) {
      preferredLocalSelectionID = localID
    }

    if isBootstrapping, selectedID != oldValue {
      invalidateAllLoads()
      hasBootstrapped = false
      bootstrapError = nil
      startBootstrapIfNeeded()
      return
    }
    loadAtSelectedEdgeIfNeeded()
  }

  private func startBootstrapIfNeeded() {
    guard
      isRemoteLoadingEnabled,
      !hasBootstrapped,
      bootstrapTask == nil,
      bootstrapError == nil,
      context.canRequestRemotePictures,
      let selectedOccurrence,
      let request = makeRequest(direction: .bootstrap, anchor: selectedOccurrence)
    else {
      if bootstrapTask == nil, bootstrapError == nil {
        hasBootstrapped = true
      }
      return
    }

    generation &+= 1
    let requestGeneration = generation
    bootstrapToken &+= 1
    let token = bootstrapToken
    let selectedIDAtRequest = selectedOccurrence.id
    let service = service
    isBootstrapping = true

    bootstrapTask = Task { [weak self] in
      do {
        let page = try await service.picturePage(for: request)
        try Task.checkCancellation()
        guard let self else { return }
        self.receiveBootstrap(
          page,
          selectedIDAtRequest: selectedIDAtRequest,
          generation: requestGeneration,
          token: token
        )
      } catch is CancellationError {
        self?.finishBootstrap(generation: requestGeneration, token: token)
      } catch {
        self?.failBootstrap(error, generation: requestGeneration, token: token)
      }
    }
  }

  private func startPreviousLoad(requiresSelectedEdge: Bool = true) {
    guard
      isRemoteLoadingEnabled,
      hasBootstrapped,
      canLoadPrevious,
      previousTask == nil,
      previousError == nil,
      !isBootstrapping,
      (!requiresSelectedEdge || selectedIndex == occurrences.startIndex),
      let anchor = occurrences.compactMap({ occurrence -> ThreadPictureOccurrence? in
        occurrence.overallIndex == nil ? nil : occurrence
      }).min(by: { ($0.overallIndex ?? .max) < ($1.overallIndex ?? .max) }),
      let request = makeRequest(direction: .previous, anchor: anchor)
    else { return }

    let requestGeneration = generation
    previousToken &+= 1
    let token = previousToken
    let service = service
    isLoadingPrevious = true

    previousTask = Task { [weak self] in
      do {
        let page = try await service.picturePage(for: request)
        try Task.checkCancellation()
        guard let self else { return }
        self.receivePrevious(page, generation: requestGeneration, token: token)
      } catch is CancellationError {
        self?.finishPrevious(generation: requestGeneration, token: token)
      } catch {
        self?.failPrevious(error, generation: requestGeneration, token: token)
      }
    }
  }

  private func startNextLoad(requiresSelectedEdge: Bool = true) {
    guard
      isRemoteLoadingEnabled,
      hasBootstrapped,
      canLoadNext,
      nextTask == nil,
      nextError == nil,
      !isBootstrapping,
      !occurrences.isEmpty,
      (!requiresSelectedEdge || selectedIndex == occurrences.index(before: occurrences.endIndex)),
      let anchor = occurrences.compactMap({ occurrence -> ThreadPictureOccurrence? in
        occurrence.overallIndex == nil ? nil : occurrence
      }).max(by: { ($0.overallIndex ?? .min) < ($1.overallIndex ?? .min) }),
      let request = makeRequest(direction: .next, anchor: anchor)
    else { return }

    let requestGeneration = generation
    nextToken &+= 1
    let token = nextToken
    let service = service
    isLoadingNext = true

    nextTask = Task { [weak self] in
      do {
        let page = try await service.picturePage(for: request)
        try Task.checkCancellation()
        guard let self else { return }
        self.receiveNext(page, generation: requestGeneration, token: token)
      } catch is CancellationError {
        self?.finishNext(generation: requestGeneration, token: token)
      } catch {
        self?.failNext(error, generation: requestGeneration, token: token)
      }
    }
  }

  private func receiveBootstrap(
    _ page: ThreadPicturePage,
    selectedIDAtRequest: ThreadPictureOccurrenceID,
    generation requestGeneration: Int,
    token: Int
  ) {
    guard isCurrentBootstrap(generation: requestGeneration, token: token) else { return }
    defer { finishBootstrap(generation: requestGeneration, token: token) }
    hasBootstrapped = true

    guard
      selectedID == selectedIDAtRequest,
      let selectedOccurrence,
      let normalizedPage = normalizedRemotePage(page),
      !normalizedPage.occurrences.isEmpty
    else {
      previousStalled = true
      nextStalled = true
      refreshAvailabilityFromRemoteBounds()
      return
    }

    let selectedPair = Self.picturePostPair(selectedOccurrence)
    let selectedLocalMatches = localOccurrences.filter {
      Self.picturePostPair($0) == selectedPair
    }
    let selectedRemoteMatches = normalizedPage.occurrences.filter {
      Self.picturePostPair($0) == selectedPair
    }
    guard
      selectedLocalMatches.count == 1,
      selectedLocalMatches.first?.id == selectedIDAtRequest,
      selectedRemoteMatches.count == 1,
      let remoteSelection = selectedRemoteMatches.first
    else {
      previousStalled = true
      nextStalled = true
      refreshAvailabilityFromRemoteBounds()
      return
    }

    let candidate = bootstrapCandidateOccurrences(
      remote: normalizedPage.occurrences,
      around: selectedOccurrence.id
    )
    let reconciled = reconcilingLocalOccurrences(
      in: candidate,
      selectedID: selectedOccurrence.id,
      existingMigrations: [:]
    )
    guard reconciled.selectedID == remoteSelection.id else {
      previousStalled = true
      nextStalled = true
      refreshAvailabilityFromRemoteBounds()
      return
    }
    galleryState = ThreadPictureGalleryState(
      occurrences: reconciled.occurrences,
      selectedID: reconciled.selectedID,
      totalCount: normalizedPage.totalCount,
      localToRemoteIDMigrations: reconciled.migrations,
      viewerContextRevision: viewerContextRevision
    )
    previousStalled = false
    nextStalled = false
    refreshAvailabilityFromRemoteBounds()
  }

  private func receivePrevious(
    _ page: ThreadPicturePage,
    generation requestGeneration: Int,
    token: Int
  ) {
    guard isCurrentPrevious(generation: requestGeneration, token: token) else { return }
    defer { finishPrevious(generation: requestGeneration, token: token) }
    previousError = nil

    guard
      page.totalCount >= totalCount,
      let normalizedPage = normalizedRemotePage(page),
      let currentMinimum = minimumRemoteIndex
    else {
      previousStalled = true
      refreshAvailabilityFromRemoteBounds()
      return
    }

    let existingIDs = Set(occurrences.map(\.id))
    let additions = normalizedPage.occurrences.filter {
      ($0.overallIndex ?? .max) < currentMinimum && !existingIDs.contains($0.id)
    }
    guard !additions.isEmpty else {
      previousStalled = true
      refreshAvailabilityFromRemoteBounds()
      return
    }

    let reconciled = reconcilingLocalOccurrences(
      in: additions + occurrences,
      selectedID: selectedID,
      existingMigrations: galleryState.localToRemoteIDMigrations
    )
    galleryState = ThreadPictureGalleryState(
      occurrences: reconciled.occurrences,
      selectedID: reconciled.selectedID,
      totalCount: normalizedPage.totalCount,
      localToRemoteIDMigrations: reconciled.migrations,
      viewerContextRevision: viewerContextRevision
    )
    previousStalled = false
    refreshAvailabilityFromRemoteBounds()
  }

  private func receiveNext(
    _ page: ThreadPicturePage,
    generation requestGeneration: Int,
    token: Int
  ) {
    guard isCurrentNext(generation: requestGeneration, token: token) else { return }
    defer { finishNext(generation: requestGeneration, token: token) }
    nextError = nil

    guard
      page.totalCount >= totalCount,
      let normalizedPage = normalizedRemotePage(page),
      let currentMaximum = maximumRemoteIndex
    else {
      nextStalled = true
      refreshAvailabilityFromRemoteBounds()
      return
    }

    let existingIDs = Set(occurrences.map(\.id))
    let additions = normalizedPage.occurrences.filter {
      ($0.overallIndex ?? .min) > currentMaximum && !existingIDs.contains($0.id)
    }
    guard !additions.isEmpty else {
      nextStalled = true
      refreshAvailabilityFromRemoteBounds()
      return
    }

    let reconciled = reconcilingLocalOccurrences(
      in: occurrences + additions,
      selectedID: selectedID,
      existingMigrations: galleryState.localToRemoteIDMigrations
    )
    galleryState = ThreadPictureGalleryState(
      occurrences: reconciled.occurrences,
      selectedID: reconciled.selectedID,
      totalCount: normalizedPage.totalCount,
      localToRemoteIDMigrations: reconciled.migrations,
      viewerContextRevision: viewerContextRevision
    )
    nextStalled = false
    refreshAvailabilityFromRemoteBounds()
  }

  private func failBootstrap(_ error: any Error, generation requestGeneration: Int, token: Int) {
    guard isCurrentBootstrap(generation: requestGeneration, token: token) else { return }
    bootstrapError = error.localizedDescription
    finishBootstrap(generation: requestGeneration, token: token)
  }

  private func failPrevious(_ error: any Error, generation requestGeneration: Int, token: Int) {
    guard isCurrentPrevious(generation: requestGeneration, token: token) else { return }
    previousError = error.localizedDescription
    finishPrevious(generation: requestGeneration, token: token)
  }

  private func failNext(_ error: any Error, generation requestGeneration: Int, token: Int) {
    guard isCurrentNext(generation: requestGeneration, token: token) else { return }
    nextError = error.localizedDescription
    finishNext(generation: requestGeneration, token: token)
  }

  private func finishBootstrap(generation requestGeneration: Int, token: Int) {
    guard isCurrentBootstrap(generation: requestGeneration, token: token) else { return }
    bootstrapTask = nil
    isBootstrapping = false
    loadAtSelectedEdgeIfNeeded()
  }

  private func finishPrevious(generation requestGeneration: Int, token: Int) {
    guard isCurrentPrevious(generation: requestGeneration, token: token) else { return }
    previousTask = nil
    isLoadingPrevious = false
    loadAtSelectedEdgeIfNeeded()
  }

  private func finishNext(generation requestGeneration: Int, token: Int) {
    guard isCurrentNext(generation: requestGeneration, token: token) else { return }
    nextTask = nil
    isLoadingNext = false
    loadAtSelectedEdgeIfNeeded()
  }

  private func loadAtSelectedEdgeIfNeeded() {
    guard
      isRemoteLoadingEnabled,
      hasBootstrapped,
      !isBootstrapping,
      let selectedIndex,
      !occurrences.isEmpty
    else { return }

    if selectedIndex == occurrences.startIndex, canLoadPrevious {
      startPreviousLoad()
    }
    if selectedIndex == occurrences.index(before: occurrences.endIndex), canLoadNext {
      startNextLoad()
    }
  }

  private func makeRequest(
    direction: ThreadPicturePageDirection,
    anchor: ThreadPictureOccurrence
  ) -> ThreadPicturePageRequest? {
    let pictureID = anchor.pictureID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      context.canRequestRemotePictures,
      !pictureID.isEmpty,
      anchor.postID > 0,
      let anchorIndex = requestIndex(for: anchor),
      anchorIndex > 0
    else { return nil }

    return ThreadPicturePageRequest(
      context: context,
      direction: direction,
      anchorPictureID: pictureID,
      anchorPostID: anchor.postID,
      anchorIndex: anchorIndex,
      anchorURL: anchor.url
    )
  }

  private func requestIndex(for occurrence: ThreadPictureOccurrence) -> Int? {
    if let overallIndex = occurrence.overallIndex {
      return overallIndex
    }
    if let imageOrdinal = occurrence.imageOrdinal, imageOrdinal > 0 {
      return imageOrdinal
    }
    return localOccurrences.firstIndex(where: { $0.id == occurrence.id }).map { $0 + 1 }
  }

  private func normalizedRemotePage(_ page: ThreadPicturePage) -> ThreadPicturePage? {
    guard page.totalCount > 0, page.totalCount >= (maximumRemoteIndex ?? 0) else { return nil }

    var seenIDs = Set<ThreadPictureOccurrenceID>()
    let uniqueRemote = page.occurrences.filter { occurrence in
      guard
        case .remote(let overallIndex, let pictureID, let postID) = occurrence.id,
        overallIndex > 0,
        overallIndex <= page.totalCount,
        postID > 0,
        !pictureID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        pictureID == occurrence.pictureID,
        postID == occurrence.postID,
        seenIDs.insert(occurrence.id).inserted
      else { return false }
      return true
    }

    let indexCounts = Dictionary(grouping: uniqueRemote, by: { $0.overallIndex ?? 0 })
      .mapValues(\.count)
    let normalized = uniqueRemote
      .filter { indexCounts[$0.overallIndex ?? 0] == 1 }
      .sorted { ($0.overallIndex ?? .max) < ($1.overallIndex ?? .max) }
    return ThreadPicturePage(occurrences: normalized, totalCount: page.totalCount)
  }

  private func bootstrapCandidateOccurrences(
    remote: [ThreadPictureOccurrence],
    around selectedLocalID: ThreadPictureOccurrenceID
  ) -> [ThreadPictureOccurrence] {
    guard
      let selectedLocalIndex = localOccurrences.firstIndex(where: { $0.id == selectedLocalID })
    else {
      return remote
    }

    let prefix = Array(localOccurrences[..<selectedLocalIndex])
    let selected = localOccurrences[selectedLocalIndex]
    let suffix = Array(localOccurrences[localOccurrences.index(after: selectedLocalIndex)...])
    return prefix + [selected] + remote + suffix
  }

  private func reconcilingLocalOccurrences(
    in candidate: [ThreadPictureOccurrence],
    selectedID: ThreadPictureOccurrenceID?,
    existingMigrations: [ThreadPictureOccurrenceID: ThreadPictureOccurrenceID]
  ) -> (
    occurrences: [ThreadPictureOccurrence],
    selectedID: ThreadPictureOccurrenceID?,
    migrations: [ThreadPictureOccurrenceID: ThreadPictureOccurrenceID]
  ) {
    let localByPair = Dictionary(grouping: localOccurrences, by: Self.picturePostPair)
    let remoteByPair = Dictionary(
      grouping: candidate.filter { occurrence in
        if case .remote = occurrence.id { return true }
        return false
      },
      by: Self.picturePostPair
    )
    let candidateIDs = Set(candidate.map(\.id))
    var migrations = existingMigrations
    var claimedRemoteIDs = Set(existingMigrations.values)

    for (pair, localMatches) in localByPair where localMatches.count == 1 {
      guard
        let local = localMatches.first,
        candidateIDs.contains(local.id),
        migrations[local.id] == nil,
        let remoteMatches = remoteByPair[pair],
        remoteMatches.count == 1,
        let remote = remoteMatches.first,
        claimedRemoteIDs.insert(remote.id).inserted
      else { continue }
      migrations[local.id] = remote.id
    }

    let reconciled = candidate.filter { occurrence in
      guard case .local = occurrence.id else { return true }
      return migrations[occurrence.id] == nil
    }
    let resolvedSelection = selectedID.flatMap { migrations[$0] } ?? selectedID
    return (reconciled, resolvedSelection, migrations)
  }

  private func refreshAvailabilityFromRemoteBounds() {
    canLoadPrevious = !previousStalled && (minimumRemoteIndex ?? 1) > 1
    canLoadNext = !nextStalled && (maximumRemoteIndex ?? totalCount) < totalCount
  }

  private var minimumRemoteIndex: Int? {
    occurrences.compactMap(\.overallIndex).min()
  }

  private var maximumRemoteIndex: Int? {
    occurrences.compactMap(\.overallIndex).max()
  }

  private func restoreLocalSnapshot(
    selection: ThreadPictureOccurrenceID? = nil,
    resetsViewerContext: Bool = true
  ) {
    let previousSelection = selectedID
    let migrations = galleryState.localToRemoteIDMigrations
    let selection = selection
      ?? localSelection(for: previousSelection, migrations: migrations)
      ?? preferredLocalSelectionID
    let validSelection = Self.validSelection(selection, in: localOccurrences)
    preferredLocalSelectionID = validSelection
    if resetsViewerContext {
      viewerContextRevision &+= 1
    }
    galleryState = ThreadPictureGalleryState(
      occurrences: localOccurrences,
      selectedID: validSelection,
      totalCount: localOccurrences.count,
      localToRemoteIDMigrations: [:],
      viewerContextRevision: viewerContextRevision
    )
    hasBootstrapped = false
    bootstrapError = nil
    previousError = nil
    nextError = nil
    previousStalled = false
    nextStalled = false
    canLoadPrevious = false
    canLoadNext = false
  }

  private func localSelection(
    for selection: ThreadPictureOccurrenceID?,
    migrations: [ThreadPictureOccurrenceID: ThreadPictureOccurrenceID]
  ) -> ThreadPictureOccurrenceID? {
    guard let selection else { return nil }
    if case .local = selection {
      return selection
    }
    return migrations.first(where: { $0.value == selection })?.key
  }

  private func localID(
    migratedTo remoteID: ThreadPictureOccurrenceID
  ) -> ThreadPictureOccurrenceID? {
    galleryState.localToRemoteIDMigrations.first(where: { $0.value == remoteID })?.key
  }

  private func invalidateAllLoads() {
    generation &+= 1
    bootstrapTask?.cancel()
    previousTask?.cancel()
    nextTask?.cancel()
    bootstrapTask = nil
    previousTask = nil
    nextTask = nil
    isBootstrapping = false
    isLoadingPrevious = false
    isLoadingNext = false
    bootstrapError = nil
    previousError = nil
    nextError = nil
  }

  private func setSelectedIDInternally(_ id: ThreadPictureOccurrenceID?) {
    galleryState = ThreadPictureGalleryState(
      occurrences: occurrences,
      selectedID: id,
      totalCount: totalCount,
      localToRemoteIDMigrations: galleryState.localToRemoteIDMigrations,
      viewerContextRevision: viewerContextRevision
    )
  }

  private func isCurrentBootstrap(generation requestGeneration: Int, token: Int) -> Bool {
    generation == requestGeneration && bootstrapToken == token && bootstrapTask != nil
  }

  private func isCurrentPrevious(generation requestGeneration: Int, token: Int) -> Bool {
    generation == requestGeneration && previousToken == token && previousTask != nil
  }

  private func isCurrentNext(generation requestGeneration: Int, token: Int) -> Bool {
    generation == requestGeneration && nextToken == token && nextTask != nil
  }

  private static func normalizedLocalOccurrences(
    _ occurrences: [ThreadPictureOccurrence]
  ) -> [ThreadPictureOccurrence] {
    var seen = Set<ThreadPictureOccurrenceID>()
    return occurrences.filter { occurrence in
      guard case .local = occurrence.id else { return false }
      return seen.insert(occurrence.id).inserted
    }
  }

  private static func validSelection(
    _ selection: ThreadPictureOccurrenceID?,
    in occurrences: [ThreadPictureOccurrence]
  ) -> ThreadPictureOccurrenceID? {
    if let selection, occurrences.contains(where: { $0.id == selection }) {
      return selection
    }
    return occurrences.first?.id
  }

  private static func picturePostPair(
    _ occurrence: ThreadPictureOccurrence
  ) -> PicturePostPair {
    PicturePostPair(pictureID: occurrence.pictureID, postID: occurrence.postID)
  }
}

private struct PicturePostPair: Hashable {
  let pictureID: String
  let postID: Int64
}
