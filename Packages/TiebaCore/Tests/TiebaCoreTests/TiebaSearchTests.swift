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
    XCTAssertEqual(result.id, "thread:10867321468")
    XCTAssertEqual(result.firstPostID, 153_721_418_012)
    XCTAssertEqual(result.matchedPostID, 153_721_418_012)
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
    XCTAssertEqual(result.target, .thread)
    XCTAssertNil(result.mainPost)
    XCTAssertNil(result.postInfo)
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

  func testForumPostSearchPreservesThreadReplyAndCommentUnionShapes() throws {
    let body = Data(
      #"""
      {
        "no": 0,
        "error": "success",
        "data": {
          "current_page": 1,
          "has_more": 0,
          "post_list": [
            {
              "tid": "42",
              "pid": "100",
              "cid": "0",
              "title": "Thread match",
              "content": "Opening post",
              "type": 1,
              "user": {
                "user_id": "1",
                "user_name": "thread-author",
                "show_nickname": "Thread Author"
              }
            },
            {
              "tid": "42",
              "pid": "201",
              "cid": "0",
              "title": "Reply match",
              "content": "Matched floor reply",
              "type": 2,
              "user": {
                "user_id": "2",
                "user_name": "reply-author",
                "show_nickname": "Reply Author"
              },
              "main_post": {
                "tid": 42,
                "title": "Thread match",
                "content": "Opening post",
                "post_num": "89",
                "like_num": 12,
                "share_num": "3",
                "user": {
                  "user_id": 1,
                  "user_name": "thread-author",
                  "show_nickname": "Thread Author",
                  "portrait": "https://himg.bdimg.com/sys/portrait/item/thread-author"
                }
              }
            },
            {
              "tid": 42,
              "pid": 202,
              "cid": "301",
              "title": "Comment match",
              "content": "Matched nested reply",
              "type": 2,
              "user": {
                "user_id": 3,
                "user_name": "comment-author",
                "show_nickname": "Comment Author"
              },
              "main_post": {
                "tid": 42,
                "title": "Thread match",
                "content": "Opening post",
                "user": {"user_id": 1, "show_nickname": "Thread Author"}
              },
              "post_info": {
                "tid": "42",
                "pid": "202",
                "title": "Parent floor",
                "content": "Parent floor content",
                "user": {
                  "user_id": "4",
                  "user_name": "parent-author",
                  "show_nickname": "Parent Author",
                  "portrait": "javascript:alert(1)"
                }
              }
            }
          ]
        }
      }
      """#.utf8)

    let page = try TiebaSearchDecoder.threads(from: body, requestedPage: 1, pageSize: 20)

    XCTAssertEqual(page.results.count, 3)
    XCTAssertEqual(page.results.map(\.threadID), [42, 42, 42])
    XCTAssertEqual(
      page.results.map(\.id),
      ["thread:42", "post:42:201", "comment:42:202:301"]
    )
    XCTAssertEqual(Set(page.results.map(\.id)).count, page.results.count)
    XCTAssertEqual(page.results[0].target, .thread)
    XCTAssertNil(page.results[0].mainPost)
    XCTAssertNil(page.results[0].postInfo)

    XCTAssertEqual(page.results[1].target, .post(201))
    XCTAssertEqual(page.results[1].firstPostID, 0)
    XCTAssertEqual(page.results[1].matchedPostID, 201)
    XCTAssertEqual(page.results[1].mainPost?.threadID, 42)
    XCTAssertNil(page.results[1].mainPost?.postID)
    XCTAssertEqual(page.results[1].mainPost?.title, "Thread match")
    XCTAssertEqual(page.results[1].mainPost?.authorName, "Thread Author")
    XCTAssertEqual(page.results[1].mainPost?.replyCount, 89)
    XCTAssertEqual(page.results[1].mainPost?.likeCount, 12)
    XCTAssertEqual(page.results[1].mainPost?.shareCount, 3)
    XCTAssertEqual(
      page.results[1].mainPost?.authorPortraitURL?.absoluteString,
      "https://himg.bdimg.com/sys/portrait/item/thread-author"
    )

    XCTAssertEqual(page.results[2].target, .comment(postID: 202, commentID: 301))
    XCTAssertEqual(page.results[2].firstPostID, 0)
    XCTAssertEqual(page.results[2].matchedPostID, 202)
    XCTAssertEqual(page.results[2].postInfo?.postID, 202)
    XCTAssertEqual(page.results[2].postInfo?.excerpt, "Parent floor content")
    XCTAssertEqual(page.results[2].postInfo?.authorID, 4)
    XCTAssertNil(page.results[2].postInfo?.authorPortraitURL)
  }

  func testUserSearchDecodesFlexibleCollectionsAndDeduplicatesExactMatch() throws {
    let body = Data(
      #"""
      {
        "no": "0",
        "error": "success",
        "data": {
          "pn": 1,
          "has_more": 0,
          "exactMatch": {
            "id": "88897",
            "name": "swift",
            "show_nickname": "Swift User",
            "user_nickname": "Alternate",
            "portrait": "https://gss0.bdstatic.com/avatar.jpg",
            "intro": "  Exact introduction  ",
            "fans_num": "104W"
          },
          "fuzzyMatch": {
            "2": {
              "id": 9,
              "name": "fallback-name",
              "show_nickname": "",
              "user_nickname": "Alternate Name",
              "portrait": "tb.1.portrait-token",
              "intro": "Related user"
            },
            "1": {
              "id": 88897,
              "name": "duplicate-exact",
              "show_nickname": "Duplicate"
            },
            "3": {
              "id": 17596400272242,
              "name": "large-uid",
              "show_nickname": "Large UID",
              "portrait": "file:///private/avatar.png"
            },
            "4": {
              "id": "10",
              "name": "",
              "show_nickname": "Nickname Only"
            }
          }
        }
      }
      """#.utf8)

    let result = try TiebaSearchDecoder.users(from: body)

    let exact = try XCTUnwrap(result.exactMatch)
    XCTAssertEqual(exact.id, 88_897)
    XCTAssertEqual(exact.username, "swift")
    XCTAssertEqual(exact.preferredName, "Swift User")
    XCTAssertEqual(exact.introduction, "Exact introduction")
    XCTAssertEqual(exact.portrait, "https://gss0.bdstatic.com/avatar.jpg")
    XCTAssertEqual(result.fuzzyMatches.map(\.id), [9, 17_596_400_272_242, 10])
    XCTAssertEqual(result.fuzzyMatches.first?.preferredName, "Alternate Name")
    XCTAssertEqual(result.fuzzyMatches.first?.portrait, "tb.1.portrait-token")
    XCTAssertEqual(
      result.fuzzyMatches.first(where: { $0.id == 17_596_400_272_242 })?.portrait,
      "file:///private/avatar.png"
    )
    XCTAssertEqual(result.fuzzyMatches.last?.username, "")
    XCTAssertEqual(result.fuzzyMatches.last?.preferredName, "Nickname Only")
  }

  func testUserSearchAcceptsEmptyArraysNullDataAndDropsInvalidUsers() throws {
    let emptyBody = Data(
      #"{"no":0,"error":"success","data":{"exactMatch":[],"fuzzyMatch":[]}}"#.utf8)
    let nullBody = Data(#"{"no":0,"error":"success","data":null}"#.utf8)
    let arrayBody = Data(
      #"{"no":0,"error":"success","data":{"exactMatch":[],"fuzzyMatch":[{"id":"7","name":"","show_nickname":"Nickname"}]}}"#.utf8)
    let invalidBody = Data(
      #"{"no":0,"error":"success","data":{"exactMatch":{"id":0,"name":"invalid"},"fuzzyMatch":[{"id":"7","name":""}]}}"#.utf8)

    for body in [emptyBody, nullBody, invalidBody] {
      let result = try TiebaSearchDecoder.users(from: body)
      XCTAssertNil(result.exactMatch)
      XCTAssertTrue(result.fuzzyMatches.isEmpty)
    }

    let arrayResult = try TiebaSearchDecoder.users(from: arrayBody)
    XCTAssertNil(arrayResult.exactMatch)
    XCTAssertEqual(arrayResult.fuzzyMatches.map(\.id), [7])
    XCTAssertEqual(arrayResult.fuzzyMatches.first?.preferredName, "Nickname")
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
    XCTAssertThrowsError(try TiebaSearchDecoder.users(from: serverError)) { error in
      XCTAssertEqual(
        error as? TiebaClientError,
        .server(code: 300003, message: "internal error")
      )
    }
    let malformedUsers = Data(
      #"{"no":0,"error":"success","data":{"exactMatch":true,"fuzzyMatch":[]}}"#.utf8)
    XCTAssertThrowsError(try TiebaSearchDecoder.users(from: malformedUsers)) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }
  }
}
