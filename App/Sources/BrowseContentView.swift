import AVKit
import SwiftUI

struct BrowseContentView: View {
  let contents: [BrowseContent]
  let onUserMention: ((Int64) -> Void)?
  let onTiebaLink: ((TiebaLinkTarget) -> Void)?

  init(
    contents: [BrowseContent],
    onUserMention: ((Int64) -> Void)? = nil,
    onTiebaLink: ((TiebaLinkTarget) -> Void)? = nil
  ) {
    self.contents = contents
    self.onUserMention = onUserMention
    self.onTiebaLink = onTiebaLink
  }

  private var blocks: [BrowseContentBlock] {
    var result = [BrowseContentBlock]()
    var inline = [BrowseContent]()

    func flushInline() {
      guard !inline.isEmpty else { return }
      result.append(.inline(inline))
      inline.removeAll(keepingCapacity: true)
    }

    for content in contents {
      switch content {
      case .text, .mention, .link, .emoticon, .unsupported:
        inline.append(content)
      case .image, .video, .voice:
        flushInline()
        result.append(.standalone(content))
      }
    }
    flushInline()
    return result
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
        switch block {
        case .inline(let contents):
          Text(
            Self.inlineText(
              contents,
              linksUserMentions: onUserMention != nil || onTiebaLink != nil
            )
          )
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, mentionOpenURLAction)
        case .standalone(let content):
          standalone(content)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var mentionOpenURLAction: OpenURLAction {
    OpenURLAction { url in
      guard let target = TiebaLink.target(from: url) else { return .systemAction }
      if case .user(let userID) = target, let onUserMention {
        onUserMention(userID)
        return .handled
      }
      guard let onTiebaLink else { return .systemAction }
      onTiebaLink(target)
      return .handled
    }
  }

  @ViewBuilder
  private func standalone(_ content: BrowseContent) -> some View {
    switch content {
    case .image(let thumbnail, let original, let width, let height):
      BrowseImageView(
        thumbnailURL: thumbnail,
        originalURL: original,
        width: width,
        height: height
      )
    case .video(let url, let cover, let width, let height):
      BrowseVideoView(url: url, coverURL: cover, width: width, height: height)
    case .voice(let url, let duration):
      VoicePlaybackButton(url: url, duration: duration)
    case .text, .mention, .link, .emoticon, .unsupported:
      EmptyView()
    }
  }

  static func inlineText(
    _ contents: [BrowseContent],
    linksUserMentions: Bool = false
  ) -> AttributedString {
    var result = AttributedString()
    for content in contents {
      var fragment: AttributedString
      switch content {
      case .text(let text):
        fragment = AttributedString(text)
      case .mention(let name, let userID):
        fragment = AttributedString("@\(name)")
        fragment.foregroundColor = .accentColor
        if linksUserMentions, let url = mentionURL(for: userID) {
          fragment.link = url
        }
      case .link(let label, let url):
        fragment = AttributedString(label.isEmpty ? url.host ?? url.absoluteString : label)
        fragment.link = url
        fragment.foregroundColor = .accentColor
      case .emoticon(let name, _):
        fragment = AttributedString(name)
      case .unsupported(let label):
        fragment = AttributedString("[\(label)]")
      case .image, .video, .voice:
        continue
      }
      result.append(fragment)
    }
    return result
  }

  static func mentionURL(for userID: Int64) -> URL? {
    TiebaLink.appURL(for: .user(userID))
  }

  static func mentionUserID(from url: URL) -> Int64? {
    guard case .user(let userID) = TiebaLink.target(from: url) else { return nil }
    return userID
  }
}

private enum BrowseContentBlock {
  case inline([BrowseContent])
  case standalone(BrowseContent)
}

private struct BrowseImageView: View {
  let thumbnailURL: URL
  let originalURL: URL?
  let width: Int
  let height: Int

  @State private var isPresented = false

  private var aspectRatio: CGFloat {
    guard width > 0, height > 0 else { return 4 / 3 }
    return min(max(CGFloat(width) / CGFloat(height), 0.5), 2)
  }

  var body: some View {
    Button {
      isPresented = true
    } label: {
      DownsampledRemoteImage(url: thumbnailURL, maxPixelSize: 1_600) { phase in
        switch phase {
        case .success(let image):
          image.resizable().scaledToFill()
        case .failure:
          Image(systemName: "photo.badge.exclamationmark")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemFill))
        default:
          ProgressView()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(uiColor: .secondarySystemFill))
        }
      }
      .aspectRatio(aspectRatio, contentMode: .fit)
      .frame(maxWidth: 560)
      .clipped()
    }
    .buttonStyle(.plain)
    .accessibilityLabel("查看大图")
    .fullScreenCover(isPresented: $isPresented) {
      ImageViewer(url: originalURL ?? thumbnailURL)
    }
  }
}

private struct BrowseVideoView: View {
  let url: URL?
  let coverURL: URL?
  let width: Int
  let height: Int

  @State private var player: AVPlayer?

  private var aspectRatio: CGFloat {
    guard width > 0, height > 0 else { return 16 / 9 }
    return min(max(CGFloat(width) / CGFloat(height), 0.5), 2)
  }

  var body: some View {
    Group {
      if let player {
        VideoPlayer(player: player)
      } else {
        ZStack {
          DownsampledRemoteImage(url: coverURL, maxPixelSize: 1_600) { phase in
            switch phase {
            case .success(let image):
              image.resizable().scaledToFill()
            case .empty, .failure:
              Color.black.opacity(0.88)
            }
          }
          if let url {
            Button {
              let newPlayer = AVPlayer(url: url)
              player = newPlayer
              newPlayer.play()
            } label: {
              Image(systemName: "play.circle.fill")
                .font(.system(size: 48))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
            }
            .accessibilityLabel("播放视频")
          }
        }
      }
    }
    .aspectRatio(aspectRatio, contentMode: .fit)
    .frame(maxWidth: 560)
    .clipped()
    .onDisappear {
      player?.pause()
    }
  }
}
