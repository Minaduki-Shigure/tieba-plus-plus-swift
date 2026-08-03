import XCTest

@testable import TiebaPlusPlus

final class UserNameFormatterTests: XCTestCase {
  func testSettingAndPreferredNameAvailabilityMatrix() {
    let cases: [(preferredName: String, username: String, showsBoth: Bool, expected: String)] = [
      ("昵称", "username", false, "昵称"),
      ("昵称", "username", true, "昵称(username)"),
      ("", "username", false, "username"),
      ("", "username", true, "username"),
    ]

    for testCase in cases {
      XCTAssertEqual(
        UserNameFormatter.displayName(
          preferredName: testCase.preferredName,
          username: testCase.username,
          showsBoth: testCase.showsBoth
        ),
        testCase.expected
      )
    }
  }

  func testTrimsBothNamesBeforeFormatting() {
    XCTAssertEqual(
      UserNameFormatter.displayName(
        preferredName: "  昵称\n",
        username: " username ",
        showsBoth: true
      ),
      "昵称(username)"
    )
    XCTAssertEqual(
      UserNameFormatter.displayName(
        preferredName: " 昵称 ",
        username: " \t ",
        showsBoth: true
      ),
      "昵称"
    )
    XCTAssertEqual(
      UserNameFormatter.displayName(
        preferredName: " \n ",
        username: " \t ",
        showsBoth: true
      ),
      ""
    )
  }

  func testSameNormalizedNameIsNotRepeated() {
    XCTAssertEqual(
      UserNameFormatter.displayName(
        preferredName: " same-name ",
        username: "same-name",
        showsBoth: true
      ),
      "same-name"
    )
  }
}
