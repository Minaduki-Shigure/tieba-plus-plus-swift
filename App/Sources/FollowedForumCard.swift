import Foundation
import SwiftUI
import UIKit

enum ForumAvatarDisplayPolicy {
  private static let allowedHostSuffixes = [
    "baidu.com",
    "bdimg.com",
    "bdstatic.com",
    "bcebos.com",
    "baidubce.com",
  ]

  static func displayURL(_ url: URL?) -> URL? {
    guard let url, allows(url) else { return nil }
    return url
  }

  static func allows(_ url: URL) -> Bool {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      components.user == nil,
      components.password == nil,
      components.port == nil || components.port == 443,
      let host = components.host?.lowercased(),
      allowedHostSuffixes.contains(where: { suffix in
        host == suffix || host.hasSuffix(".\(suffix)")
      })
    else { return false }
    return true
  }
}

struct FollowedForumCardPresentation: Equatable, Sendable {
  let avatarURL: URL?
  let slogan: String
  let progressText: String

  init(forum: FollowedForumItem) {
    avatarURL = ForumAvatarDisplayPolicy.displayURL(forum.avatarURL)
    slogan = forum.slogan.trimmingCharacters(in: .whitespacesAndNewlines)

    var details = [String]()
    if forum.level > 0 { details.append("等级 \(forum.level)") }
    if forum.experience > 0 { details.append("经验 \(forum.experience.formatted())") }
    progressText = details.joined(separator: "，")
  }

  var accessibilityValue: String {
    [slogan, progressText].filter { !$0.isEmpty }.joined(separator: "，")
  }
}

struct FollowedForumCard: View {
  let forum: FollowedForumItem
  let isPinned: Bool

  init(forum: FollowedForumItem, isPinned: Bool = false) {
    self.forum = forum
    self.isPinned = isPinned
  }

  var body: some View {
    let presentation = FollowedForumCardPresentation(forum: forum)
    HStack(alignment: .center, spacing: 10) {
      AvatarView(
        url: presentation.avatarURL,
        name: forum.name,
        size: 40,
        urlPolicy: .forumAvatar
      )

      VStack(alignment: .leading, spacing: 4) {
        Text("\(forum.name)吧")
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(2)

        if !presentation.slogan.isEmpty {
          Text(presentation.slogan)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        if !presentation.progressText.isEmpty {
          Text(presentation.progressText)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      Spacer(minLength: 0)

      if isPinned {
        Image(systemName: "pin.fill")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tint)
          .accessibilityHidden(true)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    .background(
      Color(uiColor: .secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(Color(uiColor: .separator).opacity(0.35), lineWidth: 0.5)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(forum.name)吧")
    .accessibilityValue(
      [isPinned ? "已置顶" : "", presentation.accessibilityValue]
        .filter { !$0.isEmpty }
        .joined(separator: "，")
    )
  }
}

private struct FollowedForumContextMenuModifier: ViewModifier {
  let forum: FollowedForumItem
  let isPinned: Bool
  let setPinned: (Bool) -> Void

  func body(content: Content) -> some View {
    content.contextMenu {
      Button {
        setPinned(!isPinned)
      } label: {
        Label(
          isPinned ? "取消置顶" : "置顶",
          systemImage: isPinned ? "pin.slash" : "pin"
        )
      }

      Button {
        UIPasteboard.general.string = forum.name
      } label: {
        Label("复制吧名", systemImage: "doc.on.doc")
      }
    }
  }
}

extension View {
  func followedForumContextMenu(
    forum: FollowedForumItem,
    isPinned: Bool,
    setPinned: @escaping (Bool) -> Void
  ) -> some View {
    modifier(
      FollowedForumContextMenuModifier(
        forum: forum,
        isPinned: isPinned,
        setPinned: setPinned
      )
    )
  }
}
