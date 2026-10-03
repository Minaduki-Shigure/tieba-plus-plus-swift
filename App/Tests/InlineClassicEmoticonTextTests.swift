import SwiftUI
import TiebaCore
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class InlineClassicEmoticonTextTests: XCTestCase {
  func testPlainTextKeepsOneUnchangedSegmentWithoutImageRequests() {
    let text = String(repeating: "长段正文，不需要任何图形加载。\n", count: 200)
    let contents: [BrowseContent] = [.text(text)]
    let plan = InlineClassicEmoticonPlan(contents)
    XCTAssertEqual(plan.segments, [.text(contents)])
    XCTAssertTrue(plan.urls.isEmpty)
    XCTAssertFalse(plan.containsImages)
  }

  func testKnownStructuredAndTextTokensUseSameFixedURLAndRetainTheirOrder() throws {
    let url = try XCTUnwrap(InlineClassicEmoticonPlan.thumbnailURL(exactName: "笑眼"))
    let plan = InlineClassicEmoticonPlan([
      .text("前#(笑眼)中"), .emoticon(name: "笑眼", url: nil), .text("后"),
    ])
    XCTAssertEqual(
      plan.segments,
      [
        .text([.text("前")]), .emoticon(name: "笑眼", url: url),
        .text([.text("中")]), .emoticon(name: "笑眼", url: url), .text([.text("后")]),
      ])
    XCTAssertEqual(plan.urls, [url])
  }

  func testUnknownAmbiguousAndMalformedMarkersStayLiteralAroundKnownTokens() throws {
    let prefix = "#(unknown)#(生气)#( 笑眼)#(bad#(笑眼))"
    let suffix = "#(未完成"
    let url = try XCTUnwrap(InlineClassicEmoticonPlan.thumbnailURL(exactName: "菜狗"))
    let plan = InlineClassicEmoticonPlan([.text(prefix + "#(菜狗)" + suffix)])
    XCTAssertEqual(
      plan.segments,
      [
        .text([.text(prefix)]), .emoticon(name: "菜狗", url: url), .text([.text(suffix)]),
      ])
    XCTAssertNil(InlineClassicEmoticonPlan.thumbnailURL(exactName: "生气"))
    XCTAssertNil(InlineClassicEmoticonPlan.thumbnailURL(exactName: "笑眼\u{200B}"))
  }

  func testPostProvidedURLCannotChangeArtworkOrIntroduceNewNetworkRequests() throws {
    let untrusted = try XCTUnwrap(URL(string: "https://example.com/tracker.png"))
    let url = try XCTUnwrap(InlineClassicEmoticonPlan.thumbnailURL(exactName: "滑稽"))
    let unknown: BrowseContent = .emoticon(name: "unregistered", url: untrusted)
    let plan = InlineClassicEmoticonPlan([
      .emoticon(name: "滑稽", url: untrusted), unknown,
      .emoticon(name: "生气", url: url),
    ])
    XCTAssertEqual(plan.urls, [url])
    XCTAssertEqual(
      plan.segments,
      [
        .emoticon(name: "滑稽", url: url),
        .text([unknown, .emoticon(name: "生气", url: url)]),
      ])
  }

  @MainActor
  func testLinksMentionsAndCopyTextRetainOriginalMeaningAcrossImages() throws {
    let link = try XCTUnwrap(URL(string: "https://tieba.baidu.com/p/123"))
    let interactive: [BrowseContent] = [
      .mention(name: "读者", userID: 42), .link(label: "#(滑稽)链接", url: link),
    ]
    let contents: [BrowseContent] =
      [.emoticon(name: "笑眼", url: nil)] + interactive
      + [.text("#(菜狗)后文")]
    let plan = InlineClassicEmoticonPlan(contents)
    guard case .text(let preserved) = plan.segments[1] else {
      return XCTFail("Interactive fragments must remain in the same attributed text run")
    }
    XCTAssertEqual(preserved, interactive)
    let text = BrowseContentView.inlineText(preserved, linksUserMentions: true)
    XCTAssertEqual(
      text.runs.compactMap(\.link),
      [
        try XCTUnwrap(BrowseContentView.mentionURL(for: 42)), link,
      ])
    XCTAssertEqual(BrowseContentCopyText.text(contents), "#(笑眼)@读者#(滑稽)链接#(菜狗)后文")
    XCTAssertEqual(plan.urls.count, 2, "Link labels must not be split into image attachments")
  }

  @MainActor
  func testNativeInlineTextReallyRendersImagesAndKeepsFallbackForMissingArtwork() throws {
    let url = try XCTUnwrap(InlineClassicEmoticonPlan.thumbnailURL(exactName: "笑眼"))
    let plan = InlineClassicEmoticonPlan([.text("前#(笑眼)中#(笑眼)后#(菜狗)")])
    let assets = [url: DownsampledImageAsset(image: redImage())]
    let rendered = try render(plan, assets: assets, side: 22, width: 280)
    XCTAssertGreaterThan(try redPixelCount(rendered), 500)
    XCTAssertEqual(rendered.size.width, 280, accuracy: 1)
    let fallback = try render(plan, assets: [:], side: 22, width: 280)
    XCTAssertEqual(try redPixelCount(fallback), 0)
  }

  @MainActor
  func testLargeInlineImagesWrapWithinNarrowWidthAndScaleWithoutRedecoding() throws {
    let source = redImage()
    let scaled = try XCTUnwrap(InlineClassicEmoticonText.displayImage(source, maximumSide: 44))
    XCTAssertEqual(scaled.size.width, 44, accuracy: 0.01)
    XCTAssertEqual(scaled.size.height, 44, accuracy: 0.01)
    XCTAssertTrue(scaled.cgImage === source.cgImage)
    XCTAssertNil(InlineClassicEmoticonText.displayImage(source, maximumSide: .infinity))
    let url = try XCTUnwrap(InlineClassicEmoticonPlan.thumbnailURL(exactName: "笑眼"))
    let plan = InlineClassicEmoticonPlan([.text(String(repeating: "字#(笑眼)", count: 20))])
    let image = try render(plan, assets: [url: .init(image: source)], side: 44, width: 220)
    XCTAssertEqual(image.size.width, 220, accuracy: 1)
    XCTAssertGreaterThan(image.size.height, 88)
    XCTAssertGreaterThan(try redPixelCount(image), 20_000)
  }

  @MainActor
  private func redImage() -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format).image {
      UIColor.red.setFill()
      $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    }
  }

  @MainActor
  private func render(
    _ plan: InlineClassicEmoticonPlan,
    assets: [URL: DownsampledImageAsset], side: CGFloat, width: CGFloat
  ) throws -> UIImage {
    let renderer = ImageRenderer(
      content: InlineClassicEmoticonText.text(
        plan: plan, assets: assets, imageSide: side
      ).font(.body).foregroundColor(.black).frame(width: width, alignment: .leading)
        .background(Color.white))
    renderer.proposedSize = ProposedViewSize(width: width, height: nil)
    renderer.scale = 1
    return try XCTUnwrap(renderer.uiImage)
  }

  private func redPixelCount(_ image: UIImage) throws -> Int {
    let image = try XCTUnwrap(image.cgImage)
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    try pixels.withUnsafeMutableBytes { storage in
      let context = try XCTUnwrap(
        CGContext(
          data: storage.baseAddress, width: image.width, height: image.height,
          bitsPerComponent: 8, bytesPerRow: image.width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return stride(from: 0, to: pixels.count, by: 4).filter {
      pixels[$0] > 180 && pixels[$0 + 1] < 80 && pixels[$0 + 2] < 80 && pixels[$0 + 3] > 180
    }.count
  }
}
