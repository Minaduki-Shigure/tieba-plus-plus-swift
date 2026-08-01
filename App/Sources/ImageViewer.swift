import SwiftUI

struct ImageViewer: View {
  @Environment(\.dismiss) private var dismiss
  let url: URL

  var body: some View {
    ZStack(alignment: .topTrailing) {
      Color.black.ignoresSafeArea()
      ZoomableRemoteImage(url: url)
      Button {
        dismiss()
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.title)
          .symbolRenderingMode(.palette)
          .foregroundStyle(.white, .black.opacity(0.55))
      }
      .padding()
      .accessibilityLabel("关闭")
    }
  }
}

private struct ZoomableRemoteImage: View {
  let url: URL

  @State private var scale: CGFloat = 1
  @State private var lastScale: CGFloat = 1

  var body: some View {
    DownsampledRemoteImage(url: url, maxPixelSize: 4_096) { phase in
      switch phase {
      case .success(let image):
        image
          .resizable()
          .scaledToFit()
          .scaleEffect(scale)
          .gesture(
            MagnificationGesture()
              .onChanged { value in
                scale = min(max(lastScale * value, 1), 5)
              }
              .onEnded { _ in
                lastScale = scale
              }
          )
          .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
              scale = scale > 1 ? 1 : 2
              lastScale = scale
            }
          }
      case .failure:
        Image(systemName: "photo.badge.exclamationmark")
          .font(.largeTitle)
          .foregroundStyle(.white)
      default:
        ProgressView()
          .tint(.white)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
