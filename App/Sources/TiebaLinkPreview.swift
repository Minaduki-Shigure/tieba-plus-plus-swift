import Combine
import Foundation
import SwiftUI

struct TiebaLinkPreviewMetadata: Equatable, Sendable {
  let title: String
  let subtitle: String
}

protocol TiebaLinkPreviewService: Sendable {
  func preview(for target: TiebaLinkTarget) async throws -> TiebaLinkPreviewMetadata?
}

private enum TiebaLinkPreviewLoadOutcome: Sendable {
  case success(TiebaLinkPreviewMetadata?)
  case cancelled
  case failed
}

enum PastedTiebaLinkPolicy {
  static let maximumValueCount = 8
  static let maximumTotalUTF8ByteCount = 64 * 1_024

  static func target(from values: [String]) -> TiebaLinkTarget? {
    guard !values.isEmpty, values.count <= maximumValueCount else { return nil }

    var totalByteCount = 0
    var targets = Set<TiebaLinkTarget>()
    for value in values {
      let (nextByteCount, overflow) = totalByteCount.addingReportingOverflow(value.utf8.count)
      guard !overflow, nextByteCount <= maximumTotalUTF8ByteCount else { return nil }
      totalByteCount = nextByteCount

      if let target = TiebaLink.target(fromPastedText: value) {
        targets.insert(target)
        guard targets.count == 1 else { return nil }
      }
    }
    return targets.first
  }
}

struct TiebaLinkPreviewSnapshot: Identifiable, Equatable, Sendable {
  let id: UUID
  let target: TiebaLinkTarget
  let title: String
  let subtitle: String
  let systemImage: String
  let isDetailed: Bool

  static func fallback(
    target: TiebaLinkTarget,
    id: UUID = UUID()
  ) -> TiebaLinkPreviewSnapshot {
    switch target {
    case .forum(let forumName):
      TiebaLinkPreviewSnapshot(
        id: id,
        target: target,
        title: "\(forumName)吧",
        subtitle: "贴吧主页",
        systemImage: "person.2.circle",
        isDetailed: false
      )
    case .thread(let route):
      TiebaLinkPreviewSnapshot(
        id: id,
        target: target,
        title: "帖子 \(route.threadID)",
        subtitle: threadRouteSubtitle(route),
        systemImage: "text.bubble",
        isDetailed: false
      )
    case .user(let userID):
      TiebaLinkPreviewSnapshot(
        id: id,
        target: target,
        title: "用户 \(userID)",
        subtitle: "贴吧用户",
        systemImage: "person.crop.circle",
        isDetailed: false
      )
    }
  }

  func applying(_ metadata: TiebaLinkPreviewMetadata) -> TiebaLinkPreviewSnapshot {
    TiebaLinkPreviewSnapshot(
      id: id,
      target: target,
      title: metadata.title,
      subtitle: metadata.subtitle,
      systemImage: systemImage,
      isDetailed: true
    )
  }

  private static func threadRouteSubtitle(_ route: TiebaThreadRoute) -> String {
    var parts = ["贴吧帖子"]
    if route.onlyThreadAuthor {
      parts.append("只看楼主")
    }
    if let postID = route.postID {
      parts.append("定位到回复 \(postID)")
    }
    return parts.joined(separator: " · ")
  }
}

@MainActor
final class TiebaLinkPreviewViewModel: ObservableObject {
  @Published private(set) var preview: TiebaLinkPreviewSnapshot?
  @Published private(set) var state: LoadState = .idle

  private let service: any TiebaLinkPreviewService
  private var acceptsLoading = false
  private var isResolved = false
  private var generation = 0
  private var loadTask: Task<Void, Never>?

  init(service: any TiebaLinkPreviewService) {
    self.service = service
  }

  @discardableResult
  func present(target: TiebaLinkTarget) -> UUID {
    invalidateLoad()
    let snapshot = TiebaLinkPreviewSnapshot.fallback(target: target)
    preview = snapshot
    isResolved = false

    if case .user = target {
      isResolved = true
      state = .loaded
    } else {
      state = .idle
      startLoadIfNeeded()
    }
    return snapshot.id
  }

  func sceneActivityDidChange(isActive: Bool) {
    acceptsLoading = isActive
    if isActive {
      startLoadIfNeeded()
    } else {
      cancelForInactivity()
    }
  }

  func retry(expectedID: UUID) {
    guard preview?.id == expectedID else { return }
    isResolved = false
    startLoadIfNeeded()
  }

  func dismiss(expectedID: UUID? = nil) {
    if let expectedID, preview?.id != expectedID { return }
    invalidateLoad()
    preview = nil
    isResolved = false
    state = .idle
  }

  func consumeTargetForOpening(expectedID: UUID) -> TiebaLinkTarget? {
    guard let preview, preview.id == expectedID else { return nil }
    let target = preview.target
    dismiss(expectedID: expectedID)
    return target
  }

  private func startLoadIfNeeded() {
    guard
      acceptsLoading,
      !isResolved,
      loadTask == nil,
      let preview
    else { return }
    guard case .user = preview.target else {
      startLoad(for: preview)
      return
    }
    isResolved = true
    state = .loaded
  }

  private func startLoad(for request: TiebaLinkPreviewSnapshot) {
    generation &+= 1
    let requestGeneration = generation
    let service = service
    state = .loading

    let task = Task { [weak self] in
      let outcome: TiebaLinkPreviewLoadOutcome
      do {
        let metadata = try await service.preview(for: request.target)
        try Task.checkCancellation()
        outcome = .success(metadata)
      } catch is CancellationError {
        outcome = Task.isCancelled ? .cancelled : .failed
      } catch {
        outcome = .failed
      }

      guard let self else { return }
      defer { finishLoad(requestGeneration: requestGeneration) }
      switch outcome {
      case .success(let metadata):
        guard
          requestGeneration == generation,
          acceptsLoading,
          let current = preview,
          current.id == request.id,
          current.target == request.target
        else { return }

        if let metadata {
          preview = current.applying(metadata)
        }
        isResolved = true
        state = .loaded
      case .cancelled:
        return
      case .failed:
        guard
          requestGeneration == generation,
          acceptsLoading,
          preview?.id == request.id,
          !Task.isCancelled
        else { return }
        state = .failed("未能读取预览详情，仍可直接打开。")
      }
    }
    loadTask = task
  }

  private func cancelForInactivity() {
    guard loadTask != nil else { return }
    invalidateLoad()
    state = isResolved ? .loaded : .idle
  }

  private func invalidateLoad() {
    generation &+= 1
    loadTask?.cancel()
    loadTask = nil
  }

  private func finishLoad(requestGeneration: Int) {
    guard requestGeneration == generation else { return }
    loadTask = nil
  }
}

struct TiebaLinkPreviewSheet: View {
  @ObservedObject var viewModel: TiebaLinkPreviewViewModel
  let onClose: (UUID) -> Void
  let onOpen: (UUID) -> Void

  var body: some View {
    NavigationStack {
      List {
        if let preview = viewModel.preview {
          Section {
            HStack(alignment: .top, spacing: 12) {
              Image(systemName: preview.systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .background(Color(uiColor: .secondarySystemFill), in: Circle())
                .accessibilityHidden(true)

              VStack(alignment: .leading, spacing: 5) {
                Text(preview.title)
                  .font(.headline)
                  .foregroundStyle(.primary)
                  .fixedSize(horizontal: false, vertical: true)
                Text(preview.subtitle)
                  .font(.subheadline)
                  .foregroundStyle(.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
          }

          statusSection(preview: preview)
        }
      }
      .appScrollableSurface()
      .navigationTitle("打开贴吧链接")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if let preview = viewModel.preview {
          ToolbarItem(placement: .cancellationAction) {
            Button {
              onClose(preview.id)
            } label: {
              Image(systemName: "xmark")
            }
            .accessibilityLabel("关闭链接预览")
            .help("关闭链接预览")
          }
          ToolbarItem(placement: .confirmationAction) {
            Button {
              onOpen(preview.id)
            } label: {
              Label("打开", systemImage: "arrow.right.circle.fill")
            }
          }
        }
      }
    }
    .appNavigationSurface()
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  @ViewBuilder
  private func statusSection(preview: TiebaLinkPreviewSnapshot) -> some View {
    switch viewModel.state {
    case .loading:
      Section {
        HStack(spacing: 10) {
          ProgressView()
          Text("正在读取预览信息")
            .foregroundStyle(.secondary)
        }
      }
    case .failed(let message):
      Section {
        Label(message, systemImage: "exclamationmark.triangle")
          .foregroundStyle(.secondary)
        Button {
          viewModel.retry(expectedID: preview.id)
        } label: {
          Label("重试", systemImage: "arrow.clockwise")
        }
      }
    case .idle, .loaded:
      EmptyView()
    }
  }
}
