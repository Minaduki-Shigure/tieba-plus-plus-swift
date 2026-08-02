import SwiftUI

struct PostAuthorIdentityView: View {
  let name: String
  let portraitURL: URL?
  let level: Int
  let isThreadAuthor: Bool
  let moderatorRole: BrowseModeratorRole?
  let floor: Int?
  let date: Date?
  let ipLocation: String
  let avatarSize: CGFloat
  let showsDisclosureIndicator: Bool

  init(
    name: String,
    portraitURL: URL?,
    level: Int,
    isThreadAuthor: Bool,
    moderatorRole: BrowseModeratorRole? = nil,
    floor: Int? = nil,
    date: Date?,
    ipLocation: String,
    avatarSize: CGFloat = 36,
    showsDisclosureIndicator: Bool = false
  ) {
    self.name = name
    self.portraitURL = portraitURL
    self.level = level
    self.isThreadAuthor = isThreadAuthor
    self.moderatorRole = moderatorRole
    self.floor = floor
    self.date = date
    self.ipLocation = ipLocation
    self.avatarSize = avatarSize
    self.showsDisclosureIndicator = showsDisclosureIndicator
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      AvatarView(url: portraitURL, name: name, size: avatarSize)
      VStack(alignment: .leading, spacing: 2) {
        PostAuthorNameLine(
          name: name,
          level: level,
          isThreadAuthor: isThreadAuthor,
          moderatorRole: moderatorRole
        )
        PostContextLine(floor: floor, date: date, ipLocation: ipLocation)
      }
      Spacer(minLength: 0)
      if showsDisclosureIndicator {
        Image(systemName: "chevron.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

enum PostAuthorBadge: Hashable, Sendable {
  case level(Int)
  case moderator(BrowseModeratorRole)
  case threadAuthor

  var title: String {
    switch self {
    case .level(let level):
      "Lv.\(level)"
    case .moderator(let role):
      role.title
    case .threadAuthor:
      "楼主"
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .level(let level):
      "本吧等级 \(level)"
    case .moderator(let role):
      "本吧身份：\(role.title)"
    case .threadAuthor:
      "本帖楼主"
    }
  }
}

struct PostAuthorNameLine: View {
  let name: String
  let level: Int
  let isThreadAuthor: Bool
  let moderatorRole: BrowseModeratorRole?

  var body: some View {
    if badges.isEmpty {
      authorName
    } else {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 5) {
          authorName
          badgeRow
        }
        .fixedSize(horizontal: true, vertical: false)

        VStack(alignment: .leading, spacing: 3) {
          authorName
          badgeRow
        }
      }
    }
  }

  static func badges(
    level: Int,
    moderatorRole: BrowseModeratorRole?,
    isThreadAuthor: Bool
  ) -> [PostAuthorBadge] {
    var result: [PostAuthorBadge] = []
    if level > 0 { result.append(.level(level)) }
    if let moderatorRole { result.append(.moderator(moderatorRole)) }
    if isThreadAuthor { result.append(.threadAuthor) }
    return result
  }

  private var badges: [PostAuthorBadge] {
    Self.badges(
      level: level,
      moderatorRole: moderatorRole,
      isThreadAuthor: isThreadAuthor
    )
  }

  private var authorName: some View {
    Text(name)
      .font(.subheadline.weight(.semibold))
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .layoutPriority(1)
  }

  private var badgeRow: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 5) {
        ForEach(badges, id: \.self) { badge in
          badgeView(badge)
        }
      }
      .fixedSize(horizontal: true, vertical: false)

      VStack(alignment: .leading, spacing: 2) {
        ForEach(badges, id: \.self) { badge in
          badgeView(badge)
        }
      }
    }
  }

  private func badgeView(_ badge: PostAuthorBadge) -> some View {
    Text(badge.title)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(.tint)
      .fixedSize()
      .accessibilityLabel(badge.accessibilityLabel)
  }
}

struct PostContextLine: View {
  let floor: Int?
  let date: Date?
  let ipLocation: String

  init(floor: Int? = nil, date: Date?, ipLocation: String) {
    self.floor = floor.flatMap { $0 > 0 ? $0 : nil }
    self.date = date
    self.ipLocation = ipLocation.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 5) {
        floorAndDate
        if hasPrimaryContext, !ipLocation.isEmpty {
          Text("·")
        }
        ipLocationText
      }

      VStack(alignment: .leading, spacing: 2) {
        if hasPrimaryContext {
          HStack(spacing: 5) {
            floorAndDate
          }
        }
        ipLocationText
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  private var hasPrimaryContext: Bool {
    floor != nil || date != nil
  }

  @ViewBuilder private var floorAndDate: some View {
    if let floor {
      Text("\(floor) 楼")
    }
    if floor != nil, date != nil {
      Text("·")
    }
    if let date {
      Text(date, style: .relative)
    }
  }

  @ViewBuilder private var ipLocationText: some View {
    if !ipLocation.isEmpty {
      Text("IP属地 \(ipLocation)")
        .lineLimit(1)
    }
  }
}

struct ReadOnlyAgreeLabel: View {
  let score: Int

  var body: some View {
    if score > 0 {
      Label(
        score.formatted(.number.notation(.compactName)),
        systemImage: "hand.thumbsup"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .monospacedDigit()
      .fixedSize()
      .accessibilityLabel("净赞数 \(score.formatted())")
    }
  }
}
