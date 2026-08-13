import SwiftUI

struct AvatarView: View {
  let url: URL?
  let name: String
  var size: CGFloat = 36
  var urlPolicy: DownsampledImageURLPolicy = .remoteImage

  init(
    url: URL?,
    name: String,
    size: CGFloat = 36,
    urlPolicy: DownsampledImageURLPolicy = .remoteImage
  ) {
    self.url = url
    self.name = name
    self.size = size
    self.urlPolicy = urlPolicy
  }

  var body: some View {
    DownsampledRemoteImage(
      url: url,
      maxPixelSize: max(Int(size * 3), 128),
      fetchPolicy: .allowNetwork(.preview),
      urlPolicy: urlPolicy
    ) { phase in
      switch phase {
      case .success(let asset, _):
        RemoteImageAssetView(asset: asset, contentMode: .fill)
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
