import AVKit
import SwiftUI

struct BrowseContentView: View {
  let contents: [BrowseContent]
  let imageLayout: BrowseContentImageLayout
  let onImageOpen: ((Int) -> Void)?
  let onUserMention: ((Int64) -> Void)?
  let onTiebaLink: ((TiebaLinkTarget) -> Void)?

  @Environment(\.externalWebOpenMode) private var externalWebOpenMode
  @Environment(\.openExternalWeb) private var openExternalWeb
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @State private var imageGalleryPresentation: ImageGalleryPresentation?

  init(
    contents: [BrowseContent],
    imageLayout: BrowseContentImageLayout = .responsive,
    onImageOpen: ((Int) -> Void)? = nil,
    onUserMention: ((Int64) -> Void)? = nil,
    onTiebaLink: ((TiebaLinkTarget) -> Void)? = nil
  ) {
    self.contents = contents
    self.imageLayout = imageLayout
    self.onImageOpen = onImageOpen
    self.onUserMention = onUserMention
    self.onTiebaLink = onTiebaLink
  }

  private var blocks: [BrowseContentBlock] {
    BrowseContentBlock.makeBlocks(contents)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ForEach(blocks) { block in
        switch block {
        case .inline(_, let contents):
          Text(
            Self.inlineText(
              contents,
              linksUserMentions: onUserMention != nil || onTiebaLink != nil
            )
          )
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, contentOpenURLAction)
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
        case .standalone(let contentOffset, let content):
          standalone(content, contentOffset: contentOffset)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .fullScreenCover(item: $imageGalleryPresentation) { presentation in
      ImageViewer(
        items: presentation.items,
        initialIndex: presentation.initialIndex
      )
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
    case .image(let thumbnail, _, let width, let height):
      browseImage(
        BrowseContentImageItem(
          contentOffset: contentOffset,
          thumbnailURL: thumbnail,
          width: width,
          height: height
        )
      )
    case .video(let url, let cover, let width, let height):
      BrowseVideoView(url: url, coverURL: cover, width: width, height: height)
    case .voice(let url, let duration):
      VoicePlaybackButton(url: url, duration: duration)
    case .text, .mention, .link, .emoticon, .unsupported:
      EmptyView()
    }
  }

  private func browseImage(_ image: BrowseContentImageItem) -> some View {
    BrowseImageView(
      thumbnailURL: image.thumbnailURL,
      width: image.width,
      height: image.height,
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

  static func inlineText(
    _ contents: [BrowseContent],
    linksUserMentions: Bool = false
  ) -> AttributedString {
    var result = AttributedString()
    for content in contents {
      var fragment: AttributedString
      switch content {
      case .text(let text):
        fragment = AttributedString(text)
      case .mention(let name, let userID):
        fragment = AttributedString("@\(name)")
        fragment.foregroundColor = .accentColor
        if linksUserMentions, let url = mentionURL(for: userID) {
          fragment.link = url
        }
      case .link(let label, let url):
        fragment = AttributedString(label.isEmpty ? url.host ?? url.absoluteString : label)
        fragment.link = url
        fragment.foregroundColor = .accentColor
      case .emoticon(let name, _):
        fragment = AttributedString(name)
      case .unsupported(let label):
        fragment = AttributedString("[\(label)]")
      case .image, .video, .voice:
        continue
      }
      result.append(fragment)
    }
    return result
  }

  static func mentionURL(for userID: Int64) -> URL? {
    TiebaLink.appURL(for: .user(userID))
  }

  static func mentionUserID(from url: URL) -> Int64? {
    guard case .user(let userID) = TiebaLink.target(from: url) else { return nil }
    return userID
  }
}

enum BrowseContentImageLayout: Equatable, Sendable {
  case responsive
  case singleColumn
}

struct BrowseContentImageItem: Identifiable, Equatable, Sendable {
  let contentOffset: Int
  let thumbnailURL: URL
  let width: Int
  let height: Int

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
      case .image(let thumbnail, _, let width, let height):
        flushInline()
        images.append(
          BrowseContentImageItem(
            contentOffset: offset,
            thumbnailURL: thumbnail,
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
  let onOpen: () -> Void

  @Environment(\.contentMediaLoadBehavior) private var contentMediaLoadBehavior

  private var aspectRatio: CGFloat {
    BrowseImageMasonryGeometry.sanitizedAspectRatio(width: width, height: height)
  }

  var body: some View {
    ContentRemoteImage(
      url: thumbnailURL,
      maxPixelSize: 1_600,
      loadAccessibilityLabel: "加载正文图片"
    ) { phase in
      switch phase {
      case .success(let image, _):
        Button {
          onOpen()
        } label: {
          image
            .resizable()
            .scaledToFill()
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
    .aspectRatio(aspectRatio, contentMode: .fit)
    .frame(maxWidth: .infinity)
    .clipped()
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

private struct BrowseVideoView: View {
  let url: URL?
  let coverURL: URL?
  let width: Int
  let height: Int

  @State private var player: AVPlayer?
  @Environment(\.contentMediaLoadBehavior) private var contentMediaLoadBehavior

  private var aspectRatio: CGFloat {
    guard width > 0, height > 0 else { return 16 / 9 }
    return min(max(CGFloat(width) / CGFloat(height), 0.5), 2)
  }

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
      } else {
        ZStack {
          if let coverURL {
            ContentRemoteImage(
              url: coverURL,
              maxPixelSize: 1_600,
              loadAccessibilityLabel: "加载视频封面"
            ) { phase in
              switch phase {
              case .success(let image, _):
                image
                  .resizable()
                  .scaledToFill()
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
          if let url {
            Button {
              let newPlayer = AVPlayer(url: url)
              player = newPlayer
              newPlayer.play()
            } label: {
              Image(systemName: "play.circle.fill")
                .font(.system(size: 48))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
            }
            .accessibilityLabel("播放视频")
          }
        }
      }
    }
    .aspectRatio(aspectRatio, contentMode: .fit)
    .frame(maxWidth: 560)
    .clipped()
    .onDisappear {
      player?.pause()
    }
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
