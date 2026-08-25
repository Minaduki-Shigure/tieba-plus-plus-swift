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
  let levelProgress: ForumLevelProgressPresentation?
  let isCheckedInToday: Bool

  init(forum: FollowedForumItem, isCheckedInToday: Bool = false) {
    avatarURL = ForumAvatarDisplayPolicy.displayURL(forum.avatarURL)
    slogan = forum.slogan.trimmingCharacters(in: .whitespacesAndNewlines)
    levelProgress = forum.levelProgress.map(ForumLevelProgressPresentation.init)
    self.isCheckedInToday = isCheckedInToday

    if levelProgress == nil {
      var details = [String]()
      if forum.level > 0 { details.append("等级 \(forum.level)") }
      if forum.experience > 0 { details.append("经验 \(forum.experience.formatted())") }
      progressText = details.joined(separator: "，")
    } else {
      progressText = ""
    }
  }

  var accessibilityValue: String {
    [
      slogan,
      levelProgress?.accessibilityValue ?? progressText,
      isCheckedInToday ? "今日已签到" : "",
    ]
    .filter { !$0.isEmpty }
    .joined(separator: "，")
  }
}

struct FollowedForumCard: View {
  let forum: FollowedForumItem
  let isPinned: Bool
  let isUnfollowing: Bool
  let isCheckedInToday: Bool
  @Environment(\.appDarkSurfaceStyle) private var appDarkSurfaceStyle
  @Environment(\.colorScheme) private var colorScheme

  init(
    forum: FollowedForumItem,
    isPinned: Bool = false,
    isUnfollowing: Bool = false,
    isCheckedInToday: Bool = false
  ) {
    self.forum = forum
    self.isPinned = isPinned
    self.isUnfollowing = isUnfollowing
    self.isCheckedInToday = isCheckedInToday
  }

  var body: some View {
    let presentation = FollowedForumCardPresentation(
      forum: forum,
      isCheckedInToday: isCheckedInToday
    )
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

        if let levelProgress = forum.levelProgress {
          ForumLevelProgressView(
            progress: levelProgress,
            showsCheckedInMark: presentation.isCheckedInToday
          )
            .accessibilityHidden(true)
        } else if !presentation.progressText.isEmpty || presentation.isCheckedInToday {
          HStack(spacing: 4) {
            if !presentation.progressText.isEmpty {
              Text(presentation.progressText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }
            if presentation.isCheckedInToday {
              ForumCheckedInMark()
                .accessibilityHidden(true)
            }
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      ZStack {
        if isUnfollowing {
          ProgressView()
            .controlSize(.small)
            .accessibilityHidden(true)
        } else if isPinned {
          Image(systemName: "pin.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        }
      }
      .frame(width: 20, height: 20)
    }
    .padding(10)
    .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
    .background(
      cardSurfaceColor,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(cardDividerColor, lineWidth: 0.5)
    }
    .contentShape(Rectangle())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(forum.name)吧")
    .accessibilityValue(
      [
        isPinned ? "已置顶" : "",
        isUnfollowing ? "正在取消关注" : "",
        presentation.accessibilityValue,
      ]
        .filter { !$0.isEmpty }
        .joined(separator: "，")
    )
  }

  private var usesOLEDSurfaces: Bool {
    AppSurfacePolicy.isOLEDActive(
      style: appDarkSurfaceStyle,
      colorScheme: colorScheme
    )
  }

  private var cardSurfaceColor: Color {
    usesOLEDSurfaces
      ? appDarkSurfaceStyle.color(for: .card)
      : Color(uiColor: .secondarySystemGroupedBackground)
  }

  private var cardDividerColor: Color {
    usesOLEDSurfaces
      ? appDarkSurfaceStyle.color(for: .divider)
      : Color(uiColor: .separator).opacity(0.35)
  }
}

private struct FollowedForumContextMenuModifier: ViewModifier {
  let forum: FollowedForumItem
  let isPinned: Bool
  let unfollowState: FollowedForumUnfollowControlState
  let setPinned: (Bool) -> Void
  let requestUnfollow: () -> Void

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
      .disabled(unfollowState == .busy)

      Button {
        UIPasteboard.general.string = forum.name
      } label: {
        Label("复制吧名", systemImage: "doc.on.doc")
      }

      switch unfollowState {
      case .available:
        Divider()
        Button(role: .destructive, action: requestUnfollow) {
          Label("取消关注", systemImage: "star.slash")
        }
      case .busy:
        Divider()
        Button(action: {}) {
          Label("正在取消关注", systemImage: "hourglass")
        }
        .disabled(true)
      case .unavailable:
        EmptyView()
      }
    }
  }
}

extension View {
  func followedForumContextMenu(
    forum: FollowedForumItem,
    isPinned: Bool,
    unfollowState: FollowedForumUnfollowControlState = .unavailable,
    setPinned: @escaping (Bool) -> Void,
    requestUnfollow: @escaping () -> Void = {}
  ) -> some View {
    modifier(
      FollowedForumContextMenuModifier(
        forum: forum,
        isPinned: isPinned,
        unfollowState: unfollowState,
        setPinned: setPinned,
        requestUnfollow: requestUnfollow
      )
    )
  }
}
