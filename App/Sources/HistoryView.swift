import Combine
import SwiftUI

@MainActor
final class BrowsingHistoryViewModel: ObservableObject {
  @Published private(set) var entries: [BrowsingHistoryEntry] = []
  @Published private(set) var state: LoadState = .idle
  @Published private(set) var recordingEnabled = true
  @Published private(set) var operationError: String?
  @Published private(set) var isActive = false
  @Published private(set) var isMutating = false
  @Published var selectedKind: BrowsingHistoryKind = .thread

  private let repository: any BrowsingHistoryRepository
  private var readTask: Task<Void, Never>?
  private var mutationTask: Task<Void, Never>?
  private var generation = 0
  private var mutationGeneration = 0
  private var latestRecordingMutation: Int?
  private var confirmedRecordingEnabled = true

  init(repository: any BrowsingHistoryRepository) {
    self.repository = repository
  }

  var visibleEntries: [BrowsingHistoryEntry] {
    entries(for: selectedKind)
  }

  var forumEntries: [BrowsingHistoryEntry] {
    entries(for: .forum)
  }

  func entries(for kind: BrowsingHistoryKind) -> [BrowsingHistoryEntry] {
    entries.filter { $0.kind == kind }
  }

  func sections(
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> (today: [BrowsingHistoryEntry], earlier: [BrowsingHistoryEntry]) {
    sections(kind: selectedKind, now: now, calendar: calendar)
  }

  func sections(
    kind: BrowsingHistoryKind,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> (today: [BrowsingHistoryEntry], earlier: [BrowsingHistoryEntry]) {
    let visibleEntries = entries(for: kind)
    return (
      visibleEntries.filter { calendar.isDate($0.lastVisitedAt, inSameDayAs: now) },
      visibleEntries.filter { !calendar.isDate($0.lastVisitedAt, inSameDayAs: now) }
    )
  }

  func activate() {
    guard !isActive else { return }
    isActive = true
    // A detail visit can update the existing record's metadata and date.
    // Refresh the shared snapshot without replacing either native List.
    reload()
  }

  func loadIfNeeded() {
    guard state == .idle else { return }
    reload()
  }

  func reload() {
    startLoading(showProgress: entries.isEmpty)
  }

  func refresh() async {
    guard !Task.isCancelled else { return }
    if let mutationTask {
      await mutationTask.value
      return
    }
    if readTask == nil {
      startLoading(showProgress: entries.isEmpty)
    }
    await readTask?.value
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
    mutate(recordingPreference: enabled) { repository in
      try await repository.setRecordingEnabled(enabled)
    }
  }

  func dismissOperationError() {
    operationError = nil
  }

  func cancel() {
    isActive = false
    cancelRead()
  }

  private func cancelRead() {
    generation &+= 1
    readTask?.cancel()
    readTask = nil
    if state == .loading {
      state = entries.isEmpty ? .idle : .loaded
    }
  }

  private func startLoading(showProgress: Bool) {
    // The final queued mutation reads back both projections. Do not race a
    // second read against an accepted delete, clear, or recording preference.
    guard mutationTask == nil else { return }
    generation &+= 1
    let currentGeneration = generation
    readTask?.cancel()
    operationError = nil
    if showProgress {
      state = .loading
    }
    let repository = repository
    readTask = Task {
      defer {
        if currentGeneration == generation {
          readTask = nil
        }
      }
      do {
        async let loadedEntries = repository.entries(kind: nil)
        async let loadedRecordingEnabled = repository.isRecordingEnabled()
        let (entries, recordingEnabled) = try await (loadedEntries, loadedRecordingEnabled)
        try Task.checkCancellation()
        guard currentGeneration == generation else { return }
        self.entries = entries
        confirmedRecordingEnabled = recordingEnabled
        self.recordingEnabled = recordingEnabled
        state = .loaded
      } catch is CancellationError {
        return
      } catch {
        guard currentGeneration == generation, !Task.isCancelled else { return }
        state = .failed(error.localizedDescription)
        if !entries.isEmpty { operationError = error.localizedDescription }
      }
    }
  }

  private func mutate(
    recordingPreference: Bool? = nil,
    operation: @escaping @Sendable (any BrowsingHistoryRepository) async throws -> Void
  ) {
    cancelRead()
    mutationGeneration &+= 1
    let currentMutation = mutationGeneration
    let previousMutation = mutationTask
    if let recordingPreference {
      latestRecordingMutation = currentMutation
      recordingEnabled = recordingPreference
    }
    isMutating = true
    operationError = nil
    let repository = repository
    mutationTask = Task {
      // These are explicit local writes. Navigation cancellation and another
      // user action must not drop an already accepted operation.
      await previousMutation?.value
      defer {
        if currentMutation == mutationGeneration {
          mutationTask = nil
          isMutating = false
        }
      }
      do {
        try await operation(repository)
        if let recordingPreference {
          confirmedRecordingEnabled = recordingPreference
        }
      } catch {
        operationError = error.localizedDescription
      }
      if latestRecordingMutation == currentMutation {
        latestRecordingMutation = nil
        recordingEnabled = confirmedRecordingEnabled
      }
      guard currentMutation == mutationGeneration else { return }
      do {
        async let loadedEntries = repository.entries(kind: nil)
        async let loadedRecordingEnabled = repository.isRecordingEnabled()
        let (entries, recordingEnabled) = try await (loadedEntries, loadedRecordingEnabled)
        guard currentMutation == mutationGeneration else { return }
        self.entries = entries
        confirmedRecordingEnabled = recordingEnabled
        self.recordingEnabled = recordingEnabled
        state = .loaded
      } catch {
        guard currentMutation == mutationGeneration else { return }
        state = .failed(error.localizedDescription)
        operationError = error.localizedDescription
      }
    }
  }
}

struct HistoryView: View {
  let onOpen: (BrowsingHistoryTarget) -> Void

  @Environment(\.layoutDirection) private var layoutDirection
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
    // Keep both native lists mounted, but leave their horizontal gestures to
    // row swipe actions. Category dragging belongs to the selector above them.
    ZStack {
      ForEach(BrowsingHistoryKind.allCases) { kind in
        HistoryPageView(kind: kind, model: viewModel, onOpen: onOpen)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .opacity(viewModel.selectedKind == kind ? 1 : 0)
          .allowsHitTesting(viewModel.selectedKind == kind)
          .accessibilityHidden(viewModel.selectedKind != kind)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
          Label(
            "浏览记录设置",
            systemName: viewModel.recordingEnabled
              ? "clock.arrow.circlepath"
              : "clock.badge.xmark"
          )
          .labelStyle(.iconOnly)
          .accessibilityLabel("浏览记录设置")
          .accessibilityIdentifier("history-recording-menu")
        }
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
    .onAppear(perform: viewModel.activate)
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
          Text(kind.title)
            .tag(kind)
            .accessibilityIdentifier("history-kind-\(kind.rawValue)")
        }
      }
      .pickerStyle(.segmented)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .appRegularMaterialSurface()
      .accessibilityIdentifier("history-kind-picker")

      Divider()
    }
    .contentShape(Rectangle())
    .simultaneousGesture(
      DragGesture(minimumDistance: 24)
        .onEnded { value in
          let horizontal = value.translation.width
          guard abs(horizontal) >= 40, abs(horizontal) > abs(value.translation.height) * 1.5 else {
            return
          }
          // Use the destination rather than advancing from the current value:
          // the native segmented control may already have tracked this drag.
          let movesForward = layoutDirection == .rightToLeft ? horizontal > 0 : horizontal < 0
          viewModel.selectedKind = movesForward ? .forum : .thread
        }
    )
  }
}

/// Both pages observe one repository snapshot. Keeping the List mounted through
/// loading, empty, error, and selection changes preserves its native position.
private struct HistoryPageView: View {
  let kind: BrowsingHistoryKind
  @ObservedObject var model: BrowsingHistoryViewModel
  let onOpen: (BrowsingHistoryTarget) -> Void

  var body: some View {
    historyList
      .allowsHitTesting(isActive)
      .accessibilityHidden(!isActive)
      .overlay { stateOverlay }
  }

  private var isActive: Bool {
    model.isActive && model.selectedKind == kind
  }

  @ViewBuilder
  private var stateOverlay: some View {
    if model.entries(for: kind).isEmpty {
      switch model.state {
      case .idle, .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ErrorStateView(message: message) {
          if isActive { model.reload() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded:
        EmptyStateView(
          title: kind == .thread ? "暂无帖子记录" : "暂无贴吧记录",
          systemImage: "clock"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
      }
    }
  }

  private var historyList: some View {
    let sections = model.sections(kind: kind)
    return List {
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
    .appScrollableSurface()
    .accessibilityIdentifier("history-\(kind.rawValue)-list")
    .refreshable {
      // The refresh control may retain its initial closure when the initially
      // hidden page mounts. Read activity from the shared model at invocation.
      if model.isActive, model.selectedKind == kind, !Task.isCancelled {
        await model.refresh()
      }
    }
  }

  @ViewBuilder
  private func historyRows(_ entries: [BrowsingHistoryEntry]) -> some View {
    ForEach(entries) { entry in
      Button {
        if isActive { onOpen(entry.target) }
      } label: {
        HistoryRow(entry: entry)
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("history-entry-\(entry.id)")
      .swipeActions(edge: .trailing, allowsFullSwipe: true) {
        Button(role: .destructive) {
          if isActive { model.delete(entry) }
        } label: {
          Label("删除", systemImage: "trash")
        }
      }
    }
  }
}

private struct HistoryRow: View {
  let entry: BrowsingHistoryEntry

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
      return [thread.forumName, displayedAuthorName(thread), readingProgress]
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

  private var expandedThreadMetadata: [String]? {
    guard case .thread(let thread) = entry.target else { return nil }
    let singleName = UserNameFormatter.displayName(
      preferredName: thread.authorName,
      username: thread.authorUsername,
      showsBoth: false
    )
    let combinedName = displayedAuthorName(thread)
    guard showsBothNames, combinedName != singleName else { return nil }
    let readingProgress = thread.lastFloor.map { "读至 \($0) 楼" } ?? ""
    return [thread.forumName, combinedName, readingProgress].filter { !$0.isEmpty }
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
