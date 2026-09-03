import CoreGraphics
import Foundation

struct ProfileAvatarCropState: Equatable, Sendable {
  static let initial = ProfileAvatarCropState(
    normalizedCenter: CGPoint(x: 0.5, y: 0.5),
    zoom: 1
  )

  var normalizedCenter: CGPoint
  var zoom: CGFloat
}

struct ProfileAvatarCropGeometry: Equatable, Sendable {
  static let minimumZoom: CGFloat = 1
  static let maximumZoom: CGFloat = 4

  let sourcePixelSize: CGSize
  let viewportSide: CGFloat

  var isValid: Bool {
    Self.isFinitePositive(sourcePixelSize.width)
      && Self.isFinitePositive(sourcePixelSize.height)
      && Self.isFinitePositive(viewportSide)
  }

  func clamped(_ state: ProfileAvatarCropState) -> ProfileAvatarCropState {
    guard isValid else { return .initial }
    let zoom = Self.clampedZoom(state.zoom)
    let cropSide = sourceCropSide(zoom: zoom)
    let horizontalMargin = min(max(cropSide / sourcePixelSize.width / 2, 0), 0.5)
    let verticalMargin = min(max(cropSide / sourcePixelSize.height / 2, 0), 0.5)
    let center = state.normalizedCenter
    return ProfileAvatarCropState(
      normalizedCenter: CGPoint(
        x: Self.clamp(
          center.x.isFinite ? center.x : 0.5,
          lower: horizontalMargin,
          upper: 1 - horizontalMargin
        ),
        y: Self.clamp(
          center.y.isFinite ? center.y : 0.5,
          lower: verticalMargin,
          upper: 1 - verticalMargin
        )
      ),
      zoom: zoom
    )
  }

  func applying(
    magnification: CGFloat,
    translation: CGSize,
    to state: ProfileAvatarCropState
  ) -> ProfileAvatarCropState {
    guard isValid else { return .initial }
    let baseline = clamped(state)
    let factor = magnification.isFinite && magnification > 0 ? magnification : 1
    let zoom = Self.clampedZoom(baseline.zoom * factor)
    let scale = displayScale(zoom: zoom)
    let horizontalTranslation = translation.width.isFinite ? translation.width : 0
    let verticalTranslation = translation.height.isFinite ? translation.height : 0
    let translated = ProfileAvatarCropState(
      normalizedCenter: CGPoint(
        x: baseline.normalizedCenter.x
          - horizontalTranslation / scale / sourcePixelSize.width,
        y: baseline.normalizedCenter.y
          - verticalTranslation / scale / sourcePixelSize.height
      ),
      zoom: zoom
    )
    return clamped(translated)
  }

  func settingZoom(
    _ zoom: CGFloat,
    in state: ProfileAvatarCropState
  ) -> ProfileAvatarCropState {
    guard isValid else { return .initial }
    var updated = state
    updated.zoom = zoom
    return clamped(updated)
  }

  func displayedImageSize(for state: ProfileAvatarCropState) -> CGSize {
    guard isValid else { return .zero }
    let scale = displayScale(zoom: clamped(state).zoom)
    return CGSize(
      width: sourcePixelSize.width * scale,
      height: sourcePixelSize.height * scale
    )
  }

  func displayedImageOffset(for state: ProfileAvatarCropState) -> CGSize {
    guard isValid else { return .zero }
    let state = clamped(state)
    let scale = displayScale(zoom: state.zoom)
    return CGSize(
      width: (0.5 - state.normalizedCenter.x) * sourcePixelSize.width * scale,
      height: (0.5 - state.normalizedCenter.y) * sourcePixelSize.height * scale
    )
  }

  func sourceCropRect(for state: ProfileAvatarCropState) -> CGRect? {
    guard
      isValid,
      state.normalizedCenter.x.isFinite,
      state.normalizedCenter.y.isFinite,
      (0...1).contains(state.normalizedCenter.x),
      (0...1).contains(state.normalizedCenter.y),
      state.zoom.isFinite,
      (Self.minimumZoom...Self.maximumZoom).contains(state.zoom)
    else { return nil }
    let state = clamped(state)
    let floatingSide = sourceCropSide(zoom: state.zoom)
    guard floatingSide.isFinite, floatingSide >= 1 else { return nil }
    let side = max(
      1,
      min(
        floor(floatingSide),
        floor(min(sourcePixelSize.width, sourcePixelSize.height))
      )
    )
    let centerX = state.normalizedCenter.x * sourcePixelSize.width
    let centerY = state.normalizedCenter.y * sourcePixelSize.height
    let maximumX = sourcePixelSize.width - side
    let maximumY = sourcePixelSize.height - side
    let originX = Self.clamp(
      (centerX - side / 2).rounded(),
      lower: 0,
      upper: maximumX
    )
    let originY = Self.clamp(
      (centerY - side / 2).rounded(),
      lower: 0,
      upper: maximumY
    )
    return CGRect(x: originX, y: originY, width: side, height: side)
  }

  private func displayScale(zoom: CGFloat) -> CGFloat {
    max(
      viewportSide / sourcePixelSize.width,
      viewportSide / sourcePixelSize.height
    ) * zoom
  }

  private func sourceCropSide(zoom: CGFloat) -> CGFloat {
    viewportSide / displayScale(zoom: zoom)
  }

  private static func clampedZoom(_ value: CGFloat) -> CGFloat {
    clamp(
      value.isFinite ? value : minimumZoom,
      lower: minimumZoom,
      upper: maximumZoom
    )
  }

  private static func isFinitePositive(_ value: CGFloat) -> Bool {
    value.isFinite && value > 0
  }

  private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
    min(max(value, lower), upper)
  }
}
