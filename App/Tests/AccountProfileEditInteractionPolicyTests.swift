import XCTest

@testable import TiebaPlusPlus

final class AccountProfileEditInteractionPolicyTests: XCTestCase {
  func testTextSaveRequiresNoAvatarPreparationOrPendingUpload() {
    XCTAssertFalse(
      AccountProfileEditInteractionPolicy.allowsTextSave(
        viewModelCanSave: false,
        isImportingAvatar: false,
        isCroppingAvatar: false,
        hasPendingAvatarUpload: false
      )
    )
    XCTAssertTrue(
      AccountProfileEditInteractionPolicy.allowsTextSave(
        viewModelCanSave: true,
        isImportingAvatar: false,
        isCroppingAvatar: false,
        hasPendingAvatarUpload: false
      )
    )

    for activity in 0..<3 {
      XCTAssertFalse(
        AccountProfileEditInteractionPolicy.allowsTextSave(
          viewModelCanSave: true,
          isImportingAvatar: activity == 0,
          isCroppingAvatar: activity == 1,
          hasPendingAvatarUpload: activity == 2
        )
      )
    }
  }

  func testAvatarWorkRequiresNavigationInterception() {
    XCTAssertTrue(
      AccountProfileEditInteractionPolicy.requiresNavigationInterception(
        viewModelRequiresInterception: true,
        isImportingAvatar: false,
        isCroppingAvatar: false,
        hasPendingAvatarUpload: false
      )
    )
    XCTAssertFalse(
      AccountProfileEditInteractionPolicy.requiresNavigationInterception(
        viewModelRequiresInterception: false,
        isImportingAvatar: false,
        isCroppingAvatar: false,
        hasPendingAvatarUpload: false
      )
    )
    XCTAssertTrue(
      AccountProfileEditInteractionPolicy.requiresNavigationInterception(
        viewModelRequiresInterception: false,
        isImportingAvatar: true,
        isCroppingAvatar: false,
        hasPendingAvatarUpload: false
      )
    )
    XCTAssertTrue(
      AccountProfileEditInteractionPolicy.requiresNavigationInterception(
        viewModelRequiresInterception: false,
        isImportingAvatar: false,
        isCroppingAvatar: true,
        hasPendingAvatarUpload: false
      )
    )
    XCTAssertTrue(
      AccountProfileEditInteractionPolicy.requiresNavigationInterception(
        viewModelRequiresInterception: false,
        isImportingAvatar: false,
        isCroppingAvatar: false,
        hasPendingAvatarUpload: true
      )
    )
  }
}
