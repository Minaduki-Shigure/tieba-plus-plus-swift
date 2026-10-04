import SwiftUI

/// Keep the native List mounted while the parent changes the selected channel
/// or checks a cached account lease. Rows remain virtualized by List.
struct NotificationsPageView<Row: View>: View {
  @ObservedObject var model: NotificationsViewModel
  let onRefresh: () async -> Void
  @ViewBuilder let row: (InboxMessagePresentation) -> Row
  @State private var visibleMessageIDs: Set<Int64> = []

  var body: some View {
    messageList
      // Opacity preserves the list's measured rows and offset. A spinner alone
      // would leave old private content and its accessibility actions exposed.
      .opacity(isValidatingCachedContent ? 0 : 1)
      .allowsHitTesting(acceptsActions)
      .accessibilityHidden(!model.isActive || isValidatingCachedContent)
      .overlay { stateOverlay }
      .onAppear(perform: resumeVisiblePagination)
      .onChange(of: model.isActive) { _ in resumeVisiblePagination() }
      .onChange(of: model.isResolvingSession) { _ in resumeVisiblePagination() }
      .onChange(of: model.isResolvingContentFilter) { _ in resumeVisiblePagination() }
      .onChange(of: model.state) { _ in resumeVisiblePagination() }
      .onChange(of: model.paginationEpoch) { _ in resumeVisiblePagination() }
      .onChange(of: model.isLoadingMore) { loading in
        // A page may add only filtered messages. Its old visible tail then
        // stays mounted, so there is no new row appearance to continue paging.
        if !loading { resumeVisiblePagination() }
      }
      .alert(
        "刷新失败",
        isPresented: Binding(
          get: { acceptsActions && model.refreshError != nil },
          set: { if !$0 { model.clearRefreshError() } })
      ) {
        Button("好", role: .cancel) { model.clearRefreshError() }
      } message: {
        Text(model.refreshError ?? "无法刷新消息，请重试。")
      }
  }

  private var isValidatingCachedContent: Bool {
    model.isResolvingSession || model.isResolvingContentFilter
  }

  private var acceptsActions: Bool {
    // Native refresh controls can retain the closure installed when an eager
    // pager's initially hidden List mounts. Read activity from the shared model
    // reference rather than a copied View value captured before activation.
    model.isActive && !isValidatingCachedContent
  }

  @ViewBuilder
  private var stateOverlay: some View {
    if isValidatingCachedContent {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if model.messages.isEmpty {
      switch model.state {
      case .idle, .loading:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .failed(let message):
        ErrorStateView(message: message) {
          if acceptsActions { model.reload() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      case .loaded:
        EmptyStateView(
          title: model.selectedKind == .replies ? "暂无回复消息" : "暂无提及消息",
          systemImage: model.selectedKind == .replies ? "bubble.left" : "at"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
      }
    }
  }

  private var messageList: some View {
    List {
      if !model.messages.isEmpty && model.displayableMessages.isEmpty {
        Label(
          model.selectedKind == .replies ? "暂无可显示的回复消息" : "暂无可显示的提及消息",
          systemImage: "eye.slash"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
        .padding(.vertical, 8)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
      }

      ForEach(model.displayableMessages) { presentation in
        LocallyFilteredContent(
          visibility: presentation.visibility,
          placeholder: "已屏蔽此消息"
        ) {
          row(presentation)
        }
        .frame(minHeight: 44)
        .onAppear {
          visibleMessageIDs.insert(presentation.id)
          resumeVisiblePagination()
        }
        .onDisappear { visibleMessageIDs.remove(presentation.id) }
      }

      if !model.messages.isEmpty && model.requiresExplicitPagination {
        Button {
          if acceptsActions { model.continuePagination() }
        } label: {
          Label("继续加载", systemImage: "arrow.down.circle")
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .disabled(model.isLoadingMore || model.loadMoreError != nil)
        .listRowSeparator(.hidden)
      }

      if !model.messages.isEmpty {
        // Keep the measured footer row between requests, including when a
        // completed page contains only hidden messages. Removing and inserting
        // the spinner row changes List's content size at its visible tail and
        // can move the reading position before the next page arrives.
        VStack {
          if let message = model.loadMoreError {
            LoadMoreErrorView(message: message) {
              if acceptsActions { model.retryLoadMore() }
            }
          } else {
            ProgressView()
              .opacity(model.isLoadingMore ? 1 : 0)
          }
        }
        .frame(maxWidth: .infinity, minHeight: 44)
        .allowsHitTesting(acceptsActions && model.loadMoreError != nil)
        .accessibilityHidden(!model.isLoadingMore && model.loadMoreError == nil)
        .listRowSeparator(.hidden)
      }
    }
    .listStyle(.plain)
    .appScrollableSurface()
    .accessibilityIdentifier("inbox-\(model.selectedKind.rawValue)-list")
    .refreshable {
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--inbox-scopes-ui-testing") {
          print(
            "Inbox refresh entered kind=\(model.selectedKind.rawValue) active=\(model.isActive) "
              + "session=\(model.isResolvingSession) filter=\(model.isResolvingContentFilter) "
              + "cancelled=\(Task.isCancelled)")
        }
      #endif
      if acceptsActions, !Task.isCancelled { await onRefresh() }
    }
  }

  private func resumeVisiblePagination() {
    // Anchor pagination to a real row that keeps its identity when a page is
    // appended. Replacing an invisible footer's ID at the end of a native List
    // can move the reading position along with that footer during insertion.
    guard acceptsActions, !model.requiresExplicitPagination,
      let visibleTail = model.displayableMessages.last,
      visibleMessageIDs.contains(visibleTail.id), let tail = model.paginationTail
    else { return }
    model.loadMoreIfNeeded(current: tail)
  }
}
