import Combine
import CoreGraphics
import Foundation

struct WallpaperThemeEditorProcessing: Sendable {
  var prepare: @Sendable (Data) async throws -> WallpaperThemeSource
  var render:
    @Sendable (WallpaperThemeSource, WallpaperCropState, Double, Double) async throws ->
      WallpaperThemeRenderedImage

  static let live = Self(
    prepare: { data in
      try await detached { try WallpaperThemeImageProcessor.prepare(data: data) }
    },
    render: { source, crop, aspectRatio, blurRadius in
      try await detached {
        try WallpaperThemeImageProcessor.render(
          source: source, crop: crop, aspectRatio: aspectRatio, blurRadius: blurRadius
        )
      }
    }
  )

  static func detached<Value: Sendable>(
    _ operation: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try Task.checkCancellation()
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let value = try operation()
      try Task.checkCancellation()
      return value
    }
    return try await withTaskCancellationHandler {
      let value = try await task.value
      try Task.checkCancellation()
      return value
    } onCancel: {
      task.cancel()
    }
  }
}

struct WallpaperThemeEditorSnapshot: Sendable {
  let source: WallpaperThemeSource
  let rendered: WallpaperThemeRenderedImage
  let settings: WallpaperThemeSettings
  let crop: WallpaperCropState
  let aspectRatio: Double
}

/// Owns an unsaved draft. Processing never changes the installed theme.
@MainActor
final class WallpaperThemeEditorModel: ObservableObject {
  @Published private(set) var source: WallpaperThemeSource?
  @Published private(set) var rendered: WallpaperThemeRenderedImage?
  @Published private(set) var settings = WallpaperThemeSettings.defaultValue
  @Published private(set) var crop = WallpaperCropState.initial
  @Published private(set) var viewportSize = CGSize.zero
  @Published private(set) var isImporting = false
  @Published private(set) var isRendering = false
  @Published private(set) var isSaving = false
  @Published private(set) var errorMessage: String?

  private let processing: WallpaperThemeEditorProcessing
  private let previewDelayNanoseconds: UInt64
  private(set) var importTask: Task<Void, Never>?
  private(set) var previewTask: Task<Void, Never>?
  private var importID = UUID()
  private var previewID = UUID()
  private var renderedMatchesDraft = false
  private var isActive = true
  private var pendingRestoration: WallpaperThemeDocument?

  init(
    processing: WallpaperThemeEditorProcessing = .live,
    previewDelayNanoseconds: UInt64 = 180_000_000
  ) {
    self.processing = processing
    self.previewDelayNanoseconds = previewDelayNanoseconds
  }

  deinit {
    importTask?.cancel()
    previewTask?.cancel()
  }

  var aspectRatio: Double {
    guard viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
    return Double(viewportSize.width / viewportSize.height)
  }

  var canSave: Bool {
    isActive && source != nil && rendered != nil && renderedMatchesDraft
      && !isImporting && !isRendering && !isSaving
  }

  func updateViewportSize(_ size: CGSize) {
    guard
      isActive,
      size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      size != viewportSize
    else { return }
    viewportSize = size
    clampCrop()
    schedulePreview()
  }

  func updateSettings(_ value: WallpaperThemeSettings) {
    guard isActive, !isSaving, value != settings else { return }
    let previousBlur = settings.blurRadius
    settings = value
    if previousBlur != value.blurRadius { schedulePreview() }
  }

  func updateCrop(_ value: WallpaperCropState) {
    guard isActive, !isSaving, source != nil else { return }
    let previous = crop
    crop = value
    clampCrop()
    if crop != previous { schedulePreview() }
  }

  func restore(document: WallpaperThemeDocument) {
    guard isActive, !isSaving, source == nil, !isImporting else { return }
    pendingRestoration = document
    beginImport(restoring: document.record) { document.sourceJPEG }
  }

  /// The loader can be Photos or an explicit anonymous recommendation request.
  /// A failed replacement preserves the previous draft and its editable settings.
  func importImage(
    load: @escaping @MainActor () async throws -> Data
  ) {
    guard isActive, !isSaving else { return }
    // An explicit replacement supersedes the initial restore even if loading
    // the new choice later fails or is cancelled while the page is hidden.
    pendingRestoration = nil
    beginImport(restoring: nil, load: load)
  }

  private func beginImport(
    restoring record: WallpaperThemeRecord?,
    load: @escaping @MainActor () async throws -> Data
  ) {
    importTask?.cancel()
    invalidatePreview()
    let requestID = UUID()
    importID = requestID
    isImporting = true
    errorMessage = nil
    let processing = processing
    importTask = Task { [weak self] in
      do {
        let data = try await load()
        try Task.checkCancellation()
        let prepared = try await processing.prepare(data)
        try Task.checkCancellation()
        guard let self, self.isActive, self.importID == requestID else { return }
        self.pendingRestoration = nil
        // A restored source is already sanitized and verified by the repository.
        // Keep its encoded bytes so repeated settings edits do not recompress JPEGs.
        self.source = record == nil
          ? prepared
          : WallpaperThemeSource(image: prepared.image, jpegData: data, palette: prepared.palette)
        self.rendered = nil
        self.crop = record?.crop ?? .initial
        if let record { self.settings = record.settings }
        self.clampCrop()
        self.isImporting = false
        self.importTask = nil
        self.schedulePreview()
      } catch {
        guard let self, self.isActive, self.importID == requestID else { return }
        // Only disappearance preserves a pending restore. A real load failure
        // stays visible and is not retried automatically on every appearance.
        self.pendingRestoration = nil
        self.isImporting = false
        self.importTask = nil
        if !(error is CancellationError) {
          self.errorMessage = "无法读取图片。请选用其他图片或重试。"
        }
        self.schedulePreview()
      }
    }
  }

  func retryPreview() {
    guard isActive, !isSaving, !isImporting else { return }
    errorMessage = nil
    schedulePreview()
  }

  func clearError() { errorMessage = nil }

  func save(
    using operation: @MainActor (WallpaperThemeEditorSnapshot) async throws -> Void
  ) async -> Bool {
    guard canSave, let source, let rendered else { return false }
    let snapshot = WallpaperThemeEditorSnapshot(
      source: source, rendered: rendered, settings: settings, crop: crop,
      aspectRatio: aspectRatio
    )
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      try await operation(snapshot)
      return true
    } catch {
      errorMessage = "未能保存主题。您的调整已保留，请重试。"
      return false
    }
  }

  func reset(using operation: @MainActor () async throws -> Void) async -> Bool {
    guard isActive, !isSaving, !isImporting else { return false }
    isSaving = true
    errorMessage = nil
    defer { isSaving = false }
    do {
      try await operation()
      discard()
      return true
    } catch {
      errorMessage = "未能恢复默认主题。您的调整已保留，请重试。"
      return false
    }
  }

  func discard() {
    isActive = false
    importID = UUID()
    importTask?.cancel()
    importTask = nil
    isImporting = false
    invalidatePreview()
  }

  /// System image pickers can temporarily cover the navigation page. Reopening
  /// resumes this draft without accepting any cancelled import or preview work.
  func resume() {
    guard !isActive else { return }
    isActive = true
    if let pendingRestoration {
      restore(document: pendingRestoration)
    } else {
      schedulePreview()
    }
  }

  // Awaitable handles make the state transitions testable without wall-clock sleeps.
  func waitForImport() async { await importTask?.value }
  func waitForPreview() async { await previewTask?.value }

  private func clampCrop() {
    guard let source, viewportSize.width > 0, viewportSize.height > 0 else { return }
    crop = WallpaperCropGeometry(
      sourcePixelSize: CGSize(width: source.image.width, height: source.image.height),
      viewportSize: viewportSize
    ).clamped(crop)
  }

  private func invalidatePreview() {
    previewID = UUID()
    previewTask?.cancel()
    previewTask = nil
    isRendering = false
    renderedMatchesDraft = false
  }

  private func schedulePreview() {
    invalidatePreview()
    guard
      isActive, !isImporting, let source,
      viewportSize.width > 0, viewportSize.height > 0
    else { return }
    let requestID = UUID()
    previewID = requestID
    isRendering = true
    let processing = processing
    let crop = crop
    let ratio = aspectRatio
    let blur = settings.blurRadius
    let delay = previewDelayNanoseconds
    previewTask = Task { [weak self] in
      do {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        try Task.checkCancellation()
        let result = try await processing.render(source, crop, ratio, blur)
        try Task.checkCancellation()
        guard let self, self.isActive, self.previewID == requestID else { return }
        self.rendered = result
        self.renderedMatchesDraft = true
        self.isRendering = false
        self.previewTask = nil
      } catch {
        guard let self, self.isActive, self.previewID == requestID else { return }
        self.isRendering = false
        self.previewTask = nil
        if !(error is CancellationError) {
          self.errorMessage = "无法生成预览。请重试或重新选择图片。"
        }
      }
    }
  }
}
