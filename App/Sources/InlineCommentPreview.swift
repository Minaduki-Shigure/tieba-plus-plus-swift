import SwiftUI

struct InlineCommentPreviewPresentation: Hashable, Sendable {
  let comments: [BrowseComment]
  let totalCount: Int
  let showsAllCommentsAction: Bool

  init?(post: BrowsePost, isPureReadingMode: Bool) {
    guard !isPureReadingMode else { return nil }
    let comments = post.inlineComments.filter { $0.localVisibility != .hidden }
    let totalCount = max(max(post.nestedReplyCount, 0), post.inlineComments.count)
    guard totalCount > 0 || !comments.isEmpty else { return nil }
    self.comments = comments
    self.totalCount = totalCount
    self.showsAllCommentsAction = comments.count != totalCount
      || !comments.allSatisfy { $0.localVisibility == .visible }
  }
}

struct InlineCommentReplyPresentation: Hashable, Sendable {
  let context: TextReplyComposerContext
  let accessibilityIdentifier: String

  init?(
    thread: BrowseThread,
    parentPost: BrowsePost,
    comment: BrowseComment,
    replyEntriesVisible: Bool
  ) {
    guard
      replyEntriesVisible,
      parentPost.localVisibility == .visible,
      comment.localVisibility == .visible,
      let context = TextReplyComposerContext(
        thread: thread,
        parentPost: parentPost,
        comment: comment
      )
    else { return nil }
    self.context = context
    self.accessibilityIdentifier = "inline-comment-reply-\(comment.id)"
  }
}

struct InlineCommentPreviewCard: View {
  let presentation: InlineCommentPreviewPresentation
  let openComments: (Int64?) -> Void
  let replyPresentation: (BrowseComment) -> InlineCommentReplyPresentation?
  let requestReply: (BrowseComment) -> Void
  let reportTarget: (BrowseComment) -> ContentReportTarget?
  let selectText: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(presentation.comments.enumerated()), id: \.element.id) { index, comment in
        if index > 0 {
          Divider()
        }
        switch comment.localVisibility {
        case .visible:
          let commentReplyPresentation = replyPresentation(comment)
          InlineCommentPreviewRow(
            comment: comment,
            action: { openComments(comment.id) },
            replyPresentation: commentReplyPresentation,
            requestReply: commentReplyPresentation == nil
              ? nil
              : { requestReply(comment) },
            reportTarget: reportTarget(comment),
            selectText: selectText
          )
        case .placeholder:
          Label("已屏蔽此条回复", systemImage: "hand.raised.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 9)
        case .hidden:
          EmptyView()
        }
      }

      if presentation.showsAllCommentsAction, !presentation.comments.isEmpty {
        Divider()
      }
      if presentation.showsAllCommentsAction {
        Button {
          openComments(nil)
        } label: {
          HStack(spacing: 7) {
            Image(systemName: "bubble.left.and.bubble.right")
            Text("查看全部 \(presentation.totalCount) 条回复")
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold))
          }
          .font(.subheadline)
          .foregroundStyle(.tint)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 10)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("inline-comments-all")
      }
    }
    .padding(.horizontal, 12)
    .background(Color(uiColor: .secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: 6))
  }
}

private struct InlineCommentPreviewRow: View {
  let comment: BrowseComment
  let action: () -> Void
  let replyPresentation: InlineCommentReplyPresentation?
  let requestReply: (() -> Void)?
  let reportTarget: ContentReportTarget?
  let selectText: (String) -> Void

  @Environment(\.showsBothUsernameAndNickname) private var showsBothNames
  @Environment(\.appAccentColor) private var appAccentColor

  private var bodyText: String {
    PostCopyText.text(comment: comment) ?? "（无可显示内容）"
  }

  var body: some View {
    HStack(alignment: .center, spacing: 8) {
      Button(action: action) {
        previewText
          .font(.subheadline)
          .foregroundStyle(.primary)
          .lineLimit(showsBothNames ? 5 : 4)
          .minimumScaleFactor(0.75)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 9)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityText)

      if let replyPresentation, let requestReply {
        Button(action: requestReply) {
          Image(systemName: "arrowshape.turn.up.left")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(
          "回复 \(replyPresentation.context.replyingToName ?? "此用户")"
        )
        .accessibilityIdentifier(replyPresentation.accessibilityIdentifier)
        .help("回复此条")
      }
    }
    .contextMenu {
      if let copyText = PostCopyText.text(comment: comment) {
        Button {
          selectText(copyText)
        } label: {
          Label("选择文字", systemImage: "text.cursor")
        }
      }
      if replyPresentation != nil, let requestReply {
        Button(action: requestReply) {
          Label("回复此条", systemImage: "arrowshape.turn.up.left")
        }
      }
      ContentReportMenuItem(
        target: reportTarget,
        accessibilityIdentifier: "inline-comment-report-\(comment.id)"
      )
    }
  }

  private var previewText: Text {
    var result = Text(displayedAuthorName)
      .foregroundColor(appAccentColor.color)
      .bold()
    if comment.isThreadAuthor {
      result = result + Text(" [楼主]")
        .foregroundColor(appAccentColor.color)
        .fontWeight(.semibold)
    }
    return result + Text("：\(bodyText)")
  }

  private var displayedAuthorName: String {
    UserNameFormatter.displayName(
      preferredName: comment.authorName,
      username: comment.authorUsername,
      showsBoth: showsBothNames
    )
  }

  private var accessibilityText: String {
    let authorContext = comment.isThreadAuthor
      ? "\(displayedAuthorName)，楼主"
      : displayedAuthorName
    return "\(authorContext)：\(bodyText)"
  }
}
