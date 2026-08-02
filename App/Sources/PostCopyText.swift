import Foundation

enum PostCopyText {
  static func text(threadTitle: String, post: BrowsePost) -> String? {
    let body = BrowseContentCopyText.text(post.contents)
    let title = threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)

    var parts: [String] = []
    if post.floor == 1, !title.isEmpty {
      parts.append(title)
    }
    if let body {
      parts.append(body)
    }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }
}

enum BrowseContentCopyText {
  static func text(_ contents: [BrowseContent]) -> String? {
    var projectedBody = ""
    for content in contents {
      switch content {
      case .image:
        appendBlock("[图片]", to: &projectedBody)
      case .video:
        appendBlock("[视频]", to: &projectedBody)
      case .voice:
        appendBlock("[语音]", to: &projectedBody)
      case .text, .mention, .link, .emoticon, .unsupported:
        projectedBody.append(contentsOf: fragmentText(content))
      }
    }
    let body = projectedBody.trimmingCharacters(in: .whitespacesAndNewlines)
    return body.isEmpty ? nil : body
  }

  private static func appendBlock(_ block: String, to text: inout String) {
    if !text.isEmpty, !text.hasSuffix("\n") {
      text.append("\n")
    }
    text.append(contentsOf: block)
    text.append("\n")
  }

  private static func fragmentText(_ content: BrowseContent) -> String {
    switch content {
    case .text(let text):
      text
    case .mention(let name, _):
      "@\(name)"
    case .link(let label, let url):
      label.isEmpty ? url.host ?? url.absoluteString : label
    case .emoticon(let name, _):
      name
    case .unsupported(let label):
      "[\(label)]"
    case .image:
      "[图片]"
    case .video:
      "[视频]"
    case .voice:
      "[语音]"
    }
  }
}
