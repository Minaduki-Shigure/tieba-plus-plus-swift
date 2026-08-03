import SwiftUI

enum ThreadSummaryMedia: Equatable, Sendable {
  case video(URL)
  case images([URL], totalCount: Int)
}

enum ThreadSummaryPresentation {
  static func media(for thread: BrowseThread) -> ThreadSummaryMedia? {
    guard !thread.isPinned else { return nil }
    if let cover = thread.contents.compactMap({ content -> URL? in
      guard case .video(_, let cover, _, _) = content else { return nil }
      return cover
    }).first {
      return .video(cover)
    }
    let images = thread.contents.compactMap { content -> URL? in
      guard case .image(let thumbnail, _, _, _) = content else { return nil }
      return thumbnail
    }
    guard !images.isEmpty else { return nil }
    return .images(Array(images.prefix(3)), totalCount: images.count)
  }
}

struct ThreadSummaryRow: View {
  let thread: BrowseThread
  let showsForum: Bool
  let showsAuthor: Bool

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
    switch ThreadSummaryPresentation.media(for: thread) {
    case .some(.video(let coverURL)):
      ZStack {
        ThreadPreviewImage(url: coverURL)
        Image(systemName: "play.circle.fill")
          .font(.system(size: 38))
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .black.opacity(0.55))
      }
      .frame(maxWidth: 360)
      .frame(height: 150)
      .background(Color.black.opacity(0.88))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("视频预览")
    case .some(.images(let imageURLs, let totalCount)):
      if imageURLs.count == 1, let imageURL = imageURLs.first {
        ThreadPreviewImage(url: imageURL)
          .frame(maxWidth: 360)
          .frame(height: 150)
          .clipShape(RoundedRectangle(cornerRadius: 6))
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityLabel("图片预览")
      } else {
        HStack(spacing: 5) {
          ForEach(Array(imageURLs.prefix(3).enumerated()), id: \.offset) { index, url in
            ZStack(alignment: .bottomTrailing) {
              ThreadPreviewImage(url: url)
              if index == 2, totalCount > imageURLs.count {
                Label(totalCount.formatted(), systemImage: "photo")
                  .font(.caption2.weight(.semibold))
                  .foregroundStyle(.white)
                  .padding(.horizontal, 6)
                  .padding(.vertical, 3)
                  .background(Color.black.opacity(0.7))
                  .clipShape(RoundedRectangle(cornerRadius: 4))
                  .padding(5)
              }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 94)
            .clipShape(RoundedRectangle(cornerRadius: 4))
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(totalCount) 张图片预览")
      }
    case .none:
      EmptyView()
    }
  }

  @ViewBuilder
  private var contextLine: some View {
    let hasForum = showsForum && !thread.forumName.isEmpty
    let hasAuthor = showsAuthor && !thread.authorName.isEmpty
    let date = thread.lastReplyAt ?? thread.createdAt
    if hasForum || hasAuthor || date != nil {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          contextLabels(hasForum: hasForum, hasAuthor: hasAuthor)
          Spacer(minLength: 0)
          dateLabel(date)
        }

        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 12) {
            contextLabels(hasForum: hasForum, hasAuthor: hasAuthor)
            Spacer(minLength: 0)
          }
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
      Label(thread.authorName, systemImage: "person")
        .lineLimit(1)
    }
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
          .foregroundStyle(badge.isProminent ? Color.accentColor : Color.secondary)
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

private struct ThreadPreviewImage: View {
  let url: URL

  var body: some View {
    DownsampledRemoteImage(url: url, maxPixelSize: 720) { phase in
      switch phase {
      case .success(let image, _):
        image
          .resizable()
          .scaledToFill()
      case .failure:
        Image(systemName: "photo.badge.exclamationmark")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(uiColor: .secondarySystemFill))
      case .empty:
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color(uiColor: .secondarySystemFill))
      }
    }
    .clipped()
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
