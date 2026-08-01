import Combine
import SwiftUI

@MainActor
final class BrowsingHistoryViewModel: ObservableObject {
  @Published private(set) var entries: [BrowsingHistoryEntry] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var recordingEnabled = true
  @Published private(set) var operationError: String?
  @Published var selectedKind: BrowsingHistoryKind = .thread

  private let repository: any BrowsingHistoryRepository
  private var task: Task<Void, Never>?
  private var generation = 0

  init(repository: any BrowsingHistoryRepository) {
    self.repository = repository
  }

  var visibleEntries: [BrowsingHistoryEntry] {
    entries.filter { $0.kind == selectedKind }
  }

  func sections(
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> (today: [BrowsingHistoryEntry], earlier: [BrowsingHistoryEntry]) {
    let visibleEntries = visibleEntries
    return (
      visibleEntries.filter { calendar.isDate($0.lastVisitedAt, inSameDayAs: now) },
      visibleEntries.filter { !calendar.isDate($0.lastVisitedAt, inSameDayAs: now) }
    )
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

  func delete(_ entry: BrowsingHistoryEntry) {
    mutate { repository in
      try await repository.delete(id: entry.id)
    }
  }

  func clearAll() {
    mutate { repository in
      try await repository.deleteAll(kind: nil)
    }
  }

  func setRecordingEnabled(_ enabled: Bool) {
    guard recordingEnabled != enabled else { return }
    let previousValue = recordingEnabled
    recordingEnabled = enabled
    mutate(onFailure: { [weak self] in self?.recordingEnabled = previousValue }) { repository in
      try await repository.setRecordingEnabled(enabled)
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
    if showProgress {
      state = .loading
    }
    let repository = repository
    task = Task {
      defer {
        if currentGeneration == generation {
          task = nil
        }
      }
      do {
        async let loadedEntries = repository.entries(kind: nil)
        async let loadedRecordingEnabled = repository.isRecordingEnabled()
        let (entries, recordingEnabled) = try await (loadedEntries, loadedRecordingEnabled)
        try Task.checkCancellation()
        guard currentGeneration == generation else { return }
        self.entries = entries
        self.recordingEnabled = recordingEnabled
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
    onFailure: @escaping @MainActor () -> Void = {},
    operation: @escaping @Sendable (any BrowsingHistoryRepository) async throws -> Void
  ) {
    generation &+= 1
    let currentGeneration = generation
    task?.cancel()
    let repository = repository
    task = Task {
      defer {
        if currentGeneration == generation {
          task = nil
        }
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
        onFailure()
        operationError = error.localizedDescription
      }
    }
  }
}

struct HistoryView: View {
  let onOpen: (BrowsingHistoryTarget) -> Void

  @StateObject private var viewModel: BrowsingHistoryViewModel
  @State private var showsClearConfirmation = false

  init(
    repository: any BrowsingHistoryRepository,
    onOpen: @escaping (BrowsingHistoryTarget) -> Void
  ) {
    self.onOpen = onOpen
    _viewModel = StateObject(wrappedValue: BrowsingHistoryViewModel(repository: repository))
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
          historyList
        }
      } else {
        historyList
      }
    }
    .navigationTitle("浏览记录")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .top, spacing: 0) {
      categoryPicker
    }
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Menu {
          Toggle(
            "记录浏览历史",
            isOn: Binding(
              get: { viewModel.recordingEnabled },
              set: { viewModel.setRecordingEnabled($0) }
            )
          )
        } label: {
          Image(
            systemName: viewModel.recordingEnabled
              ? "clock.arrow.circlepath"
              : "clock.badge.xmark"
          )
        }
        .accessibilityLabel("浏览记录设置")
        .help("浏览记录设置")

        Button(role: .destructive) {
          showsClearConfirmation = true
        } label: {
          Image(systemName: "trash")
        }
        .disabled(viewModel.entries.isEmpty)
        .accessibilityLabel("清空浏览记录")
        .help("清空浏览记录")
      }
    }
    .confirmationDialog(
      "清空全部浏览记录？",
      isPresented: $showsClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("清空全部记录", role: .destructive, action: viewModel.clearAll)
      Button("取消", role: .cancel) {}
    }
    .alert(
      "无法更新浏览记录",
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
        "记录类型",
        selection: Binding(
          get: { viewModel.selectedKind },
          set: { viewModel.selectedKind = $0 }
        )
      ) {
        ForEach(BrowsingHistoryKind.allCases) { kind in
          Text(kind.title).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .background(.regularMaterial)
      .accessibilityIdentifier("history-kind-picker")

      Divider()
    }
  }

  private var historyList: some View {
    let sections = viewModel.sections()
    return List {
      if viewModel.visibleEntries.isEmpty {
        EmptyStateView(
          title: viewModel.selectedKind == .thread ? "暂无帖子记录" : "暂无贴吧记录",
          systemImage: "clock"
        )
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
      }

      if !sections.today.isEmpty {
        Section("今天") {
          historyRows(sections.today)
        }
      }

      if !sections.earlier.isEmpty {
        Section("更早") {
          historyRows(sections.earlier)
        }
      }
    }
    .listStyle(.insetGrouped)
    .refreshable { await viewModel.refresh() }
  }

  @ViewBuilder
  private func historyRows(_ entries: [BrowsingHistoryEntry]) -> some View {
    ForEach(entries) { entry in
      Button {
        onOpen(entry.target)
      } label: {
        HistoryRow(entry: entry)
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
}

private struct HistoryRow: View {
  let entry: BrowsingHistoryEntry

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      AvatarView(url: avatarURL, name: avatarName, size: 40)

      VStack(alignment: .leading, spacing: 5) {
        Text(title)
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(2)

        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }

        HStack(spacing: 10) {
          Text(entry.lastVisitedAt, style: .relative)
          if entry.visitCount > 1 {
            Label(entry.visitCount.formatted(), systemImage: "arrow.counterclockwise")
          }
        }
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
      return forum.displayName
    case .thread(let thread):
      if !thread.title.isEmpty { return thread.title }
      if !thread.excerpt.isEmpty { return thread.excerpt }
      return "帖子 \(thread.threadID)"
    }
  }

  private var subtitle: String {
    switch entry.target {
    case .forum(let forum):
      return forum.name == forum.displayName ? "" : forum.name
    case .thread(let thread):
      let readingProgress = thread.lastFloor.map { "读至 \($0) 楼" } ?? ""
      return [thread.forumName, thread.authorName, readingProgress]
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }
  }

  private var avatarURL: URL? {
    switch entry.target {
    case .forum(let forum):
      return forum.avatarURL
    case .thread(let thread):
      return thread.authorAvatarURL
    }
  }

  private var avatarName: String {
    switch entry.target {
    case .forum(let forum):
      return forum.displayName
    case .thread(let thread):
      return thread.authorName.isEmpty ? title : thread.authorName
    }
  }
}
