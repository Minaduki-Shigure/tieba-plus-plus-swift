import SwiftUI
import TiebaCore

struct BrowseContentView: View {
  let contents: [BrowseContent]
  let imageLayout: BrowseContentImageLayout
  let onImageOpen: ((Int) -> Void)?
  let onUserMention: ((Int64) -> Void)?
  let onTiebaLink: ((TiebaLinkTarget) -> Void)?
  let allowsDirectTextSelection: Bool
  let tracksAnimationVisibility: Bool
  let maximumPreviewPixelSize: Int

  @Environment(\.externalWebOpenMode) private var externalWebOpenMode
  @Environment(\.openExternalWeb) private var openExternalWeb
  @Environment(\.openURL) private var openURL
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.appAccentColor) private var appAccentColor
  @Environment(\.contentImagePreviewQuality) private var contentImagePreviewQuality
  @State private var imageGalleryPresentation: ImageGalleryPresentation?

  init(
    contents: [BrowseContent],
    imageLayout: BrowseContentImageLayout = .responsive,
    onImageOpen: ((Int) -> Void)? = nil,
    onUserMention: ((Int64) -> Void)? = nil,
    onTiebaLink: ((TiebaLinkTarget) -> Void)? = nil,
    allowsDirectTextSelection: Bool = true,
    tracksAnimationVisibility: Bool = false,
    maximumPreviewPixelSize: Int = 1_600
  ) {
    self.contents = contents
    self.imageLayout = imageLayout
    self.onImageOpen = onImageOpen
    self.onUserMention = onUserMention
    self.onTiebaLink = onTiebaLink
    self.allowsDirectTextSelection = allowsDirectTextSelection
    self.tracksAnimationVisibility = tracksAnimationVisibility
    self.maximumPreviewPixelSize = max(maximumPreviewPixelSize, 1)
  }

  private var blocks: [BrowseContentBlock] {
    BrowseContentBlock.makeBlocks(contents)
  }

  @ViewBuilder
  var body: some View {
    if installsImageGalleryCover {
      content
        .fullScreenCover(item: $imageGalleryPresentation) { presentation in
          ImageViewer(
            items: presentation.items,
            initialIndex: presentation.initialIndex
          )
        }
    } else {
      content
    }
  }

  private var installsImageGalleryCover: Bool {
    guard onImageOpen == nil else { return false }
    #if PERFORMANCE_HARNESS
      if ThreadScrollPerformanceScenario.installsLegacyEmptyImageGalleryCovers {
        return true
      }
    #endif
    return Self.containsImage(contents)
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 9) {
      ForEach(blocks) { block in
        switch block {
        case .inline(_, let contents):
          inlineContent(contents)
        case .imageRun(let images):
          BrowseImageMasonryLayout(
            imageLayout: imageLayout,
            forcesSingleColumn: dynamicTypeSize.isAccessibilitySize
          ) {
            ForEach(images) { image in
              browseImage(image)
                .layoutValue(
                  key: BrowseImageAspectRatioLayoutValueKey.self,
                  value: image.aspectRatio
                )
            }
          }
          .clipped()
        case .standalone(let contentOffset, let content):
          standalone(content, contentOffset: contentOffset)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  @ViewBuilder
  private func inlineContent(_ contents: [BrowseContent]) -> some View {
    if let plainText = Self.plainInlineText(contents) {
      Text(plainText)
        .modifier(DirectTextSelectionModifier(isEnabled: allowsDirectTextSelection))
        #if PERFORMANCE_HARNESS
          .threadScrollProfileFixedSize(
            horizontal: false,
            vertical: true,
            isEnabled: ThreadScrollPerformanceScenario.appliesLongTextFixedSize
          )
        #endif
    } else {
      Text(
        Self.inlineText(
          contents,
          linksUserMentions: onUserMention != nil || onTiebaLink != nil,
          accentColor: appAccentColor.color
        )
      )
        .modifier(DirectTextSelectionModifier(isEnabled: allowsDirectTextSelection))
        #if PERFORMANCE_HARNESS
          .threadScrollProfileFixedSize(
            horizontal: false,
            vertical: true,
            isEnabled: ThreadScrollPerformanceScenario.appliesLongTextFixedSize
          )
        #endif
        .environment(\.openURL, contentOpenURLAction)
    }
  }

  private var contentOpenURLAction: OpenURLAction {
    OpenURLAction { url in
      switch BrowseContentLinkRouter.disposition(for: url, mode: externalWebOpenMode) {
      case .tieba(let target):
        if case .user(let userID) = target, let onUserMention {
          onUserMention(userID)
          return .handled
        }
        guard let onTiebaLink else { return .systemAction }
        onTiebaLink(target)
        return .handled
      case .system:
        return .systemAction
      case .inAppSafari(let url):
        imageGalleryPresentation = nil
        return openExternalWeb(url) ? .handled : .systemAction
      case .rejected:
        return .discarded
      }
    }
  }

  @ViewBuilder
  private func standalone(_ content: BrowseContent, contentOffset: Int) -> some View {
    switch content {
    case .image(let thumbnail, let fullSize, _, let dynamic, let width, let height):
      browseImage(
        BrowseContentImageItem(
          contentOffset: contentOffset,
          thumbnailURL: thumbnail,
          fullSizeURL: fullSize,
          dynamicURL: dynamic,
          width: width,
          height: height
        )
      )
    case .video(let video):
      BrowseVideoView(
        video: video,
        tracksAnimationVisibility: tracksAnimationVisibility,
        maximumPreviewPixelSize: maximumPreviewPixelSize
      ) { pageURL in
        openVideoPage(pageURL)
      }
    case .voice(let url, let duration):
      VoicePlaybackButton(url: url, duration: duration)
    case .text, .mention, .link, .emoticon, .unsupported:
      EmptyView()
    }
  }

  private func browseImage(_ image: BrowseContentImageItem) -> some View {
    BrowseImageView(
      thumbnailURL: BrowseContentImageSourceResolver.previewURL(
        thumbnail: image.thumbnailURL,
        fullSize: image.fullSizeURL,
        dynamic: image.dynamicURL,
        quality: contentImagePreviewQuality
      ),
      width: image.width,
      height: image.height,
      tracksAnimationVisibility: tracksAnimationVisibility,
      maximumPreviewPixelSize: maximumPreviewPixelSize,
      onOpen: {
        if let onImageOpen {
          onImageOpen(image.contentOffset)
        } else {
          imageGalleryPresentation = ImageGalleryPresentation(
            contents: contents,
            selectedContentOffset: image.contentOffset
          )
        }
      }
    )
  }

  private func openVideoPage(_ pageURL: URL) {
    guard let pageURL = SecureTiebaURL.videoPage(pageURL) else { return }
    switch BrowseContentLinkRouter.disposition(for: pageURL, mode: externalWebOpenMode) {
    case .tieba(let target):
      if case .user(let userID) = target, let onUserMention {
        onUserMention(userID)
      } else if let onTiebaLink {
        onTiebaLink(target)
      } else {
        openURL(pageURL)
      }
    case .system(let url):
      openURL(url)
    case .inAppSafari(let url):
      imageGalleryPresentation = nil
      if !openExternalWeb(url) {
        openURL(url)
      }
    case .rejected:
      break
    }
  }

  static func inlineText(
    _ contents: [BrowseContent],
    linksUserMentions: Bool = false,
    accentColor: Color = AppAccentColor.defaultValue.color
  ) -> AttributedString {
    var result = AttributedString()
    for content in contents {
      var fragment: AttributedString
      switch content {
      case .text(let text):
        fragment = AttributedString(text)
      case .mention(let name, let userID):
        fragment = AttributedString("@\(name)")
        fragment.foregroundColor = accentColor
        if linksUserMentions, let url = mentionURL(for: userID) {
          fragment.link = url
        }
      case .link(let label, let url):
        fragment = AttributedString(label.isEmpty ? url.host ?? url.absoluteString : label)
        fragment.link = url
        fragment.foregroundColor = accentColor
      case .emoticon(let name, _):
        fragment = AttributedString(
          TiebaClassicEmoticonCatalog.token(for: name) ?? name
        )
      case .unsupported(let label):
        fragment = AttributedString("[\(label)]")
      case .image, .video, .voice:
        continue
      }
      result.append(fragment)
    }
    return result
  }

  static func plainInlineText(_ contents: [BrowseContent]) -> String? {
    if contents.count == 1, case .text(let text) = contents[0] {
      return text
    }

    var result = ""
    for content in contents {
      switch content {
      case .text(let text):
        result.append(contentsOf: text)
      case .emoticon(let name, _):
        result.append(contentsOf: TiebaClassicEmoticonCatalog.token(for: name) ?? name)
      case .unsupported(let label):
        result.append(contentsOf: "[\(label)]")
      case .mention, .link, .image, .video, .voice:
        return nil
      }
    }
    return result
  }

  static func containsImage(_ contents: [BrowseContent]) -> Bool {
    contents.contains { content in
      if case .image = content { return true }
      return false
    }
  }

  static func mentionURL(for userID: Int64) -> URL? {
    TiebaLink.appURL(for: .user(userID))
  }

  static func mentionUserID(from url: URL) -> Int64? {
    guard case .user(let userID) = TiebaLink.target(from: url) else { return nil }
    return userID
  }
}

private struct DirectTextSelectionModifier: ViewModifier {
  let isEnabled: Bool

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content.textSelection(.enabled)
    } else {
      content.textSelection(.disabled)
    }
  }
}

enum BrowseContentImageLayout: Equatable, Sendable {
  case responsive
  case singleColumn
}

struct BrowseContentImageItem: Identifiable, Equatable, Sendable {
  let contentOffset: Int
  let thumbnailURL: URL
  let fullSizeURL: URL?
  let dynamicURL: URL?
  let width: Int
  let height: Int

  init(
    contentOffset: Int,
    thumbnailURL: URL,
    fullSizeURL: URL?,
    dynamicURL: URL? = nil,
    width: Int,
    height: Int
  ) {
    self.contentOffset = contentOffset
    self.thumbnailURL = thumbnailURL
    self.fullSizeURL = fullSizeURL
    self.dynamicURL = dynamicURL
    self.width = width
    self.height = height
  }

  var id: Int { contentOffset }

  var aspectRatio: CGFloat {
    BrowseImageMasonryGeometry.sanitizedAspectRatio(width: width, height: height)
  }
}

enum BrowseContentBlockID: Hashable, Sendable {
  case inline(Int)
  case imageRun(Int)
  case standalone(Int)
}

enum BrowseContentBlock: Identifiable, Equatable, Sendable {
  case inline(contentOffset: Int, contents: [BrowseContent])
  case imageRun([BrowseContentImageItem])
  case standalone(contentOffset: Int, content: BrowseContent)

  var id: BrowseContentBlockID {
    switch self {
    case .inline(let contentOffset, _):
      .inline(contentOffset)
    case .imageRun(let images):
      .imageRun(images.first?.contentOffset ?? -1)
    case .standalone(let contentOffset, _):
      .standalone(contentOffset)
    }
  }

  static func makeBlocks(_ contents: [BrowseContent]) -> [BrowseContentBlock] {
    var result = [BrowseContentBlock]()
    var inline = [BrowseContent]()
    var inlineStartOffset: Int?
    var images = [BrowseContentImageItem]()

    func flushInline() {
      guard !inline.isEmpty, let startOffset = inlineStartOffset else { return }
      result.append(.inline(contentOffset: startOffset, contents: inline))
      inline.removeAll(keepingCapacity: true)
      inlineStartOffset = nil
    }

    func flushImages() {
      guard !images.isEmpty else { return }
      result.append(.imageRun(images))
      images.removeAll(keepingCapacity: true)
    }

    for (offset, content) in contents.enumerated() {
      switch content {
      case .text, .mention, .link, .emoticon, .unsupported:
        flushImages()
        if inline.isEmpty {
          inlineStartOffset = offset
        }
        inline.append(content)
      case .image(let thumbnail, let fullSize, _, let dynamic, let width, let height):
        flushInline()
        images.append(
          BrowseContentImageItem(
            contentOffset: offset,
            thumbnailURL: thumbnail,
            fullSizeURL: fullSize,
            dynamicURL: dynamic,
            width: width,
            height: height
          )
        )
      case .video, .voice:
        flushInline()
        flushImages()
        result.append(.standalone(contentOffset: offset, content: content))
      }
    }

    flushInline()
    flushImages()
    return result
  }
}

struct BrowseImageMasonryPlan: Equatable {
  let columnCount: Int
  let assignments: [Int]
  let frames: [CGRect]
  let size: CGSize
}

enum BrowseImageMasonryGeometry {
  static let mediumWidth: CGFloat = 600
  static let expandedWidth: CGFloat = 840
  static let maximumSingleColumnWidth: CGFloat = 560
  static let fallbackAspectRatio: CGFloat = 4 / 3

  static func sanitizedAspectRatio(width: Int, height: Int) -> CGFloat {
    guard width > 0, height > 0 else { return fallbackAspectRatio }
    return sanitizedAspectRatio(CGFloat(width) / CGFloat(height))
  }

  static func sanitizedAspectRatio(_ aspectRatio: CGFloat) -> CGFloat {
    guard aspectRatio.isFinite, aspectRatio > 0 else { return fallbackAspectRatio }
    return min(max(aspectRatio, 0.5), 2)
  }

  static func sanitizedSpacing(_ spacing: CGFloat) -> CGFloat {
    guard spacing.isFinite, spacing > 0 else { return 0 }
    return spacing
  }

  static func columnCount(
    availableWidth: CGFloat,
    itemCount: Int,
    imageLayout: BrowseContentImageLayout,
    forcesSingleColumn: Bool = false
  ) -> Int {
    guard itemCount > 0 else { return 0 }
    if forcesSingleColumn {
      return 1
    }

    let requestedColumnCount: Int
    switch imageLayout {
    case .singleColumn:
      requestedColumnCount = 1
    case .responsive:
      guard availableWidth.isFinite, availableWidth >= 0 else {
        return 1
      }
      if availableWidth < mediumWidth {
        requestedColumnCount = 1
      } else if availableWidth < expandedWidth {
        requestedColumnCount = 2
      } else {
        requestedColumnCount = 3
      }
    }
    return min(requestedColumnCount, itemCount)
  }

  static func resolvedWidth(
    proposedWidth: CGFloat?,
    idealWidths: [CGFloat] = []
  ) -> CGFloat {
    if let proposedWidth, proposedWidth.isFinite, proposedWidth >= 0 {
      return proposedWidth
    }
    let idealWidth = idealWidths
      .filter { $0.isFinite && $0 > 0 }
      .max() ?? maximumSingleColumnWidth
    return min(idealWidth, maximumSingleColumnWidth)
  }

  static func columnAssignments(
    aspectRatios: [CGFloat],
    columnCount: Int
  ) -> [Int] {
    guard !aspectRatios.isEmpty else { return [] }
    let safeColumnCount = min(max(columnCount, 1), aspectRatios.count)
    var columnHeights = Array(repeating: CGFloat.zero, count: safeColumnCount)
    var assignments = [Int]()
    assignments.reserveCapacity(aspectRatios.count)

    for aspectRatio in aspectRatios {
      var shortestColumn = 0
      for column in 1..<safeColumnCount
      where columnHeights[column] < columnHeights[shortestColumn] {
        shortestColumn = column
      }
      assignments.append(shortestColumn)
      columnHeights[shortestColumn] += 1 / sanitizedAspectRatio(aspectRatio)
    }
    return assignments
  }

  static func plan(
    availableWidth: CGFloat,
    aspectRatios: [CGFloat],
    imageLayout: BrowseContentImageLayout,
    forcesSingleColumn: Bool = false,
    horizontalSpacing: CGFloat = 8,
    verticalSpacing: CGFloat = 8
  ) -> BrowseImageMasonryPlan {
    let safeWidth = availableWidth.isFinite ? max(availableWidth, 0) : 0
    let columnCount = columnCount(
      availableWidth: availableWidth,
      itemCount: aspectRatios.count,
      imageLayout: imageLayout,
      forcesSingleColumn: forcesSingleColumn
    )
    guard columnCount > 0 else {
      return BrowseImageMasonryPlan(
        columnCount: 0,
        assignments: [],
        frames: [],
        size: CGSize(width: safeWidth, height: 0)
      )
    }

    let horizontalSpacing = sanitizedSpacing(horizontalSpacing)
    let verticalSpacing = sanitizedSpacing(verticalSpacing)
    let spacingWidth = CGFloat(columnCount - 1) * horizontalSpacing
    let availableColumnWidth = max((safeWidth - spacingWidth) / CGFloat(columnCount), 0)
    let columnWidth = columnCount == 1
      ? min(availableColumnWidth, maximumSingleColumnWidth)
      : availableColumnWidth
    let sanitizedAspectRatios = aspectRatios.map(sanitizedAspectRatio)
    let assignments = columnAssignments(
      aspectRatios: sanitizedAspectRatios,
      columnCount: columnCount
    )
    var columnBottoms = Array(repeating: CGFloat.zero, count: columnCount)
    var columnItemCounts = Array(repeating: 0, count: columnCount)
    var frames = [CGRect]()
    frames.reserveCapacity(aspectRatios.count)

    for (aspectRatio, column) in zip(sanitizedAspectRatios, assignments) {
      let y = columnBottoms[column]
        + (columnItemCounts[column] == 0 ? 0 : verticalSpacing)
      let height = columnWidth / aspectRatio
      frames.append(
        CGRect(
          x: CGFloat(column) * (columnWidth + horizontalSpacing),
          y: y,
          width: columnWidth,
          height: height
        )
      )
      columnBottoms[column] = y + height
      columnItemCounts[column] += 1
    }

    return BrowseImageMasonryPlan(
      columnCount: columnCount,
      assignments: assignments,
      frames: frames,
      size: CGSize(width: safeWidth, height: columnBottoms.max() ?? 0)
    )
  }
}

private struct BrowseImageAspectRatioLayoutValueKey: LayoutValueKey {
  static let defaultValue = BrowseImageMasonryGeometry.fallbackAspectRatio
}

private struct BrowseImageMasonryLayout: Layout {
  let imageLayout: BrowseContentImageLayout
  let forcesSingleColumn: Bool
  let horizontalSpacing: CGFloat
  let verticalSpacing: CGFloat

  init(
    imageLayout: BrowseContentImageLayout,
    forcesSingleColumn: Bool,
    horizontalSpacing: CGFloat = 8,
    verticalSpacing: CGFloat = 8
  ) {
    self.imageLayout = imageLayout
    self.forcesSingleColumn = forcesSingleColumn
    self.horizontalSpacing = horizontalSpacing
    self.verticalSpacing = verticalSpacing
  }

  func sizeThatFits(
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) -> CGSize {
    plan(width: resolvedWidth(proposal: proposal, subviews: subviews), subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect,
    proposal: ProposedViewSize,
    subviews: Subviews,
    cache: inout ()
  ) {
    let plan = plan(width: bounds.width, subviews: subviews)
    for (subview, frame) in zip(subviews, plan.frames) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: frame.width, height: frame.height)
      )
    }
  }

  private func plan(width: CGFloat, subviews: Subviews) -> BrowseImageMasonryPlan {
    BrowseImageMasonryGeometry.plan(
      availableWidth: width,
      aspectRatios: subviews.map { $0[BrowseImageAspectRatioLayoutValueKey.self] },
      imageLayout: imageLayout,
      forcesSingleColumn: forcesSingleColumn,
      horizontalSpacing: horizontalSpacing,
      verticalSpacing: verticalSpacing
    )
  }

  private func resolvedWidth(proposal: ProposedViewSize, subviews: Subviews) -> CGFloat {
    BrowseImageMasonryGeometry.resolvedWidth(
      proposedWidth: proposal.width,
      idealWidths: subviews.map { $0.sizeThatFits(.unspecified).width }
    )
  }
}

private struct BrowseImageView: View {
  let thumbnailURL: URL
  let width: Int
  let height: Int
  let tracksAnimationVisibility: Bool
  let maximumPreviewPixelSize: Int
  let onOpen: () -> Void

  @Environment(\.contentMediaLoadBehavior) private var contentMediaLoadBehavior

  private var aspectRatio: CGFloat {
    BrowseImageMasonryGeometry.sanitizedAspectRatio(width: width, height: height)
  }

  var body: some View {
    BrowseImagePreviewFrame(aspectRatio: aspectRatio) {
      ContentRemoteImage(
        url: thumbnailURL,
        maxPixelSize: maximumPreviewPixelSize,
        loadAccessibilityLabel: "加载正文图片"
      ) { phase in
        switch phase {
        case .success(let asset, _):
          Button {
            onOpen()
          } label: {
            RemoteImageAssetView(
              asset: asset,
              contentMode: .fill,
              tracksScrollVisibility: tracksAnimationVisibility
            )
              .contentThumbnailDimming()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("查看大图")
        case .empty:
          if contentMediaLoadBehavior != .userInitiated {
            Button(action: onOpen) {
              imageLoadingPlaceholder
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看大图")
          } else {
            imageLoadingPlaceholder
          }
        case .loadRequired:
          imageActionPlaceholder(title: "加载图片", systemImage: "arrow.down.circle")
        case .failure:
          if contentMediaLoadBehavior != .userInitiated {
            Button(action: onOpen) {
              imageActionPlaceholder(
                title: "图片加载失败",
                systemImage: "photo.badge.exclamationmark"
              )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看大图")
          } else if canRetryImageLoad {
            imageActionPlaceholder(
              title: "重新加载",
              systemImage: "arrow.clockwise.circle"
            )
          } else {
            imageActionPlaceholder(
              title: "图片加载失败",
              systemImage: "photo.badge.exclamationmark"
            )
          }
        }
      }
      .buttonStyle(.plain)
    }
  }

  private var imageLoadingPlaceholder: some View {
    ZStack {
      Color(uiColor: .secondarySystemFill)
      ProgressView()
    }
    .accessibilityHidden(true)
  }

  private func imageActionPlaceholder(title: String, systemImage: String) -> some View {
    Label(title, systemImage: systemImage)
      .font(.callout.weight(.medium))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(uiColor: .secondarySystemFill))
      .contentShape(Rectangle())
  }

  private var canRetryImageLoad: Bool {
    contentMediaLoadBehavior == .userInitiated
      && RemoteImageURLPolicy.allows(thumbnailURL)
  }
}

struct BrowseImagePreviewFrame<Content: View>: View {
  let aspectRatio: CGFloat
  private let content: Content

  init(aspectRatio: CGFloat, @ViewBuilder content: () -> Content) {
    self.aspectRatio = BrowseImageMasonryGeometry.sanitizedAspectRatio(aspectRatio)
    self.content = content()
  }

  var body: some View {
    Color.clear
      .aspectRatio(aspectRatio, contentMode: .fit)
      .frame(maxWidth: .infinity)
      .overlay {
        GeometryReader { proxy in
          content
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
      }
      .contentShape(Rectangle())
      .clipped()
  }
}

enum BrowseVideoPrimaryAction: Equatable, Sendable {
  case play(URL)
  case openPage(URL)
  case unavailable
}

enum BrowseVideoPresentationPolicy {
  static func playbackURL(for video: BrowseVideoContent) -> URL? {
    guard let url = video.url, VideoPlaybackURLPolicy.allows(url) else { return nil }
    return url
  }

  static func pageURL(for video: BrowseVideoContent) -> URL? {
    SecureTiebaURL.videoPage(video.pageURL)
  }

  static func showsFailurePageAction(
    for video: BrowseVideoContent,
    state: VideoPlaybackState
  ) -> Bool {
    guard case .failed = state else { return false }
    return playbackURL(for: video) != nil && pageURL(for: video) != nil
  }

  static func primaryAction(for video: BrowseVideoContent) -> BrowseVideoPrimaryAction {
    if let url = playbackURL(for: video) {
      return .play(url)
    }
    if let pageURL = pageURL(for: video) {
      return .openPage(pageURL)
    }
    return .unavailable
  }
}

private struct BrowseVideoView: View {
  let video: BrowseVideoContent
  let tracksAnimationVisibility: Bool
  let maximumPreviewPixelSize: Int
  let openPage: (URL) -> Void

  @State private var ownerID = UUID()
  @Environment(\.contentMediaLoadBehavior) private var contentMediaLoadBehavior
  @EnvironmentObject private var controller: VideoPlaybackController

  private var aspectRatio: CGFloat {
    guard video.width > 0, video.height > 0 else { return 16 / 9 }
    return min(max(CGFloat(video.width) / CGFloat(video.height), 0.5), 2)
  }

  var body: some View {
    Group {
      if
        let playbackURL,
        let sessionID = activeSessionID,
        let player = controller.player(for: ownerID, url: playbackURL)
      {
        InlineVideoPlayer(
          player: player,
          ownerID: ownerID,
          sessionID: sessionID,
          controller: controller
        )
      } else {
        ZStack {
          if let coverURL = video.cover {
            ContentRemoteImage(
              url: coverURL,
              maxPixelSize: maximumPreviewPixelSize,
              loadAccessibilityLabel: "加载视频封面"
            ) { phase in
              switch phase {
              case .success(let asset, _):
                RemoteImageAssetView(
                  asset: asset,
                  contentMode: .fill,
                  tracksScrollVisibility: tracksAnimationVisibility
                )
                  .accessibilityHidden(true)
              case .empty:
                ZStack {
                  Color.black.opacity(0.88)
                  ProgressView()
                    .tint(.white)
                }
                .accessibilityHidden(true)
              case .loadRequired:
                videoCoverActionPlaceholder(
                  title: "加载封面",
                  systemImage: "arrow.down.circle"
                )
              case .failure:
                if canRetryCoverLoad(coverURL) {
                  videoCoverActionPlaceholder(
                    title: "重新加载封面",
                    systemImage: "arrow.clockwise.circle"
                  )
                } else {
                  videoCoverActionPlaceholder(
                    title: "封面加载失败",
                    systemImage: "photo.badge.exclamationmark"
                  )
                }
              }
            }
            .buttonStyle(.plain)
          } else {
            Color.black.opacity(0.88)
              .accessibilityHidden(true)
          }

          switch BrowseVideoPresentationPolicy.primaryAction(for: video) {
          case .play(let url):
            Button {
              controller.start(ownerID: ownerID, url: url)
            } label: {
              Image(systemName: "play.circle.fill")
                .font(.system(size: 48))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
            }
            .accessibilityLabel("播放视频")
            .accessibilityHint(
              Text(failureMessage.map { "\($0) 再次尝试播放。" } ?? "开始播放")
            )
          case .openPage(let pageURL):
            Button {
              openPage(pageURL)
            } label: {
              Label("打开视频", systemImage: "safari")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityHint("在网页中打开")
          case .unavailable:
            Label("视频不可用", systemImage: "video.slash")
              .font(.callout.weight(.medium))
              .foregroundStyle(.white)
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
              .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
          }

        }
        .overlay(alignment: .topLeading) {
          if let failureMessage {
            Text(failureMessage)
              .font(.caption.weight(.medium))
              .foregroundStyle(.white)
              .lineLimit(2)
              .padding(.horizontal, 8)
              .padding(.vertical, 6)
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
        .overlay(alignment: .bottomTrailing) {
          if showsFailurePageAction, let pageURL {
            Button {
              openPage(pageURL)
            } label: {
              Label("网页打开", systemImage: "safari")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityHint("改用网页打开")
            .padding(8)
          }
        }
      }
    }
    .aspectRatio(aspectRatio, contentMode: .fit)
    .frame(maxWidth: 560)
    .clipped()
    .onChange(of: playbackURL) { controller.sourceDidChange(ownerID: ownerID, to: $0) }
    .onDisappear { controller.ownerDidDisappear(ownerID) }
  }

  private var playbackURL: URL? {
    BrowseVideoPresentationPolicy.playbackURL(for: video)
  }

  private var pageURL: URL? {
    BrowseVideoPresentationPolicy.pageURL(for: video)
  }

  private var showsFailurePageAction: Bool {
    let state: VideoPlaybackState
    if
      controller.snapshot.ownerID == ownerID,
      controller.snapshot.sourceURL == playbackURL
    {
      state = controller.snapshot.state
    } else {
      state = .idle
    }
    return BrowseVideoPresentationPolicy.showsFailurePageAction(for: video, state: state)
  }

  private var activeSessionID: UUID? {
    guard
      controller.snapshot.ownerID == ownerID,
      controller.snapshot.sourceURL == playbackURL
    else { return nil }
    return controller.snapshot.sessionID
  }

  private var failureMessage: String? {
    guard
      controller.snapshot.ownerID == ownerID,
      controller.snapshot.sourceURL == playbackURL,
      case .failed(let message) = controller.snapshot.state
    else { return nil }
    return message
  }

  private func videoCoverActionPlaceholder(
    title: String,
    systemImage: String
  ) -> some View {
    ZStack(alignment: .bottomTrailing) {
      Color.black.opacity(0.88)
      Label(title, systemImage: systemImage)
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
    .contentShape(Rectangle())
  }

  private func canRetryCoverLoad(_ coverURL: URL) -> Bool {
    contentMediaLoadBehavior == .userInitiated && RemoteImageURLPolicy.allows(coverURL)
  }
}
