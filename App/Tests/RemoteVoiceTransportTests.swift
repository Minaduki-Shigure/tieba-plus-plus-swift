import Foundation
import XCTest

@testable import TiebaPlusPlus

final class RemoteVoiceTransportTests: XCTestCase {
  func testDownloadPolicyChecksDeclaredAndObservedSizes() {
    XCTAssertFalse(
      RemoteVoiceDownloadPolicy.exceedsLimit(
        totalBytesWritten: 8,
        totalBytesExpected: 8,
        maximumResponseBytes: 8
      )
    )
    XCTAssertTrue(
      RemoteVoiceDownloadPolicy.exceedsLimit(
        totalBytesWritten: 9,
        totalBytesExpected: -1,
        maximumResponseBytes: 8
      )
    )
    XCTAssertTrue(
      RemoteVoiceDownloadPolicy.exceedsLimit(
        totalBytesWritten: 0,
        totalBytesExpected: 9,
        maximumResponseBytes: 8
      )
    )
  }

  func testHardenedConfigurationDisablesAmbientCredentialsCookiesAndCache() {
    let source = URLSessionConfiguration.default
    source.httpCookieStorage = .shared
    source.urlCredentialStorage = .shared
    source.httpShouldSetCookies = true
    source.httpCookieAcceptPolicy = .always
    source.urlCache = URLCache(memoryCapacity: 1_024, diskCapacity: 0, directory: nil)
    source.requestCachePolicy = .returnCacheDataElseLoad
    source.httpAdditionalHeaders = [
      "Authorization": "Bearer secret",
      "Cookie": "session=secret",
    ]

    let result = BoundedHTTPSRemoteVoiceTransport.hardenedConfiguration(from: source)

    XCTAssertNil(result.httpCookieStorage)
    XCTAssertNil(result.urlCredentialStorage)
    XCTAssertFalse(result.httpShouldSetCookies)
    XCTAssertEqual(result.httpCookieAcceptPolicy, .never)
    XCTAssertNil(result.urlCache)
    XCTAssertEqual(result.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(result.httpAdditionalHeaders)
  }

  func testRequestIsCredentialFreeUncachedGET() throws {
    var request = BoundedHTTPSRemoteVoiceTransport.request(from: voiceURL("request"))
    request.setValue(nil, forHTTPHeaderField: "Cookie")

    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(request.value(forHTTPHeaderField: "Accept"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.httpBody)
  }

  func testContentEncodingPolicyAcceptsOnlyAbsentOrIdentityEncoding() throws {
    let url = voiceURL("encoding")
    let absent = try XCTUnwrap(
      HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])
    )
    let identity = try XCTUnwrap(
      HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Encoding": " Identity "]
      )
    )
    let gzip = try XCTUnwrap(
      HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Encoding": "gzip"]
      )
    )

    XCTAssertTrue(BoundedHTTPSRemoteVoiceTransport.hasIdentityContentEncoding(absent))
    XCTAssertTrue(BoundedHTTPSRemoteVoiceTransport.hasIdentityContentEncoding(identity))
    XCTAssertFalse(BoundedHTTPSRemoteVoiceTransport.hasIdentityContentEncoding(gzip))
  }

  func testRedirectDelegateRejectsEveryRedirect() throws {
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let sourceURL = voiceURL("source")
    let task = session.downloadTask(with: sourceURL)
    defer { task.cancel() }
    let delegate = BoundedHTTPSRemoteVoiceTaskDelegate(maximumResponseBytes: 100)
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: sourceURL,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": voiceURL("target").absoluteString]
      )
    )
    let recorder = RemoteVoiceRedirectRecorder()

    delegate.urlSession(
      session,
      task: task,
      willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: voiceURL("target"))
    ) { request in
      recorder.record(request)
    }

    XCTAssertTrue(recorder.wasCalled)
    XCTAssertNil(recorder.request)
  }

  func testDownloadPersistsOnlyUntilLeaseRelease() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = makeTransport(temporaryDirectory: root)
    let requestedURL = voiceURL("success")

    var lease: RemoteVoiceFileLease? = try await transport.download(from: requestedURL)
    let leaseDirectory = try XCTUnwrap(lease).fileURL.deletingLastPathComponent()

    XCTAssertEqual(
      try Data(contentsOf: XCTUnwrap(lease).fileURL),
      RemoteVoiceURLProtocol.voiceData
    )
    XCTAssertEqual(try XCTUnwrap(lease).sourceURL, requestedURL)
    XCTAssertEqual(
      try XCTUnwrap(lease).byteCount,
      Int64(RemoteVoiceURLProtocol.voiceData.count)
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: leaseDirectory.path))

    lease = nil

    XCTAssertFalse(FileManager.default.fileExists(atPath: leaseDirectory.path))
  }

  func testDownloadRejectsHTTPFailureEmptyBodyAndOversize() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let normalTransport = makeTransport(temporaryDirectory: root)

    do {
      _ = try await normalTransport.download(from: voiceURL("not-found"))
      XCTFail("Expected invalid response")
    } catch RemoteVoiceDownloadError.invalidResponse {
      // Expected.
    }

    do {
      _ = try await normalTransport.download(from: voiceURL("empty"))
      XCTFail("Expected empty response rejection")
    } catch RemoteVoiceDownloadError.invalidResponse {
      // Expected.
    }

    do {
      _ = try await normalTransport.download(from: voiceURL("partial"))
      XCTFail("Expected partial response rejection")
    } catch RemoteVoiceDownloadError.invalidResponse {
      // Expected.
    }

    let boundedTransport = makeTransport(
      maximumResponseBytes: 8,
      temporaryDirectory: root
    )
    do {
      _ = try await boundedTransport.download(from: voiceURL("oversize"))
      XCTFail("Expected response-too-large")
    } catch RemoteVoiceDownloadError.responseTooLarge {
      // Expected.
    } catch is CancellationError {
      XCTFail("Policy cancellation must not become caller cancellation")
    }
  }

  func testDownloadAcceptsResponseWithoutDeclaredLength() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let lease = try await makeTransport(temporaryDirectory: root)
      .download(from: voiceURL("chunked"))

    XCTAssertEqual(try Data(contentsOf: lease.fileURL), RemoteVoiceURLProtocol.voiceData)
    XCTAssertEqual(lease.byteCount, Int64(RemoteVoiceURLProtocol.voiceData.count))
  }

  func testCallerCancellationRemainsCancellationError() async throws {
    let root = temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = makeTransport(temporaryDirectory: root)
    let task = Task {
      try await transport.download(from: voiceURL("pending"))
    }
    for _ in 0..<10 {
      await Task.yield()
    }

    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    }
  }

  private func makeTransport(
    maximumResponseBytes: Int64 = RemoteVoiceDownloadPolicy.maximumResponseBytes,
    temporaryDirectory: URL
  ) -> BoundedHTTPSRemoteVoiceTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RemoteVoiceURLProtocol.self]
    return BoundedHTTPSRemoteVoiceTransport(
      configuration: configuration,
      maximumResponseBytes: maximumResponseBytes,
      temporaryDirectory: temporaryDirectory
    )
  }

  private func voiceURL(_ identifier: String) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "tiebac.baidu.com"
    components.path = "/c/p/voice"
    components.queryItems = [
      URLQueryItem(name: "voice_md5", value: identifier),
      URLQueryItem(name: "play_from", value: "pb_voice_play"),
    ]
    return components.url!
  }

  private func temporaryRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("RemoteVoiceTransportTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}

private final class RemoteVoiceURLProtocol: URLProtocol, @unchecked Sendable {
  static let voiceData = Data([0x49, 0x44, 0x33, 0x04, 0, 0, 0, 0, 0, 0, 1])

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "tiebac.baidu.com"
      && request.url?.path == "/c/p/voice"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard
      let url = request.url,
      let identifier = URLComponents(url: url, resolvingAgainstBaseURL: false)?
        .queryItems?
        .first(where: { $0.name == "voice_md5" })?
        .value
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    if identifier == "pending" {
      return
    }

    let statusCode: Int
    switch identifier {
    case "not-found":
      statusCode = 404
    case "partial":
      statusCode = 206
    default:
      statusCode = 200
    }
    let body: Data
    switch identifier {
    case "empty":
      body = Data()
    case "oversize":
      body = Data(repeating: 0x41, count: 9)
    default:
      body = Self.voiceData
    }
    var headers = [
      "Content-Type": "audio/mpeg",
      "Content-Length": String(body.count),
    ]
    if identifier == "chunked" {
      headers.removeValue(forKey: "Content-Length")
    }
    if identifier == "partial" {
      headers["Content-Range"] = "bytes 0-10/100"
    }
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: headers
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if !body.isEmpty {
      client?.urlProtocol(self, didLoad: body)
    }
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class RemoteVoiceRedirectRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var didRecord = false
  private var storedRequest: URLRequest?

  var wasCalled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didRecord
  }

  var request: URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return storedRequest
  }

  func record(_ request: URLRequest?) {
    lock.lock()
    didRecord = true
    storedRequest = request
    lock.unlock()
  }
}
