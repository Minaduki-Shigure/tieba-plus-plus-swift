import Foundation

enum RemoteVoiceDownloadPolicy {
  static let maximumResponseBytes: Int64 = 16 * 1_024 * 1_024

  static func exceedsLimit(
    totalBytesWritten: Int64,
    totalBytesExpected: Int64,
    maximumResponseBytes: Int64 = maximumResponseBytes
  ) -> Bool {
    totalBytesWritten > maximumResponseBytes
      || (totalBytesExpected > 0 && totalBytesExpected > maximumResponseBytes)
  }
}

enum RemoteVoiceDownloadError: Error, Equatable, LocalizedError {
  case invalidURL
  case invalidResponse
  case responseTooLarge
  case cannotPersistDownload

  var errorDescription: String? {
    switch self {
    case .invalidURL:
      "语音地址无效。"
    case .invalidResponse:
      "贴吧返回了无效的语音响应。"
    case .responseTooLarge:
      "语音文件超过 16 MiB 的安全上限。"
    case .cannotPersistDownload:
      "无法准备语音临时文件。"
    }
  }
}

protocol RemoteVoiceDownloading: Sendable {
  func download(from url: URL) async throws -> RemoteVoiceFileLease
}

final class RemoteVoiceFileLease: @unchecked Sendable {
  let fileURL: URL
  let sourceURL: URL
  let byteCount: Int64

  private let cleanupDirectoryURL: URL

  init(
    fileURL: URL,
    cleanupDirectoryURL: URL,
    sourceURL: URL,
    byteCount: Int64
  ) {
    self.fileURL = fileURL
    self.cleanupDirectoryURL = cleanupDirectoryURL
    self.sourceURL = sourceURL
    self.byteCount = byteCount
  }

  deinit {
    try? FileManager.default.removeItem(at: cleanupDirectoryURL)
  }
}

final class BoundedHTTPSRemoteVoiceTransport: RemoteVoiceDownloading, @unchecked Sendable {
  static let shared = BoundedHTTPSRemoteVoiceTransport()

  private let session: URLSession
  private let maximumResponseBytes: Int64
  private let temporaryDirectory: URL

  init(
    configuration: URLSessionConfiguration = .ephemeral,
    maximumResponseBytes: Int64 = RemoteVoiceDownloadPolicy.maximumResponseBytes,
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) {
    precondition(maximumResponseBytes > 0)
    session = URLSession(configuration: Self.hardenedConfiguration(from: configuration))
    self.maximumResponseBytes = maximumResponseBytes
    self.temporaryDirectory = temporaryDirectory
  }

  func download(from url: URL) async throws -> RemoteVoiceFileLease {
    guard VoicePlaybackURLPolicy.allows(url) else {
      throw RemoteVoiceDownloadError.invalidURL
    }

    let delegate = BoundedHTTPSRemoteVoiceTaskDelegate(
      maximumResponseBytes: maximumResponseBytes
    )
    let temporaryDownloadURL: URL
    let urlResponse: URLResponse
    do {
      (temporaryDownloadURL, urlResponse) = try await session.download(
        for: Self.request(from: url),
        delegate: delegate
      )
    } catch {
      if Task.isCancelled {
        throw CancellationError()
      }
      if delegate.exceededResponseLimit {
        throw RemoteVoiceDownloadError.responseTooLarge
      }
      throw error
    }
    defer { try? FileManager.default.removeItem(at: temporaryDownloadURL) }

    try Task.checkCancellation()
    guard
      let response = urlResponse as? HTTPURLResponse,
      response.statusCode == 200,
      response.value(forHTTPHeaderField: "Content-Range") == nil,
      Self.hasIdentityContentEncoding(response),
      let finalURL = response.url,
      finalURL == url,
      VoicePlaybackURLPolicy.allows(finalURL)
    else { throw RemoteVoiceDownloadError.invalidResponse }
    guard
      !RemoteVoiceDownloadPolicy.exceedsLimit(
        totalBytesWritten: 0,
        totalBytesExpected: response.expectedContentLength,
        maximumResponseBytes: maximumResponseBytes
      )
    else { throw RemoteVoiceDownloadError.responseTooLarge }

    let fileSize: Int64
    do {
      let values = try temporaryDownloadURL.resourceValues(forKeys: [.fileSizeKey])
      guard let measuredFileSize = values.fileSize else {
        throw RemoteVoiceDownloadError.cannotPersistDownload
      }
      fileSize = Int64(measuredFileSize)
    } catch let error as RemoteVoiceDownloadError {
      throw error
    } catch {
      throw RemoteVoiceDownloadError.cannotPersistDownload
    }
    guard fileSize > 0 else {
      throw RemoteVoiceDownloadError.invalidResponse
    }
    guard fileSize <= maximumResponseBytes else {
      throw RemoteVoiceDownloadError.responseTooLarge
    }
    try Task.checkCancellation()

    let leaseDirectory = temporaryDirectory
      .appendingPathComponent("TiebaPlusPlusRemoteVoices", isDirectory: true)
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
      throw RemoteVoiceDownloadError.cannotPersistDownload
    }

    if Task.isCancelled {
      try? FileManager.default.removeItem(at: leaseDirectory)
      throw CancellationError()
    }
    return RemoteVoiceFileLease(
      fileURL: persistedFileURL,
      cleanupDirectoryURL: leaseDirectory,
      sourceURL: finalURL,
      byteCount: fileSize
    )
  }

  static func hasIdentityContentEncoding(_ response: HTTPURLResponse) -> Bool {
    guard let value = response.value(forHTTPHeaderField: "Content-Encoding") else {
      return true
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
      .caseInsensitiveCompare("identity") == .orderedSame
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

  static func request(from url: URL) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    return request
  }
}

final class BoundedHTTPSRemoteVoiceTaskDelegate: NSObject,
  URLSessionDownloadDelegate, @unchecked Sendable
{
  private final class State: @unchecked Sendable {
    private let lock = NSLock()
    private var responseLimitExceeded = false

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
  }

  private let maximumResponseBytes: Int64
  private let state = State()

  var exceededResponseLimit: Bool {
    state.readResponseLimitExceeded()
  }

  init(maximumResponseBytes: Int64) {
    self.maximumResponseBytes = maximumResponseBytes
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(nil)
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
    guard
      !RemoteVoiceDownloadPolicy.exceedsLimit(
        totalBytesWritten: totalBytesWritten,
        totalBytesExpected: totalBytesExpectedToWrite,
        maximumResponseBytes: maximumResponseBytes
      )
    else {
      state.markResponseLimitExceeded()
      downloadTask.cancel()
      return
    }
  }

  func urlSession(
    _ session: URLSession,
    downloadTask: URLSessionDownloadTask,
    didFinishDownloadingTo location: URL
  ) {}
}
