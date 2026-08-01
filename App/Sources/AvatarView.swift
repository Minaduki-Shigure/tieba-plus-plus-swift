import SwiftUI

struct AvatarView: View {
  let url: URL?
  let name: String
  var size: CGFloat = 36

  var body: some View {
    DownsampledRemoteImage(url: url, maxPixelSize: max(Int(size * 3), 128)) { phase in
      switch phase {
      case .success(let image):
        image
          .resizable()
          .scaledToFill()
      case .empty, .failure:
        ZStack {
          Color(uiColor: .secondarySystemFill)
          Text(String(name.prefix(1)))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .accessibilityHidden(true)
  }
}
