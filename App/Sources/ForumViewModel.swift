import Combine
import Foundation

@MainActor
final class ForumViewModel: ObservableObject {
  @Published private(set) var forum: BrowseForum
  @Published private(set) var threads: [BrowseThread] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var isLoadingMore = false
  @Published private(set) var loadMoreError: String?
  @Published private(set) var options: ForumBrowseOptions
  @Published private(set) var channels: [BrowseForumChannel] = []
  @Published private(set) var selectedChannelID: Int?
  @Published private(set) var selectedChannelSort: ForumChannelSort = .unspecified

  let forumName: String

  private let service: any BrowseService
  private var currentPage = 0
  private var hasMore = true
  private var channelCursor: Int64?
  private var channelSortMemory: [Int: ForumChannelSort] = [:]
  private var loadTask: Task<Void, Never>?
  private var loadGeneration = 0

  init(
    forumName: String,
    service: any BrowseService,
    options: ForumBrowseOptions = ForumBrowseOptions()
  ) {
    self.forumName = forumName
    self.forum = .placeholder(name: forumName)
    self.service = service
    self.options = options
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    invalidateCurrentLoad()
    currentPage = 0
    hasMore = true
    channelCursor = nil
    isLoadingMore = false
    loadMoreError = nil
    threads = []
    state = .loading
    load(page: 1, replacing: true)
  }

  func refresh() async {
    reload()
    await loadTask?.value
  }

  func setSort(_ sort: ForumThreadSort) {
    guard selectedChannelID == nil else { return }
    guard options.sort != sort else { return }
    options.sort = sort
    reload()
  }

  func setChannelID(_ channelID: Int?) {
    let channel = channelID.flatMap { requestedID in
      channels.first { $0.id == requestedID }
    }
    if channelID != nil, channel == nil { return }
    guard selectedChannelID != channelID else { return }
    selectedChannelID = channelID
    if let channel {
      let sort = resolvedSort(for: channel)
      selectedChannelSort = sort
      channelSortMemory[channel.id] = sort
      options.featuredOnly = false
      options.featuredClassificationID = nil
    } else {
      selectedChannelSort = .unspecified
    }
    reload()
  }

  func setChannelSort(_ sort: ForumChannelSort) {
    guard
      let channel = selectedChannel,
      channel.sortOptions.contains(where: { $0.id == sort.rawValue })
    else { return }
    guard selectedChannelSort != sort else { return }
    selectedChannelSort = sort
    channelSortMemory[channel.id] = sort
    reload()
  }

  var selectedChannelSortOptions: [BrowseForumChannelSortOption] {
    selectedChannel?.sortOptions ?? []
  }

  func setFeaturedOnly(_ featuredOnly: Bool) {
    guard selectedChannelID == nil else { return }
    guard options.featuredOnly != featuredOnly else { return }
    options.featuredOnly = featuredOnly
    if !featuredOnly {
      options.featuredClassificationID = nil
    }
    reload()
  }

  func setFeaturedClassificationID(_ classificationID: Int?) {
    guard selectedChannelID == nil else { return }
    guard options.featuredClassificationID != classificationID else { return }
    options.featuredOnly = true
    options.featuredClassificationID = classificationID
    reload()
  }

  func cancel() {
    invalidateCurrentLoad()
    isLoadingMore = false
    if state == .loading {
      state = threads.isEmpty ? .idle : .loaded
    }
  }

  func loadMoreIfNeeded(current thread: BrowseThread) {
    guard
      thread.id == threads.last?.id,
      hasMore,
      !isLoadingMore,
      loadMoreError == nil,
      state == .loaded
    else {
      return
    }
    load(page: currentPage + 1, replacing: false)
  }

  func retryLoadMore() {
    guard loadMoreError != nil, hasMore, !isLoadingMore, state == .loaded else { return }
    load(page: currentPage + 1, replacing: false)
  }

  private func load(page: Int, replacing: Bool) {
    let forumName = forumName
    let service = service
    let options = options
    let forum = forum
    let selectedChannel = self.selectedChannel
    let selectedChannelSort = self.selectedChannelSort
    let requestedChannelCursor = replacing ? nil : channelCursor
    loadGeneration &+= 1
    let generation = loadGeneration
    if !replacing {
      loadMoreError = nil
      isLoadingMore = true
    }
    loadTask = Task {
      defer {
        if generation == loadGeneration {
          isLoadingMore = false
          loadTask = nil
        }
      }
      do {
        if let selectedChannel, forum.id > 0 {
          let response = try await service.forumChannelThreads(
            forumID: forum.id,
            forumName: forumName,
            channel: selectedChannel,
            page: page,
            pageSize: 30,
            sort: selectedChannelSort,
            lastThreadID: requestedChannelCursor
          )
          try Task.checkCancellation()
          guard generation == loadGeneration else { return }
          let merged = replacing ? response.threads : merge(threads, response.threads)
          let addedItems = replacing
            ? !response.threads.isEmpty
            : merged.count > threads.count
          let cursorAdvanced = response.nextPageCursor != nil
            && response.nextPageCursor != requestedChannelCursor
          threads = merged
          currentPage = response.currentPage
          channelCursor = response.nextPageCursor
          hasMore = response.hasMore && addedItems && cursorAdvanced
        } else {
          let response = try await service.threads(
            forumName: forumName,
            page: page,
            pageSize: 30,
            options: options
          )
          try Task.checkCancellation()
          guard generation == loadGeneration else { return }
          self.forum = response.forum
          if replacing || !response.channels.isEmpty {
            applyChannels(response.channels)
          }
          currentPage = response.currentPage
          hasMore = response.hasMore
          channelCursor = nil
          threads = replacing ? response.threads : merge(threads, response.threads)
        }
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if replacing {
          state = .failed(error.localizedDescription)
        } else {
          loadMoreError = error.localizedDescription
        }
      }
    }
  }

  private func invalidateCurrentLoad() {
    loadGeneration &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private var selectedChannel: BrowseForumChannel? {
    guard let selectedChannelID else { return nil }
    return channels.first { $0.id == selectedChannelID }
  }

  private func resolvedSort(for channel: BrowseForumChannel) -> ForumChannelSort {
    if let remembered = channelSortMemory[channel.id],
      channel.sortOptions.contains(where: { $0.id == remembered.rawValue })
    {
      return remembered
    }
    return channel.sortOptions.first?.sort ?? .unspecified
  }

  private func applyChannels(_ newChannels: [BrowseForumChannel]) {
    let channelIDs = Set(newChannels.map(\.id))
    channelSortMemory = channelSortMemory.filter { channelIDs.contains($0.key) }
    for channel in newChannels {
      channelSortMemory[channel.id] = resolvedSort(for: channel)
    }
    channels = newChannels

    guard let selectedChannelID else {
      selectedChannelSort = .unspecified
      return
    }
    guard let channel = newChannels.first(where: { $0.id == selectedChannelID }) else {
      self.selectedChannelID = nil
      selectedChannelSort = .unspecified
      channelCursor = nil
      return
    }
    selectedChannelSort = resolvedSort(for: channel)
  }

  private func merge(_ existing: [BrowseThread], _ newItems: [BrowseThread]) -> [BrowseThread] {
    var seen = Set(existing.map(\.id))
    return existing + newItems.filter { seen.insert($0.id).inserted }
  }
}
