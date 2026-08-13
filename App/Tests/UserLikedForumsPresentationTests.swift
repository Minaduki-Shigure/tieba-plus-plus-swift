import Foundation
import XCTest

@testable import TiebaPlusPlus

final class UserLikedForumsPresentationTests: XCTestCase {
  func testAvatarPolicyAllowsKnownTiebaCDNHosts() throws {
    for rawValue in [
      "https://himg.bdimg.com/sys/portrait/item/token",
      "https://imgsrc.baidu.com/forum/pic.jpg",
      "https://example.bcebos.com/forum/avatar.png",
    ] {
      let url = try XCTUnwrap(URL(string: rawValue))
      XCTAssertEqual(ForumAvatarDisplayPolicy.displayURL(url), url)
    }
  }

  func testAvatarPolicyRejectsUnrelatedHTTPSHostsAndSuffixConfusion() throws {
    for rawValue in [
      "https://example.com/avatar.png",
      "https://baidu.com.example.com/avatar.png",
      "https://notbaidu.com/avatar.png",
    ] {
      let url = try XCTUnwrap(URL(string: rawValue))
      XCTAssertNil(ForumAvatarDisplayPolicy.displayURL(url))
    }
  }

  func testAvatarPolicyRejectsInsecureOrCredentialBearingURLs() throws {
    for rawValue in [
      "http://himg.bdimg.com/avatar.png",
      "https://user@himg.bdimg.com/avatar.png",
      "https://himg.bdimg.com:8443/avatar.png",
    ] {
      let url = try XCTUnwrap(URL(string: rawValue))
      XCTAssertNil(ForumAvatarDisplayPolicy.displayURL(url))
    }
  }
}
