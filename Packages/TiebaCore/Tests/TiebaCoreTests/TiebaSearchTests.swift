import Foundation
import XCTest

@testable import TiebaCore

final class TiebaSearchTests: XCTestCase {
  func testForumSearchDecodesObjectAndDictionaryShapesWithMixedIntegers() throws {
    let body = Data(
      #"""
      {
        "no": "0",
        "error": "success",
        "data": {
          "is_login": 0,
          "exactMatch": {
            "forum_id": 420740,
            "forum_name": "swift",
            "forum_name_show": "Swift",
            "avatar": "https://imgsa.baidu.com/forum/swift.jpg",
            "post_num_ori": "75346",
            "concern_num_ori": 40534,
            "intro": "Swift language",
            "slogan": "Write the code"
          },
          "fuzzyMatch": {
            "1": {
              "forum_id": "99",
              "forum_name": "swiftui",
              "forum_name_show": "SwiftUI",
              "avatar": "file:///private/avatar.png",
              "post_num_ori": 12,
              "concern_num_ori": "34"
            },
            "0": {
              "forum_id": 420740,
              "forum_name": "swift",
              "forum_name_show": "Swift"
            }
          },
          "ignored": "value"
        }
      }
      """#.utf8)

    let result = try TiebaSearchDecoder.forums(from: body)

    let exact = try XCTUnwrap(result.exactMatch)
    XCTAssertEqual(exact.id, 420740)
    XCTAssertEqual(exact.name, "swift")
    XCTAssertEqual(exact.displayName, "Swift")
    XCTAssertEqual(exact.postCount, 75346)
    XCTAssertEqual(exact.memberCount, 40534)
    XCTAssertEqual(exact.avatarURL?.scheme, "https")
    XCTAssertEqual(result.fuzzyMatches.map(\.name), ["swiftui"])
    XCTAssertNil(result.fuzzyMatches.first?.avatarURL)
    XCTAssertFalse(result.isLoggedIn)
  }

  func testForumSearchAcceptsEmptyExactArrayAndFuzzyArray() throws {
    let body = Data(
      #"""
      {
        "no": 0,
        "error": "success",
        "data": {
          "is_login": "0",
          "exactMatch": [],
          "fuzzyMatch": [
            {
              "forum_id": "7",
              "forum_name": "ios",
              "forum_name_show": "iOS",
              "post_num_ori": "100",
              "concern_num_ori": 200
            }
          ]
        }
      }
      """#.utf8)

    let result = try TiebaSearchDecoder.forums(from: body)

    XCTAssertNil(result.exactMatch)
    XCTAssertEqual(result.fuzzyMatches.map(\.id), [7])
  }

  func testThreadSearchMapsMixedValuesMediaAndPagination() throws {
    let body = Data(
      #"""
      {
        "no": 0,
        "error": "success",
        "data": {
          "is_login": 0,
          "current_page": "2",
          "has_more": 1,
          "post_list": [
            {
              "tid": "10867321468",
              "pid": 153721418012,
              "forum_id": "216",
              "forum_name": "汽车",
              "title": "Result title",
              "content": "Result excerpt",
              "time": 1700000000,
              "post_num": "158",
              "like_num": 285,
              "share_num": "6",
              "user": {
                "user_id": 4345924106,
                "user_name": "fallback",
                "show_nickname": "Display name",
                "portrait": "javascript:alert(1)"
              },
              "media": [
                {
                  "type": "pic",
                  "width": "560",
                  "height": 746,
                  "small_pic": "https://tiebapic.baidu.com/forum/small.jpg",
                  "big_pic": "https://tiebapic.baidu.com/forum/big.jpg"
                },
                {
                  "type": "pic",
                  "width": "1",
                  "height": "1",
                  "small_pic": "file:///private/image.jpg"
                },
                {
                  "type": "video",
                  "width": "1920",
                  "height": "1080",
                  "small_pic": "https://example.com/cover.jpg"
                }
              ],
              "unknown_future_field": {"value": true}
            }
          ]
        }
      }
      """#.utf8)

    let page = try TiebaSearchDecoder.threads(from: body, requestedPage: 1, pageSize: 15)

    XCTAssertEqual(page.pagination.currentPage, 2)
    XCTAssertEqual(page.pagination.pageSize, 15)
    XCTAssertTrue(page.pagination.hasMore)
    XCTAssertTrue(page.pagination.hasPrevious)
    XCTAssertFalse(page.isLoggedIn)
    let result = try XCTUnwrap(page.results.first)
    XCTAssertEqual(result.threadID, 10_867_321_468)
    XCTAssertEqual(result.firstPostID, 153_721_418_012)
    XCTAssertEqual(result.forumID, 216)
    XCTAssertEqual(result.authorName, "Display name")
    XCTAssertNil(result.authorPortraitURL)
    XCTAssertEqual(result.replyCount, 158)
    XCTAssertEqual(result.likeCount, 285)
    XCTAssertEqual(result.shareCount, 6)
    XCTAssertEqual(result.createdAt?.timeIntervalSince1970, 1_700_000_000)
    XCTAssertEqual(result.images.count, 1)
    XCTAssertEqual(result.images.first?.width, 560)
    XCTAssertEqual(result.images.first?.height, 746)
  }

  func testThreadSearchAcceptsNullMediaAndMissingOptionalFields() throws {
    let body = Data(
      #"""
      {
        "no": 0,
        "error": "success",
        "data": {
          "is_login": 0,
          "has_more": 0,
          "post_list": [
            {"tid": 1, "pid": "2", "title": "Minimal", "media": null}
          ]
        }
      }
      """#.utf8)

    let page = try TiebaSearchDecoder.threads(from: body, requestedPage: 3, pageSize: 20)

    XCTAssertEqual(page.pagination.currentPage, 3)
    XCTAssertFalse(page.pagination.hasMore)
    XCTAssertEqual(page.results.first?.images, [])
  }

  func testSearchMapsServerAndMalformedJSONErrors() throws {
    let serverError = Data(#"{"no":300003,"error":"internal error"}"#.utf8)
    XCTAssertThrowsError(try TiebaSearchDecoder.forums(from: serverError)) { error in
      XCTAssertEqual(
        error as? TiebaClientError,
        .server(code: 300003, message: "internal error")
      )
    }

    XCTAssertThrowsError(try TiebaSearchDecoder.forums(from: Data(#"{"unexpected":true}"#.utf8))) {
      error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }
  }
}
