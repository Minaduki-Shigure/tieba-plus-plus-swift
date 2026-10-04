import SwiftUI

/// Keep the native List mounted while the parent changes the selected channel
/// or checks a cached account lease. Rows remain virtualized by List.
struct NotificationsPageView<Row: View>: View {
  @ObservedObject var model: NotificationsViewModel
  let isActive: Bool
  let onRefresh: () async -> Void
  @ViewBuilder let row: (InboxMessagePresentation) -> Row
  @State private var visibleTail: InboxPaginationVisibilityKey?

  var body: some View {
    messageList
      // Opacity preserves the list's measured rows and offset. A spinner alone
      // would leave old private content and its accessibility actions exposed.
      .opacity(isValidatingCachedContent ? 0 : 1)
      .allowsHitTesting(acceptsActions)
      .accessibilityHidden(!isActive || isValidatingCachedContent)
      .overlay { stateOverlay }
      .onAppear(perform: resumeVisiblePagination)
      .onChange(of: isActive) { _ in resumeVisiblePagination() }
      .onChange(of: model.isActive) { _ in resumeVisiblePagination() }
      .onChange(of: model.isResolvingSession) { _ in resumeVisiblePagination() }
      .onChange(of: model.isResolvingContentFilter) { _ in resumeVisiblePagination() }
      .onChange(of: model.state) { _ in resumeVisiblePagination() }
      .alert(
        "刷新失败",
        isPresented: Binding(
          get: { isActive && model.refreshError != nil },
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
    isActive && model.isActive && !isValidatingCachedContent
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
      } else {
        ForEach(model.displayableMessages) { presentation in
          LocallyFilteredContent(
            visibility: presentation.visibility,
            placeholder: "已屏蔽此消息"
          ) {
            row(presentation)
          }
          .frame(minHeight: 44)
        }
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
      } else if model.hasNextPage, let tail = model.paginationTail {
        let key = InboxPaginationVisibilityKey(
          messageID: tail.id, count: model.messages.count, epoch: model.paginationEpoch)
        Color.clear
          .frame(height: 1)
          .id(key)
          .listRowInsets(EdgeInsets())
          .listRowSeparator(.hidden)
          .accessibilityHidden(true)
          .onAppear {
            visibleTail = key
            resumeVisiblePagination()
          }
          .onDisappear {
            if visibleTail == key { visibleTail = nil }
          }
      }

      if model.isLoadingMore {
        HStack {
          Spacer()
          ProgressView()
          Spacer()
        }
        .listRowSeparator(.hidden)
      } else if let message = model.loadMoreError {
        LoadMoreErrorView(message: message) {
          if acceptsActions { model.retryLoadMore() }
        }
        .listRowSeparator(.hidden)
      }
    }
    .listStyle(.plain)
    .appScrollableSurface()
    .accessibilityIdentifier("inbox-\(model.selectedKind.rawValue)-list")
    .refreshable {
      if acceptsActions, !Task.isCancelled { await onRefresh() }
    }
  }

  private func resumeVisiblePagination() {
    guard acceptsActions, let tail = model.paginationTail,
      visibleTail
        == InboxPaginationVisibilityKey(
          messageID: tail.id, count: model.messages.count, epoch: model.paginationEpoch)
    else { return }
    model.loadMoreIfNeeded(current: tail)
  }
}

private struct InboxPaginationVisibilityKey: Hashable {
  let messageID: Int64
  let count: Int
  let epoch: Int
}
