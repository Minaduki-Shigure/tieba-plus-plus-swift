import UIKit
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class WallpaperWindowSizeReaderTests: XCTestCase {
  func testUsesAttachedWindowSizeInsteadOfSmallerNavigationContainerAndTracksResize() async {
    let portrait = CGSize(width: 390, height: 844)
    let landscape = CGSize(width: 844, height: 390)
    let window = UIWindow(frame: CGRect(origin: .zero, size: portrait))
    let container = UIView(frame: CGRect(x: 0, y: 100, width: 250, height: 500))
    let observer = WallpaperWindowSizeObserverView(frame: container.bounds)
    defer {
      observer.removeFromSuperview()
      window.isHidden = true
    }
    var sizes: [CGSize] = []
    observer.onSizeChange = { sizes.append($0) }
    container.addSubview(observer)
    window.addSubview(container)

    XCTAssertTrue(sizes.isEmpty, "Attaching during layout must not publish synchronously")
    await drainMainQueue()
    XCTAssertEqual(sizes, [portrait])

    // Reserving a tab bar or displaying a keyboard only changes the container.
    container.frame.size.height -= 49
    observer.frame = container.bounds
    observer.setNeedsLayout()
    observer.layoutIfNeeded()
    await drainMainQueue()
    XCTAssertEqual(sizes, [portrait])

    window.bounds.size = landscape
    observer.setNeedsLayout()
    observer.layoutIfNeeded()
    XCTAssertEqual(sizes, [portrait])
    await drainMainQueue()
    XCTAssertEqual(sizes, [portrait, landscape])
    XCTAssertNotEqual(observer.bounds.size, landscape)
  }

  func testSupersededWindowFramesAndDetachedObserversCannotPublishStaleSizes() async {
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    let observer = WallpaperWindowSizeObserverView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    defer {
      observer.removeFromSuperview()
      window.isHidden = true
    }
    var sizes: [CGSize] = []
    observer.onSizeChange = { sizes.append($0) }
    window.addSubview(observer)
    window.bounds.size = CGSize(width: 844, height: 390)
    observer.setNeedsLayout()
    observer.layoutIfNeeded()
    await drainMainQueue()
    XCTAssertEqual(sizes, [CGSize(width: 844, height: 390)])

    window.bounds.size = CGSize(width: 600, height: 800)
    observer.setNeedsLayout()
    observer.layoutIfNeeded()
    observer.removeFromSuperview()
    await drainMainQueue()
    XCTAssertEqual(sizes, [CGSize(width: 844, height: 390)])

    window.addSubview(observer)
    await drainMainQueue()
    XCTAssertEqual(sizes, [CGSize(width: 844, height: 390), CGSize(width: 600, height: 800)])
  }

  private func drainMainQueue() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
  }
}
