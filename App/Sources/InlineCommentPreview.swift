import SwiftUI
import UIKit

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

struct InlineCommentPreviewCard: View {
  let presentation: InlineCommentPreviewPresentation
  let openComments: (Int64?) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(presentation.comments.enumerated()), id: \.element.id) { index, comment in
        if index > 0 {
          Divider()
        }
        switch comment.localVisibility {
        case .visible:
          InlineCommentPreviewRow(comment: comment) {
            openComments(comment.id)
          }
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

  private var bodyText: String {
    BrowseContentCopyText.text(comment.contents) ?? "（无可显示内容）"
  }

  var body: some View {
    Button(action: action) {
      previewText
        .font(.subheadline)
        .foregroundStyle(.primary)
        .lineLimit(4)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(comment.authorName)：\(bodyText)")
    .contextMenu {
      if let copyText = BrowseContentCopyText.text(comment.contents) {
        Button {
          UIPasteboard.general.string = copyText
        } label: {
          Label("复制此条回复", systemImage: "doc.on.doc")
        }
      }
    }
  }

  private var previewText: Text {
    var result = Text(comment.authorName)
      .foregroundColor(.accentColor)
      .bold()
    if comment.isThreadAuthor {
      result = result + Text(" [楼主]")
        .foregroundColor(.accentColor)
        .fontWeight(.semibold)
    }
    return result + Text("：\(bodyText)")
  }
}
