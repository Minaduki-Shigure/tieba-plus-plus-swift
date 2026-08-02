import SwiftUI

struct PostAuthorNameLine: View {
  let name: String
  let level: Int
  let isThreadAuthor: Bool

  var body: some View {
    HStack(spacing: 5) {
      Text(name)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .layoutPriority(1)

      if level > 0 {
        Text("Lv.\(level)")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.tint)
          .fixedSize()
          .accessibilityLabel("本吧等级 \(level)")
      }

      if isThreadAuthor {
        Text("楼主")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.tint)
          .fixedSize()
      }
    }
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
