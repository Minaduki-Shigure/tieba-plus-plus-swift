import Combine
import SwiftUI

@MainActor
final class LocalFavoritesViewModel: ObservableObject {
  @Published private(set) var entries: [LocalFavoriteEntry] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var operationError: String?
  @Published var selectedKind: LocalFavoriteKind = .thread

  private let repository: any LocalFavoritesRepository
  private var task: Task<Void, Never>?
  private var generation = 0

  init(repository: any LocalFavoritesRepository) {
    self.repository = repository
  }

  var visibleEntries: [LocalFavoriteEntry] {
    entries.filter { $0.kind == selectedKind }
  }

  var favoriteForums: [ForumHistorySnapshot] {
    entries.compactMap { entry in
      guard case .forum(let forum) = entry.target else { return nil }
      return forum
    }
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    startLoading(showProgress: entries.isEmpty)
  }

  func refresh() async {
    startLoading(showProgress: false)
    await task?.value
  }

  func delete(_ entry: LocalFavoriteEntry) {
    mutate { repository in
      try await repository.delete(id: entry.id)
    }
  }

  func clearAll() {
    mutate { repository in
      try await repository.deleteAll(kind: nil)
    }
  }

  func dismissOperationError() {
    operationError = nil
  }

  func cancel() {
    generation &+= 1
    task?.cancel()
    task = nil
    if state == .loading {
      state = entries.isEmpty ? .idle : .loaded
    }
  }

  private func startLoading(showProgress: Bool) {
    generation &+= 1
    let currentGeneration = generation
    task?.cancel()
    if showProgress { state = .loading }
    let repository = repository
    task = Task {
      defer {
        if currentGeneration == generation { task = nil }
      }
      do {
        let entries = try await repository.entries(kind: nil)
        try Task.checkCancellation()
        guard currentGeneration == generation else { return }
        self.entries = entries
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard currentGeneration == generation, !Task.isCancelled else { return }
        state = .failed(error.localizedDescription)
      }
    }
  }

  private func mutate(
    operation: @escaping @Sendable (any LocalFavoritesRepository) async throws -> Void
  ) {
    generation &+= 1
    let currentGeneration = generation
    task?.cancel()
    let repository = repository
    task = Task {
      defer {
        if currentGeneration == generation { task = nil }
      }
      do {
        try await operation(repository)
        let entries = try await repository.entries(kind: nil)
        try Task.checkCancellation()
        guard currentGeneration == generation else { return }
        self.entries = entries
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard currentGeneration == generation, !Task.isCancelled else { return }
        operationError = error.localizedDescription
      }
    }
  }
}

struct LocalFavoritesView: View {
  let onOpen: (LocalFavoriteTarget) -> Void

  @StateObject private var viewModel: LocalFavoritesViewModel
  @State private var showsClearConfirmation = false

  init(
    repository: any LocalFavoritesRepository,
    onOpen: @escaping (LocalFavoriteTarget) -> Void
  ) {
    self.onOpen = onOpen
    _viewModel = StateObject(wrappedValue: LocalFavoritesViewModel(repository: repository))
  }

  var body: some View {
    Group {
      if viewModel.entries.isEmpty {
        switch viewModel.state {
        case .idle, .loading:
          ProgressView()
        case .failed(let message):
          ErrorStateView(message: message, retry: viewModel.reload)
        case .loaded:
          favoritesList
        }
      } else {
        favoritesList
      }
    }
    .navigationTitle("本地收藏")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .top, spacing: 0) { categoryPicker }
    .toolbar {
      ToolbarItem(placement: .navigationBarTrailing) {
        Button(role: .destructive) {
          showsClearConfirmation = true
        } label: {
          Image(systemName: "trash")
        }
        .disabled(viewModel.entries.isEmpty)
        .accessibilityLabel("清空本地收藏")
        .help("清空本地收藏")
      }
    }
    .confirmationDialog(
      "清空全部本地收藏？",
      isPresented: $showsClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("清空全部收藏", role: .destructive, action: viewModel.clearAll)
      Button("取消", role: .cancel) {}
    }
    .alert(
      "无法更新本地收藏",
      isPresented: Binding(
        get: { viewModel.operationError != nil },
        set: { if !$0 { viewModel.dismissOperationError() } }
      )
    ) {
      Button("好", action: viewModel.dismissOperationError)
    } message: {
      Text(viewModel.operationError ?? "未知错误")
    }
    .task { await viewModel.refresh() }
    .onDisappear(perform: viewModel.cancel)
  }

  private var categoryPicker: some View {
    VStack(spacing: 0) {
      Picker(
        "收藏类型",
        selection: Binding(
          get: { viewModel.selectedKind },
          set: { viewModel.selectedKind = $0 }
        )
      ) {
        ForEach(LocalFavoriteKind.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.regularMaterial)
      .accessibilityIdentifier("favorite-kind-picker")

      Divider()
    }
  }

  private var favoritesList: some View {
    List {
      if viewModel.visibleEntries.isEmpty {
        EmptyStateView(
          title: viewModel.selectedKind == .thread ? "暂无收藏帖子" : "暂无收藏贴吧",
          systemImage: "bookmark"
        )
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
      }

      ForEach(viewModel.visibleEntries) { entry in
        Button {
          onOpen(entry.target)
        } label: {
          LocalFavoriteRow(entry: entry)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          Button(role: .destructive) {
            viewModel.delete(entry)
          } label: {
            Label("删除", systemImage: "trash")
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .refreshable { await viewModel.refresh() }
  }
}

private struct LocalFavoriteRow: View {
  let entry: LocalFavoriteEntry

  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AvatarView(url: avatarURL, name: avatarName, size: 40)
      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(2)
        if let expandedThreadMetadata {
          ForEach(expandedThreadMetadata.indices, id: \.self) { index in
            Text(expandedThreadMetadata[index])
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .lineLimit(3)
              .minimumScaleFactor(0.75)
          }
        } else if !subtitle.isEmpty {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        Text(entry.savedAt, style: .relative)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(.vertical, 3)
    .contentShape(Rectangle())
  }

  private var title: String {
    switch entry.target {
    case .forum(let forum):
      forum.displayName
    case .thread(let thread):
      !thread.title.isEmpty
        ? thread.title
        : (!thread.excerpt.isEmpty ? thread.excerpt : "帖子 \(thread.threadID)")
    }
  }

  private var subtitle: String {
    switch entry.target {
    case .forum(let forum):
      return forum.name == forum.displayName ? "" : forum.name
    case .thread(let thread):
      let progress = thread.lastFloor.map { "读至 \($0) 楼" } ?? ""
      return [thread.forumName, displayedAuthorName(thread), progress]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }
  }

  private var avatarURL: URL? {
    switch entry.target {
    case .forum(let forum):
      forum.avatarURL
    case .thread(let thread):
      thread.authorAvatarURL
    }
  }

  private var expandedThreadMetadata: [String]? {
    guard case .thread(let thread) = entry.target else { return nil }
    let singleName = UserNameFormatter.displayName(
      preferredName: thread.authorName,
      username: thread.authorUsername,
      showsBoth: false
    )
    let combinedName = displayedAuthorName(thread)
    guard showsBothNames, combinedName != singleName else { return nil }
    let progress = thread.lastFloor.map { "读至 \($0) 楼" } ?? ""
    return [thread.forumName, combinedName, progress].filter { !$0.isEmpty }
  }

  private var avatarName: String {
    switch entry.target {
    case .forum(let forum):
      return forum.displayName
    case .thread(let thread):
      let authorName = displayedAuthorName(thread)
      return authorName.isEmpty ? title : authorName
    }
  }

  private func displayedAuthorName(_ thread: ThreadHistorySnapshot) -> String {
    UserNameFormatter.displayName(
      preferredName: thread.authorName,
      username: thread.authorUsername,
      showsBoth: showsBothNames
    )
  }
}
