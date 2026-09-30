import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main
struct GIFDiagnostic {
  static func main() throws {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data as CFMutableData, UTType.gif.identifier as CFString, 2, nil)!
    CGImageDestinationSetProperties(
      destination,
      [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for (color, delay) in [(UInt32(0xFF00_00FF), 0.07), (UInt32(0x00FF_00FF), 0.13)] {
      var bytes = [UInt8]()
      for _ in 0..<(8 * 6) {
        bytes += [UInt8(color >> 24), UInt8((color >> 16) & 255), UInt8((color >> 8) & 255), 255]
      }
      let provider = CGDataProvider(data: Data(bytes) as CFData)!
      let image = CGImage(
        width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 32,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
      CGImageDestinationAddImage(
        destination, image,
        [kCGImagePropertyGIFDictionary: [
          kCGImagePropertyGIFDelayTime: delay,
          kCGImagePropertyGIFUnclampedDelayTime: delay,
        ]] as CFDictionary)
    }
    precondition(CGImageDestinationFinalize(destination))
    let encoded = data as Data
    print("::notice title=GIF size::\(encoded.count)")
    let base64 = Array(encoded.base64EncodedString())
    for index in stride(from: 0, to: base64.count, by: 2_000) {
      let part = String(base64[index..<min(index + 2_000, base64.count)])
      print("::notice title=GIF base64 \(index)::\(part)")
    }
    let source = CGImageSourceCreateWithData(encoded as CFData, nil)!
    print("::notice title=ImageIO count::\(CGImageSourceGetCount(source))")
    do {
      let inspected = try ComposerGIFSanitizer.sanitize(encoded)
      print("::notice title=Sanitized::\(inspected.width)x\(inspected.height) frames=\(inspected.frameCount)")
    } catch {
      print("::notice title=Sanitizer error::\(error)")
    }
  }
}
