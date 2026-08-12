import SwiftUI

struct FollowedForumCard: View {
  let forum: FollowedForumItem

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      Image(systemName: "text.bubble")
        .frame(width: 40, height: 40)
        .background(Color.accentColor.opacity(0.12), in: Circle())
        .foregroundStyle(Color.accentColor)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text("\(forum.name)吧")
          .font(.headline)
          .foregroundStyle(.primary)
          .lineLimit(2)

        if !detailText.isEmpty {
          Text(detailText)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
      }

      Spacer(minLength: 0)
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
    .accessibilityValue(detailText)
  }

  private var detailText: String {
    var details = [String]()
    if forum.level > 0 { details.append("等级 \(forum.level)") }
    if forum.experience > 0 { details.append("经验 \(forum.experience.formatted())") }
    return details.joined(separator: "，")
  }
}
