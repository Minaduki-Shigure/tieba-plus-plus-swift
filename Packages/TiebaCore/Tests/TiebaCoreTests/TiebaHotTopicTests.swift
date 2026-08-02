import Foundation
import XCTest

@testable import TiebaCore

final class TiebaHotTopicTests: XCTestCase {
  func testListDecodesRankedTopicsAndDropsInvalidOrDuplicateEntries() throws {
    let body = Data(
      #"""
      {
        "no": "0",
        "error": "",
        "data": {
          "list": {
            "ret": [
              {
                "mul_id": "28356723",
                "mul_name": "First topic",
                "topic_info": {
                  "topic_desc": "  First description  ",
                  "head_pic": "http://tiebapic.baidu.com/forum/first.jpg",
                  "real_discuss_num": "2963760",
                  "topic_tag": 2,
                  "idx_bang": "1"
                }
              },
              {
                "mul_id": 28356723,
                "mul_name": "Duplicate topic",
                "topic_info": {"real_discuss_num": 1}
              },
              {
                "mul_id": 28356724,
                "mul_name": "Second topic",
                "topic_info": {
                  "topic_desc": "Second description",
                  "head_pic": "file:///private/topic.jpg",
                  "real_discuss_num": -5,
                  "topic_tag": "1"
                }
              },
              {"mul_id": 0, "mul_name": "Invalid"},
              {"mul_id": 28356725, "mul_name": "   "}
            ]
          },
          "ignored": true
        }
      }
      """#.utf8
    )

    let topics = try TiebaHotTopicDecoder.topics(from: body)

    XCTAssertEqual(topics.map(\.id), [28_356_723, 28_356_724])
    XCTAssertEqual(topics.first?.name, "First topic")
    XCTAssertEqual(topics.first?.description, "First description")
    XCTAssertEqual(topics.first?.imageURL?.scheme, "http")
    XCTAssertEqual(topics.first?.discussionCount, 2_963_760)
    XCTAssertEqual(topics.first?.rank, 1)
    XCTAssertEqual(topics.first?.tag, 2)
    XCTAssertNil(topics.last?.imageURL)
    XCTAssertEqual(topics.last?.discussionCount, 0)
    XCTAssertEqual(topics.last?.rank, 3)
    XCTAssertEqual(topics.last?.tag, 1)
  }

  func testDetailDecodesTopicForumsThreadsMediaAndCursor() throws {
    let body = Data(
      #"""
      {
        "no": 0,
        "error": "success",
        "data": {
          "topic_info": {
            "topic_id": "28356723",
            "topic_name": "First topic",
            "topic_desc": " Topic description ",
            "discuss_num": "2963760",
            "topic_image": "https://tiebapic.baidu.com/forum/topic.jpg",
            "idx_num": "2"
          },
          "relate_forum": [
            {
              "forum_id": "70579",
              "forum_name": "movie",
              "avatar": "http://imgsa.baidu.com/forum/movie.jpg",
              "desc": " Movie forum ",
              "member_num": "1000",
              "thread_num": 2000,
              "post_num": "3000"
            },
            {"forum_id": 70579, "forum_name": "duplicate"},
            {"forum_id": 0, "forum_name": "invalid"}
          ],
          "relate_thread": {
            "thread_list": [
              {
                "feed_id": "10911476537",
                "thread_info": {
                  "tid": 10911476537,
                  "first_post_id": "153784661519",
                  "forum_id": "70579",
                  "forum_name": "movie",
                  "title": "Thread title",
                  "abstract": "Thread excerpt",
                  "create_time": "1785586147",
                  "reply_num": "412",
                  "agree_num": 2957,
                  "share_num": "9",
                  "author": {
                    "id": "407101876",
                    "name": "fallback",
                    "show_nickname": "Display name",
                    "portrait": "javascript:alert(1)"
                  },
                  "media": [
                    {
                      "type": "pic",
                      "width": "560",
                      "height": 1084,
                      "small_pic": "https://tiebapic.baidu.com/forum/small.jpg",
                      "big_pic": "https://tiebapic.baidu.com/forum/big.jpg"
                    },
                    {
                      "type": "pic",
                      "width": 1,
                      "height": 1,
                      "small_pic": "file:///private/image.jpg"
                    },
                    {
                      "type": "video",
                      "small_pic": "https://example.com/video.jpg"
                    }
                  ]
                }
              },
              {
                "feed_id": 10911476538,
                "thread_info": {"tid": "10911476537", "title": "Duplicate"}
              },
              {
                "feed_id": "10911476539",
                "thread_info": {
                  "tid": 0,
                  "forum_id": 1,
                  "forum_name": "fallback",
                  "title": null,
                  "abstract": "Cursor fallback",
                  "author": {"name_show": "Alternate author"},
                  "media": null
                }
              },
              {"feed_id": 0, "thread_info": {"tid": 0}}
            ]
          },
          "has_more": "true",
          "wreq": {"pn": "2"}
        }
      }
      """#.utf8
    )

    let page = try TiebaHotTopicDecoder.page(
      from: body,
      requestedTopicID: 28_356_723,
      requestedTopicName: "Requested topic",
      requestedPage: 1,
      pageSize: 10
    )

    XCTAssertEqual(page.topic.id, 28_356_723)
    XCTAssertEqual(page.topic.name, "First topic")
    XCTAssertEqual(page.topic.description, "Topic description")
    XCTAssertEqual(page.topic.discussionCount, 2_963_760)
    XCTAssertEqual(page.topic.rank, 2)
    XCTAssertEqual(page.relatedForums.map(\.id), [70_579])
    XCTAssertEqual(page.relatedForums.first?.memberCount, 1_000)
    XCTAssertEqual(page.relatedForums.first?.avatarURL?.scheme, "http")
    XCTAssertEqual(page.threads.map(\.id), [10_911_476_537, 10_911_476_539])
    XCTAssertEqual(page.pagination.currentPage, 2)
    XCTAssertTrue(page.pagination.hasMore)
    XCTAssertTrue(page.pagination.hasPrevious)
    XCTAssertEqual(page.nextPageCursor, 10_911_476_539)

    let first = try XCTUnwrap(page.threads.first)
    XCTAssertEqual(first.firstPostID, 153_784_661_519)
    XCTAssertEqual(first.authorID, 407_101_876)
    XCTAssertEqual(first.authorName, "Display name")
    XCTAssertNil(first.authorPortraitURL)
    XCTAssertEqual(first.replyCount, 412)
    XCTAssertEqual(first.likeCount, 2_957)
    XCTAssertEqual(first.shareCount, 9)
    XCTAssertEqual(first.createdAt?.timeIntervalSince1970, 1_785_586_147)
    XCTAssertEqual(first.images.count, 1)
    XCTAssertEqual(first.images.first?.width, 560)
    XCTAssertEqual(first.images.first?.height, 1_084)
    XCTAssertEqual(page.threads.last?.authorName, "Alternate author")
  }

  func testDetailFallsBackToRequestedTopicAndStopsOnEmptyPage() throws {
    let body = Data(
      #"{"no":0,"error":"success","data":{"topic_info":{},"relate_thread":{"thread_list":[]},"has_more":1,"wreq":{}}}"#.utf8
    )

    let page = try TiebaHotTopicDecoder.page(
      from: body,
      requestedTopicID: 99,
      requestedTopicName: "Requested topic",
      requestedPage: 3,
      pageSize: 10
    )

    XCTAssertEqual(page.topic.id, 99)
    XCTAssertEqual(page.topic.name, "Requested topic")
    XCTAssertEqual(page.pagination.currentPage, 3)
    XCTAssertFalse(page.pagination.hasMore)
    XCTAssertTrue(page.threads.isEmpty)
    XCTAssertNil(page.nextPageCursor)
  }

  func testHotTopicErrorsPreserveServerSemanticsAndRejectMalformedSuccess() throws {
    let serverError = Data(
      #"{"no":"300003","error":"topic unavailable","data":true}"#.utf8
    )
    XCTAssertThrowsError(try TiebaHotTopicDecoder.topics(from: serverError)) { error in
      XCTAssertEqual(
        error as? TiebaClientError,
        .server(code: 300_003, message: "topic unavailable")
      )
    }

    let nullList = Data(#"{"no":0,"error":"","data":null}"#.utf8)
    XCTAssertTrue(try TiebaHotTopicDecoder.topics(from: nullList).isEmpty)

    let malformedList = Data(#"{"no":0,"error":"","data":{"list":true}}"#.utf8)
    XCTAssertThrowsError(try TiebaHotTopicDecoder.topics(from: malformedList)) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }

    let malformedDetail = Data(#"{"no":0,"error":"","data":{"has_more":false}}"#.utf8)
    XCTAssertThrowsError(
      try TiebaHotTopicDecoder.page(
        from: malformedDetail,
        requestedTopicID: 1,
        requestedTopicName: "topic",
        requestedPage: 1,
        pageSize: 10
      )
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON)
    }
  }
}
