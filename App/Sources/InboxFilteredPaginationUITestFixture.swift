#if DEBUG
  import Combine
  import Foundation
  import SwiftUI

  @MainActor
  final class InboxFilteredPaginationUITestProbe: ObservableObject {
    @Published var waitingForPage = 0
    @Published var deliveredHiddenRows = 0
    @Published var deliveredFinalRows = 0
    @Published var filterReads = 0
    @Published var unexpected = 0
  }

  struct InboxFilteredPaginationUITestProbeView: View {
    @ObservedObject var probe: InboxFilteredPaginationUITestProbe

    var body: some View {
      Text(
        "waiting=\(probe.waitingForPage) hiddenRows=\(probe.deliveredHiddenRows) "
          + "finalRows=\(probe.deliveredFinalRows) "
          + "filterReads=\(probe.filterReads) unexpected=\(probe.unexpected)"
      )
      .font(.system(size: 7, design: .monospaced))
      .accessibilityIdentifier("inbox-filtered-pagination-state")
    }
  }

  /// Completes held service IO only. It cannot access a view model, request the
  /// next page, apply filtering or change the native List's reading position.
  struct InboxFilteredPaginationUITestCompletionControl: View {
    @ObservedObject var probe: InboxFilteredPaginationUITestProbe
    let backend: InboxFilteredPaginationUITestBackend

    var body: some View {
      if probe.waitingForPage > 0 {
        Button("返回第\(probe.waitingForPage)页") { Task { await backend.releasePendingPage() } }
          .font(.caption)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("inbox-filtered-pagination-release-\(probe.waitingForPage)")
          .padding(.trailing, 12)
          .padding(.bottom, 80)
      }
    }
  }

  actor InboxFilteredPaginationUITestBackend: ContentFilterRepository {
    static let hiddenMarker = "应被隐藏的中间页"
    private let probe: InboxFilteredPaginationUITestProbe
    private let filterSnapshot: ContentFilterSnapshot
    private var pendingResponse: CheckedContinuation<Void, any Error>?
    private var pendingPage = 0
    private var pendingRowCount = 0
    private var heldPages: Set<Int> = []

    init(probe: InboxFilteredPaginationUITestProbe) {
      self.probe = probe
      filterSnapshot = ContentFilterSnapshot(
        displayMode: .hidden, blockVideos: false,
        rules: [.keyword(Self.hiddenMarker, list: .block)])
    }

    func snapshot() async throws -> ContentFilterSnapshot {
      await MainActor.run { probe.filterReads += 1 }
      return filterSnapshot
    }

    func beforeReturning(_ page: InboxPage) async throws {
      guard page.kind == .replies, page.currentPage > 1 else { return }
      guard !heldPages.contains(page.currentPage), pendingResponse == nil,
        (2...3).contains(page.currentPage), page.messages.count == 20,
        page.messages.allSatisfy({
          $0.content.contains(Self.hiddenMarker) == (page.currentPage == 2)
        })
      else {
        await MainActor.run { probe.unexpected += 1 }
        throw ContentFilterStoreError.unavailable
      }
      heldPages.insert(page.currentPage)
      pendingPage = page.currentPage
      pendingRowCount = page.messages.count
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          pendingResponse = continuation
          Task { @MainActor [probe] in probe.waitingForPage = page.currentPage }
        }
      } onCancel: {
        Task { await self.cancelPendingPage() }
      }
    }

    func releasePendingPage() async {
      guard let continuation = pendingResponse else {
        await MainActor.run { probe.unexpected += 1 }
        return
      }
      pendingResponse = nil
      let page = pendingPage
      let count = pendingRowCount
      await MainActor.run {
        probe.waitingForPage = 0
        if page == 2 { probe.deliveredHiddenRows = count }
        if page == 3 { probe.deliveredFinalRows = count }
      }
      continuation.resume()
    }

    private func cancelPendingPage() async {
      guard let continuation = pendingResponse else { return }
      pendingResponse = nil
      await MainActor.run { probe.waitingForPage = 0 }
      continuation.resume(throwing: CancellationError())
    }

    func add(_ rule: ContentFilterRule) throws -> ContentFilterRule {
      throw ContentFilterStoreError.unavailable
    }
    func delete(id: UUID) throws { throw ContentFilterStoreError.unavailable }
    func deleteAll(in list: ContentFilterList) throws { throw ContentFilterStoreError.unavailable }
    func setDisplayMode(_ mode: ContentFilterDisplayMode) throws {
      throw ContentFilterStoreError.unavailable
    }
    func setBlockVideos(_ blockVideos: Bool) throws { throw ContentFilterStoreError.unavailable }
    func reset() throws { throw ContentFilterStoreError.unavailable }
  }
#endif
