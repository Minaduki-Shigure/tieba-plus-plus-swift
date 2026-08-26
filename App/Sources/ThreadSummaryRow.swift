import SwiftUI

struct ThreadSummaryImagePreview: Identifiable, Equatable, Sendable {
  let contentOffset: Int
  let previewURL: URL

  var id: Int { contentOffset }
}

struct ThreadSummaryVideoPreview: Identifiable, Hashable, Sendable {
  let contentOffset: Int
  let video: BrowseVideoContent

  var id: Int { contentOffset }
}

enum ThreadSummaryMedia: Equatable, Sendable {
  case video(ThreadSummaryVideoPreview)
  case images([ThreadSummaryImagePreview], totalCount: Int)
}

enum ThreadSummaryMediaPresentation: Equatable, Sendable {
  case expanded(ThreadSummaryMedia)
  case collapsed(ThreadSummaryMedia)
}

enum ThreadSummaryMediaInteraction: Equatable, Sendable {
  case gallery
  case openThread
  case disabled
}

enum ThreadSummaryMediaInteractionPolicy {
  static func permitsOpening(
    interaction: ThreadSummaryMediaInteraction,
    environmentActionAvailable: Bool
  ) -> Bool {
    interaction == .gallery && environmentActionAvailable
  }
}

enum ThreadSummaryPresentation {
  static func media(
    for thread: BrowseThread,
    quality: ContentImagePreviewQuality = .standard
  ) -> ThreadSummaryMedia? {
    guard !thread.isPinned else { return nil }
    var images: [ThreadSummaryImagePreview] = []
    images.reserveCapacity(3)
    var totalImageCount = 0

    for (contentOffset, content) in thread.contents.enumerated() {
      switch content {
      case .video(let video):
        guard isPresentableVideo(video) else { continue }
        return .video(
          ThreadSummaryVideoPreview(contentOffset: contentOffset, video: video)
        )
      case .image(let thumbnail, let fullSize, _, let dynamic, _, _):
        totalImageCount += 1
        guard images.count < 3 else { continue }
        images.append(
          ThreadSummaryImagePreview(
            contentOffset: contentOffset,
            previewURL: BrowseContentImageSourceResolver.previewURL(
              thumbnail: thumbnail,
              fullSize: fullSize,
              dynamic: dynamic,
              quality: quality
            )
          )
        )
      default:
        continue
      }
    }

    guard totalImageCount > 0 else { return nil }
    return .images(images, totalCount: totalImageCount)
  }

  private static func isPresentableVideo(_ video: BrowseVideoContent) -> Bool {
    BrowseVideoPresentationPolicy.playbackURL(for: video) != nil
      || BrowseVideoPresentationPolicy.pageURL(for: video) != nil
      || video.cover.map(RemoteImageURLPolicy.allows) == true
  }

  static func mediaPresentation(
    for thread: BrowseThread,
    hidesMedia: Bool,
    quality: ContentImagePreviewQuality = .standard
  ) -> ThreadSummaryMediaPresentation? {
    guard let media = media(for: thread, quality: quality) else { return nil }
    guard hidesMedia else { return .expanded(media) }

    return .collapsed(media)
  }

  static func authorAvatarURL(for thread: BrowseThread, showsAuthor: Bool) -> URL? {
    let hasAuthorIdentity =
      !thread.authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !thread.authorUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard
      showsAuthor,
      !thread.isPinned,
      thread.localVisibility == .visible,
      hasAuthorIdentity
    else { return nil }
    return thread.authorAvatarURL
  }
}

struct ThreadSummaryNavigationRequest: Equatable, Sendable {
  let thread: BrowseThread
  let initialFocus: ThreadInitialFocus?

  var linkRoute: TiebaThreadRoute? {
    guard initialFocus == .firstReply, thread.id > 0 else { return nil }
    return TiebaThreadRoute(threadID: thread.id)
  }

  var destinationID: String {
    let focus = initialFocus == .firstReply ? "replies" : "top"
    return "thread-summary:\(thread.id):\(focus)"
  }
}

enum ThreadSummaryNavigationPolicy {
  static func primaryRequest(for thread: BrowseThread) -> ThreadSummaryNavigationRequest? {
    guard thread.id > 0, thread.localVisibility == .visible else { return nil }
    return ThreadSummaryNavigationRequest(thread: thread, initialFocus: nil)
  }

  static func repliesRequest(for thread: BrowseThread) -> ThreadSummaryNavigationRequest? {
    guard thread.id > 0, !thread.isPinned, thread.localVisibility == .visible else { return nil }
    return ThreadSummaryNavigationRequest(thread: thread, initialFocus: .firstReply)
  }

  static func repliesAccessibilityLabel(replyCount: Int) -> String {
    let count = max(replyCount, 0)
    if count == 0 {
      return "打开回复区，当前 0 条回复"
    }
    return "查看 \(count.formatted()) 条回复，打开回复区"
  }
}

enum ThreadSummaryContextNavigationPolicy {
  static func forumURL(for thread: BrowseThread, showsForum: Bool) -> URL? {
    guard
      showsForum,
      !thread.isPinned,
      thread.localVisibility == .visible
    else { return nil }
    return TiebaLink.appURL(for: .forum(thread.forumName))
  }

  static func authorURL(for thread: BrowseThread, showsAuthor: Bool) -> URL? {
    let hasAuthorIdentity =
      !thread.authorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !thread.authorUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    guard
      showsAuthor,
      !thread.isPinned,
      thread.localVisibility == .visible,
      hasAuthorIdentity
    else { return nil }
    return TiebaLink.appURL(for: .user(thread.authorID))
  }
}

enum ThreadSummaryContextLayoutMode: Equatable, Sendable {
  case adaptive
  case compact
}

enum ThreadSummaryRowInteractionMode: Equatable, Sendable {
  case contextual
  case threadFocused
}

struct ThreadSummaryTrailingMetricAction: Equatable, Sendable {
  let systemImage: String
  let accessibilityLabel: String
  let accessibilityIdentifier: String
  let isEnabled: Bool
}

enum ThreadSummaryContextLayoutStrategy: Equatable, Sendable {
  case widthAdaptive
  case singleLine
  case stacked
}

enum ThreadSummaryContextLayoutPolicy {
  static func strategy(
    mode: ThreadSummaryContextLayoutMode,
    dynamicTypeSize: DynamicTypeSize
  ) -> ThreadSummaryContextLayoutStrategy {
    guard mode == .compact else { return .widthAdaptive }
    return AppDynamicTypeLayout.prefersExpandedControls(for: dynamicTypeSize)
      ? .stacked
      : .singleLine
  }
}

struct ThreadSummaryRow<Header: View>: View {
  let thread: BrowseThread
  let showsForum: Bool
  let showsAuthor: Bool
  let searchQuery: String
  let contextLayout: ThreadSummaryContextLayoutMode
  let mediaInteraction: ThreadSummaryMediaInteraction
  let interactionMode: ThreadSummaryRowInteractionMode
  let trailingMetricAction: ThreadSummaryTrailingMetricAction?
  private let header: () -> Header
  private let onTrailingMetricAction: () -> Void
  private let onNavigate: (ThreadSummaryNavigationRequest) -> Void

  @Environment(\.contentImagePreviewQuality) private var contentImagePreviewQuality
  @Environment(\.appAccentColor) private var appAccentColor
  @Environment(\.hidesThreadListMedia) private var hidesThreadListMedia
  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames
  @Environment(\.openThreadSummaryImage) private var openThreadSummaryImage
  @Environment(\.externalWebOpenMode) private var externalWebOpenMode
  @Environment(\.openExternalWeb) private var openExternalWeb
  @Environment(\.openURL) private var openURL
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize

  init(
    thread: BrowseThread,
    showsForum: Bool = false,
    showsAuthor: Bool = true,
    searchQuery: String = "",
    contextLayout: ThreadSummaryContextLayoutMode = .adaptive,
    mediaInteraction: ThreadSummaryMediaInteraction = .openThread,
    interactionMode: ThreadSummaryRowInteractionMode = .contextual,
    trailingMetricAction: ThreadSummaryTrailingMetricAction? = nil,
    onTrailingMetricAction: @escaping () -> Void = {},
    onNavigate: @escaping (ThreadSummaryNavigationRequest) -> Void
  ) where Header == EmptyView {
    self.init(
      thread: thread,
      showsForum: showsForum,
      showsAuthor: showsAuthor,
      searchQuery: searchQuery,
      contextLayout: contextLayout,
      mediaInteraction: mediaInteraction,
      interactionMode: interactionMode,
      trailingMetricAction: trailingMetricAction,
      onTrailingMetricAction: onTrailingMetricAction,
      header: { EmptyView() },
      onNavigate: onNavigate
    )
  }

  init(
    thread: BrowseThread,
    showsForum: Bool = false,
    showsAuthor: Bool = true,
    searchQuery: String = "",
    contextLayout: ThreadSummaryContextLayoutMode = .adaptive,
    mediaInteraction: ThreadSummaryMediaInteraction = .openThread,
    interactionMode: ThreadSummaryRowInteractionMode = .contextual,
    trailingMetricAction: ThreadSummaryTrailingMetricAction? = nil,
    onTrailingMetricAction: @escaping () -> Void = {},
    @ViewBuilder header: @escaping () -> Header,
    onNavigate: @escaping (ThreadSummaryNavigationRequest) -> Void
  ) {
    self.thread = thread
    self.showsForum = showsForum
    self.showsAuthor = showsAuthor
    self.searchQuery = searchQuery
    self.contextLayout = contextLayout
    self.mediaInteraction = mediaInteraction
    self.interactionMode = interactionMode
    self.trailingMetricAction = trailingMetricAction
    self.header = header
    self.onTrailingMetricAction = onTrailingMetricAction
    self.onNavigate = onNavigate
  }

  var body: some View {
    if thread.isPinned {
      primaryNavigation {
        VStack(alignment: .leading, spacing: 6) {
          header()
          pinnedRow
        }
      }
    } else {
      regularRow
    }
  }

  private var pinnedRow: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Label("置顶", systemImage: "pin.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tint)
        .fixedSize()
      SearchHighlightedText(displayTitle, query: searchQuery)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
  }

  @ViewBuilder
  private var regularRow: some View {
    switch interactionMode {
    case .contextual:
      contextualRegularRow
    case .threadFocused:
      threadFocusedRegularRow
    }
  }

  private var contextualRegularRow: some View {
    VStack(alignment: .leading, spacing: 8) {
      primaryNavigation {
        titleSection
      }

      contextLine(allowsNavigation: true)
      contextualMediaSurface
      HStack(alignment: .center, spacing: 0) {
        metricLine(allowsReplyNavigation: true)
        trailingMetricActionButton
      }
    }
    .padding(.vertical, 4)
  }

  private var threadFocusedRegularRow: some View {
    VStack(alignment: .leading, spacing: 0) {
      primaryNavigation {
        titleSection
      }

      if hasContextLine {
        threadNavigationSurface(accessibilityLabel: "打开主题 \(displayTitle)") {
          contextLine(allowsNavigation: false)
            .frame(minHeight: 44, alignment: .leading)
            .padding(.vertical, 4)
        }
      }

      if mediaPresentation != nil {
        threadNavigationSurface(accessibilityLabel: "打开主题 \(displayTitle)") {
          passiveMediaPreview
            .padding(.vertical, 4)
        }
      }

      HStack(alignment: .center, spacing: 0) {
        threadNavigationSurface(accessibilityLabel: "打开主题 \(displayTitle)") {
          metricLine(allowsReplyNavigation: false)
            .frame(minHeight: 44, alignment: .leading)
            .padding(.vertical, 4)
        }
        trailingMetricActionButton
          .padding(.vertical, 4)
      }
    }
    .padding(.vertical, 4)
  }

  private var titleSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      header()

      if !badges.isEmpty {
        badgeLine
      }

      SearchHighlightedText(displayTitle, query: searchQuery)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)

      if shouldShowExcerpt {
        SearchHighlightedText(thread.excerpt, query: searchQuery)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func primaryNavigation<Label: View>(
    @ViewBuilder label: () -> Label
  ) -> some View {
    Group {
      if let request = ThreadSummaryNavigationPolicy.primaryRequest(for: thread) {
        Button {
          onNavigate(request)
        } label: {
          primaryNavigationLabel(label: label)
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开主题")
      } else {
        label()
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
    }
  }

  private func primaryNavigationLabel<Label: View>(
    @ViewBuilder label: () -> Label
  ) -> some View {
    HStack(alignment: .center, spacing: 8) {
      label()
        .frame(maxWidth: .infinity, alignment: .leading)
      Image(systemName: "chevron.right")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.tertiary)
        .accessibilityHidden(true)
    }
    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    .contentShape(Rectangle())
  }

  private func threadNavigationSurface<Label: View>(
    accessibilityLabel: String,
    @ViewBuilder label: () -> Label
  ) -> some View {
    Group {
      if let request = ThreadSummaryNavigationPolicy.primaryRequest(for: thread) {
        Button {
          onNavigate(request)
        } label: {
          label()
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("打开主题")
      } else {
        label()
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
      }
    }
  }

  private var displayTitle: String {
    if !thread.title.isEmpty {
      return thread.title
    }
    if !thread.excerpt.isEmpty {
      return thread.excerpt
    }
    return "帖子 \(thread.id)"
  }

  private var shouldShowExcerpt: Bool {
    !thread.excerpt.isEmpty && thread.excerpt != thread.title
  }

  private var mediaPresentation: ThreadSummaryMediaPresentation? {
    ThreadSummaryPresentation.mediaPresentation(
      for: thread,
      hidesMedia: hidesThreadListMedia,
      quality: contentImagePreviewQuality
    )
  }

  @ViewBuilder
  private var mediaPreview: some View {
    switch mediaPresentation {
    case .some(.collapsed(let media)):
      collapsedMediaPreview(media)
    case .some(.expanded(let media)):
      expandedMediaPreview(media)
    case .none:
      EmptyView()
    }
  }

  @ViewBuilder
  private var contextualMediaSurface: some View {
    switch mediaInteraction {
    case .gallery:
      mediaPreview
    case .openThread:
      if mediaPresentation != nil {
        threadNavigationSurface(accessibilityLabel: "打开主题 \(displayTitle)") {
          passiveMediaPreview
        }
      }
    case .disabled:
      passiveMediaPreview
    }
  }

  private var passiveMediaPreview: some View {
    mediaPreview
      .allowsHitTesting(false)
      .accessibilityHidden(true)
  }

  @ViewBuilder
  private func collapsedMediaPreview(_ media: ThreadSummaryMedia) -> some View {
    switch media {
    case .video:
      CompactListMediaView(summary: .video)
    case .images(let images, let totalCount):
      let summary = ThreadListMediaSummary.images(count: totalCount)
      if let firstImage = images.first, canOpenImages {
        Button {
          openImage(firstImage)
        } label: {
          CompactListMediaView(summary: summary, permitsHitTesting: true)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("打开 \(max(totalCount, 0).formatted()) 张图片")
        .help("打开图片")
      } else {
        CompactListMediaView(summary: summary)
      }
    }
  }

  @ViewBuilder
  private func expandedMediaPreview(_ media: ThreadSummaryMedia) -> some View {
    switch media {
    case .video(let preview):
      expandedVideoPreview(preview)
    case .images(let images, let totalCount):
      if images.count == 1, let image = images.first {
        ThreadPreviewImage(
          url: image.previewURL,
          loadAccessibilityLabel: "加载帖子图片",
          successAccessibilityLabel: "图片预览",
          openAccessibilityLabel: "打开图片，共 \(totalCount) 张",
          onOpen: imageOpenAction(for: image)
        )
        .frame(maxWidth: 360)
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        HStack(spacing: 5) {
          ForEach(images) { image in
            let index = images.firstIndex(of: image) ?? 0
            ZStack(alignment: .bottomTrailing) {
              ThreadPreviewImage(
                url: image.previewURL,
                loadAccessibilityLabel: "加载帖子图片 \(index + 1)",
                successAccessibilityLabel: "图片预览 \(index + 1)，共 \(totalCount) 张",
                openAccessibilityLabel: "打开图片 \(index + 1)，共 \(totalCount) 张",
                onOpen: imageOpenAction(for: image)
              )
              if index == 2, totalCount > images.count {
                Label(totalCount.formatted(), systemImage: "photo")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.white)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 3)
                  .background(Color.black.opacity(0.7))
                  .clipShape(RoundedRectangle(cornerRadius: 4))
                  .padding(5)
                  .accessibilityHidden(true)
                  .allowsHitTesting(false)
              }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 94)
            .clipShape(RoundedRectangle(cornerRadius: 4))
          }
        }
      }
    }
  }

  @ViewBuilder
  private func expandedVideoPreview(_ preview: ThreadSummaryVideoPreview) -> some View {
    switch BrowseVideoPresentationPolicy.primaryAction(for: preview.video) {
    case .play, .openPage:
      BrowseVideoView(
        video: preview.video,
        tracksAnimationVisibility: false,
        maximumPreviewPixelSize: 720,
        maximumWidth: 360,
        fixedHeight: 150,
        openPage: openVideoPage
      )
      .id(ThreadSummaryVideoPlaybackIdentity(threadID: thread.id, preview: preview))
      .background(Color.black.opacity(0.88))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .frame(maxWidth: .infinity, alignment: .leading)
    case .unavailable:
      if let coverURL = preview.video.cover, RemoteImageURLPolicy.allows(coverURL) {
        ZStack {
          ThreadPreviewImage(
            url: coverURL,
            loadAccessibilityLabel: "加载视频封面",
            successAccessibilityLabel: "视频封面",
            appliesContentThumbnailDimming: false
          )
          Image(systemName: "play.circle.fill")
            .font(.system(size: 38))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .black.opacity(0.55))
            .accessibilityHidden(true)
            .allowsHitTesting(false)
        }
        .frame(maxWidth: 360)
        .frame(height: 150)
        .background(Color.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func imageOpenAction(for image: ThreadSummaryImagePreview) -> (() -> Void)? {
    guard canOpenImages else { return nil }
    return { openImage(image) }
  }

  private func openImage(_ image: ThreadSummaryImagePreview) {
    guard canOpenImages else { return }
    _ = openThreadSummaryImage(
      thread: thread,
      contentOffset: image.contentOffset
    )
  }

  private var canOpenImages: Bool {
    ThreadSummaryMediaInteractionPolicy.permitsOpening(
      interaction: mediaInteraction,
      environmentActionAvailable: openThreadSummaryImage.isAvailable
    )
  }

  private func openVideoPage(_ pageURL: URL) {
    switch ThreadSummaryVideoPageRouter.disposition(
      for: pageURL,
      mode: externalWebOpenMode
    ) {
    case .tieba(let target):
      guard let appURL = TiebaLink.appURL(for: target) else { return }
      openURL(appURL)
    case .system(let url):
      openURL(url)
    case .inAppSafari(let url):
      if !openExternalWeb(url) {
        openURL(url)
      }
    case .rejected:
      break
    }
  }

  private var hasContextLine: Bool {
    let hasForum = showsForum && !displayedForumName.isEmpty
    let hasAuthor = showsAuthor && !displayedAuthorName.isEmpty
    return hasForum || hasAuthor || thread.lastReplyAt != nil || thread.createdAt != nil
  }

  @ViewBuilder
  private func contextLine(allowsNavigation: Bool) -> some View {
    let hasForum = showsForum && !displayedForumName.isEmpty
    let hasAuthor = showsAuthor && !displayedAuthorName.isEmpty
    let date = thread.lastReplyAt ?? thread.createdAt
    if hasForum || hasAuthor || date != nil {
      Group {
        switch ThreadSummaryContextLayoutPolicy.strategy(
          mode: contextLayout,
          dynamicTypeSize: dynamicTypeSize
        ) {
        case .widthAdaptive:
          ViewThatFits(in: .horizontal) {
            horizontalContextLine(
              hasForum: hasForum,
              hasAuthor: hasAuthor,
              date: date,
              allowsNavigation: allowsNavigation
            )
            stackedContextLine(
              hasForum: hasForum,
              hasAuthor: hasAuthor,
              date: date,
              allowsNavigation: allowsNavigation
            )
          }
        case .singleLine:
          horizontalContextLine(
            hasForum: hasForum,
            hasAuthor: hasAuthor,
            date: date,
            allowsNavigation: allowsNavigation
          )
        case .stacked:
          stackedContextLine(
            hasForum: hasForum,
            hasAuthor: hasAuthor,
            date: date,
            allowsNavigation: allowsNavigation
          )
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private func horizontalContextLine(
    hasForum: Bool,
    hasAuthor: Bool,
    date: Date?,
    allowsNavigation: Bool
  ) -> some View {
    HStack(spacing: 10) {
      contextLabels(
        hasForum: hasForum,
        hasAuthor: hasAuthor,
        allowsNavigation: allowsNavigation
      )
      Spacer(minLength: 4)
      dateLabel(date)
        .layoutPriority(2)
    }
  }

  private func stackedContextLine(
    hasForum: Bool,
    hasAuthor: Bool,
    date: Date?,
    allowsNavigation: Bool
  ) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      contextLabels(
        hasForum: hasForum,
        hasAuthor: hasAuthor,
        allowsNavigation: allowsNavigation
      )
      dateLabel(date)
    }
  }

  private func metricLine(allowsReplyNavigation: Bool) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) {
        primaryMetrics(allowsReplyNavigation: allowsReplyNavigation)
        secondaryMetrics
        Spacer(minLength: 0)
      }

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 14) {
          primaryMetrics(allowsReplyNavigation: allowsReplyNavigation)
          Spacer(minLength: 0)
        }
        if thread.agreeCount > 0 || thread.shareCount > 0 {
          HStack(spacing: 14) {
            secondaryMetrics
            Spacer(minLength: 0)
          }
        }
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private func contextLabels(
    hasForum: Bool,
    hasAuthor: Bool,
    allowsNavigation: Bool
  ) -> some View {
    if hasForum {
      if allowsNavigation, let url = ThreadSummaryContextNavigationPolicy.forumURL(
        for: thread,
        showsForum: showsForum
      ) {
        Button {
          openURL(url)
        } label: {
          forumContextLabel
            .foregroundStyle(.tint)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("打开 \(displayedForumName)吧")
        .accessibilityHint("查看贴吧")
        .help("打开贴吧")
      } else {
        forumContextLabel
      }
    }
    if hasAuthor {
      if allowsNavigation, let url = ThreadSummaryContextNavigationPolicy.authorURL(
        for: thread,
        showsAuthor: showsAuthor
      ) {
        Button {
          openURL(url)
        } label: {
          authorContextLabel
            .foregroundStyle(.tint)
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("打开作者 \(displayedAuthorName)")
        .accessibilityHint("查看用户主页")
        .help("打开作者主页")
      } else {
        authorContextLabel
      }
    }
  }

  private var forumContextLabel: some View {
    Label("\(displayedForumName)吧", systemImage: "text.bubble")
      .lineLimit(1)
  }

  private var displayedForumName: String {
    thread.forumName
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }

  private var authorContextLabel: some View {
    HStack(spacing: 5) {
      if let avatarURL = ThreadSummaryPresentation.authorAvatarURL(
        for: thread,
        showsAuthor: showsAuthor
      ) {
        AvatarView(url: avatarURL, name: displayedAuthorName, size: 24)
      } else {
        Image(systemName: "person")
          .accessibilityHidden(true)
      }
      Text(displayedAuthorName)
        .lineLimit(authorNameLineLimit)
        .minimumScaleFactor(0.75)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(displayedAuthorName)
  }

  private var displayedAuthorName: String {
    UserNameFormatter.displayName(
      preferredName: thread.authorName,
      username: thread.authorUsername,
      showsBoth: showsBothNames
    )
  }

  private var authorNameLineLimit: Int {
    let usesCompactSingleLine = contextLayout == .compact
      && ThreadSummaryContextLayoutPolicy.strategy(
        mode: contextLayout,
        dynamicTypeSize: dynamicTypeSize
      ) == .singleLine
    return usesCompactSingleLine ? 1 : (showsBothNames ? 2 : 1)
  }

  @ViewBuilder
  private func dateLabel(_ date: Date?) -> some View {
    if let date {
      Text(date, style: .relative)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
  }

  @ViewBuilder
  private func primaryMetrics(allowsReplyNavigation: Bool) -> some View {
    if allowsReplyNavigation,
      let request = ThreadSummaryNavigationPolicy.repliesRequest(for: thread)
    {
      Button {
        onNavigate(request)
      } label: {
        ThreadMetric(systemImage: "bubble.left", value: thread.replyCount, label: "回复")
          .frame(minWidth: 44, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.borderless)
      .accessibilityLabel(
        ThreadSummaryNavigationPolicy.repliesAccessibilityLabel(replyCount: thread.replyCount)
      )
      .help("查看回复")
    } else {
      ThreadMetric(systemImage: "bubble.left", value: thread.replyCount, label: "回复")
    }
    if thread.viewCount > 0 {
      ThreadMetric(systemImage: "eye", value: thread.viewCount, label: "浏览")
    }
  }

  @ViewBuilder
  private var trailingMetricActionButton: some View {
    if let trailingMetricAction {
      ThreadSummaryTrailingMetricActionButton(
        action: trailingMetricAction,
        perform: onTrailingMetricAction
      )
    }
  }

  @ViewBuilder
  private var secondaryMetrics: some View {
    if thread.agreeCount > 0 {
      ThreadMetric(systemImage: "hand.thumbsup", value: thread.agreeCount, label: "赞同")
    }
    if thread.shareCount > 0 {
      ThreadMetric(
        systemImage: "arrowshape.turn.up.right",
        value: thread.shareCount,
        label: "分享"
      )
    }
  }

  private var badgeLine: some View {
    ViewThatFits(in: .horizontal) {
      badgeRow(badges)
      VStack(alignment: .leading, spacing: 5) {
        badgeRow(Array(badges.prefix(2)))
        if badges.count > 2 {
          badgeRow(Array(badges.dropFirst(2)))
        }
      }
    }
  }

  private func badgeRow(_ badges: [ThreadSummaryBadge]) -> some View {
    HStack(spacing: 10) {
      ForEach(Array(badges.enumerated()), id: \.offset) { _, badge in
        Label(badge.title, systemImage: badge.systemImage)
          .font(.caption2.weight(.semibold))
          .foregroundStyle(badge.isProminent ? appAccentColor.color : Color.secondary)
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
      }
    }
  }

  private var badges: [ThreadSummaryBadge] {
    var result: [ThreadSummaryBadge] = []
    if thread.isFeatured {
      result.append(ThreadSummaryBadge(title: "精华", systemImage: "star.fill", isProminent: true))
    }
    if thread.isLive || thread.kind == .live {
      result.append(
        ThreadSummaryBadge(
          title: "直播",
          systemImage: "dot.radiowaves.left.and.right",
          isProminent: true
        )
      )
    }
    if thread.isShared {
      result.append(
        ThreadSummaryBadge(
          title: "转发",
          systemImage: "arrowshape.turn.up.right.fill",
          isProminent: false
        )
      )
    }
    if let kindBadge, !result.contains(where: { $0.title == kindBadge.title }) {
      result.append(kindBadge)
    }
    return result
  }

  private var kindBadge: ThreadSummaryBadge? {
    switch thread.kind {
    case .article:
      nil
    case .album:
      ThreadSummaryBadge(title: "图集", systemImage: "photo.on.rectangle", isProminent: false)
    case .externalShare:
      ThreadSummaryBadge(title: "分享", systemImage: "link", isProminent: false)
    case .voice:
      ThreadSummaryBadge(title: "语音", systemImage: "waveform", isProminent: false)
    case .cloudDrive:
      ThreadSummaryBadge(title: "网盘", systemImage: "externaldrive", isProminent: false)
    case .story:
      ThreadSummaryBadge(title: "故事", systemImage: "book", isProminent: false)
    case .video:
      ThreadSummaryBadge(title: "视频", systemImage: "play.rectangle.fill", isProminent: false)
    case .live:
      ThreadSummaryBadge(
        title: "直播",
        systemImage: "dot.radiowaves.left.and.right",
        isProminent: true
      )
    case .help:
      ThreadSummaryBadge(title: "求助", systemImage: "questionmark.circle", isProminent: false)
    case .vote:
      ThreadSummaryBadge(title: "投票", systemImage: "chart.bar", isProminent: false)
    case .lottery:
      ThreadSummaryBadge(title: "抽奖", systemImage: "gift", isProminent: false)
    case .unknown:
      nil
    }
  }
}

struct ThreadSummaryVideoPlaybackIdentity: Hashable, Sendable {
  let threadID: Int64
  let preview: ThreadSummaryVideoPreview
}

enum ThreadSummaryVideoPageRouter {
  static func disposition(
    for url: URL,
    mode: ExternalWebOpenMode
  ) -> BrowseContentLinkDisposition {
    guard let pageURL = SecureTiebaURL.videoPage(url) else { return .rejected }
    return BrowseContentLinkRouter.disposition(for: pageURL, mode: mode)
  }
}

private struct ThreadPreviewImage: View {
  let url: URL
  let loadAccessibilityLabel: String
  let successAccessibilityLabel: String
  let openAccessibilityLabel: String?
  let onOpen: (() -> Void)?
  let appliesContentThumbnailDimming: Bool

  init(
    url: URL,
    loadAccessibilityLabel: String,
    successAccessibilityLabel: String,
    openAccessibilityLabel: String? = nil,
    onOpen: (() -> Void)? = nil,
    appliesContentThumbnailDimming: Bool = true
  ) {
    self.url = url
    self.loadAccessibilityLabel = loadAccessibilityLabel
    self.successAccessibilityLabel = successAccessibilityLabel
    self.openAccessibilityLabel = openAccessibilityLabel
    self.onOpen = onOpen
    self.appliesContentThumbnailDimming = appliesContentThumbnailDimming
  }

  @Environment(\.contentMediaLoadBehavior) private var contentMediaLoadBehavior

  var body: some View {
    ContentRemoteImage(
      url: url,
      maxPixelSize: 720,
      loadAccessibilityLabel: loadAccessibilityLabel
    ) { phase in
      switch phase {
      case .success(let asset, _):
        successfulPreview(asset)
      case .failure:
        previewPlaceholder(systemImage: failureSystemImage)
      case .empty:
        ZStack {
          Color(uiColor: .secondarySystemFill)
          ProgressView()
        }
        .accessibilityHidden(true)
      case .loadRequired:
        previewPlaceholder(systemImage: "arrow.down.circle")
      }
    }
    .buttonStyle(.borderless)
    .clipped()
  }

  @ViewBuilder
  private func successfulPreview(_ asset: DownsampledImageAsset) -> some View {
    if let onOpen {
      Button(action: onOpen) {
        renderedPreview(asset)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
          .contentShape(Rectangle())
          .accessibilityHidden(true)
      }
      .buttonStyle(.borderless)
      .contentShape(Rectangle())
      .accessibilityLabel(openAccessibilityLabel ?? successAccessibilityLabel)
    } else {
      renderedPreview(asset)
        .accessibilityLabel(successAccessibilityLabel)
    }
  }

  private func renderedPreview(_ asset: DownsampledImageAsset) -> some View {
    RemoteImageAssetView(asset: asset, contentMode: .fill)
      .contentThumbnailDimming(applies: appliesContentThumbnailDimming)
  }

  private var failureSystemImage: String {
    contentMediaLoadBehavior == .userInitiated && RemoteImageURLPolicy.allows(url)
      ? "arrow.clockwise.circle"
      : "photo.badge.exclamationmark"
  }

  private func previewPlaceholder(systemImage: String) -> some View {
    Image(systemName: systemImage)
      .font(.title3)
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Color(uiColor: .secondarySystemFill))
      .contentShape(Rectangle())
  }
}

private struct ThreadMetric: View {
  let systemImage: String
  let value: Int
  let label: String

  var body: some View {
    Label(max(value, 0).formatted(.number.notation(.compactName)), systemImage: systemImage)
      .lineLimit(1)
      .fixedSize(horizontal: true, vertical: false)
      .accessibilityLabel("\(label) \(max(value, 0).formatted())")
  }
}

struct ThreadSummaryTrailingMetricActionButton: View {
  let action: ThreadSummaryTrailingMetricAction
  let perform: () -> Void

  var body: some View {
    Button {
      guard action.isEnabled else { return }
      perform()
    } label: {
      Image(systemName: action.systemImage)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }
    .buttonStyle(.borderless)
    .disabled(!action.isEnabled)
    .foregroundStyle(.tint)
    .accessibilityLabel(action.accessibilityLabel)
    .accessibilityIdentifier(action.accessibilityIdentifier)
    .help(action.accessibilityLabel)
  }
}

private struct ThreadSummaryBadge: Equatable {
  let title: String
  let systemImage: String
  let isProminent: Bool
}
