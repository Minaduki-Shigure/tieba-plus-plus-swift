import SwiftUI

struct AvatarView: View {
  let url: URL?
  let name: String
  var size: CGFloat = 36

  var body: some View {
    AsyncImage(url: url) { phase in
      switch phase {
      case .success(let image):
        image
          .resizable()
          .scaledToFill()
      default:
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
