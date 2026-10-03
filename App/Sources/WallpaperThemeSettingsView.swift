import CoreGraphics
import PhotosUI
import SwiftUI
import UIKit

@MainActor
struct WallpaperThemeSettingsView: View {
  @ObservedObject private var controller: WallpaperThemeController
  @StateObject private var model = WallpaperThemeEditorModel()
  @Environment(\.dismiss) private var dismiss
  @AppStorage(AppPreferenceKey.accentColor)
  private var defaultAccentColor = AppAccentColor.defaultValue.rawValue
  @State private var selectedImage: PhotosPickerItem?
  @State private var didLoadDocument = false
  @State private var confirmReset = false
  @State private var recommendations: [WallpaperRecommendation] = []
  @State private var recommendationTask: Task<Void, Never>?
  @State private var recommendationRequestID = UUID()
  @State private var isLoadingRecommendations = false
  @State private var recommendationError: String?
  @State private var attachedWindowSize = CGSize.zero

  init(controller: WallpaperThemeController = .shared) {
    self.controller = controller
  }

  var body: some View {
    GeometryReader { contentGeometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          imageSelection
          if let source = model.source {
            cropSection(source: source, availableWidth: max(1, contentGeometry.size.width - 32))
            appearanceSection
            previewSection(availableWidth: max(1, contentGeometry.size.width - 32))
          }
          errorSection
          resetSection
        }
        .padding(16)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
      }
      .accessibilityIdentifier("wallpaper-theme-editor-scroll")
      .appScrollableSurface()
      .background(Color(uiColor: .systemGroupedBackground))
      .onAppear {
        model.resume()
        model.updateViewportSize(attachedWindowSize)
      }
    }
    .background {
      WallpaperWindowSizeReader { size in
        attachedWindowSize = size
        model.updateViewportSize(size)
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }
    .navigationTitle("透明图片主题")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(model.isSaving)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("取消") {
          model.discard()
          dismiss()
        }
        .disabled(model.isSaving)
        .accessibilityIdentifier("wallpaper-theme-cancel")
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("保存并启用") { save() }
          .disabled(!didLoadDocument || !model.canSave)
          .accessibilityIdentifier("wallpaper-theme-save")
      }
    }
    .interactiveDismissDisabled(model.isSaving)
    .tint(previewAccentStyle.color)
    .task {
      guard !didLoadDocument else { return }
      await controller.load()
      guard !Task.isCancelled else { return }
      if let document = controller.document { model.restore(document: document) }
      didLoadDocument = true
    }
    .onChange(of: selectedImage) { item in
      guard let item else { return }
      selectedImage = nil
      model.resume()
      model.importImage {
        guard let file = try await item.loadTransferable(type: SecurePickedImageFile.self) else {
          throw SecurePickedImageFileError.invalidSource
        }
        defer { file.removeTemporaryCopy() }
        try Task.checkCancellation()
        return try await WallpaperThemeEditorProcessing.detached {
          // The transferred file is already privately copied and bounded. Read it
          // in chunks as well, so replacement/growth cannot bypass the byte cap.
          let handle = try FileHandle(forReadingFrom: file.fileURL)
          defer { try? handle.close() }
          var result = Data()
          while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try Task.checkCancellation()
            guard Int64(result.count + chunk.count) <= SecurePickedImageFile.maximumSourceByteCount
            else {
              throw SecurePickedImageFileError.sourceTooLarge(
                maximumByteCount: SecurePickedImageFile.maximumSourceByteCount
              )
            }
            result.append(chunk)
          }
          return result
        }
      }
    }
    .onDisappear {
      model.discard()
      recommendationRequestID = UUID()
      recommendationTask?.cancel()
      recommendationTask = nil
      isLoadingRecommendations = false
    }
    .confirmationDialog("恢复默认主题？", isPresented: $confirmReset, titleVisibility: .visible) {
      Button("恢复默认主题", role: .destructive) {
        Task { @MainActor in
          if await model.reset(using: { try await controller.reset() }) { dismiss() }
        }
      }
      .accessibilityIdentifier("wallpaper-theme-confirm-reset")
    } message: {
      Text("移除当前图片主题，并恢复原有外观和强调色。")
    }
  }

  private var imageSelection: some View {
    let photoPickerTitle = model.source == nil ? "从照片选择图片" : "更换图片"
    return VStack(alignment: .leading, spacing: 12) {
      Text(controller.document == nil ? "尚未启用" : "已启用")
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("wallpaper-theme-status")
      Text("选择背景图片，调整裁剪和配色后保存。预览中的调整不会立即改变当前主题。")
        .font(.subheadline)
        .foregroundStyle(.secondary)
      PhotosPicker(selection: $selectedImage, matching: .images, photoLibrary: .shared()) {
        Label(photoPickerTitle, systemImage: "photo.on.rectangle")
          .frame(maxWidth: .infinity, minHeight: 32)
      }
      .buttonStyle(.borderedProminent)
      .disabled(!didLoadDocument || model.isSaving)
      .accessibilityIdentifier("wallpaper-theme-photo-picker")
      if !didLoadDocument || model.isImporting || model.isSaving {
        ProgressView(model.isSaving ? "正在保存…" : "正在读取图片…")
          .accessibilityIdentifier("wallpaper-theme-import-progress")
      }
      #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--wallpaper-theme-ui-testing") {
          Button("使用测试图片") {
            model.importImage { Self.testImageData() }
          }
          .disabled(!didLoadDocument || model.isSaving)
          .accessibilityIdentifier("wallpaper-theme-test-image")
        }
      #endif
      recommendationSection
    }
  }

  private var recommendationSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button(action: loadRecommendations) {
        Label(
          recommendations.isEmpty ? "加载推荐壁纸" : "重新加载推荐壁纸",
          systemImage: "photo.stack"
        )
      }
      .disabled(isLoadingRecommendations || model.isSaving)
      .accessibilityIdentifier("wallpaper-theme-load-recommendations")
      if isLoadingRecommendations { ProgressView("正在加载推荐壁纸…") }
      if let recommendationError {
        Text(recommendationError).font(.footnote).foregroundStyle(.secondary)
      }
      if !recommendations.isEmpty {
        ScrollView(.horizontal) {
          LazyHStack(spacing: 12) {
            ForEach(recommendations, id: \.id) { recommendation in
              Button {
                model.importImage {
                  try await WallpaperRecommendationService.shared.fetchImage(recommendation)
                }
              } label: {
                WallpaperThemeRecommendationCell(recommendation: recommendation)
              }
              .buttonStyle(.bordered)
              .disabled(!didLoadDocument || model.isSaving)
              .accessibilityLabel("选择推荐壁纸：\(recommendation.title)")
            }
          }
        }
      }
    }
  }

  private func cropSection(source: WallpaperThemeSource, availableWidth: CGFloat) -> some View {
    let width = min(availableWidth, 360 * CGFloat(model.aspectRatio))
    return VStack(alignment: .leading, spacing: 12) {
      Text("裁剪").font(.headline)
      Text("拖动和双指缩放，裁剪比例随当前窗口调整。")
        .font(.footnote).foregroundStyle(.secondary)
      WallpaperThemeCropCanvas(
        source: source,
        crop: Binding(get: { model.crop }, set: { model.updateCrop($0) }),
        size: CGSize(width: width, height: width / CGFloat(model.aspectRatio))
      )
      .frame(maxWidth: .infinity)
      Slider(
        value: Binding(
          get: { model.crop.zoom },
          set: {
            var value = model.crop
            value.zoom = $0
            model.updateCrop(value)
          }
        ),
        in: 1...4
      )
      .accessibilityLabel("图片缩放")
      .accessibilityIdentifier("wallpaper-theme-zoom")
      Button("重置裁剪") { model.updateCrop(.initial) }
        .accessibilityIdentifier("wallpaper-theme-reset-crop")
    }
    .disabled(model.isImporting || model.isSaving)
  }

  private var appearanceSection: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("外观").font(.headline)
      Picker("阅读配色", selection: settingsBinding(\.appearance)) {
        Text("浅色").tag(WallpaperThemeAppearance.light)
        Text("深色").tag(WallpaperThemeAppearance.dark)
      }
      .pickerStyle(.segmented)
      .accessibilityIdentifier("wallpaper-theme-appearance")
      VStack(alignment: .leading) {
        Text("图片不透明度 \(Int((model.settings.imageOpacity * 100).rounded()))%")
        Slider(value: settingsBinding(\.imageOpacity), in: 0...1)
          .accessibilityLabel("图片不透明度")
          .accessibilityIdentifier("wallpaper-theme-opacity")
      }
      VStack(alignment: .leading) {
        Text("模糊 \(Int(model.settings.blurRadius.rounded()))")
        Slider(value: settingsBinding(\.blurRadius), in: 0...30, step: 1)
          .accessibilityLabel("图片模糊")
          .accessibilityIdentifier("wallpaper-theme-blur")
      }
      VStack(alignment: .leading, spacing: 10) {
        Text("图片配色").font(.subheadline)
        if let source = model.source {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
            ForEach(Array(source.palette.enumerated()), id: \.offset) { index, rgb in
              Button {
                var settings = model.settings
                settings.accentRGB = rgb
                model.updateSettings(settings)
              } label: {
                Circle()
                  .fill(Color(uiColor: AppAccentColorComponents(rgb: rgb).uiColor))
                  .frame(width: 36, height: 36)
                  .overlay {
                    Circle().stroke(
                      Color.primary, lineWidth: model.settings.accentRGB == rgb ? 3 : 0)
                  }
                  .padding(4)
              }
              .buttonStyle(.plain)
              .accessibilityLabel("图片配色 \(index + 1)")
              .accessibilityValue(model.settings.accentRGB == rgb ? "已选择" : "")
              .accessibilityIdentifier("wallpaper-theme-palette-\(index)")
            }
          }
        }
        ColorPicker(
          "自选强调色",
          selection: Binding(
            get: { accentSelection.editingSeed.cgColor },
            set: { color in
              guard let seed = AppAccentColorSeed(cgColor: color) else { return }
              var settings = model.settings
              settings.accentRGB = seed.rgb
              model.updateSettings(settings)
            }
          ),
          supportsOpacity: false
        )
        .accessibilityIdentifier("wallpaper-theme-custom-accent")
        Button("使用原有强调色") {
          var settings = model.settings
          settings.accentRGB = nil
          model.updateSettings(settings)
        }
        .disabled(model.settings.accentRGB == nil)
        .accessibilityIdentifier("wallpaper-theme-default-accent")
      }
    }
    .disabled(model.isImporting || model.isSaving)
  }

  private func previewSection(availableWidth: CGFloat) -> some View {
    let width = min(availableWidth, 320 * CGFloat(model.aspectRatio))
    let height = width / CGFloat(model.aspectRatio)
    return VStack(alignment: .leading, spacing: 12) {
      Text("阅读预览").font(.headline)
      ZStack {
        model.settings.appearance == .dark ? Color.black : Color.white
        if let rendered = model.rendered {
          WallpaperThemePreview(image: rendered.image, settings: model.settings)
            .frame(width: width, height: height)
        }
        VStack(alignment: .leading, spacing: 14) {
          Label("贴吧++", systemImage: "text.bubble")
            .font(.headline).foregroundStyle(previewAccentStyle.color)
          Text("阅读预览").font(.title3.weight(.semibold))
          Text("背景与阅读内容一起显示。可调整图片透明度与配色，让文字更容易阅读。")
            .font(.body)
          Spacer(minLength: 0)
          HStack {
            Label("回复", systemImage: "bubble.right")
            Spacer()
            Image(systemName: "bookmark")
          }
          .foregroundStyle(previewAccentStyle.color)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(width: width, height: height)
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .environment(\.colorScheme, model.settings.appearance == .dark ? .dark : .light)
      .accessibilityIdentifier("wallpaper-theme-preview")
      .frame(maxWidth: .infinity)
      Text("图片不透明度可从 0% 调至 100%。搭配模糊、浅色或深色阅读配色，调整喜欢的效果。")
        .font(.footnote)
        .foregroundStyle(.secondary)
      if model.isRendering { ProgressView("正在生成预览…") }
    }
  }

  @ViewBuilder
  private var errorSection: some View {
    if let error = model.errorMessage ?? controller.errorMessage {
      VStack(alignment: .leading, spacing: 10) {
        Text(error).font(.subheadline).foregroundStyle(.secondary)
          .accessibilityIdentifier("wallpaper-theme-error")
        if controller.document == nil && controller.errorMessage != nil {
          Button("重新读取已保存主题") { retrySavedTheme() }
            .disabled(!didLoadDocument || model.isImporting || model.isSaving)
            .accessibilityIdentifier("wallpaper-theme-retry-load")
        }
        if model.source != nil && !model.isRendering && !model.isImporting && !model.canSave {
          Button("重新生成预览") { model.retryPreview() }
            .disabled(model.isSaving)
        }
      }
    }
  }

  private var resetSection: some View {
    Button("恢复默认主题", role: .destructive) { confirmReset = true }
      .disabled(
        (controller.document == nil && controller.errorMessage == nil)
          || !didLoadDocument || model.isSaving || model.isImporting
      )
      .accessibilityIdentifier("wallpaper-theme-reset")
  }

  private var accentSelection: AppAccentColorSelection {
    if let rgb = model.settings.accentRGB, let seed = AppAccentColorSeed(rgb: rgb) {
      return .custom(seed)
    }
    return .resolved(defaultAccentColor)
  }

  private var previewAccentStyle: AppAccentColorStyle {
    AppAccentColorStyle(selection: accentSelection)
  }

  private func settingsBinding<Value>(
    _ keyPath: WritableKeyPath<WallpaperThemeSettings, Value>
  ) -> Binding<Value> {
    Binding(
      get: { model.settings[keyPath: keyPath] },
      set: { value in
        var settings = model.settings
        settings[keyPath: keyPath] = value
        model.updateSettings(settings)
      }
    )
  }

  private func save() {
    Task { @MainActor in
      if await model.save(using: { snapshot in
        try await controller.save(
          source: snapshot.source, rendered: snapshot.rendered,
          settings: snapshot.settings, crop: snapshot.crop, aspectRatio: snapshot.aspectRatio
        )
      }) {
        dismiss()
      }
    }
  }

  private func retrySavedTheme() {
    didLoadDocument = false
    Task { @MainActor in
      await controller.load()
      if model.source == nil, let document = controller.document {
        model.restore(document: document)
      }
      didLoadDocument = true
    }
  }

  private func loadRecommendations() {
    guard !isLoadingRecommendations else { return }
    recommendationTask?.cancel()
    let requestID = UUID()
    recommendationRequestID = requestID
    isLoadingRecommendations = true
    recommendationError = nil
    recommendationTask = Task { @MainActor in
      do {
        let result = try await WallpaperRecommendationService.shared.fetchCatalog()
        try Task.checkCancellation()
        guard recommendationRequestID == requestID else { return }
        recommendations = result
        if result.isEmpty { recommendationError = "暂时没有推荐壁纸，您仍可从照片选择图片。" }
      } catch {
        guard recommendationRequestID == requestID, !Task.isCancelled else { return }
        recommendationError = "推荐壁纸暂时无法加载。可重试，或从照片选择图片。"
      }
      isLoadingRecommendations = false
      recommendationTask = nil
    }
  }

  #if DEBUG
    /// Deterministic UI fixture: never substitutes for testing the system Photos picker.
    private static func testImageData() -> Data {
      let format = UIGraphicsImageRendererFormat()
      format.scale = 1
      format.opaque = true
      return UIGraphicsImageRenderer(size: CGSize(width: 240, height: 360), format: format)
        .jpegData(withCompressionQuality: 0.9) { context in
          UIColor.systemTeal.setFill()
          context.fill(CGRect(x: 0, y: 0, width: 240, height: 360))
          UIColor.systemOrange.setFill()
          context.fill(CGRect(x: 0, y: 0, width: 120, height: 180))
          UIColor.systemIndigo.setFill()
          context.fill(CGRect(x: 120, y: 180, width: 120, height: 180))
        }
    }
  #endif
}

@MainActor
private struct WallpaperThemeCropCanvas: View {
  let source: WallpaperThemeSource
  @Binding var crop: WallpaperCropState
  let size: CGSize
  @GestureState private var delta = WallpaperThemeCropGestureDelta()

  var body: some View {
    let geometry = WallpaperCropGeometry(
      sourcePixelSize: CGSize(width: source.image.width, height: source.image.height),
      viewportSize: size
    )
    let state = geometry.applying(
      magnification: delta.magnification, translation: delta.translation, to: crop
    )
    let frame = geometry.displayFrame(for: state)
    ZStack(alignment: .topLeading) {
      Color.black
      Image(decorative: source.image, scale: 1)
        .resizable()
        .interpolation(.high)
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
      Path { path in
        for fraction in [CGFloat(1.0 / 3.0), CGFloat(2.0 / 3.0)] {
          path.move(to: CGPoint(x: size.width * fraction, y: 0))
          path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
          path.move(to: CGPoint(x: 0, y: size.height * fraction))
          path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
        }
      }
      .stroke(.white.opacity(0.7), lineWidth: 1)
      .allowsHitTesting(false)
    }
    .frame(width: size.width, height: size.height)
    .clipped()
    .contentShape(Rectangle())
    .gesture(
      SimultaneousGesture(
        MagnificationGesture(minimumScaleDelta: 0.005),
        DragGesture(minimumDistance: 2)
      )
      .updating($delta) { value, delta, _ in
        delta.magnification = value.first ?? 1
        delta.translation = value.second?.translation ?? .zero
      }
      .onEnded { value in
        crop = geometry.applying(
          magnification: value.first ?? 1,
          translation: value.second?.translation ?? .zero,
          to: crop
        )
      }
    )
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("背景图片裁剪区域")
    .accessibilityValue("缩放 \(Int((crop.zoom * 100).rounded()))%")
    .accessibilityAdjustableAction { direction in
      var updated = crop
      switch direction {
      case .increment: updated.zoom += 0.1
      case .decrement: updated.zoom -= 0.1
      @unknown default: return
      }
      crop = geometry.clamped(updated)
    }
    .accessibilityIdentifier("wallpaper-theme-crop")
  }
}

private struct WallpaperThemeCropGestureDelta {
  var magnification: CGFloat = 1
  var translation: CGSize = .zero
}

@MainActor
private struct WallpaperThemeRecommendationCell: View {
  let recommendation: WallpaperRecommendation
  @State private var thumbnail: WallpaperRecommendationThumbnail?
  @State private var didFail = false
  @State private var requestID = UUID()

  var body: some View {
    VStack(spacing: 8) {
      ZStack {
        Color(uiColor: .secondarySystemBackground)
        if let thumbnail {
          Image(decorative: thumbnail.image, scale: 1)
            .resizable()
            .scaledToFill()
            .frame(width: 104, height: 132)
        } else if didFail {
          Image(systemName: "photo.badge.exclamationmark")
        } else {
          ProgressView()
        }
      }
      .frame(width: 104, height: 132)
      .clipped()
      Text(recommendation.title).font(.subheadline).lineLimit(2)
    }
    .frame(width: 112)
    .task(id: recommendation.id) {
      let currentID = UUID()
      requestID = currentID
      didFail = false
      do {
        let value = try await WallpaperRecommendationThumbnailLoader.shared.load(recommendation)
        try Task.checkCancellation()
        guard requestID == currentID else { return }
        thumbnail = value
      } catch {
        guard requestID == currentID, !Task.isCancelled else { return }
        didFail = true
      }
    }
    .onDisappear {
      requestID = UUID()
      thumbnail = nil
    }
  }
}

private struct WallpaperRecommendationThumbnail: @unchecked Sendable {
  let image: CGImage
}

/// Only visible recommendations request thumbnails, with two bounded transfers at
/// a time. No downloaded source bytes or full-size decoded images are retained.
private actor WallpaperRecommendationThumbnailLoader {
  static let shared = WallpaperRecommendationThumbnailLoader()
  private var activeCount = 0
  private var waiters: [(UUID, CheckedContinuation<Void, any Error>)] = []

  func load(_ item: WallpaperRecommendation) async throws -> WallpaperRecommendationThumbnail {
    try await acquire()
    defer { release() }
    try Task.checkCancellation()
    let data = try await WallpaperRecommendationService.shared.fetchImage(item)
    return try await WallpaperThemeEditorProcessing.detached {
      let prepared = try WallpaperThemeImageProcessor.prepare(
        data: data, maximumPixelDimension: 256)
      return WallpaperRecommendationThumbnail(image: prepared.image)
    }
  }

  private func acquire() async throws {
    try Task.checkCancellation()
    if activeCount < 2 {
      activeCount += 1
      return
    }
    let id = UUID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          continuation.resume(throwing: CancellationError())
        } else {
          waiters.append((id, continuation))
        }
      }
    } onCancel: {
      Task { await self.cancelWaiter(id) }
    }
  }

  private func release() {
    if waiters.isEmpty {
      activeCount -= 1
    } else {
      waiters.removeFirst().1.resume()
    }
  }

  private func cancelWaiter(_ id: UUID) {
    guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
    waiters.remove(at: index).1.resume(throwing: CancellationError())
  }
}
