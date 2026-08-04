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

  func testConfirmationCopyIdentifiesEachContentKind() throws {
    let cases: [(ContentAgreementKind, String, Int64?)] = [
      (.topic, "主题", nil),
      (.post, "楼层", nil),
      (.subpost, "楼中楼回复", 20),
    ]

    for (kind, objectName, parentPostID) in cases {
      let target = try XCTUnwrap(
        ContentAgreementTarget(
          kind: kind,
          forumID: 1,
          forumName: "Swift",
          threadID: 10,
          parentPostID: parentPostID,
          objectID: kind == .subpost ? 30 : 20
        )
      )
      let agree = PendingContentAgreementChange(target: target, targetAgreed: true)
      let withdraw = PendingContentAgreementChange(target: target, targetAgreed: false)

      XCTAssertEqual(agree.confirmationTitle, "点赞这个\(objectName)？")
      XCTAssertEqual(agree.actionTitle, "点赞")
      XCTAssertTrue(agree.confirmationMessage.contains(objectName))
      XCTAssertEqual(withdraw.confirmationTitle, "取消点赞这个\(objectName)？")
      XCTAssertEqual(withdraw.actionTitle, "取消点赞")
    }
  }
}
