import SwiftUI
import TiebaCore
import UIKit

/// A display-only projection. Copying, filtering and submission continue to use
/// the original BrowseContent; attachment characters never enter those models.
struct InlineClassicEmoticonPlan: Equatable, Sendable {
  enum Segment: Equatable, Sendable {
    case text([BrowseContent])
    case emoticon(name: String, url: URL)
  }

  let segments: [Segment]
  let urls: [URL]
  let paragraphs: [[Segment]]

  private static let entriesByName = Dictionary(
    uniqueKeysWithValues: TiebaClassicEmoticonCatalog.entries.map { ($0.name, $0) }
  )

  init(_ contents: [BrowseContent]) {
    var segments: [Segment] = []
    var pendingText: [BrowseContent] = []
    var urls: Set<URL> = []

    func appendEmoticon(_ name: String, url: URL) {
      if !pendingText.isEmpty {
        segments.append(.text(pendingText))
        pendingText.removeAll(keepingCapacity: true)
      }
      segments.append(.emoticon(name: name, url: url))
      urls.insert(url)
    }

    for content in contents {
      switch content {
      case .emoticon(let name, _):
        // Never use a URL supplied by post content to resolve a classic face.
        if let url = Self.thumbnailURL(exactName: name) {
          appendEmoticon(name, url: url)
        } else {
          pendingText.append(content)
        }
      case .text(let text):
        guard text.contains("#(") else {
          pendingText.append(content)
          continue
        }
        var cursor = text.startIndex
        var plainStart = cursor
        while let marker = text.range(of: "#(", range: cursor..<text.endIndex) {
          guard let closing = text[marker.upperBound...].firstIndex(of: ")") else { break }
          let name = String(text[marker.upperBound..<closing])
          cursor = text.index(after: closing)
          guard let url = Self.thumbnailURL(exactName: name) else { continue }
          if plainStart < marker.lowerBound {
            pendingText.append(.text(String(text[plainStart..<marker.lowerBound])))
          }
          appendEmoticon(name, url: url)
          plainStart = cursor
        }
        if plainStart < text.endIndex {
          pendingText.append(.text(String(text[plainStart...])))
        }
      default:
        pendingText.append(content)
      }
    }
    if !pendingText.isEmpty { segments.append(.text(pendingText)) }
    self.segments = segments
    self.urls = urls.sorted { $0.absoluteString < $1.absoluteString }
    self.paragraphs = urls.isEmpty ? [segments] : Self.splitParagraphs(segments)
  }

  private static func splitParagraphs(_ segments: [Segment]) -> [[Segment]] {
    var result: [[Segment]] = []
    var paragraph: [Segment] = []
    var text: [BrowseContent] = []

    func flushText() {
      guard !text.isEmpty else { return }
      paragraph.append(.text(text))
      text.removeAll(keepingCapacity: true)
    }

    for segment in segments {
      switch segment {
      case .emoticon:
        flushText()
        paragraph.append(segment)
      case .text(let contents):
        for content in contents {
          guard case .text(let value) = content else {
            // Keep attributed links/mentions intact, including their labels.
            text.append(content)
            continue
          }
          for (index, line) in value.split(
            omittingEmptySubsequences: false, whereSeparator: \.isNewline
          ).enumerated() {
            if index > 0 {
              flushText()
              result.append(paragraph)
              paragraph.removeAll(keepingCapacity: true)
            }
            if !line.isEmpty { text.append(.text(String(line))) }
          }
        }
      }
    }
    flushText()
    result.append(paragraph)
    return result
  }

  static func thumbnailURL(exactName name: String) -> URL? {
    guard let entry = entriesByName[name], name.utf8.elementsEqual(entry.name.utf8) else {
      return nil
    }
    return entry.thumbnailURL
  }

  var containsImages: Bool {
    #if PERFORMANCE_HARNESS
      guard ThreadScrollPerformanceScenario.rendersInlineEmoticonImages else { return false }
    #endif
    return !urls.isEmpty
  }
}

/// One native Text per paragraph, including its images, links and mentions.
/// There are no per-emoticon views, UIKit text views or animation timers.
struct InlineClassicEmoticonText: View {
  let plan: InlineClassicEmoticonPlan
  let prefix: Text
  let linksUserMentions: Bool
  let accentColor: Color
  let splitsParagraphs: Bool
  let imageLoader: DefaultInlineEmoticonImageLoader

  @Environment(\.contentMediaLoadPolicy) private var mediaLoadPolicy
  @Environment(\.contentMediaLoadBehavior) private var mediaLoadBehavior
  @Environment(\.contentImagePreviewNetworkAccess) private var previewNetworkAccess
  @ScaledMetric private var imageSide: CGFloat
  @ScaledMetric private var baselineOffset: CGFloat
  @State private var assets: [URL: DownsampledImageAsset] = [:]
  @State private var activeAttempt: UUID?

  init(
    plan: InlineClassicEmoticonPlan,
    prefix: Text = Text(""),
    linksUserMentions: Bool = false,
    accentColor: Color = AppAccentColor.defaultValue.color,
    relativeTo textStyle: Font.TextStyle = .body,
    imageSide: CGFloat = 22,
    splitsParagraphs: Bool = false,
    imageLoader: DefaultInlineEmoticonImageLoader = .init()
  ) {
    self.plan = plan
    self.prefix = prefix
    self.linksUserMentions = linksUserMentions
    self.accentColor = accentColor
    self.splitsParagraphs = splitsParagraphs
    self.imageLoader = imageLoader
    _imageSide = ScaledMetric(wrappedValue: imageSide, relativeTo: textStyle)
    _baselineOffset = ScaledMetric(wrappedValue: -3, relativeTo: textStyle)
  }

  private var request: InlineEmoticonImageRequest {
    InlineEmoticonImageRequest(
      urls: plan.urls,
      fetchPolicy: ContentRemoteImageLoadDecision.fetchPolicy(
        policy: mediaLoadPolicy,
        behavior: mediaLoadBehavior,
        lastObservedPolicy: nil,
        request: .init(url: nil, maxPixelSize: 120),
        authorizedRequest: nil,
        networkAccess: previewNetworkAccess
      )
    )
  }

  var body: some View {
    let currentRequest = request
    let cached = imageLoader.cachedImages(for: currentRequest)
    let available = assets.merging(cached) { _, cached in cached }
    let missing = InlineEmoticonImageRequest(
      urls: currentRequest.urls.filter { available[$0] == nil },
      fetchPolicy: currentRequest.fetchPolicy
    )
    if missing.urls.isEmpty {
      // The normal warm-cache scrolling path has no placeholder layout or task.
      renderedContent(assets: available)
    } else {
      renderedContent(assets: available)
        .task(id: currentRequest) {
          let attempt = UUID()
          activeAttempt = attempt
          let loaded = await InlineEmoticonImageLoader.load(missing, using: imageLoader)
          guard !Task.isCancelled, activeAttempt == attempt, !loaded.isEmpty else { return }
          // One batch/state update for the entire inline block, even when the
          // display has several paragraphs. Text-only/failed batches do not
          // invalidate layout a second time.
          assets = available.merging(loaded) { _, loaded in loaded }
        }
    }
  }

  @ViewBuilder
  private func renderedContent(assets: [URL: DownsampledImageAsset]) -> some View {
    if splitsParagraphs, plan.paragraphs.count > 1 {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(plan.paragraphs.enumerated()), id: \.offset) { index, segments in
          if segments.isEmpty {
            Text(" ").accessibilityHidden(true)
          } else {
            Self.text(
              segments: segments, assets: assets, prefix: index == 0 ? prefix : Text(""),
              linksUserMentions: linksUserMentions, accentColor: accentColor,
              imageSide: imageSide, baselineOffset: baselineOffset
            )
          }
        }
      }
    } else {
      Self.text(
        plan: plan, assets: assets, prefix: prefix,
        linksUserMentions: linksUserMentions, accentColor: accentColor,
        imageSide: imageSide, baselineOffset: baselineOffset
      )
    }
  }

  static func text(
    plan: InlineClassicEmoticonPlan,
    assets: [URL: DownsampledImageAsset],
    prefix: Text = Text(""),
    linksUserMentions: Bool = false,
    accentColor: Color = AppAccentColor.defaultValue.color,
    imageSide: CGFloat = 22,
    baselineOffset: CGFloat = -3
  ) -> Text {
    text(
      segments: plan.segments, assets: assets, prefix: prefix,
      linksUserMentions: linksUserMentions, accentColor: accentColor,
      imageSide: imageSide, baselineOffset: baselineOffset
    )
  }

  private static func text(
    segments: [InlineClassicEmoticonPlan.Segment],
    assets: [URL: DownsampledImageAsset],
    prefix: Text,
    linksUserMentions: Bool,
    accentColor: Color,
    imageSide: CGFloat,
    baselineOffset: CGFloat
  ) -> Text {
    segments.reduce(prefix) { result, segment in
      switch segment {
      case .text(let contents):
        if let plain = BrowseContentView.plainInlineText(contents) {
          return result + Text(plain)
        }
        return result
          + Text(
            BrowseContentView.inlineText(
              contents, linksUserMentions: linksUserMentions, accentColor: accentColor
            ))
      case .emoticon(let name, let url):
        let token = "#(\(name))"
        guard let asset = assets[url],
          let image = displayImage(asset.image, maximumSide: imageSide)
        else { return result + Text(token) }
        #if PERFORMANCE_HARNESS
          ThreadScrollPerformanceScenario.recordInlineEmoticonRendering(imageCount: 1)
        #endif
        return result
          + Text(Image(uiImage: image))
          .baselineOffset(baselineOffset)
          .accessibilityLabel(Text(token))
      }
    }
  }

  static func displayImage(_ image: UIImage, maximumSide: CGFloat) -> UIImage? {
    guard let cgImage = image.cgImage, maximumSide.isFinite, maximumSide > 0 else {
      return nil
    }
    // Reuse the decoded pixels; changing point scale does not redraw or decode.
    return UIImage(
      cgImage: cgImage,
      scale: CGFloat(max(cgImage.width, cgImage.height)) / maximumSide,
      orientation: image.imageOrientation
    )
  }
}

struct InlineEmoticonCopyModifier: ViewModifier {
  let isEnabled: Bool
  let contents: [BrowseContent]
  @State private var selection: SelectableTextPresentation?

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.contextMenu {
        Button {
          selection = SelectableTextPresentation(text: BrowseContentCopyText.text(contents))
        } label: {
          Label("选择文字", systemImage: "text.cursor")
        }
      }
      .sheet(item: $selection) { presentation in
        SelectableTextSheet(presentation: presentation) { command, expected in
          if let text = SelectableTextSheetCommandPolicy.consume(
            command, expected: expected, pending: &selection
          ) {
            SelectableTextPasteboard.write(text)
          }
        }
      }
    } else {
      content
    }
  }
}
