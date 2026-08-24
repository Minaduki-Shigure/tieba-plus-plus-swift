import SwiftUI

enum ThreadListMediaSummary: Equatable, Sendable {
  case video
  case images(count: Int)

  var title: String {
    switch self {
    case .video:
      "视频"
    case .images(let count):
      "\(max(count, 0).formatted()) 张图片"
    }
  }

  var accessibilityLabel: String {
    switch self {
    case .video:
      "包含视频，预览已收起"
    case .images(let count):
      "包含 \(max(count, 0).formatted()) 张图片，预览已收起"
    }
  }

  fileprivate var systemImage: String {
    switch self {
    case .video:
      "play.rectangle"
    case .images:
      "photo.on.rectangle"
    }
  }
}

struct CompactListMediaView: View {
  let summary: ThreadListMediaSummary
  private let permitsHitTesting: Bool

  init(summary: ThreadListMediaSummary, permitsHitTesting: Bool = false) {
    self.summary = summary
    self.permitsHitTesting = permitsHitTesting
  }

  var body: some View {
    Label(summary.title, systemImage: summary.systemImage)
      .font(.caption.weight(.medium))
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(Color(uiColor: .secondarySystemFill))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .frame(maxWidth: maximumWidth, alignment: .leading)
      .allowsHitTesting(permitsHitTesting)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(summary.accessibilityLabel)
  }

  private var maximumWidth: CGFloat? {
    permitsHitTesting ? nil : .infinity
  }
}
