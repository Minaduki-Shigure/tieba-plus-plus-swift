import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ContentImagePreviewPolicyTests: XCTestCase {
  func testAutomaticUsesHighDefinitionOnlyOnAvailableEconomicalNetworks() {
    for (snapshot, permitsHighDefinition) in representativeSnapshots {
      let result = ContentImagePreviewPolicy.resolved(
        preference: .automatic,
        networkSnapshot: snapshot
      )
      XCTAssertEqual(result.quality, permitsHighDefinition ? .highDefinition : .standard)
      XCTAssertEqual(result.networkAccess, permitsHighDefinition ? .economicalOnly : .unrestricted)
    }
  }

  func testExplicitQualityAndExistingDefaultRemainIndependentOfNetwork() {
    XCTAssertEqual(ContentImagePreviewQuality.defaultValue, .standard)
    for preference: ContentImagePreviewQuality in [.standard, .highDefinition] {
      for (snapshot, _) in representativeSnapshots {
        let result = ContentImagePreviewPolicy.resolved(
          preference: preference,
          networkSnapshot: snapshot
        )
        XCTAssertEqual(result.quality, preference)
        XCTAssertEqual(result.networkAccess, .unrestricted)
      }
    }
  }

  func testNetworkChangesReplaceSourcesWithoutChangingGalleryOriginal() throws {
    let thumbnail = try XCTUnwrap(URL(string: "https://img.example/standard.jpg"))
    let fullSize = try XCTUnwrap(URL(string: "https://img.example/large.jpg"))
    let original = try XCTUnwrap(URL(string: "https://img.example/original.jpg"))
    let changes: [(ContentMediaNetworkSnapshot, URL)] = [
      (.unknown, thumbnail),
      (snapshot(status: .available), fullSize),
      (snapshot(status: .available, isExpensive: true), thumbnail),
      (snapshot(status: .available), fullSize),
      (snapshot(status: .available, isConstrained: true), thumbnail),
      (snapshot(status: .unavailable), thumbnail),
    ]

    for (network, expectedURL) in changes {
      let policy = ContentImagePreviewPolicy.resolved(preference: .automatic, networkSnapshot: network)
      XCTAssertEqual(
        BrowseContentImageSourceResolver.previewURL(
          thumbnail: thumbnail,
          fullSize: fullSize,
          quality: policy.quality
        ),
        expectedURL
      )
      XCTAssertEqual(
        BrowseContentImageSourceResolver.galleryURL(
          thumbnail: thumbnail,
          fullSize: fullSize,
          original: original
        ),
        original
      )
    }
  }

  func testAutomaticHighDefinitionUsesExistingFallbacksWhenHigherQualityIsAbsent() throws {
    let thumbnail = try XCTUnwrap(URL(string: "https://img.example/standard.jpg"))
    let dynamic = try XCTUnwrap(URL(string: "https://img.example/animated.webp"))
    let policy = ContentImagePreviewPolicy.resolved(
      preference: .automatic,
      networkSnapshot: snapshot(status: .available)
    )
    XCTAssertEqual(
      BrowseContentImageSourceResolver.previewURL(
        thumbnail: thumbnail, fullSize: nil, quality: policy.quality
      ),
      thumbnail
    )
    XCTAssertEqual(
      BrowseContentImageSourceResolver.previewURL(
        thumbnail: thumbnail, fullSize: nil, dynamic: dynamic, quality: policy.quality
      ),
      dynamic
    )
  }

  func testUnresolvedAutomaticPreferenceFailsConservativelyToStandard() throws {
    let thumbnail = try XCTUnwrap(URL(string: "https://img.example/standard.jpg"))
    let fullSize = try XCTUnwrap(URL(string: "https://img.example/large.jpg"))
    XCTAssertEqual(
      BrowseContentImageSourceResolver.previewURL(
        thumbnail: thumbnail, fullSize: fullSize, quality: .automatic
      ),
      thumbnail
    )
  }

  func testAutomaticHighDefinitionRequestCannotEscapeToAnExpensivePath() throws {
    let request = try previewRequest()
    let policy = ContentImagePreviewPolicy.resolved(
      preference: .automatic,
      networkSnapshot: snapshot(status: .available)
    )
    // This policy is attached to the request selected on Wi-Fi. A path change
    // before the monitor publishes its next snapshot must not relax transport.
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .automatic,
        behavior: .automatic,
        lastObservedPolicy: .automatic,
        request: request,
        authorizedRequest: nil,
        networkAccess: policy.networkAccess
      ),
      .allowEconomicalNetwork(.preview)
    )
    let restricted = policy.networkAccess.applying(to: URLRequest(url: try XCTUnwrap(request.url)))
    XCTAssertFalse(restricted.allowsCellularAccess)
    XCTAssertFalse(restricted.allowsExpensiveNetworkAccess)
    XCTAssertFalse(restricted.allowsConstrainedNetworkAccess)
  }

  func testAdaptiveQualityPreservesTapToLoadAndDataSavingGates() throws {
    let request = try previewRequest()
    for access: RemoteImageNetworkAccess in [.unrestricted, .economicalOnly] {
      for policy: ContentMediaLoadPolicy in [.networkAware, .tapToLoad] {
        XCTAssertEqual(
          ContentRemoteImageLoadDecision.fetchPolicy(
            policy: policy,
            behavior: .userInitiated,
            lastObservedPolicy: policy,
            request: request,
            authorizedRequest: nil,
            networkAccess: access
          ),
          .cacheOnly(.preview)
        )
      }
    }
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .networkAware,
        behavior: .economicalNetworkOnly,
        lastObservedPolicy: .networkAware,
        request: request,
        authorizedRequest: nil,
        networkAccess: .unrestricted
      ),
      .allowEconomicalNetwork(.preview)
    )
  }

  func testExplicitTapRemainsAuthorizedButCannotAuthorizeAReplacementSource() throws {
    let request = try previewRequest()
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)
    state.authorize(request: request, policy: .tapToLoad, behavior: .userInitiated)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        behavior: .userInitiated,
        lastObservedPolicy: state.lastObservedPolicy,
        request: request,
        authorizedRequest: state.authorizedRequest,
        networkAccess: .economicalOnly
      ),
      .allowNetwork(.preview)
    )
    let replacement = ContentRemoteImageRequestIdentity(
      url: URL(string: "https://img.example/standard.jpg"), maxPixelSize: request.maxPixelSize
    )
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        behavior: .userInitiated,
        lastObservedPolicy: state.lastObservedPolicy,
        request: replacement,
        authorizedRequest: state.authorizedRequest,
        networkAccess: .unrestricted
      ),
      .cacheOnly(.preview)
    )
  }

  private func previewRequest() throws -> ContentRemoteImageRequestIdentity {
    ContentRemoteImageRequestIdentity(
      url: try XCTUnwrap(URL(string: "https://img.example/large.jpg")), maxPixelSize: 720
    )
  }

  private var representativeSnapshots: [(ContentMediaNetworkSnapshot, Bool)] {
    [
      (.unknown, false),
      (snapshot(status: .unavailable), false),
      (snapshot(status: .available), true),
      (snapshot(status: .available, isExpensive: true), false),
      (snapshot(status: .available, isConstrained: true), false),
      (snapshot(status: .available, isExpensive: true, isConstrained: true), false),
    ]
  }

  private func snapshot(
    status: ContentMediaNetworkSnapshot.Status,
    isExpensive: Bool = false,
    isConstrained: Bool = false
  ) -> ContentMediaNetworkSnapshot {
    ContentMediaNetworkSnapshot(
      status: status, isExpensive: isExpensive, isConstrained: isConstrained
    )
  }
}
