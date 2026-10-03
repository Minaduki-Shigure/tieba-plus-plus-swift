import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct WallpaperThemeSource: @unchecked Sendable {
  let image: CGImage
  let jpegData: Data
  let palette: [UInt32]
}

struct WallpaperThemeRenderedImage: @unchecked Sendable {
  let image: CGImage
  let jpegData: Data
}

/// Run on an explicit user-initiated worker, never from a scrolling view's body.
/// Prepared images are opaque, upright sRGB JPEGs without imported metadata.
enum WallpaperThemeImageProcessor {
  static let maximumInputBytes = 32 * 1_024 * 1_024
  static let maximumJPEGBytes = 8 * 1_024 * 1_024
  static let maximumDeclaredDimension = 16_384
  static let maximumDeclaredPixels = 100_000_000
  static let maximumOutputDimension = 2_048
  static let maximumOutputPixels = 4_000_000
  private static let processingLock = NSLock()

  static func prepare(
    data: Data, maximumPixelDimension: Int = maximumOutputDimension
  ) throws -> WallpaperThemeSource {
    try withExclusiveProcessing {
      try prepareImage(data: data, maximumPixelDimension: maximumPixelDimension)
    }
  }

  static func render(
    source: WallpaperThemeSource, crop: WallpaperCropState,
    aspectRatio: Double, blurRadius: Double
  ) throws -> WallpaperThemeRenderedImage {
    try withExclusiveProcessing {
      try renderImage(source: source, crop: crop, aspectRatio: aspectRatio, blurRadius: blurRadius)
    }
  }

  /// Core Image may finish a GPU operation after its caller is cancelled. One
  /// shared permit bounds bitmap memory across previews, imports and thumbnails.
  /// A cancelled waiter checks again after admission, before allocating pixels.
  static func withExclusiveProcessing<Result>(_ operation: () throws -> Result) throws -> Result {
    try Task.checkCancellation()
    processingLock.lock()
    defer { processingLock.unlock() }
    try Task.checkCancellation()
    return try operation()
  }

  private static func prepareImage(data: Data, maximumPixelDimension: Int) throws -> WallpaperThemeSource {
    try Task.checkCancellation()
    guard (1...maximumOutputDimension).contains(maximumPixelDimension) else {
      throw WallpaperThemeError.invalidSettings
    }
    guard !data.isEmpty else { throw WallpaperThemeError.invalidImage }
    guard data.count <= maximumInputBytes else { throw WallpaperThemeError.imageTooLarge }
    guard
      let source = CGImageSourceCreateWithData(
        data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      CGImageSourceGetStatus(source) == .statusComplete,
      CGImageSourceGetCount(source) == 1,
      let type = CGImageSourceGetType(source) as String?,
      [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.heif.identifier]
        .contains(type),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = dimension(properties[kCGImagePropertyPixelWidth]),
      let height = dimension(properties[kCGImagePropertyPixelHeight])
    else { throw WallpaperThemeError.invalidImage }
    guard
      width <= maximumDeclaredDimension, height <= maximumDeclaredDimension,
      width <= maximumDeclaredPixels / height
    else { throw WallpaperThemeError.imageTooLarge }
    let longest = Double(max(width, height))
    let scale = min(
      1, Double(maximumPixelDimension) / longest,
      sqrt(Double(maximumOutputPixels) / Double(width * height)))
    let thumbnailLimit = max(1, Int(floor(longest * scale)))
    try Task.checkCancellation()
    guard
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: thumbnailLimit,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary),
      accepts(thumbnail)
    else { throw WallpaperThemeError.invalidImage }
    try Task.checkCancellation()
    let image = try opaqueImage(thumbnail, width: thumbnail.width, height: thumbnail.height)
    let jpeg = try encodeJPEG(image)
    let palette = try palette(from: image)
    try Task.checkCancellation()
    return .init(image: image, jpegData: jpeg, palette: palette)
  }

  private static func renderImage(
    source: WallpaperThemeSource, crop: WallpaperCropState,
    aspectRatio: Double, blurRadius: Double
  ) throws -> WallpaperThemeRenderedImage {
    try Task.checkCancellation()
    guard
      accepts(source.image), !source.jpegData.isEmpty,
      source.jpegData.count <= maximumJPEGBytes, crop.isValid,
      WallpaperThemeRecord.accepts(aspectRatio: aspectRatio),
      blurRadius.isFinite, (0...30).contains(blurRadius)
    else { throw WallpaperThemeError.invalidSettings }
    let geometry = WallpaperCropGeometry(
      sourcePixelSize: CGSize(width: source.image.width, height: source.image.height),
      viewportSize: CGSize(width: aspectRatio * 1_000, height: 1_000))
    let rect = geometry.sourceCropRect(for: crop)
    guard rect.width >= 1, rect.height >= 1,
      let cropped = source.image.cropping(to: rect.integral)
    else { throw WallpaperThemeError.renderingFailed }
    let width = max(1, Int(floor(rect.width)))
    let height = max(1, Int(floor(rect.height)))
    var image = try opaqueImage(cropped, width: width, height: height)
    try Task.checkCancellation()
    if blurRadius > 0 {
      let input = CIImage(cgImage: image)
      let bounds = CGRect(x: 0, y: 0, width: width, height: height)
      // Clamp at the edges before blurring, then restore the finite output extent.
      // This avoids dark edge halos and never asks Core Image for an infinite image.
      let output = input.clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blurRadius])
        .cropped(to: bounds)
      let context = CIContext(options: [.cacheIntermediates: false])
      guard let blurred = context.createCGImage(output, from: bounds), accepts(blurred) else {
        throw WallpaperThemeError.renderingFailed
      }
      image = try opaqueImage(blurred, width: width, height: height)
    }
    try Task.checkCancellation()
    let jpeg = try encodeJPEG(image)
    try Task.checkCancellation()
    return .init(image: image, jpegData: jpeg)
  }

  private static func dimension(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber,
      CFGetTypeID(number) != CFBooleanGetTypeID(),
      let integer = Int(number.stringValue), integer > 0
    else { return nil }
    return integer
  }

  private static func accepts(_ image: CGImage) -> Bool {
    image.width > 0 && image.height > 0
      && image.width <= maximumOutputDimension && image.height <= maximumOutputDimension
      && image.width <= maximumOutputPixels / image.height
      && image.bytesPerRow > 0 && image.bytesPerRow <= 16_384
      && image.height <= 32 * 1_024 * 1_024 / image.bytesPerRow
  }

  private static func opaqueImage(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
    guard width > 0, height > 0,
      width <= maximumOutputDimension, height <= maximumOutputDimension,
      width <= maximumOutputPixels / height,
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw WallpaperThemeError.renderingFailed }
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else { throw WallpaperThemeError.renderingFailed }
    return result
  }

  private static func encodeJPEG(_ image: CGImage) throws -> Data {
    // The image has no source metadata; ImageIO receives only an explicit quality.
    for quality in [0.90, 0.78, 0.62] {
      try Task.checkCancellation()
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(
        data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
      else { throw WallpaperThemeError.renderingFailed }
      CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else {
        throw WallpaperThemeError.renderingFailed
      }
      if data.length <= maximumJPEGBytes { return data as Data }
    }
    throw WallpaperThemeError.imageTooLarge
  }

  private static func palette(from image: CGImage) throws -> [UInt32] {
    try Task.checkCancellation()
    let side = 48
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw WallpaperThemeError.renderingFailed }
    context.interpolationQuality = .low
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    guard let data = context.data else { throw WallpaperThemeError.renderingFailed }
    let pixels = data.assumingMemoryBound(to: UInt8.self)
    var buckets: [Int: (count: Int, r: Int, g: Int, b: Int)] = [:]
    for index in 0..<(side * side) {
      let r = Int(pixels[index * 4]), g = Int(pixels[index * 4 + 1])
      let b = Int(pixels[index * 4 + 2])
      let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
      let previous = buckets[key] ?? (0, 0, 0, 0)
      buckets[key] = (previous.count + 1, previous.r + r, previous.g + g, previous.b + b)
    }
    let ordered = buckets.sorted {
      $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count
    }
    var result: [UInt32] = []
    for entry in ordered {
      let value = entry.value
      let r = value.r / value.count, g = value.g / value.count, b = value.b / value.count
      let rgb = UInt32(r << 16 | g << 8 | b)
      let distinct = result.allSatisfy {
        let dr = r - Int(($0 >> 16) & 255), dg = g - Int(($0 >> 8) & 255)
        let db = b - Int($0 & 255)
        return dr * dr + dg * dg + db * db >= 32 * 32
      }
      if distinct { result.append(rgb) }
      if result.count == 6 { break }
    }
    try Task.checkCancellation()
    return result
  }
}
