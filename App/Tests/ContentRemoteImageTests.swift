import SwiftUI
import XCTest

@testable import TiebaPlusPlus

final class ContentRemoteImageTests: XCTestCase {
  @MainActor
  func testEnvironmentDefaultsToAutomaticLoading() {
    XCTAssertEqual(EnvironmentValues().contentMediaLoadPolicy, .automatic)
    XCTAssertEqual(EnvironmentValues().contentMediaLoadBehavior, .automatic)
  }

  func testAutomaticPolicyAlwaysAllowsPreviewNetworking() throws {
    let request = try request(url: "https://img.example/image.jpg", maxPixelSize: 1_600)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .automatic,
        behavior: .automatic,
        lastObservedPolicy: .tapToLoad,
        request: request,
        authorizedRequest: nil
      ),
      .allowNetwork(.preview)
    )
  }

  func testEconomicalAutomaticPolicyRestrictsPreviewNetworking() throws {
    let request = try request(url: "https://img.example/image.jpg", maxPixelSize: 1_600)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .networkAware,
        behavior: .economicalNetworkOnly,
        lastObservedPolicy: .networkAware,
        request: request,
        authorizedRequest: nil
      ),
      .allowEconomicalNetwork(.preview)
    )
  }

  func testCurrentManualAuthorizationStaysUnrestrictedAcrossNetworkChanges() throws {
    let request = try request(url: "https://img.example/image.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.networkAware)
    state.authorize(
      request: request,
      policy: .networkAware,
      behavior: .userInitiated
    )

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .networkAware,
        behavior: .economicalNetworkOnly,
        lastObservedPolicy: state.lastObservedPolicy,
        request: request,
        authorizedRequest: state.authorizedRequest
      ),
      .allowNetwork(.preview)
    )
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.reloadID(
        attempt: state.reloadAttempt,
        behavior: .userInitiated,
        hasCurrentAuthorization: true
      ),
      ContentRemoteImageLoadDecision.reloadID(
        attempt: state.reloadAttempt,
        behavior: .economicalNetworkOnly,
        hasCurrentAuthorization: true
      )
    )
  }

  func testStaleAuthorizationCannotRelaxNewDataSavingPolicy() throws {
    let request = try request(url: "https://img.example/image.jpg", maxPixelSize: 720)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .networkAware,
        behavior: .economicalNetworkOnly,
        lastObservedPolicy: .tapToLoad,
        request: request,
        authorizedRequest: request
      ),
      .allowEconomicalNetwork(.preview)
    )
  }

  func testDataSavingGateUsesCacheUntilExactRequestIsAuthorized() throws {
    let request = try request(url: "https://img.example/image.jpg", maxPixelSize: 720)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .networkAware,
        behavior: .userInitiated,
        lastObservedPolicy: .networkAware,
        request: request,
        authorizedRequest: nil
      ),
      .cacheOnly(.preview)
    )
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .networkAware,
        behavior: .userInitiated,
        lastObservedPolicy: .networkAware,
        request: request,
        authorizedRequest: request
      ),
      .allowNetwork(.preview)
    )
  }

  func testTapToLoadUsesCacheOnlyUntilExactRequestIsAuthorized() throws {
    let request = try request(url: "https://img.example/image.jpg", maxPixelSize: 720)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        behavior: .userInitiated,
        lastObservedPolicy: .tapToLoad,
        request: request,
        authorizedRequest: nil
      ),
      .cacheOnly(.preview)
    )
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        behavior: .userInitiated,
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
          behavior: .userInitiated,
          lastObservedPolicy: .tapToLoad,
          request: candidate,
          authorizedRequest: authorized
        ),
        .cacheOnly(.preview)
      )
    }
  }

  func testStaleAuthorizationCannotSurviveAutomaticToTapTransitionFirstFrame() throws {
    let request = try request(url: "https://img.example/image.jpg", maxPixelSize: 720)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        behavior: .userInitiated,
        lastObservedPolicy: .automatic,
        request: request,
        authorizedRequest: request
      ),
      .cacheOnly(.preview)
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
        behavior: .userInitiated,
        request: secure
      )
    )

    XCTAssertFalse(
      ContentRemoteImageLoadDecision.permitsManualAction(
        behavior: .userInitiated,
        request: nilURL
      )
    )
    XCTAssertFalse(
      ContentRemoteImageLoadDecision.permitsManualAction(
        behavior: .userInitiated,
        request: cleartext
      )
    )
    XCTAssertFalse(
      ContentRemoteImageLoadDecision.permitsManualAction(
        behavior: .userInitiated,
        request: credentialed
      )
    )
    XCTAssertFalse(
      ContentRemoteImageLoadDecision.permitsManualAction(
        behavior: .automatic,
        request: secure
      )
    )
    XCTAssertFalse(
      ContentRemoteImageLoadDecision.permitsManualAction(
        behavior: .economicalNetworkOnly,
        request: secure
      )
    )
  }

  func testTaskIdentityChangesForPolicySwitchesAndRetries() {
    let automatic = ContentRemoteImageLoadDecision.reloadID(
      attempt: 0,
      behavior: .automatic,
      hasCurrentAuthorization: false
    )
    let economical = ContentRemoteImageLoadDecision.reloadID(
      attempt: 0,
      behavior: .economicalNetworkOnly,
      hasCurrentAuthorization: false
    )
    let tapToLoad = ContentRemoteImageLoadDecision.reloadID(
      attempt: 0,
      behavior: .userInitiated,
      hasCurrentAuthorization: false
    )
    let retry = ContentRemoteImageLoadDecision.reloadID(
      attempt: 1,
      behavior: .userInitiated,
      hasCurrentAuthorization: true
    )

    XCTAssertNotEqual(automatic, economical)
    XCTAssertNotEqual(economical, tapToLoad)
    XCTAssertNotEqual(automatic, tapToLoad)
    XCTAssertNotEqual(tapToLoad, retry)
  }

  func testFailedManualAttemptExhaustsAuthorizationAndRequiresAnotherTap() throws {
    let request = try request(url: "https://img.example/failure.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)
    state.authorize(request: request, policy: .tapToLoad, behavior: .userInitiated)
    let attempt = try XCTUnwrap(state.authorizedAttempt)

    state.attemptCompleted(.failure, attempt: attempt)

    XCTAssertNil(state.authorizedAttempt)
    XCTAssertEqual(state.failedRequest, request)
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        behavior: .userInitiated,
        lastObservedPolicy: state.lastObservedPolicy,
        request: request,
        authorizedRequest: state.authorizedRequest
      ),
      .cacheOnly(.preview)
    )

    state.authorize(request: request, policy: .tapToLoad, behavior: .userInitiated)

    XCTAssertNotNil(state.authorizedAttempt)
    XCTAssertNil(state.failedRequest)
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.storedFailurePresentation(
        policy: .tapToLoad,
        behavior: .userInitiated,
        request: request,
        state: state
      ),
      .loading
    )
  }

  func testFinishedManualAttemptReturnsToCurrentEconomicalPolicy() throws {
    let request = try request(url: "https://img.example/failure.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.networkAware)
    state.authorize(
      request: request,
      policy: .networkAware,
      behavior: .userInitiated
    )
    let attempt = try XCTUnwrap(state.authorizedAttempt)
    let activeReloadID = ContentRemoteImageLoadDecision.reloadID(
      attempt: state.reloadAttempt,
      behavior: .economicalNetworkOnly,
      hasCurrentAuthorization: true
    )

    state.attemptCompleted(.failure, attempt: attempt)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .networkAware,
        behavior: .economicalNetworkOnly,
        lastObservedPolicy: state.lastObservedPolicy,
        request: request,
        authorizedRequest: state.authorizedRequest
      ),
      .allowEconomicalNetwork(.preview)
    )
    XCTAssertNotEqual(
      activeReloadID,
      ContentRemoteImageLoadDecision.reloadID(
        attempt: state.reloadAttempt,
        behavior: .economicalNetworkOnly,
        hasCurrentAuthorization: false
      )
    )
  }

  func testStoredFailureCannotOfferAnotherButtonDuringActiveManualAttempt() throws {
    let request = try request(url: "https://img.example/loading.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.storedFailurePresentation(
        policy: .tapToLoad,
        behavior: .userInitiated,
        request: request,
        state: state
      ),
      .loadRequired
    )

    state.authorize(request: request, policy: .tapToLoad, behavior: .userInitiated)

    XCTAssertEqual(
      ContentRemoteImageLoadDecision.storedFailurePresentation(
        policy: .tapToLoad,
        behavior: .userInitiated,
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
        behavior: .userInitiated,
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
    state.authorize(request: request, policy: .tapToLoad, behavior: .userInitiated)
    let attempt = try XCTUnwrap(state.authorizedAttempt)

    state.attemptCompleted(.cancelled, attempt: attempt)

    XCTAssertNil(state.authorizedAttempt)
    XCTAssertEqual(state.failedRequest, request)
  }

  func testSuccessfulManualAttemptConsumesAuthorizationWithoutRecordingFailure() throws {
    let request = try request(url: "https://img.example/success.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)
    state.authorize(request: request, policy: .tapToLoad, behavior: .userInitiated)
    let attempt = try XCTUnwrap(state.authorizedAttempt)

    state.attemptCompleted(.success, attempt: attempt)

    XCTAssertNil(state.authorizedAttempt)
    XCTAssertNil(state.failedRequest)
    XCTAssertEqual(
      ContentRemoteImageLoadDecision.fetchPolicy(
        policy: .tapToLoad,
        behavior: .userInitiated,
        lastObservedPolicy: state.lastObservedPolicy,
        request: request,
        authorizedRequest: state.authorizedRequest
      ),
      .cacheOnly(.preview)
    )
  }

  func testStaleAttemptCannotConsumeNewAuthorization() throws {
    let request = try request(url: "https://img.example/retry.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)
    state.authorize(request: request, policy: .tapToLoad, behavior: .userInitiated)
    let staleAttempt = try XCTUnwrap(state.authorizedAttempt)
    state.authorize(request: request, policy: .tapToLoad, behavior: .userInitiated)
    let currentAttempt = try XCTUnwrap(state.authorizedAttempt)

    state.attemptCompleted(.cancelled, attempt: staleAttempt)

    XCTAssertEqual(state.authorizedAttempt, currentAttempt)
    XCTAssertNil(state.failedRequest)
  }

  func testRequestAndPolicyChangesClearManualTerminalState() throws {
    let request = try request(url: "https://img.example/old.jpg", maxPixelSize: 720)
    var state = ContentRemoteImageLoadState()
    state.synchronizePolicy(.tapToLoad)
    state.authorize(request: request, policy: .tapToLoad, behavior: .userInitiated)
    let firstAttempt = try XCTUnwrap(state.authorizedAttempt)
    state.attemptCompleted(.failure, attempt: firstAttempt)
    XCTAssertEqual(state.failedRequest, request)

    state.requestChanged()
    XCTAssertNil(state.failedRequest)

    state.authorize(request: request, policy: .tapToLoad, behavior: .userInitiated)
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
