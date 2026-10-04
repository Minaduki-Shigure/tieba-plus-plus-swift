#if DEBUG
  import Combine
  import Foundation
  import SwiftUI

  @MainActor
  final class SearchPaginationAnchorUITestProbe: ObservableObject {
    @Published var waitingForPage = 0
    @Published var deliveredRows = 0
    @Published var unexpected = 0
  }

  struct SearchPaginationAnchorUITestProbeView: View {
    @ObservedObject var probe: SearchPaginationAnchorUITestProbe

    var body: some View {
      Text(
        "waiting=\(probe.waitingForPage) deliveredRows=\(probe.deliveredRows) "
          + "unexpected=\(probe.unexpected)"
      )
      .font(.system(size: 7, design: .monospaced))
      .accessibilityIdentifier("search-pagination-anchor-state")
    }
  }

  /// This control completes only a suspended service response. It has no
  /// access to a view model, navigation state, List or scroll position.
  struct SearchPaginationAnchorUITestCompletionControl: View {
    @ObservedObject var probe: SearchPaginationAnchorUITestProbe
    let backend: SearchPaginationAnchorUITestBackend

    var body: some View {
      if probe.waitingForPage == 2 {
        Button("返回搜索第2页") { Task { await backend.releaseSecondPage() } }
          .font(.caption)
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("search-pagination-anchor-release")
          .padding(.trailing, 12)
          .padding(.bottom, 80)
      }
    }
  }

  actor SearchPaginationAnchorUITestBackend {
    private let probe: SearchPaginationAnchorUITestProbe
    private var pendingResponse: CheckedContinuation<Void, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var heldSecondPage = false

    init(probe: SearchPaginationAnchorUITestProbe) { self.probe = probe }

    func beforeReturning(_ page: ThreadSearchPageData) async throws {
      guard page.currentPage > 1 else { return }
      guard page.currentPage == 2, page.threads.count == 20,
        page.threads.first?.title == "测试·最新·帖子21",
        page.threads.last?.title == "测试·最新·帖子40",
        !heldSecondPage, pendingResponse == nil
      else {
        await MainActor.run { probe.unexpected += 1 }
        throw BrowseError.unavailable("离线搜索分页请求不符合预期。")
      }
      heldSecondPage = true
      try await withTaskCancellationHandler {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, any Error>) in
          pendingResponse = continuation
          timeoutTask = Task {
            do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
            await self.finishWithoutDelivery(timedOut: true)
          }
          Task { @MainActor [probe] in probe.waitingForPage = 2 }
        }
      } onCancel: {
        Task { await self.finishWithoutDelivery(timedOut: false) }
      }
    }

    func releaseSecondPage() async {
      guard let continuation = pendingResponse else {
        await MainActor.run { probe.unexpected += 1 }
        return
      }
      pendingResponse = nil
      timeoutTask?.cancel()
      timeoutTask = nil
      await MainActor.run {
        probe.waitingForPage = 0
        probe.deliveredRows = 20
      }
      continuation.resume()
    }

    private func finishWithoutDelivery(timedOut: Bool) async {
      guard let continuation = pendingResponse else { return }
      pendingResponse = nil
      timeoutTask?.cancel()
      timeoutTask = nil
      await MainActor.run {
        probe.waitingForPage = 0
        if timedOut { probe.unexpected += 1 }
      }
      continuation.resume(throwing: CancellationError())
    }
  }
#endif
