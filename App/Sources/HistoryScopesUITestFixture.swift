#if DEBUG
  import Combine
  import Foundation
  import SwiftUI

  /// The production history view and destinations backed by a fresh temporary
  /// file store. Tests use only user controls; this host exposes no model hooks.
  @MainActor
  struct HistoryScopesUITestRoot: View {
    let service:
      any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
    let auxiliaryRepository: any LocalFavoritesRepository & ForumSearchHistoryRepository
    @StateObject private var probe = HistoryScopesUITestProbe()
    @State private var repository: HistoryScopesUITestRepository?
    @State private var destination: BrowsingHistoryTarget?
    @State private var setupError: String?

    var body: some View {
      NavigationStack {
        if let repository {
          NavigationLink("进入离线浏览记录") {
            HistoryView(repository: repository) { destination = $0 }
              .navigationDestination(
                isPresented: Binding(
                  get: { destination != nil }, set: { if !$0 { destination = nil } })
              ) {
                if let destination {
                  switch destination {
                  case .thread(let snapshot):
                    ThreadView(
                      thread: snapshot.browseThread, service: service,
                      historyRepository: repository, favoritesRepository: auxiliaryRepository,
                      searchHistoryRepository: auxiliaryRepository)
                  case .forum(let snapshot):
                    ForumView(
                      forumName: snapshot.name, service: service,
                      historyRepository: repository, favoritesRepository: auxiliaryRepository,
                      searchHistoryRepository: auxiliaryRepository)
                  }
                }
              }
          }
          .navigationTitle("离线历史入口")
        } else if let setupError {
          Text(setupError)
        } else {
          ProgressView()
        }
      }
      .overlay(alignment: .topLeading) {
        Text(probe.summary)
          .font(.system(size: 7, design: .monospaced))
          .accessibilityIdentifier("history-store-summary")
          .allowsHitTesting(false)
      }
      .task {
        guard repository == nil else { return }
        do {
          repository = try await HistoryScopesUITestRepository.prepared(probe: probe)
        } catch {
          setupError = error.localizedDescription
        }
      }
    }

    nonisolated static func threadSnapshot(_ number: Int) -> ThreadHistorySnapshot {
      ThreadHistorySnapshot(
        threadID: Int64(980_000 + number), forumID: 100, forumName: "历史贴吧·1",
        title: "历史帖子·\(number)", excerpt: "离线历史，两个分类分别保留阅读位置。",
        authorName: "历史作者", replyCount: 3, viewCount: 20)
    }
  }

  @MainActor
  private final class HistoryScopesUITestProbe: ObservableObject {
    @Published var summary = "preparing"
  }

  private actor HistoryScopesUITestRepository: BrowsingHistoryRepository {
    let store: FileBrowsingHistoryStore
    let probe: HistoryScopesUITestProbe
    let directory: URL

    init(store: FileBrowsingHistoryStore, probe: HistoryScopesUITestProbe, directory: URL) {
      self.store = store
      self.probe = probe
      self.directory = directory
    }

    static func prepared(probe: HistoryScopesUITestProbe) async throws -> Self {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("history-ui-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let store = FileBrowsingHistoryStore(
        fileURL: directory.appendingPathComponent("history.json"))
      let now = Date()
      for number in 1...30 {
        let date = now.addingTimeInterval(-Double(number * 60))
        try await store.record(.thread(HistoryScopesUITestRoot.threadSnapshot(number)), at: date)
        try await store.record(.forum(ForumHistorySnapshot(name: "历史贴吧·\(number)")), at: date)
      }
      try await store.setRecordingEnabled(false)
      let result = Self(store: store, probe: probe, directory: directory)
      try await result.publish()
      return result
    }

    func entries(kind: BrowsingHistoryKind?) async throws -> [BrowsingHistoryEntry] {
      try await store.entries(kind: kind)
    }
    func isRecordingEnabled() async throws -> Bool { try await store.isRecordingEnabled() }
    func setRecordingEnabled(_ enabled: Bool) async throws {
      try await store.setRecordingEnabled(enabled)
      try await publish()
    }
    func record(_ target: BrowsingHistoryTarget, at date: Date) async throws {
      try await store.record(target, at: date)
      try await publish()
    }
    func updateThreadProgress(
      threadID: Int64, postID: Int64, floor: Int, options: ThreadBrowseOptions, at date: Date
    ) async throws {
      try await store.updateThreadProgress(
        threadID: threadID, postID: postID, floor: floor, options: options, at: date)
      try await publish()
    }
    func updateThreadOptions(
      threadID: Int64, options: ThreadBrowseOptions, at date: Date
    ) async throws {
      try await store.updateThreadOptions(threadID: threadID, options: options, at: date)
      try await publish()
    }
    func delete(id: String) async throws {
      try await store.delete(id: id)
      try await publish()
    }
    func deleteAll(kind: BrowsingHistoryKind?) async throws {
      try await store.deleteAll(kind: kind)
      try await publish()
    }

    private func publish() async throws {
      // Reopen the archive to verify persistence independently of the model.
      let persisted = FileBrowsingHistoryStore(
        fileURL: directory.appendingPathComponent("history.json"))
      let entries = try await persisted.entries(kind: nil)
      let recording = try await persisted.isRecordingEnabled()
      let threads = entries.filter { $0.kind == .thread }
      let forums = entries.filter { $0.kind == .forum }
      let summary =
        "threads=\(threads.count) forums=\(forums.count) recording=\(recording) "
        + "firstThread=\(threads.first?.id ?? "none") firstForum=\(forums.first?.id ?? "none")"
      await MainActor.run { probe.summary = summary }
    }
  }
#endif
