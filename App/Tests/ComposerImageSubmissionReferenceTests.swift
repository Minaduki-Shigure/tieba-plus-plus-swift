import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ComposerImageSubmissionReferenceTests: XCTestCase {
  func testReferenceRoundTripsExactIdentityAndRedactsDiagnostics() throws {
    let reference = try XCTUnwrap(
      ComposerImageSubmissionReference(
        submissionID: referenceUUID(1),
        sessionRevision: referenceUUID(2)
      )
    )

    let encoded = try JSONEncoder().encode(reference)
    let decoded = try JSONDecoder().decode(
      ComposerImageSubmissionReference.self,
      from: encoded
    )

    XCTAssertEqual(decoded, reference)
    XCTAssertEqual(reference.description, "ComposerImageSubmissionReference(redacted)")
    XCTAssertTrue(Mirror(reflecting: reference).children.isEmpty)
    XCTAssertFalse(reference.description.contains(reference.submissionID.uuidString))
    XCTAssertFalse(reference.debugDescription.contains(reference.sessionRevision.uuidString))
  }

  func testReferenceRejectsZeroMissingAndUnknownFields() throws {
    let zero = "00000000-0000-0000-0000-000000000000"
    let zeroUUID = try XCTUnwrap(UUID(uuidString: zero))
    let submission = referenceUUID(1).uuidString
    let revision = referenceUUID(2).uuidString

    XCTAssertNil(
      ComposerImageSubmissionReference(
        submissionID: zeroUUID,
        sessionRevision: referenceUUID(2)
      )
    )
    XCTAssertNil(
      ComposerImageSubmissionReference(
        submissionID: referenceUUID(1),
        sessionRevision: zeroUUID
      )
    )
    for json in [
      #"{"submissionID":"\#(zero)","sessionRevision":"\#(revision)"}"#,
      #"{"submissionID":"\#(submission)","sessionRevision":"\#(zero)"}"#,
      #"{"submissionID":"\#(submission)"}"#,
      #"{"sessionRevision":"\#(revision)"}"#,
      #"{"submissionID":"\#(submission)","sessionRevision":"\#(revision)","extra":1}"#,
    ] {
      XCTAssertThrowsError(
        try JSONDecoder().decode(
          ComposerImageSubmissionReference.self,
          from: Data(json.utf8)
        )
      )
    }
  }
}

private func referenceUUID(_ value: UInt8) -> UUID {
  UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, value))
}
