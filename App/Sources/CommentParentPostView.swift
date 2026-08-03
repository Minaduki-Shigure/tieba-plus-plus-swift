import SwiftUI
import UIKit

struct CommentParentPostView: View {
  let post: CommentParentPostContext
  let service:
    any BrowseService & ForumPostSearchService & UserProfileService & ForumInformationService
  let historyRepository: any BrowsingHistoryRepository
  let favoritesRepository: any LocalFavoritesRepository
  let searchHistoryRepository: any ForumSearchHistoryRepository
  let openMentionedUser: (Int64) -> Void
  let openTiebaLink: (TiebaLinkTarget) -> Void

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

        ReadOnlyAgreeLabel(score: post.agreeScore)
          .padding(.top, 2)
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
    }
    .accessibilityIdentifier("comments-parent-post")
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
