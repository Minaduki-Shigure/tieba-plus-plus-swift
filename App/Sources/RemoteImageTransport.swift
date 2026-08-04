import Foundation

enum RemoteImageDownloadKind: Hashable, Sendable {
  case preview
  case original
}

enum RemoteImageNetworkAccess: Hashable, Sendable {
  case unrestricted
  case economicalOnly

  func applying(to request: URLRequest) -> URLRequest {
    var request = request
    let allowsRestrictedNetworks = self == .unrestricted
    request.allowsCellularAccess = allowsRestrictedNetworks
    request.allowsExpensiveNetworkAccess = allowsRestrictedNetworks
    request.allowsConstrainedNetworkAccess = allowsRestrictedNetworks
    return request
  }
}

struct RemoteImageDownloadProgress: Equatable, Sendable {
  let receivedByteCount: Int64
  let expectedByteCount: Int64?

  var fractionCompleted: Double? {
    guard
      receivedByteCount >= 0,
      let expectedByteCount,
      expectedByteCount > 0,
      receivedByteCount <= expectedByteCount
    else { return nil }
    return min(max(Double(receivedByteCount) / Double(expectedByteCount), 0), 1)
  }

  var percentageCompleted: Int? {
    guard
      receivedByteCount >= 0,
      let expectedByteCount,
      expectedByteCount > 0,
      receivedByteCount <= expectedByteCount
    else { return nil }
    if receivedByteCount == expectedByteCount {
      return 100
    }
    let product = receivedByteCount.multipliedFullWidth(by: 100)
    return Int(expectedByteCount.dividingFullWidth(product).quotient)
  }
}

struct RemoteImageDownloadLimits: Equatable, Sendable {
  static let standard = RemoteImageDownloadLimits(
    previewMaximumResponseBytes: RemoteImageDownloadPolicy.previewMaximumResponseBytes,
    originalMaximumResponseBytes: RemoteImageDownloadPolicy.originalMaximumResponseBytes
  )

  let previewMaximumResponseBytes: Int64
  let originalMaximumResponseBytes: Int64

  init(previewMaximumResponseBytes: Int64, originalMaximumResponseBytes: Int64) {
    precondition(previewMaximumResponseBytes > 0)
    precondition(originalMaximumResponseBytes > 0)
    self.previewMaximumResponseBytes = previewMaximumResponseBytes
    self.originalMaximumResponseBytes = originalMaximumResponseBytes
  }

  func maximumResponseBytes(for kind: RemoteImageDownloadKind) -> Int64 {
    switch kind {
    case .preview:
      previewMaximumResponseBytes
    case .original:
      originalMaximumResponseBytes
    }
  }
}

enum RemoteImageDownloadPolicy {
  static let previewMaximumResponseBytes: Int64 = 16 * 1_024 * 1_024
  static let originalMaximumResponseBytes: Int64 = 80 * 1_024 * 1_024

  // Retained for callers that still describe the original image as full size.
  static let fullSizeMaximumResponseBytes = originalMaximumResponseBytes

  static func kind(forMaxPixelSize maxPixelSize: Int) -> RemoteImageDownloadKind {
    maxPixelSize <= 720 ? .preview : .original
  }

  static func maximumResponseBytes(for maxPixelSize: Int) -> Int64 {
    RemoteImageDownloadLimits.standard.maximumResponseBytes(
      for: kind(forMaxPixelSize: maxPixelSize)
    )
  }

  static func exceedsLimit(
    totalBytesWritten: Int64,
    totalBytesExpected: Int64,
    maximumResponseBytes: Int64
  ) -> Bool {
    totalBytesWritten > maximumResponseBytes
      || (totalBytesExpected > 0 && totalBytesExpected > maximumResponseBytes)
  }
}

enum RemoteImageURLPolicy {
  static func allows(_ url: URL) -> Bool {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      components.scheme?.lowercased() == "https",
      let host = components.host,
      !host.isEmpty,
      components.user == nil,
      components.password == nil
    else { return false }
    return true
  }

  static func sanitizedRedirectRequest(
    _ request: URLRequest,
    networkAccess: RemoteImageNetworkAccess
  ) -> URLRequest? {
    guard let url = request.url, allows(url) else { return nil }
    var request = request
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    request.setValue(nil, forHTTPHeaderField: "Cookie")
    request.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
    return networkAccess.applying(to: request)
  }
}

enum RemoteImageDownloadError: Error, Equatable {
  case invalidURL
  case invalidResponse
  case responseTooLarge
  case cannotPersistDownload
}

protocol RemoteImageDownloading: Sendable {
  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess,
    onProgress: @escaping @Sendable (RemoteImageDownloadProgress) -> Void
  ) async throws -> RemoteImageFileLease
}

extension RemoteImageDownloading {
  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess,
    onProgress: @escaping @Sendable (RemoteImageDownloadProgress) -> Void
  ) async throws -> RemoteImageFileLease {
    try await download(from: url, kind: kind, networkAccess: networkAccess)
  }

  func download(from url: URL, kind: RemoteImageDownloadKind) async throws
    -> RemoteImageFileLease
  {
    try await download(from: url, kind: kind, networkAccess: .unrestricted)
  }
}

final class RemoteImageFileLease: @unchecked Sendable {
  let fileURL: URL
  let sourceURL: URL
  let mimeType: String?
  let suggestedFilename: String?
  let byteCount: Int64

  private let cleanupDirectoryURL: URL

  init(
    fileURL: URL,
    cleanupDirectoryURL: URL,
    sourceURL: URL,
    mimeType: String?,
    suggestedFilename: String?,
    byteCount: Int64
  ) {
    self.fileURL = fileURL
    self.cleanupDirectoryURL = cleanupDirectoryURL
    self.sourceURL = sourceURL
    self.mimeType = mimeType
    self.suggestedFilename = suggestedFilename
    self.byteCount = byteCount
  }

  deinit {
    try? FileManager.default.removeItem(at: cleanupDirectoryURL)
  }
}

final class BoundedHTTPSRemoteImageTransport: RemoteImageDownloading, @unchecked Sendable {
  static let shared = BoundedHTTPSRemoteImageTransport()

  private let session: URLSession
  private let limits: RemoteImageDownloadLimits
  private let temporaryDirectory: URL

  init(
    configuration: URLSessionConfiguration = .ephemeral,
    limits: RemoteImageDownloadLimits = .standard,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) {
    session = URLSession(configuration: Self.hardenedConfiguration(from: configuration))
    self.limits = limits
    self.temporaryDirectory = temporaryDirectory
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess
  ) async throws -> RemoteImageFileLease
  {
    try await download(
      from: url,
      kind: kind,
      networkAccess: networkAccess,
      onProgress: { _ in }
    )
  }

  func download(
    from url: URL,
    kind: RemoteImageDownloadKind,
    networkAccess: RemoteImageNetworkAccess,
    onProgress: @escaping @Sendable (RemoteImageDownloadProgress) -> Void
  ) async throws -> RemoteImageFileLease
  {
    guard RemoteImageURLPolicy.allows(url) else {
      throw RemoteImageDownloadError.invalidURL
    }

    let maximumResponseBytes = limits.maximumResponseBytes(for: kind)
    let delegate = BoundedHTTPSRemoteImageTaskDelegate(
      maximumResponseBytes: maximumResponseBytes,
      networkAccess: networkAccess,
      onProgress: onProgress
    )
    let temporaryDownloadURL: URL
    let urlResponse: URLResponse
    do {
      (temporaryDownloadURL, urlResponse) = try await session.download(
        for: Self.request(from: url, networkAccess: networkAccess),
        delegate: delegate
      )
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      if delegate.exceededResponseLimit {
        throw RemoteImageDownloadError.responseTooLarge
      }
      throw error
    }
    defer { try? FileManager.default.removeItem(at: temporaryDownloadURL) }

    try Task.checkCancellation()
    guard
      let response = urlResponse as? HTTPURLResponse,
      (200..<300).contains(response.statusCode),
      let finalURL = response.url,
      RemoteImageURLPolicy.allows(finalURL)
    else { throw RemoteImageDownloadError.invalidResponse }
    guard
      !RemoteImageDownloadPolicy.exceedsLimit(
        totalBytesWritten: 0,
        totalBytesExpected: response.expectedContentLength,
        maximumResponseBytes: maximumResponseBytes
      )
    else { throw RemoteImageDownloadError.responseTooLarge }

    let fileSize: Int64
    do {
      let values = try temporaryDownloadURL.resourceValues(forKeys: [.fileSizeKey])
      guard let measuredFileSize = values.fileSize else {
        throw RemoteImageDownloadError.cannotPersistDownload
      }
      fileSize = Int64(measuredFileSize)
    } catch let error as RemoteImageDownloadError {
      throw error
    } catch {
      throw RemoteImageDownloadError.cannotPersistDownload
    }
    guard fileSize <= maximumResponseBytes else {
      throw RemoteImageDownloadError.responseTooLarge
    }
    try Task.checkCancellation()

    let leaseDirectory = temporaryDirectory
      .appendingPathComponent("TiebaPlusPlusRemoteImages", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let persistedFileURL = leaseDirectory.appendingPathComponent("download", isDirectory: false)
    do {
      try FileManager.default.createDirectory(
        at: leaseDirectory,
        withIntermediateDirectories: true
      )
      try FileManager.default.moveItem(at: temporaryDownloadURL, to: persistedFileURL)
    } catch {
      try? FileManager.default.removeItem(at: leaseDirectory)
      throw RemoteImageDownloadError.cannotPersistDownload
    }

    if Task.isCancelled {
      try? FileManager.default.removeItem(at: leaseDirectory)
      throw CancellationError()
    }
    return RemoteImageFileLease(
      fileURL: persistedFileURL,
      cleanupDirectoryURL: leaseDirectory,
      sourceURL: finalURL,
      mimeType: response.mimeType,
      suggestedFilename: response.suggestedFilename,
      byteCount: fileSize
    )
  }

  static func hardenedConfiguration(
    from configuration: URLSessionConfiguration
  ) -> URLSessionConfiguration {
    let hardened = URLSessionConfiguration.ephemeral
    hardened.protocolClasses = configuration.protocolClasses
    hardened.httpCookieStorage = nil
    hardened.urlCredentialStorage = nil
    hardened.httpShouldSetCookies = false
    hardened.httpCookieAcceptPolicy = .never
    hardened.urlCache = nil
    hardened.requestCachePolicy = .reloadIgnoringLocalCacheData
    hardened.httpAdditionalHeaders = nil
    hardened.timeoutIntervalForRequest = 30
    hardened.timeoutIntervalForResource = 60
    return hardened
  }

  static func request(
    from url: URL,
    networkAccess: RemoteImageNetworkAccess
  ) -> URLRequest {
    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    return networkAccess.applying(to: request)
  }
}

private final class BoundedHTTPSRemoteImageTaskDelegate: NSObject,
  URLSessionDownloadDelegate, @unchecked Sendable
{
  private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var responseLimitExceeded = false
    private var lastReceivedByteCount: Int64?
    private var establishedExpectedByteCount: Int64?
    private var lastReportedPercentage: Int?
    private var reportedInitialIndeterminateProgress = false
    private var permanentlyIndeterminate = false

    func markResponseLimitExceeded() {
      lock.lock()
      responseLimitExceeded = true
      lock.unlock()
    }

    func readResponseLimitExceeded() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      return responseLimitExceeded
    }

    func progressToReport(
      receivedByteCount: Int64,
      expectedByteCount rawExpectedByteCount: Int64
    ) -> RemoteImageDownloadProgress? {
      lock.lock()
      defer { lock.unlock() }

      if let lastReceivedByteCount, receivedByteCount < lastReceivedByteCount {
        return nil
      }
      self.lastReceivedByteCount = receivedByteCount

      guard !permanentlyIndeterminate else { return nil }
      let observedExpectedByteCount = rawExpectedByteCount > 0
        ? rawExpectedByteCount
        : nil

      if let establishedExpectedByteCount {
        guard
          observedExpectedByteCount == establishedExpectedByteCount,
          receivedByteCount <= establishedExpectedByteCount
        else {
          permanentlyIndeterminate = true
          return RemoteImageDownloadProgress(
            receivedByteCount: receivedByteCount,
            expectedByteCount: nil
          )
        }

        let progress = RemoteImageDownloadProgress(
          receivedByteCount: receivedByteCount,
          expectedByteCount: establishedExpectedByteCount
        )
        guard let percentage = progress.percentageCompleted else { return nil }
        guard lastReportedPercentage != percentage else { return nil }
        lastReportedPercentage = percentage
        return progress
      }

      if let observedExpectedByteCount {
        guard receivedByteCount <= observedExpectedByteCount else {
          permanentlyIndeterminate = true
          return RemoteImageDownloadProgress(
            receivedByteCount: receivedByteCount,
            expectedByteCount: nil
          )
        }
        establishedExpectedByteCount = observedExpectedByteCount
        let progress = RemoteImageDownloadProgress(
          receivedByteCount: receivedByteCount,
          expectedByteCount: observedExpectedByteCount
        )
        lastReportedPercentage = progress.percentageCompleted
        return progress
      }

      guard !reportedInitialIndeterminateProgress else { return nil }
      reportedInitialIndeterminateProgress = true
      return RemoteImageDownloadProgress(
        receivedByteCount: receivedByteCount,
        expectedByteCount: nil
      )
    }
  }

  private let maximumResponseBytes: Int64
  private let networkAccess: RemoteImageNetworkAccess
  private let onProgress: @Sendable (RemoteImageDownloadProgress) -> Void
  private let state = State()

  var exceededResponseLimit: Bool {
    state.readResponseLimitExceeded()
  }

  init(
    maximumResponseBytes: Int64,
    networkAccess: RemoteImageNetworkAccess,
    onProgress: @escaping @Sendable (RemoteImageDownloadProgress) -> Void
  ) {
    self.maximumResponseBytes = maximumResponseBytes
    self.networkAccess = networkAccess
    self.onProgress = onProgress
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(
      RemoteImageURLPolicy.sanitizedRedirectRequest(
        request,
        networkAccess: networkAccess
      )
    )
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping @Sendable (
      URLSession.AuthChallengeDisposition, URLCredential?
    ) -> Void
  ) {
    if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
      completionHandler(.performDefaultHandling, nil)
    } else {
      completionHandler(.cancelAuthenticationChallenge, nil)
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didWriteData bytesWritten: Int64,
    totalBytesWritten: Int64,
    totalBytesExpectedToWrite: Int64
  ) {
    if RemoteImageDownloadPolicy.exceedsLimit(
      totalBytesWritten: totalBytesWritten,
      totalBytesExpected: totalBytesExpectedToWrite,
      maximumResponseBytes: maximumResponseBytes
    ) {
      state.markResponseLimitExceeded()
      downloadTask.cancel()
      return
    }
    if let progress = state.progressToReport(
      receivedByteCount: totalBytesWritten,
      expectedByteCount: totalBytesExpectedToWrite
    ) {
      onProgress(progress)
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
}
