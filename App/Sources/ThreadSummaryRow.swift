import SwiftUI

enum ThreadSummaryMedia: Equatable, Sendable {
  case video(URL)
  case images([URL], totalCount: Int)
}

enum ThreadSummaryMediaPresentation: Equatable, Sendable {
  case expanded(ThreadSummaryMedia)
  case collapsed(ThreadListMediaSummary)
}

enum ThreadSummaryPresentation {
  static func media(
    for thread: BrowseThread,
    quality: ContentImagePreviewQuality = .standard
  ) -> ThreadSummaryMedia? {
    guard !thread.isPinned else { return nil }
    if let cover = thread.contents.compactMap({ content -> URL? in
      guard case .video(_, let cover, _, _) = content else { return nil }
      return cover
    }).first {
      return .video(cover)
    }
    let images = thread.contents.compactMap { content -> URL? in
      guard case .image(let thumbnail, let fullSize, _, _, _) = content else { return nil }
      return BrowseContentImageSourceResolver.previewURL(
        thumbnail: thumbnail,
        fullSize: fullSize,
        quality: quality
      )
    }
    guard !images.isEmpty else { return nil }
    return .images(Array(images.prefix(3)), totalCount: images.count)
  }

  static func mediaPresentation(
    for thread: BrowseThread,
    hidesMedia: Bool,
    quality: ContentImagePreviewQuality = .standard
  ) -> ThreadSummaryMediaPresentation? {
    guard let media = media(for: thread, quality: quality) else { return nil }
    guard hidesMedia else { return .expanded(media) }

    switch media {
    case .video:
      return .collapsed(.video)
    case .images(_, let totalCount):
      return .collapsed(.images(count: totalCount))
    }
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

struct ThreadSummaryRow: View {
  let thread: BrowseThread
  let showsForum: Bool
  let showsAuthor: Bool

  @Environment(\.contentMediaLoadBehavior) private var contentMediaLoadBehavior
  @Environment(\.contentImagePreviewQuality) private var contentImagePreviewQuality
  @Environment(\.appAccentColor) private var appAccentColor
  @Environment(\.hidesThreadListMedia) private var hidesThreadListMedia
  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames

  init(
    thread: BrowseThread,
    showsForum: Bool = false,
    showsAuthor: Bool = true
  ) {
    self.thread = thread
    self.showsForum = showsForum
    self.showsAuthor = showsAuthor
  }

  var body: some View {
    if thread.isPinned {
      pinnedRow
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
      Text(displayTitle)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.primary)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.vertical, 2)
  }

  private var regularRow: some View {
    VStack(alignment: .leading, spacing: 8) {
      if !badges.isEmpty {
        badgeLine
      }

      Text(displayTitle)
        .font(.headline)
        .foregroundStyle(.primary)
        .lineLimit(3)
        .fixedSize(horizontal: false, vertical: true)

      if shouldShowExcerpt {
        Text(thread.excerpt)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .lineLimit(3)
          .fixedSize(horizontal: false, vertical: true)
      }

      mediaPreview
      contextLine
      metricLine
    }
    .padding(.vertical, 4)
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

  @ViewBuilder
  private var mediaPreview: some View {
    switch ThreadSummaryPresentation.mediaPresentation(
      for: thread,
      hidesMedia: hidesThreadListMedia,
      quality: contentImagePreviewQuality
    ) {
    case .some(.collapsed(let summary)):
      CompactListMediaView(summary: summary)
    case .some(.expanded(let media)):
      expandedMediaPreview(media)
    case .none:
      EmptyView()
    }
  }

  @ViewBuilder
  private func expandedMediaPreview(_ media: ThreadSummaryMedia) -> some View {
    switch media {
    case .video(let coverURL):
      mediaAccessibility(label: "视频预览") {
        ZStack {
          ThreadPreviewImage(
            url: coverURL,
            role: .videoCover,
            loadAccessibilityLabel: "加载视频封面",
            successAccessibilityLabel: "视频预览"
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
    case .images(let imageURLs, let totalCount):
      if imageURLs.count == 1, let imageURL = imageURLs.first {
        mediaAccessibility(label: "图片预览") {
          ThreadPreviewImage(
            url: imageURL,
            role: .staticImage,
            loadAccessibilityLabel: "加载帖子图片",
            successAccessibilityLabel: "图片预览"
          )
          .frame(maxWidth: 360)
          .frame(height: 150)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } else {
        mediaAccessibility(label: "\(totalCount) 张图片预览") {
          HStack(spacing: 5) {
            ForEach(Array(imageURLs.prefix(3).enumerated()), id: \.offset) { index, url in
              ZStack(alignment: .bottomTrailing) {
                ThreadPreviewImage(
                  url: url,
                  role: .staticImage,
                  loadAccessibilityLabel: "加载帖子图片 \(index + 1)",
                  successAccessibilityLabel: "图片预览 \(index + 1)，共 \(totalCount) 张"
                )
                if index == 2, totalCount > imageURLs.count {
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
  }

  @ViewBuilder
  private func mediaAccessibility<Content: View>(
    label: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    switch contentMediaLoadBehavior {
    case .automatic, .economicalNetworkOnly:
      content()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    case .userInitiated:
      content()
    }
  }

  @ViewBuilder
  private var contextLine: some View {
    let hasForum = showsForum && !thread.forumName.isEmpty
    let hasAuthor = showsAuthor && !displayedAuthorName.isEmpty
    let date = thread.lastReplyAt ?? thread.createdAt
    if hasForum || hasAuthor || date != nil {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          contextLabels(hasForum: hasForum, hasAuthor: hasAuthor)
          Spacer(minLength: 0)
          dateLabel(date)
        }

        VStack(alignment: .leading, spacing: 4) {
          contextLabels(hasForum: hasForum, hasAuthor: hasAuthor)
          dateLabel(date)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  private var metricLine: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) {
        primaryMetrics
        secondaryMetrics
        Spacer(minLength: 0)
      }

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 14) {
          primaryMetrics
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
  private func contextLabels(hasForum: Bool, hasAuthor: Bool) -> some View {
    if hasForum {
      Label("\(thread.forumName)吧", systemImage: "text.bubble")
        .lineLimit(1)
    }
    if hasAuthor {
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
          .lineLimit(showsBothNames ? 2 : 1)
          .minimumScaleFactor(0.75)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(displayedAuthorName)
    }
  }

  private var displayedAuthorName: String {
    UserNameFormatter.displayName(
      preferredName: thread.authorName,
      username: thread.authorUsername,
      showsBoth: showsBothNames
    )
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
  private var primaryMetrics: some View {
    ThreadMetric(systemImage: "bubble.left", value: thread.replyCount, label: "回复")
    if thread.viewCount > 0 {
      ThreadMetric(systemImage: "eye", value: thread.viewCount, label: "浏览")
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

enum ThreadPreviewImageRole: Equatable, Sendable {
  case staticImage
  case videoCover

  var appliesContentThumbnailDimming: Bool {
    self == .staticImage
  }
}

private struct ThreadPreviewImage: View {
  let url: URL
  let role: ThreadPreviewImageRole
  let loadAccessibilityLabel: String
  let successAccessibilityLabel: String

  @Environment(\.contentMediaLoadBehavior) private var contentMediaLoadBehavior

  var body: some View {
    ContentRemoteImage(
      url: url,
      maxPixelSize: 720,
      loadAccessibilityLabel: loadAccessibilityLabel
    ) { phase in
      switch phase {
      case .success(let image, _):
        image
          .resizable()
          .scaledToFill()
          .contentThumbnailDimming(applies: role.appliesContentThumbnailDimming)
          .accessibilityLabel(successAccessibilityLabel)
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

private struct ThreadSummaryBadge: Equatable {
  let title: String
  let systemImage: String
  let isProminent: Bool
}
