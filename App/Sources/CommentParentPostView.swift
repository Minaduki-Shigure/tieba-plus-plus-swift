import SwiftUI
import UIKit

struct CommentParentPostView: View {
  let post: CommentParentPostContext
  let agreementTarget: ContentAgreementTarget?
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let openMentionedUser: (Int64) -> Void
  let openTiebaLink: (TiebaLinkTarget) -> Void
  let requestAgreementChange: (ContentAgreementTarget, Bool) -> Void
  let retryAgreement: (ContentAgreementTarget) -> Void
  let requestReply: (() -> Void)?

  @Environment(\.contentAgreementStore) private var contentAgreementStore
  @Environment(\.hidesReplyEntryPoints) private var hidesReplyEntryPoints

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(alignment: .top, spacing: 10) {
        if post.authorID > 0 {
          NavigationLink {
            UserProfileView(
              userID: post.authorID,
              service: service,
              historyRepository: historyRepository,
              favoritesRepository: favoritesRepository,
              searchHistoryRepository: searchHistoryRepository
            )
          } label: {
            authorIdentity
          }
          .buttonStyle(.plain)
        } else {
          authorIdentity
        }

        ContentAgreementControlSlot(
          store: contentAgreementStore,
          target: agreementTarget,
          fallbackAgreeScore: post.agreeScore,
          requestChange: requestAgreementChange,
          retry: retryAgreement
        )

        if replyEntryVisible, let requestReply {
          Button {
            guard replyEntryVisible else { return }
            requestReply()
          } label: {
            Image(systemName: "arrowshape.turn.up.left")
          }
          .buttonStyle(.plain)
          .accessibilityLabel(
            post.floor == 1
              ? "回复主题"
              : (post.floor > 1 ? "回复第 \(post.floor) 楼" : "回复父楼")
          )
          .help(post.floor == 1 ? "回复主题" : "回复父楼")
        }
      }

      BrowseContentView(
        contents: post.contents,
        onUserMention: openMentionedUser,
        onTiebaLink: openTiebaLink
      )
    }
    .padding(.vertical, 4)
    .contextMenu {
      if let copyText = BrowseContentCopyText.text(post.contents) {
        Button {
          UIPasteboard.general.string = copyText
        } label: {
          Label("复制父楼内容", systemImage: "doc.on.doc")
        }
      }
      if replyEntryVisible, let requestReply {
        Button {
          guard replyEntryVisible else { return }
          requestReply()
        } label: {
          Label(
            post.floor == 1 ? "回复主题" : "回复父楼",
            systemImage: "arrowshape.turn.up.left"
          )
        }
      }
    }
    .accessibilityIdentifier("comments-parent-post")
  }

  private var replyEntryVisible: Bool {
    ReplyEntryVisibilityPolicy(
      preferenceHidden: hidesReplyEntryPoints,
      pureReading: false,
      contextAvailable: requestReply != nil
    ).showsReplyEntry
  }

  private var authorIdentity: some View {
    PostAuthorIdentityView(
      name: post.authorName,
      username: post.authorUsername,
      portraitURL: post.authorPortraitURL,
      level: post.authorLevel,
      isThreadAuthor: post.isThreadAuthor,
      moderatorRole: post.moderatorRole,
      floor: post.floor,
      date: post.createdAt,
      ipLocation: post.authorIPLocation,
      showsDisclosureIndicator: post.authorID > 0
    )
  }
}
