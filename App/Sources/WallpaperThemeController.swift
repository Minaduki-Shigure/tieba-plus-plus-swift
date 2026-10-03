import Combine
import CoreGraphics
import Foundation

/// One decoded wallpaper is shared by every page. It is never a content-image cache entry.
struct WallpaperThemeSnapshot: @unchecked Sendable {
  let id: UUID
  let settings: WallpaperThemeSettings
  let image: CGImage
}

@MainActor
final class WallpaperThemeController: ObservableObject {
  static let shared = WallpaperThemeController(
    repository: WallpaperThemeRepository(directory: WallpaperThemeRepository.defaultDirectory())
  )

  @Published private(set) var document: WallpaperThemeDocument?
  @Published private(set) var snapshot: WallpaperThemeSnapshot?
  @Published private(set) var isLoading = false
  @Published private(set) var isUpdating = false
  @Published private(set) var errorMessage: String?

  private let repository: WallpaperThemeRepository
  private var didLoad = false
  private var loadTask: Task<Void, Never>?

  init(repository: WallpaperThemeRepository) {
    self.repository = repository
  }

  func load() async {
    guard !didLoad else { return }
    if let loadTask {
      await loadTask.value
      return
    }
    guard !isUpdating else { return }
    // Reserve the read before enqueuing work; save/reset cannot slip between task
    // creation and the first actor turn of performLoad and then be overwritten.
    isLoading = true
    let task = Task { await performLoad() }
    loadTask = task
    await task.value
    loadTask = nil
  }

  private func performLoad() async {
    defer { isLoading = false }
    do {
      let loaded = try await repository.load()
      let image: CGImage?
      if let loaded {
        let decoded = try await Task.detached(priority: .userInitiated) {
          try WallpaperThemeImageProcessor.prepare(data: loaded.renderedJPEG)
        }.value
        try Task.checkCancellation()
        image = decoded.image
      } else {
        image = nil
      }
      publish(loaded, image: image)
      didLoad = true
      errorMessage = nil
    } catch is CancellationError {
      // A disappearing window can retry the same read; there was no mutation.
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func save(
    source: WallpaperThemeSource,
    rendered: WallpaperThemeRenderedImage,
    settings: WallpaperThemeSettings,
    crop: WallpaperCropState,
    aspectRatio: Double
  ) async throws {
    guard !isLoading, !isUpdating else { throw WallpaperThemeControllerError.busy }
    try Task.checkCancellation()
    isUpdating = true
    defer { isUpdating = false }
    do {
      let saved = try await repository.save(
        sourceJPEG: source.jpegData,
        renderedJPEG: rendered.jpegData,
        settings: settings,
        crop: crop,
        aspectRatio: aspectRatio
      )
      // The atomic commit is the boundary. Cancellation after it cannot hide a known save.
      publish(saved, image: rendered.image)
      didLoad = true
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  func reset() async throws {
    guard !isLoading, !isUpdating else { throw WallpaperThemeControllerError.busy }
    try Task.checkCancellation()
    isUpdating = true
    defer { isUpdating = false }
    do {
      try await repository.reset()
      publish(nil, image: nil)
      didLoad = true
      errorMessage = nil
    } catch {
      errorMessage = error.localizedDescription
      throw error
    }
  }

  private func publish(_ value: WallpaperThemeDocument?, image: CGImage?) {
    document = value
    if let value, let image {
      snapshot = WallpaperThemeSnapshot(
        id: value.record.id,
        settings: value.record.settings,
        image: image
      )
    } else {
      snapshot = nil
    }
  }
}

enum WallpaperThemeControllerError: LocalizedError {
  case busy

  var errorDescription: String? { "壁纸正在读取或保存，请稍后再试。" }
}
