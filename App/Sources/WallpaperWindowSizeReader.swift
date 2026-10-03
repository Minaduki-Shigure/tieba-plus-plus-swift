import SwiftUI
import UIKit

/// Crop to the actual wallpaper window, independent of navigation bars,
/// keyboards and the space reserved by the root tab control.
struct WallpaperWindowSizeReader: UIViewRepresentable {
  let onSizeChange: @MainActor (CGSize) -> Void

  func makeUIView(context: Context) -> WallpaperWindowSizeObserverView {
    let view = WallpaperWindowSizeObserverView()
    view.isUserInteractionEnabled = false
    view.onSizeChange = onSizeChange
    return view
  }

  func updateUIView(_ view: WallpaperWindowSizeObserverView, context: Context) {
    view.onSizeChange = onSizeChange
    view.observeWindowSize()
  }
}

@MainActor
final class WallpaperWindowSizeObserverView: UIView {
  var onSizeChange: (@MainActor (CGSize) -> Void)?
  private weak var observedWindow: UIWindow?
  private var observedSize: CGSize?
  private var observationID: UInt64 = 0

  override func didMoveToWindow() {
    super.didMoveToWindow()
    observeWindowSize()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    observeWindowSize()
  }

  func observeWindowSize() {
    guard let window else {
      observationID &+= 1
      observedWindow = nil
      observedSize = nil
      return
    }
    let size = window.bounds.size
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      return
    }
    guard observedWindow !== window || observedSize != size else { return }
    observedWindow = window
    observedSize = size
    observationID &+= 1
    let currentObservation = observationID
    // UIKit may lay out this observer while SwiftUI updates its hierarchy.
    // Defer publishing and reject frames superseded by a resize or detachment.
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window,
        self.window === window,
        self.observationID == currentObservation,
        window.bounds.size == size
      else { return }
      self.onSizeChange?(size)
    }
  }
}
