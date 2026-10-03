import SwiftUI
import UIKit

/// Live backgrounds share window coordinates even when nested navigation or
/// scrolling containers reserve different amounts of space. Editor previews
/// intentionally keep their separate, local crop geometry.
struct WallpaperLiveCanvas: View {
  let image: CGImage
  let settings: WallpaperThemeSettings
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceTransparency) private var reducesTransparency

  var body: some View {
    WallpaperLiveCanvasRepresentable(
      image: image, settings: settings,
      highContrast: contrast == .increased, reducesTransparency: reducesTransparency
    )
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}

private struct WallpaperLiveCanvasRepresentable: UIViewRepresentable {
  let image: CGImage
  let settings: WallpaperThemeSettings
  let highContrast: Bool
  let reducesTransparency: Bool

  func makeUIView(context: Context) -> WallpaperLiveCanvasView {
    let view = WallpaperLiveCanvasView()
    configure(view)
    return view
  }

  func updateUIView(_ view: WallpaperLiveCanvasView, context: Context) {
    configure(view)
  }

  private func configure(_ view: WallpaperLiveCanvasView) {
    view.configure(
      image: image, settings: settings,
      highContrast: highContrast, reducesTransparency: reducesTransparency)
  }
}

@MainActor
final class WallpaperLiveCanvasView: UIView {
  private let imageLayer = CALayer()
  private var hidesImage = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
    isOpaque = true
    clipsToBounds = true
    imageLayer.contentsGravity = .resizeAspectFill
    layer.addSublayer(imageLayer)
  }

  required init?(coder: NSCoder) { return nil }

  func configure(
    image: CGImage, settings: WallpaperThemeSettings,
    highContrast: Bool, reducesTransparency: Bool
  ) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    backgroundColor = settings.appearance == .dark ? .black : .white
    imageLayer.contents = image
    imageLayer.opacity = Float(settings.imageOpacity)
    hidesImage = highContrast || reducesTransparency
    updateImageFrame()
    CATransaction.commit()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    updateImageFrame()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    updateImageFrame()
  }

  private func updateImageFrame() {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    guard let window else {
      imageLayer.isHidden = true
      return
    }
    imageLayer.frame = convert(window.bounds, from: window)
    imageLayer.isHidden = hidesImage
  }
}
