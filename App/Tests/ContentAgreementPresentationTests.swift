import XCTest

@testable import TiebaPlusPlus

final class ContentAgreementPresentationTests: XCTestCase {
  func testSignedOutAndUnknownStatesKeepThePublicScoreReadOnly() {
    XCTAssertEqual(
      ContentAgreementControlPresentation(
        state: .signedOut,
        fallbackAgreeScore: 17
      ),
      .readOnly(score: 17)
    )
    XCTAssertEqual(
      ContentAgreementControlPresentation(
        state: .unknown,
        fallbackAgreeScore: -1
      ),
      .readOnly(score: 0)
    )
  }

  func testTransientStatesPreserveTheBestAvailableScore() {
    let previous = ContentAgreementSnapshot(isAgreed: true, agreeScore: 23)

    XCTAssertEqual(
      ContentAgreementControlPresentation(
        state: .loading(previous: previous),
        fallbackAgreeScore: 8
      ),
      .loading(score: 23)
    )
    XCTAssertEqual(
      ContentAgreementControlPresentation(
        state: .loading(previous: nil),
        fallbackAgreeScore: 8
      ),
      .loading(score: 8)
    )
    XCTAssertEqual(
      ContentAgreementControlPresentation(
        state: .ready(previous),
        fallbackAgreeScore: 8
      ),
      .ready(previous)
    )
    XCTAssertEqual(
      ContentAgreementControlPresentation(
        state: .mutating(previous: previous, targetAgreed: false),
        fallbackAgreeScore: 8
      ),
      .mutating(previous)
    )
    XCTAssertEqual(
      ContentAgreementControlPresentation(
        state: .failed(previous: previous),
        fallbackAgreeScore: 8
      ),
      .retry(score: 23)
    )
    XCTAssertEqual(
      ContentAgreementControlPresentation(
        state: .failed(previous: nil),
        fallbackAgreeScore: 8
      ),
      .retry(score: 8)
    )
  }
}
