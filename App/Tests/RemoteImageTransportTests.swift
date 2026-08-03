import Foundation
import XCTest

@testable import TiebaPlusPlus

final class RemoteImageTransportTests: XCTestCase {
  func testURLPolicyAllowsOnlyCredentialFreeHTTPSURLsWithHosts() throws {
    XCTAssertTrue(RemoteImageURLPolicy.allows(try XCTUnwrap(URL(string: "https://img.example/a"))))

    for value in [
      "http://img.example/a",
      "file:///tmp/image.jpg",
      "https:///image.jpg",
      "https://user@img.example/a",
      "https://user:password@img.example/a",
    ] {
      XCTAssertFalse(
        RemoteImageURLPolicy.allows(try XCTUnwrap(URL(string: value))),
        value
      )
    }
  }

  func testRedirectPolicyRejectsUnsafeTargetAndStripsCredentialsFromAllowedRequest() throws {
    var allowed = URLRequest(url: try XCTUnwrap(URL(string: "https://cdn.example/image")))
    allowed.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
    allowed.setValue("session=secret", forHTTPHeaderField: "Cookie")
    allowed.setValue("Basic secret", forHTTPHeaderField: "Proxy-Authorization")
    allowed.cachePolicy = .returnCacheDataElseLoad
    allowed.allowsCellularAccess = true
    allowed.allowsExpensiveNetworkAccess = true
    allowed.allowsConstrainedNetworkAccess = true

    let sanitized = try XCTUnwrap(
      RemoteImageURLPolicy.sanitizedRedirectRequest(
        allowed,
        networkAccess: .economicalOnly
      )
    )
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "Proxy-Authorization"))
    XCTAssertEqual(sanitized.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(sanitized.allowsCellularAccess)
    XCTAssertFalse(sanitized.allowsExpensiveNetworkAccess)
    XCTAssertFalse(sanitized.allowsConstrainedNetworkAccess)

    let cleartext = URLRequest(url: try XCTUnwrap(URL(string: "http://cdn.example/image")))
    XCTAssertNil(
      RemoteImageURLPolicy.sanitizedRedirectRequest(
        cleartext,
        networkAccess: .economicalOnly
      )
    )

    let credentialed = URLRequest(
      url: try XCTUnwrap(URL(string: "https://user@cdn.example/image"))
    )
    XCTAssertNil(
      RemoteImageURLPolicy.sanitizedRedirectRequest(
        credentialed,
        networkAccess: .economicalOnly
      )
    )
  }

  func testInitialRequestAppliesNetworkAccessFlags() throws {
    let url = try XCTUnwrap(URL(string: "https://img.example/image"))

    let unrestricted = BoundedHTTPSRemoteImageTransport.request(
      from: url,
      networkAccess: .unrestricted
    )
    XCTAssertEqual(unrestricted.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertTrue(unrestricted.allowsCellularAccess)
    XCTAssertTrue(unrestricted.allowsExpensiveNetworkAccess)
    XCTAssertTrue(unrestricted.allowsConstrainedNetworkAccess)

    let economical = BoundedHTTPSRemoteImageTransport.request(
      from: url,
      networkAccess: .economicalOnly
    )
    XCTAssertEqual(economical.cachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertFalse(economical.allowsCellularAccess)
    XCTAssertFalse(economical.allowsExpensiveNetworkAccess)
    XCTAssertFalse(economical.allowsConstrainedNetworkAccess)
  }

  func testUnrestrictedRedirectSanitizationRestoresUnrestrictedAccess() throws {
    var request = URLRequest(url: try XCTUnwrap(URL(string: "https://cdn.example/image")))
    request.allowsCellularAccess = false
    request.allowsExpensiveNetworkAccess = false
    request.allowsConstrainedNetworkAccess = false

    let sanitized = try XCTUnwrap(
      RemoteImageURLPolicy.sanitizedRedirectRequest(
        request,
        networkAccess: .unrestricted
      )
    )

    XCTAssertTrue(sanitized.allowsCellularAccess)
    XCTAssertTrue(sanitized.allowsExpensiveNetworkAccess)
    XCTAssertTrue(sanitized.allowsConstrainedNetworkAccess)
  }

  func testHardenedConfigurationDisablesAmbientStateAndCaching() {
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

    let result = BoundedHTTPSRemoteImageTransport.hardenedConfiguration(from: source)

    XCTAssertNil(result.httpCookieStorage)
    XCTAssertNil(result.urlCredentialStorage)
    XCTAssertFalse(result.httpShouldSetCookies)
    XCTAssertEqual(result.httpCookieAcceptPolicy, .never)
    XCTAssertNil(result.urlCache)
    XCTAssertEqual(result.requestCachePolicy, .reloadIgnoringLocalCacheData)
    XCTAssertNil(result.httpAdditionalHeaders)
  }

  func testDownloadPersistsIntoUniqueLeaseDirectoryUntilLeaseIsReleased() async throws {
    let root = makeTemporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = makeTransport(temporaryDirectory: root)
    let requestedURL = try XCTUnwrap(URL(string: "https://remote-image.test/success"))

    var lease: RemoteImageFileLease? = try await transport.download(
      from: requestedURL,
      kind: .preview
    )
    let leaseDirectory = try XCTUnwrap(lease).fileURL.deletingLastPathComponent()

    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(lease).fileURL), Data("image".utf8))
    XCTAssertEqual(try XCTUnwrap(lease).sourceURL, requestedURL)
    XCTAssertEqual(try XCTUnwrap(lease).mimeType, "image/jpeg")
    XCTAssertEqual(try XCTUnwrap(lease).byteCount, 5)
    XCTAssertNotNil(UUID(uuidString: leaseDirectory.lastPathComponent))
    XCTAssertTrue(FileManager.default.fileExists(atPath: leaseDirectory.path))

    lease = nil

    XCTAssertFalse(FileManager.default.fileExists(atPath: leaseDirectory.path))
  }

  func testEconomicalDownloadCarriesRestrictionsIntoURLSession() async throws {
    let root = makeTemporaryDirectoryURL()
    defer { try? FileManager.default.removeItem(at: root) }
    let transport = makeTransport(temporaryDirectory: root)
    let requestedURL = try XCTUnwrap(
      URL(string: "https://remote-image.test/economical-flags")
    )

    let lease = try await transport.download(
      from: requestedURL,
      kind: .preview,
      networkAccess: .economicalOnly
    )
    let recordedRequest = try XCTUnwrap(
      RemoteImageURLProtocol.recordedRequest(forPath: requestedURL.path)
    )

    XCTAssertFalse(recordedRequest.allowsCellularAccess)
    XCTAssertFalse(recordedRequest.allowsExpensiveNetworkAccess)
    XCTAssertFalse(recordedRequest.allowsConstrainedNetworkAccess)
    withExtendedLifetime(lease) {}
  }

  func testDownloadRejectsNonSuccessHTTPResponse() async throws {
    let transport = makeTransport(temporaryDirectory: makeTemporaryDirectoryURL())
    let url = try XCTUnwrap(URL(string: "https://remote-image.test/not-found"))

    do {
      _ = try await transport.download(from: url, kind: .preview)
      XCTFail("Expected an invalid response error")
    } catch RemoteImageDownloadError.invalidResponse {
      // Expected.
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testObservedOversizeIsNotReportedAsCallerCancellation() async throws {
    let transport = makeTransport(
      limits: RemoteImageDownloadLimits(
        previewMaximumResponseBytes: 8,
        originalMaximumResponseBytes: 16
      ),
      temporaryDirectory: makeTemporaryDirectoryURL()
    )
    let url = try XCTUnwrap(URL(string: "https://remote-image.test/oversize"))

    do {
      _ = try await transport.download(from: url, kind: .preview)
      XCTFail("Expected a response-too-large error")
    } catch RemoteImageDownloadError.responseTooLarge {
      // Expected.
    } catch is CancellationError {
      XCTFail("A policy cancellation must not be exposed as caller cancellation")
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testCallerCancellationRemainsCancellationError() async throws {
    let transport = makeTransport(temporaryDirectory: makeTemporaryDirectoryURL())
    let url = try XCTUnwrap(URL(string: "https://remote-image.test/pending"))
    let task = Task {
      try await transport.download(from: url, kind: .preview)
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
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func makeTransport(
    limits: RemoteImageDownloadLimits = .standard,
    temporaryDirectory: URL
  ) -> BoundedHTTPSRemoteImageTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RemoteImageURLProtocol.self]
    return BoundedHTTPSRemoteImageTransport(
      configuration: configuration,
      limits: limits,
      temporaryDirectory: temporaryDirectory
    )
  }

  private func makeTemporaryDirectoryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("RemoteImageTransportTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
  }
}

private final class RemoteImageURLProtocol: URLProtocol, @unchecked Sendable {
  private static let requestRecorder = RemoteImageRequestRecorder()

  static func recordedRequest(forPath path: String) -> URLRequest? {
    requestRecorder.request(forPath: path)
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "remote-image.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    Self.requestRecorder.record(request)
    guard let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.badURL))
      return
    }
    if url.path == "/pending" {
      return
    }

    let statusCode = url.path == "/not-found" ? 404 : 200
    let body: Data
    if url.path == "/oversize" {
      body = Data(repeating: 0x41, count: 9)
    } else {
      body = Data("image".utf8)
    }
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "image/jpeg"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class RemoteImageRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var requestsByPath = [String: URLRequest]()

  func record(_ request: URLRequest) {
    guard let path = request.url?.path else { return }
    lock.lock()
    requestsByPath[path] = request
    lock.unlock()
  }

  func request(forPath path: String) -> URLRequest? {
    lock.lock()
    defer { lock.unlock() }
    return requestsByPath[path]
  }
}
