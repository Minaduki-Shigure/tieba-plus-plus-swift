import Foundation
import TiebaCore

struct InlineEmoticonImageRequest: Hashable, Sendable {
  let urls: [URL]
  let fetchPolicy: DownsampledImageFetchPolicy

  init(urls: [URL], fetchPolicy: DownsampledImageFetchPolicy) {
    // A stable identity prevents repeated tokens or their order from restarting
    // the same paragraph's task. Only the compiled catalog may initiate a load.
    self.urls = Set(urls.filter(TiebaClassicEmoticonCatalog.allowsThumbnailURL))
      .sorted { $0.absoluteString < $1.absoluteString }
    self.fetchPolicy = fetchPolicy
  }
}

protocol InlineEmoticonImageLoading: Sendable {
  func image(
    at url: URL,
    fetchPolicy: DownsampledImageFetchPolicy
  ) async throws -> DownsampledImageAsset
}

struct DefaultInlineEmoticonImageLoader: InlineEmoticonImageLoading {
  let repository: DownsampledImageRepository

  init(repository: DownsampledImageRepository? = nil) {
    if let repository {
      self.repository = repository
      return
    }
    #if PERFORMANCE_HARNESS
      if ThreadScrollPerformanceScenario.requested?.usesInlineEmoticonFixture == true {
        self.repository = ThreadScrollPerformanceScenario.inlineEmoticonImageRepository
        return
      }
    #endif
    self.repository = .shared
  }

  func image(
    at url: URL,
    fetchPolicy: DownsampledImageFetchPolicy
  ) async throws -> DownsampledImageAsset {
    try await repository.image(
      at: url,
      maxPixelSize: 120,
      fetchPolicy: fetchPolicy,
      urlPolicy: .classicEmoticon,
      onProgress: nil
    )
  }
}

enum InlineEmoticonImageLoader {
  static func load(
    _ request: InlineEmoticonImageRequest,
    using loader: any InlineEmoticonImageLoading = DefaultInlineEmoticonImageLoader()
  ) async -> [URL: DownsampledImageAsset] {
    guard !Task.isCancelled, !request.urls.isEmpty else { return [:] }

    return await withTaskGroup(of: (URL, DownsampledImageAsset?).self) { group in
      var pendingURLs = request.urls.makeIterator()
      var images: [URL: DownsampledImageAsset] = [:]
      for _ in 0..<min(4, request.urls.count) {
        guard !Task.isCancelled, let url = pendingURLs.next() else { break }
        group.addTaskUnlessCancelled {
          await loadImage(at: url, fetchPolicy: request.fetchPolicy, using: loader)
        }
      }

      for await (url, image) in group {
        // A view may have changed content or network policy while this group
        // was awaiting cached data or a transport that finishes after cancel.
        guard !Task.isCancelled else {
          group.cancelAll()
          return [:]
        }
        if let image { images[url] = image }
        if let nextURL = pendingURLs.next() {
          group.addTaskUnlessCancelled {
            await loadImage(at: nextURL, fetchPolicy: request.fetchPolicy, using: loader)
          }
        }
      }
      return Task.isCancelled ? [:] : images
    }
  }

  private static func loadImage(
    at url: URL,
    fetchPolicy: DownsampledImageFetchPolicy,
    using loader: any InlineEmoticonImageLoading
  ) async -> (URL, DownsampledImageAsset?) {
    do {
      try Task.checkCancellation()
      let image = try await loader.image(at: url, fetchPolicy: fetchPolicy)
      try Task.checkCancellation()
      return (url, image)
    } catch {
      // A missing thumbnail leaves its text fallback intact without preventing
      // the other catalog images in this paragraph from appearing.
      return (url, nil)
    }
  }
}
