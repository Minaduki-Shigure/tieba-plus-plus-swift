import AVFoundation
import SwiftUI

struct VoicePlaybackButton: View {
  let url: URL
  let duration: Int

  @State private var player: AVPlayer?
  @State private var isPlaying = false

  var body: some View {
    Button {
      if isPlaying {
        player?.pause()
        isPlaying = false
      } else {
        let activePlayer = player ?? AVPlayer(url: url)
        player = activePlayer
        activePlayer.play()
        isPlaying = true
      }
    } label: {
      HStack(spacing: 8) {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
          .frame(width: 16)
        Text("\(duration) 秒")
          .monospacedDigit()
      }
      .padding(.horizontal, 12)
      .frame(height: 36)
      .background(Color(uiColor: .secondarySystemFill))
      .clipShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(isPlaying ? "暂停语音" : "播放语音")
    .onDisappear {
      player?.pause()
      isPlaying = false
    }
  }
}
