import SwiftUI
import XCTest

@testable import TiebaPlusPlus

final class ContentRemoteImageTests: XCTestCase {
  @MainActor
  func testEnvironmentDefaultsToAutomaticLoading() {
    XCTAssertEqual(EnvironmentValues().contentMediaLoadPolicy, .automatic)
  }

  func testAutomaticPolicyAlwaysAllowsPreviewNetworking() throws {
    let request = try request(url: "https://img.example/image.jpg", maxPixelSize: 1_600)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .automatic,
        lastObservedPolicy: .tapToLoad,
        request: request,
        authorizedRequest: nil
      ),
      .allowNetwork(.preview)
    )
  }

  func testTapToLoadUsesCacheOnlyUntilExactRequestIsAuthorized() throws {
    let request = try request(url: "https://img.example/image.jpg", maxPixelSize: 720)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        lastObservedPolicy: .tapToLoad,
        request: request,
        authorizedRequest: nil
      ),
      .cacheOnly
    )
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        lastObservedPolicy: .tapToLoad,
        request: request,
        authorizedRequest: request
      ),
      .allowNetwork(.preview)
    )
  }

  func testManualAuthorizationIsBoundToURLAndPixelSize() throws {
    let authorized = try request(url: "https://img.example/image.jpg", maxPixelSize: 720)
    let changedURL = try request(url: "https://img.example/other.jpg", maxPixelSize: 720)
    let changedSize = try request(url: "https://img.example/image.jpg", maxPixelSize: 721)

    for candidate in [changedURL, changedSize] {
      XCTAssertEqual(
        ContentRemoteImageLoadDecision.fetchPolicy(
          policy: .tapToLoad,
          lastObservedPolicy: .tapToLoad,
          request: candidate,
          authorizedRequest: authorized
        ),
        .cacheOnly
      )
    }
  }

  func testStaleAuthorizationCannotSurviveAutomaticToTapTransitionFirstFrame() throws {
    let request = try request(url: "https://img.example/image.jpg", maxPixelSize: 720)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        lastObservedPolicy: .automatic,
        request: request,
        authorizedRequest: request
      ),
      .cacheOnly
    )
  }

  func testInvalidURLsCannotPresentManualNetworkAction() throws {
    let nilURL = ContentRemoteImageRequestIdentity(url: nil, maxPixelSize: 720)
    let cleartext = try request(url: "http://img.example/image.jpg", maxPixelSize: 720)
    let credentialed = try request(
      url: "https://user:password@img.example/image.jpg",
      maxPixelSize: 720
    )
    let secure = try request(url: "https://img.example/image.jpg", maxPixelSize: 720)

    XCTAssertTrue(
      ContentRemoteImageLoadDecision.permitsManualAction(
        policy: .tapToLoad,
        request: secure
      )
    )

    XCTAssertFalse(
      ContentRemoteImageLoadDecision.permitsManualAction(
        policy: .tapToLoad,
        request: nilURL
      )
    )
    XCTAssertFalse(
      ContentRemoteImageLoadDecision.permitsManualAction(
        policy: .tapToLoad,
        request: cleartext
      )
    )
    XCTAssertFalse(
      ContentRemoteImageLoadDecision.permitsManualAction(
        policy: .tapToLoad,
        request: credentialed
      )
    )
    XCTAssertFalse(
      ContentRemoteImageLoadDecision.permitsManualAction(
        policy: .automatic,
        request: secure
      )
    )
  }

  func testTaskIdentityChangesForPolicySwitchesAndRetries() {
    let automatic = ContentRemoteImageLoadDecision.reloadID(
      attempt: 0,
      policy: .automatic
    )
    let tapToLoad = ContentRemoteImageLoadDecision.reloadID(
      attempt: 0,
      policy: .tapToLoad
    )
    let retry = ContentRemoteImageLoadDecision.reloadID(
      attempt: 1,
      policy: .tapToLoad
    )

    XCTAssertNotEqual(automatic, tapToLoad)
    XCTAssertNotEqual(tapToLoad, retry)
  }

  func testFailedManualAttemptExhaustsAuthorizationAndRequiresAnotherTap() throws {
    let request = try request(url: "https://img.example/failure.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)
    state.authorize(request: request, policy: .tapToLoad)
    let attempt = try XCTUnwrap(state.authorizedAttempt)

    state.attemptCompleted(.failure, attempt: attempt)

    XCTAssertNil(state.authorizedAttempt)
    XCTAssertEqual(state.failedRequest, request)
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        lastObservedPolicy: state.lastObservedPolicy,
        request: request,
        authorizedRequest: state.authorizedRequest
      ),
      .cacheOnly
    )

    state.authorize(request: request, policy: .tapToLoad)

    XCTAssertNotNil(state.authorizedAttempt)
    XCTAssertNil(state.failedRequest)
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.storedFailurePresentation(
        policy: .tapToLoad,
        request: request,
        state: state
      ),
      .loading
    )
  }

  func testStoredFailureCannotOfferAnotherButtonDuringActiveManualAttempt() throws {
    let request = try request(url: "https://img.example/loading.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.storedFailurePresentation(
        policy: .tapToLoad,
        request: request,
        state: state
      ),
      .loadRequired
    )

    state.authorize(request: request, policy: .tapToLoad)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.storedFailurePresentation(
        policy: .tapToLoad,
        request: request,
        state: state
      ),
      .loading
    )

    let attempt = try XCTUnwrap(state.authorizedAttempt)
    state.attemptCompleted(.failure, attempt: attempt)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.storedFailurePresentation(
        policy: .tapToLoad,
        request: request,
        state: state
      ),
      .retry
    )
  }

  func testCancelledManualAttemptIsAlsoExhausted() throws {
    let request = try request(url: "https://img.example/cancelled.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)
    state.authorize(request: request, policy: .tapToLoad)
    let attempt = try XCTUnwrap(state.authorizedAttempt)

    state.attemptCompleted(.cancelled, attempt: attempt)

    XCTAssertNil(state.authorizedAttempt)
    XCTAssertEqual(state.failedRequest, request)
  }

  func testSuccessfulManualAttemptConsumesAuthorizationWithoutRecordingFailure() throws {
    let request = try request(url: "https://img.example/success.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)
    state.authorize(request: request, policy: .tapToLoad)
    let attempt = try XCTUnwrap(state.authorizedAttempt)

    state.attemptCompleted(.success, attempt: attempt)

    XCTAssertNil(state.authorizedAttempt)
    XCTAssertNil(state.failedRequest)
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        lastObservedPolicy: state.lastObservedPolicy,
        request: request,
        authorizedRequest: state.authorizedRequest
      ),
      .cacheOnly
    )
  }

  func testStaleAttemptCannotConsumeNewAuthorization() throws {
    let request = try request(url: "https://img.example/retry.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)
    state.authorize(request: request, policy: .tapToLoad)
    let staleAttempt = try XCTUnwrap(state.authorizedAttempt)
    state.authorize(request: request, policy: .tapToLoad)
    let currentAttempt = try XCTUnwrap(state.authorizedAttempt)

    state.attemptCompleted(.cancelled, attempt: staleAttempt)

    XCTAssertEqual(state.authorizedAttempt, currentAttempt)
    XCTAssertNil(state.failedRequest)
  }

  func testRequestAndPolicyChangesClearManualTerminalState() throws {
    let request = try request(url: "https://img.example/old.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)
    state.authorize(request: request, policy: .tapToLoad)
    let firstAttempt = try XCTUnwrap(state.authorizedAttempt)
    state.attemptCompleted(.failure, attempt: firstAttempt)
    XCTAssertEqual(state.failedRequest, request)

    state.requestChanged()
    XCTAssertNil(state.failedRequest)

    state.authorize(request: request, policy: .tapToLoad)
    let secondAttempt = try XCTUnwrap(state.authorizedAttempt)
    state.attemptCompleted(.failure, attempt: secondAttempt)
    state.synchronizePolicy(.automatic)

    XCTAssertNil(state.authorizedAttempt)
    XCTAssertNil(state.failedRequest)
    XCTAssertEqual(state.lastObservedPolicy, .automatic)
  }

  private func request(
    url value: String,
    maxPixelSize: Int
  ) throws -> ContentRemoteImageRequestIdentity {
    ContentRemoteImageRequestIdentity(
      url: try XCTUnwrap(URL(string: value)),
      maxPixelSize: maxPixelSize
    )
  }
}
