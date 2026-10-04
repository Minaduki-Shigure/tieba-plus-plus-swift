#if DEBUG
  import Combine
  import Foundation
  import SwiftUI

  @MainActor
  final class ForumSearchResumeUITestProbe: ObservableObject {
    @Published var requests: [String] = []
    @Published var historyWrites = 0
    @Published var historyQueries: [String] = []
    @Published var cancellations = 0
    @Published var lateResponses = 0
    @Published var unexpected = 0

    var summary: String {
      "requests=\(requests.count) cancellations=\(cancellations) "
        + "late=\(lateResponses) unexpected=\(unexpected)"
    }
  }

  struct ForumSearchResumeUITestProbeView: View {
    @ObservedObject var probe: ForumSearchResumeUITestProbe

    var body: some View {
      VStack(alignment: .leading, spacing: 1) {
        Text(probe.summary)
          .accessibilityIdentifier("forum-search-resume-counts")
        Text(probe.requests.joined(separator: " | "))
          .lineLimit(1)
          .accessibilityLabel(probe.requests.joined(separator: " | "))
          .accessibilityIdentifier("forum-search-resume-requests")
        Text("writes=\(probe.historyWrites) entries=\(probe.historyQueries.joined(separator: "|"))")
          .accessibilityIdentifier("forum-search-resume-history")
      }
      .font(.system(size: 7, design: .monospaced))
    }
  }

  /// Only a transport completion control. It never accesses the search model,
  /// navigation or lifecycle; the test must leave and return through real tabs.
  struct ForumSearchResumeUITestCompletionControl: View {
    @ObservedObject var probe: ForumSearchResumeUITestProbe
    let backend: ForumSearchResumeUITestBackend

    var body: some View {
      if probe.requests.count == 2, probe.lateResponses == 0 {
        Button("释放旧响应") { Task { await backend.releaseFirstResponse() } }
          .buttonStyle(.borderedProminent)
          .accessibilityIdentifier("forum-search-resume-release-old")
          .padding(.trailing, 12)
          .padding(.bottom, 80)
      }
    }
  }

  actor ForumSearchResumeUITestBackend: ForumPostSearchService, ForumSearchHistoryRepository {
    static let forumName = "恢复测试"
    private let probe: ForumSearchResumeUITestProbe
    private var requestCount = 0
    private var historyWriteCount = 0
    private var historyEntries: [ForumSearchHistoryEntry] = []
    private var firstRequest: CheckedContinuation<ForumPostSearchPageData, any Error>?
    private var expiryTask: Task<Void, Never>?

    init(probe: ForumSearchResumeUITestProbe) { self.probe = probe }

    func searchForumPosts(
      query: String, forumName: String, page: Int, pageSize: Int,
      sort: ForumPostSearchSort, filter: ForumPostSearchFilter
    ) async throws -> ForumPostSearchPageData {
      guard query == "actors", forumName == Self.forumName, page == 1, pageSize == 20,
        sort == .newest, filter == .all, requestCount < 2
      else {
        await MainActor.run { probe.unexpected += 1 }
        throw BrowseError.unavailable("非预期的离线吧内搜索请求")
      }
      requestCount += 1
      let number = requestCount
      await MainActor.run {
        probe.requests.append("\(query):\(forumName):\(page):\(sort.rawValue):\(filter.rawValue)")
      }
      if number == 1 {
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            firstRequest = continuation
            expiryTask = Task {
              do { try await Task.sleep(nanoseconds: 120_000_000_000) } catch { return }
              await expireFirstResponse()
            }
          }
        } onCancel: {
          // Deliberately retain the response so the UI test can deliver it late,
          // as can happen with a service that does not immediately cancel IO.
          Task { @MainActor [probe] in probe.cancellations += 1 }
        }
      }
      return Self.response(title: "恢复后的搜索结果", id: 990_002)
    }

    func releaseFirstResponse() async {
      guard let continuation = firstRequest else { return }
      firstRequest = nil
      expiryTask?.cancel()
      expiryTask = nil
      continuation.resume(returning: Self.response(title: "已取消的旧搜索结果", id: 990_001))
      await MainActor.run { probe.lateResponses += 1 }
    }

    private func expireFirstResponse() async {
      guard let continuation = firstRequest else { return }
      firstRequest = nil
      expiryTask = nil
      continuation.resume(throwing: BrowseError.unavailable("离线首读等待超时"))
      await MainActor.run { probe.unexpected += 1 }
    }

    func entries(forumName: String) -> [ForumSearchHistoryEntry] {
      historyEntries.filter { $0.forumName == forumName }
    }

    func record(query: String, forumName: String, at date: Date) async {
      let entry = ForumSearchHistoryEntry(forumName: forumName, query: query, searchedAt: date)
      historyEntries.removeAll { $0.id == entry.id }
      historyEntries.insert(entry, at: 0)
      historyWriteCount += 1
      let count = historyWriteCount
      let queries = historyEntries.map(\.query)
      await MainActor.run {
        probe.historyWrites = count
        probe.historyQueries = queries
      }
    }

    func delete(id: String) { historyEntries.removeAll { $0.id == id } }
    func deleteAll(forumName: String) { historyEntries.removeAll { $0.forumName == forumName } }
    func reset() { historyEntries = [] }

    private static func response(title: String, id: Int64) -> ForumPostSearchPageData {
      let thread = BrowseThread(
        id: id, forumID: 100, forumName: forumName, title: title, excerpt: "首读取消后正常恢复",
        authorName: "离线作者", replyCount: 0, viewCount: 1, createdAt: nil,
        lastReplyAt: nil, contents: [], firstPostID: id + 1_000_000)
      let item = ForumPostSearchItem(
        thread: thread, target: .thread, matchedTitle: title, matchedExcerpt: thread.excerpt,
        matchedAuthorID: 0, matchedAuthorName: "离线作者", matchedAuthorPortraitURL: nil,
        matchedAt: nil, replyCount: 0, likeCount: 0, shareCount: 0, matchedContents: [])
      return ForumPostSearchPageData(results: [item], currentPage: 1, hasMore: false)
    }
  }
#endif
