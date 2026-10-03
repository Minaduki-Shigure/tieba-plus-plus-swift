import Foundation

struct WallpaperRecommendation: Identifiable, Equatable, Sendable {
  let id: String
  let url: URL
  let title: String
}

enum WallpaperRecommendationPolicy {
  // Both URLs serve the same author's TiebaLite/wallpapers.json. The static fallback
  // was verified against the original Pages repository, not a replacement image feed.
  static let catalogURL = URL(string: "https://huancheng65.github.io/TiebaLite/wallpapers.json")!
  static let staticCatalogURL = URL(
    string:
      "https://raw.githubusercontent.com/HuanCheng65/huancheng65.github.io/master/TiebaLite/wallpapers.json"
  )!
  static let maximumCatalogBytes = 64 * 1_024
  static let maximumImageBytes = 32 * 1_024 * 1_024
  static let maximumItems = 64

  static func allowsCatalogURL(_ url: URL) -> Bool {
    url == catalogURL || url == staticCatalogURL
  }

  static func allowsImageURL(_ url: URL) -> Bool {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme == "https",
      components.host == "ftp.bmp.ovh",
      components.user == nil, components.password == nil, components.port == nil,
      components.query == nil, components.fragment == nil,
      components.percentEncodedPath.hasPrefix("/imgs/"),
      !components.percentEncodedPath.contains("%"),
      !components.percentEncodedPath.contains(".."),
      url.absoluteString.utf8.count <= 2_048
    else { return false }
    return true
  }

  static func decodeCatalog(_ data: Data) throws -> [WallpaperRecommendation] {
    guard data.count <= maximumCatalogBytes else {
      throw WallpaperRecommendationError.invalidCatalog
    }
    let strings = try JSONDecoder().decode([String].self, from: data)
    guard !strings.isEmpty, strings.count <= maximumItems else {
      throw WallpaperRecommendationError.invalidCatalog
    }
    var seen = Set<URL>()
    var result: [WallpaperRecommendation] = []
    for string in strings {
      guard let url = URL(string: string), allowsImageURL(url), seen.insert(url).inserted else {
        continue
      }
      result.append(
        WallpaperRecommendation(
          id: url.absoluteString, url: url, title: "壁纸 \(result.count + 1)"
        ))
    }
    guard !result.isEmpty else { throw WallpaperRecommendationError.invalidCatalog }
    return result
  }
}

enum WallpaperRecommendationError: LocalizedError, Equatable {
  case invalidCatalog
  case unavailable
  case invalidImage

  var errorDescription: String? {
    switch self {
    case .invalidCatalog: "推荐壁纸目录不可用，请稍后重试或选择本地照片。"
    case .unavailable: "暂时无法读取推荐壁纸，请重试或选择本地照片。"
    case .invalidImage: "这张推荐壁纸无法安全下载，请重试或选择其他图片。"
    }
  }
}

actor WallpaperRecommendationService {
  static let shared = WallpaperRecommendationService()

  private let catalogDownloader: any RemoteImageDownloading
  private let imageDownloader: any RemoteImageDownloading
  private var catalog: [WallpaperRecommendation] = []

  init(
    catalogDownloader: any RemoteImageDownloading = BoundedHTTPSRemoteImageTransport(
      limits: RemoteImageDownloadLimits(
        previewMaximumResponseBytes: Int64(WallpaperRecommendationPolicy.maximumCatalogBytes),
        originalMaximumResponseBytes: Int64(WallpaperRecommendationPolicy.maximumCatalogBytes)
      )
    ),
    imageDownloader: any RemoteImageDownloading = BoundedHTTPSRemoteImageTransport(
      limits: RemoteImageDownloadLimits(
        previewMaximumResponseBytes: Int64(WallpaperRecommendationPolicy.maximumImageBytes),
        originalMaximumResponseBytes: Int64(WallpaperRecommendationPolicy.maximumImageBytes)
      )
    )
  ) {
    self.catalogDownloader = catalogDownloader
    self.imageDownloader = imageDownloader
  }

  func fetchCatalog() async throws -> [WallpaperRecommendation] {
    for url in [
      WallpaperRecommendationPolicy.catalogURL, WallpaperRecommendationPolicy.staticCatalogURL,
    ] {
      try Task.checkCancellation()
      do {
        let file = try await catalogDownloader.download(
          from: url,
          kind: .preview,
          networkAccess: .unrestricted,
          redirectURLValidator: WallpaperRecommendationPolicy.allowsCatalogURL,
          onProgress: { _ in }
        )
        try Task.checkCancellation()
        let data = try read(file, maximumBytes: WallpaperRecommendationPolicy.maximumCatalogBytes)
        let result = try WallpaperRecommendationPolicy.decodeCatalog(data)
        try Task.checkCancellation()
        catalog = result
        return result
      } catch {
        if Task.isCancelled || error is CancellationError { throw CancellationError() }
      }
    }
    throw WallpaperRecommendationError.unavailable
  }

  func fetchImage(_ item: WallpaperRecommendation) async throws -> Data {
    try Task.checkCancellation()
    guard catalog.contains(item), WallpaperRecommendationPolicy.allowsImageURL(item.url) else {
      throw WallpaperRecommendationError.invalidImage
    }
    do {
      let file = try await imageDownloader.download(
        from: item.url,
        kind: .original,
        networkAccess: .unrestricted,
        redirectURLValidator: {
          $0 == item.url && WallpaperRecommendationPolicy.allowsImageURL($0)
        },
        onProgress: { _ in }
      )
      try Task.checkCancellation()
      let data = try read(file, maximumBytes: WallpaperRecommendationPolicy.maximumImageBytes)
      try Task.checkCancellation()
      return data
    } catch {
      if Task.isCancelled || error is CancellationError { throw CancellationError() }
      throw WallpaperRecommendationError.invalidImage
    }
  }

  private func read(_ file: RemoteImageFileLease, maximumBytes: Int) throws -> Data {
    guard file.byteCount > 0, file.byteCount <= maximumBytes else {
      throw WallpaperRecommendationError.invalidImage
    }
    let handle = try FileHandle(forReadingFrom: file.fileURL)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard !data.isEmpty, data.count <= maximumBytes, data.count == file.byteCount else {
      throw WallpaperRecommendationError.invalidImage
    }
    return data
  }
}
