import Foundation

enum WallpaperThemeAppearance: String, Codable, CaseIterable, Sendable {
  case light
  case dark
}

struct WallpaperThemeSettings: Codable, Equatable, Sendable {
  var appearance: WallpaperThemeAppearance
  var imageOpacity: Double
  var blurRadius: Double
  var accentRGB: UInt32?

  static let defaultValue = Self(
    appearance: .light, imageOpacity: 1, blurRadius: 0, accentRGB: nil)

  var isValid: Bool {
    imageOpacity.isFinite && (0...1).contains(imageOpacity)
      && blurRadius.isFinite && (0...30).contains(blurRadius)
      && (accentRGB.map { $0 <= 0xFF_FF_FF } ?? true)
  }
}

struct WallpaperCropState: Codable, Equatable, Sendable {
  var centerX: Double
  var centerY: Double
  var zoom: Double

  static let initial = Self(centerX: 0.5, centerY: 0.5, zoom: 1)

  var isValid: Bool {
    centerX.isFinite && centerY.isFinite && zoom.isFinite
      && (0...1).contains(centerX) && (0...1).contains(centerY) && (1...4).contains(zoom)
  }
}

/// Normalized centers use the image's top-left origin. Geometry is independent
/// of screen scale; displayFrame is in viewport points and may have negative origins.
struct WallpaperCropGeometry: Equatable, Sendable {
  let sourcePixelSize: CGSize
  let viewportSize: CGSize

  var isValid: Bool {
    [sourcePixelSize.width, sourcePixelSize.height, viewportSize.width, viewportSize.height]
      .allSatisfy { $0.isFinite && $0 > 0 }
      && baseScale.isFinite && baseScale > 0
  }

  func clamped(_ state: WallpaperCropState) -> WallpaperCropState {
    guard isValid else { return .initial }
    let zoom = min(max(state.zoom.isFinite ? state.zoom : 1, 1), 4)
    let scale = baseScale * zoom
    let marginX = min(0.5, viewportSize.width / scale / sourcePixelSize.width / 2)
    let marginY = min(0.5, viewportSize.height / scale / sourcePixelSize.height / 2)
    return .init(
      centerX: min(max(state.centerX.isFinite ? state.centerX : 0.5, marginX), 1 - marginX),
      centerY: min(max(state.centerY.isFinite ? state.centerY : 0.5, marginY), 1 - marginY),
      zoom: zoom)
  }

  func applying(
    magnification: CGFloat, translation: CGSize, to state: WallpaperCropState
  ) -> WallpaperCropState {
    guard isValid else { return .initial }
    let baseline = clamped(state)
    let factor = magnification.isFinite && magnification > 0 ? magnification : 1
    let zoom = min(max(baseline.zoom * factor, 1), 4)
    let scale = baseScale * zoom
    let dx = translation.width.isFinite ? translation.width : 0
    let dy = translation.height.isFinite ? translation.height : 0
    return clamped(
      .init(
        centerX: baseline.centerX - dx / scale / sourcePixelSize.width,
        centerY: baseline.centerY - dy / scale / sourcePixelSize.height,
        zoom: zoom))
  }

  func sourceCropRect(for state: WallpaperCropState) -> CGRect {
    guard isValid else { return .zero }
    let state = clamped(state)
    let scale = baseScale * state.zoom
    let size = CGSize(width: viewportSize.width / scale, height: viewportSize.height / scale)
    return CGRect(
      x: state.centerX * sourcePixelSize.width - size.width / 2,
      y: state.centerY * sourcePixelSize.height - size.height / 2,
      width: size.width, height: size.height)
  }

  func displayFrame(for state: WallpaperCropState) -> CGRect {
    guard isValid else { return .zero }
    let state = clamped(state)
    let scale = baseScale * state.zoom
    let size = CGSize(width: sourcePixelSize.width * scale, height: sourcePixelSize.height * scale)
    return CGRect(
      x: viewportSize.width / 2 - state.centerX * size.width,
      y: viewportSize.height / 2 - state.centerY * size.height,
      width: size.width, height: size.height)
  }

  private var baseScale: CGFloat {
    max(viewportSize.width / sourcePixelSize.width, viewportSize.height / sourcePixelSize.height)
  }
}

struct WallpaperThemeRecord: Codable, Equatable, Sendable {
  let id: UUID
  let settings: WallpaperThemeSettings
  let crop: WallpaperCropState
  let aspectRatio: Double

  var isValid: Bool {
    settings.isValid && crop.isValid && Self.accepts(aspectRatio: aspectRatio)
  }

  static func accepts(aspectRatio: Double) -> Bool {
    aspectRatio.isFinite && (0.1...10).contains(aspectRatio)
  }
}

struct WallpaperThemeDocument: Sendable {
  let record: WallpaperThemeRecord
  let sourceJPEG: Data
  let renderedJPEG: Data
}

enum WallpaperThemeError: Error, Equatable, LocalizedError, Sendable {
  case invalidSettings
  case invalidImage
  case imageTooLarge
  case renderingFailed
  case unsafeStorage
  case corruptedStorage
  case storageFailed

  var errorDescription: String? {
    switch self {
    case .invalidSettings: "背景设置无效，请重新调整。"
    case .invalidImage: "无法读取这张静态图片，请选择 JPEG、PNG 或 HEIF 图片。"
    case .imageTooLarge: "图片过大，请选择较小的图片。"
    case .renderingFailed: "无法生成背景预览，请重新选择图片。"
    case .unsafeStorage: "背景文件位置不可用，现有背景尚未被替换。"
    case .corruptedStorage: "背景文件已损坏，请重新选择背景或恢复默认外观。"
    case .storageFailed: "无法保存背景，请检查可用存储空间后重试。"
    }
  }
}
