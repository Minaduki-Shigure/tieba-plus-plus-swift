import Foundation
import XCTest

@testable import TiebaCore

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

final class TiebaPicturePageRequestFactoryTests: XCTestCase {
  private let factory = TiebaRequestFactory(configuration: .init())
  private let pictureID = String(repeating: "a", count: 40)

  func testNextRequestUsesExactAnonymousSignedFieldSet() throws {
    let request = try factory.picturePage(
      forumID: 2_432_903,
      forumName: " minecraft ",
      threadID: 6_639_694_648,
      cursor: try cursor(),
      direction: .next,
      onlyThreadAuthor: false
    )
    let fields = try formFields(request)

    XCTAssertEqual(request.url?.absoluteString, "https://c.tieba.baidu.com/c/f/pb/picpage")
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertFalse(request.httpShouldHandleCookies)
    XCTAssertEqual(
      request.value(forHTTPHeaderField: "Content-Type"),
      "application/x-www-form-urlencoded"
    )
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(
      Set(fields.keys),
      Set([
        "_client_type", "_client_version", "forum_id", "from", "kw", "next",
        "not_see_lz", "obj_type", "page_name", "pic_id", "pic_index", "prev",
        "q_type", "sign", "subapp_type", "tid",
      ])
    )
    XCTAssertEqual(fields["_client_type"], "2")
    XCTAssertEqual(fields["_client_version"], "7.2.0.0")
    XCTAssertEqual(fields["forum_id"], "2432903")
    XCTAssertEqual(fields["from"], "1021636m")
    XCTAssertEqual(fields["kw"], "minecraft")
    XCTAssertEqual(fields["next"], "10")
    XCTAssertEqual(fields["not_see_lz"], "1")
    XCTAssertEqual(fields["obj_type"], "pb")
    XCTAssertEqual(fields["page_name"], "PB")
    XCTAssertEqual(fields["pic_id"], pictureID)
    XCTAssertEqual(fields["pic_index"], "1")
    XCTAssertEqual(fields["prev"], "0")
    XCTAssertEqual(fields["q_type"], "2")
    XCTAssertEqual(fields["subapp_type"], "mini")
    XCTAssertEqual(fields["tid"], "6639694648")
    XCTAssertEqual(fields["sign"], "8b0b86b479d25bc1bc605e9b5c14d414")

    let unsigned = fields.filter { $0.key != "sign" }.map { ($0.key, $0.value) }
    XCTAssertEqual(fields["sign"], TiebaFormSigner.signature(for: unsigned))
    for forbidden in [
      "BDUSS", "bdusstoken", "stoken", "Cookie", "CUID", "tieba_cuid", "IMEI",
      "phone_imei", "client_id", "client_user_token", "user_id", "scr_h", "scr_w",
      "timestamp", "model", "net_type",
    ] {
      XCTAssertNil(fields[forbidden], forbidden)
    }
  }

  func testPreviousAuthorOnlyRequestUsesVerifiedReverseSemantics() throws {
    let request = try factory.picturePage(
      forumID: 2_432_903,
      forumName: "minecraft",
      threadID: 6_639_694_648,
      cursor: try cursor(overallIndex: 9),
      direction: .previous,
      onlyThreadAuthor: true
    )
    let fields = try formFields(request)

    XCTAssertEqual(fields["next"], "0")
    XCTAssertEqual(fields["prev"], "10")
    XCTAssertEqual(fields["not_see_lz"], "0")
    XCTAssertEqual(fields["pic_index"], "9")
  }

  func testFormEncodingPreservesForumNamePlus() throws {
    let request = try factory.picturePage(
      forumID: 1,
      forumName: "C++",
      threadID: 2,
      cursor: try cursor(),
      direction: .next,
      onlyThreadAuthor: false
    )
    let rawBody = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)

    XCTAssertTrue(rawBody.contains("kw=C%2B%2B"))
    XCTAssertEqual(try formFields(request)["kw"], "C++")
  }

  func testRequestRejectsInvalidArgumentsAndHeaderInjection() throws {
    XCTAssertThrowsError(
      try factory.picturePage(
        forumID: 0, forumName: "x", threadID: 1, cursor: try cursor(), direction: .next,
        onlyThreadAuthor: false)
    )
    XCTAssertThrowsError(
      try factory.picturePage(
        forumID: 1, forumName: "x", threadID: 0, cursor: try cursor(), direction: .next,
        onlyThreadAuthor: false)
    )
    XCTAssertThrowsError(
      try factory.picturePage(
        forumID: 1, forumName: " \n ", threadID: 1, cursor: try cursor(), direction: .next,
        onlyThreadAuthor: false)
    )
    XCTAssertThrowsError(
      try factory.picturePage(
        forumID: 1, forumName: String(repeating: "a", count: 101), threadID: 1,
        cursor: try cursor(), direction: .next, onlyThreadAuthor: false)
    )

    let injected = TiebaRequestFactory(
      configuration: .init(userAgent: "client\r\nCookie: secret")
    )
    XCTAssertThrowsError(
      try injected.picturePage(
        forumID: 1, forumName: "x", threadID: 1, cursor: try cursor(), direction: .next,
        onlyThreadAuthor: false)
    )
  }

  func testPictureCursorAcceptsOnlyStrictBaiduJPGURLs() throws {
    for rawValue in [
      "http://tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg",
      "https://imgsrc.baidu.com/forum/pic/item/\(pictureID).jpg?tbpicau=2026-08-15-05_abc123",
      "https://imgsa.baidu.com/forum/w%3D960/sign=abc/\(pictureID).jpg",
      "https://c.hiphotos.baidu.com/forum/w%3D960/sign=abc/\(pictureID).jpg",
    ] {
      let cursor = TiebaPicturePageCursor(imageURL: try XCTUnwrap(URL(string: rawValue)))
      XCTAssertEqual(cursor?.pictureID, pictureID, rawValue)
      XCTAssertEqual(cursor?.overallIndex, 1, rawValue)
    }
    XCTAssertNotNil(
      TiebaPicturePageCursor(
        imageURL: try XCTUnwrap(
          URL(string: "https://tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg")
        ),
        overallIndex: 10_000
      )
    )
    XCTAssertEqual(
      TiebaPicturePageCursor(serverPictureID: pictureID, overallIndex: 9)?.pictureID,
      pictureID
    )
    XCTAssertNil(
      TiebaPicturePageCursor(serverPictureID: pictureID.uppercased(), overallIndex: 9)
    )
    XCTAssertNil(TiebaPicturePageCursor(serverPictureID: "short", overallIndex: 9))
    XCTAssertNil(TiebaPicturePageCursor(serverPictureID: pictureID, overallIndex: 0))
    XCTAssertNil(TiebaPicturePageCursor(serverPictureID: pictureID, overallIndex: 10_001))
  }

  func testPictureCursorRejectsUntrustedOrAmbiguousURLs() throws {
    let invalidURLs = [
      "https://example.com/forum/pic/item/\(pictureID).jpg",
      "https://tiebapic.baidu.com.example.com/forum/pic/item/\(pictureID).jpg",
      "https://user@tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg",
      "https://tiebapic.baidu.com:443/forum/pic/item/\(pictureID).jpg",
      "https://tiebapic.baidu.com./forum/pic/item/\(pictureID).jpg",
      "ftp://tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg",
      "https://tiebapic.baidu.com/not-forum/pic/item/\(pictureID).jpg",
      "https://tiebapic.baidu.com/forum//item/\(pictureID).jpg",
      "https://tiebapic.baidu.com/forum/%2e%2e/item/\(pictureID).jpg",
      "https://tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg/extra",
      "https://tiebapic.baidu.com/forum/pic/item/\(pictureID.uppercased()).jpg",
      "https://tiebapic.baidu.com/forum/pic/item/\(pictureID).png",
      "https://tiebapic.baidu.com/forum/pic/item/\(String(repeating: "a", count: 39)).jpg",
      "https://tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg?",
      "https://tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg?size=large",
      "https://tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg?tbpicau=",
      "https://tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg?tbpicau=abc&tbpicau=def",
      "https://tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg#fragment",
    ]
    for rawValue in invalidURLs {
      guard let url = URL(string: rawValue) else { continue }
      XCTAssertNil(TiebaPicturePageCursor(imageURL: url), rawValue)
    }

    let validURL = try XCTUnwrap(
      URL(string: "https://tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg")
    )
    XCTAssertNil(TiebaPicturePageCursor(imageURL: validURL, overallIndex: 0))
    XCTAssertNil(TiebaPicturePageCursor(imageURL: validURL, overallIndex: 10_001))
  }

  func testPicturePageEndpointRedirectPolicyIsExactSameOriginHTTPS() throws {
    let source = try XCTUnwrap(URL(string: "https://c.tieba.baidu.com/c/f/pb/picpage"))
    let sameOrigin = try XCTUnwrap(URL(string: "https://c.tieba.baidu.com/c/f/pb/picpage2"))
    let downgrade = try XCTUnwrap(URL(string: "http://c.tieba.baidu.com/c/f/pb/picpage"))
    let crossOrigin = try XCTUnwrap(URL(string: "https://tiebac.baidu.com/c/f/pb/picpage"))
    let suffixAttack = try XCTUnwrap(URL(string: "https://c.tieba.baidu.com.example.com/x"))

    XCTAssertTrue(TiebaPicturePageEndpointPolicy.allows(source))
    XCTAssertTrue(TiebaPicturePageEndpointPolicy.allowsRedirect(from: source, to: sameOrigin))
    XCTAssertTrue(TiebaRedirectPolicy.sameOrigin.allows(from: source, to: sameOrigin))
    XCTAssertFalse(TiebaRedirectPolicy.sameOrigin.allows(from: source, to: downgrade))
    XCTAssertFalse(TiebaRedirectPolicy.sameOrigin.allows(from: source, to: crossOrigin))
    XCTAssertFalse(TiebaPicturePageEndpointPolicy.allows(suffixAttack))
    XCTAssertFalse(
      TiebaPicturePageEndpointPolicy.allows(
        URL(string: "https://c.tieba.baidu.com:443/c/f/pb/picpage")
      )
    )
  }

  private func cursor(overallIndex: Int = 1) throws -> TiebaPicturePageCursor {
    try XCTUnwrap(
      TiebaPicturePageCursor(
        imageURL: XCTUnwrap(
          URL(string: "https://tiebapic.baidu.com/forum/pic/item/\(pictureID).jpg")
        ),
        overallIndex: overallIndex
      )
    )
  }
}

final class TiebaPicturePageDecoderTests: XCTestCase {
  private let forumID: Int64 = 2_432_903

  func testDecodesBoundedNumericResponseAndNormalizesKnownMediaHTTP() throws {
    let first = picture(overallIndex: 1, id: pictureID("a"), sourceID: pictureID("b"))
    let second = picture(
      overallIndex: 2,
      id: pictureID("c"),
      sourceID: pictureID("d"),
      longPicture: "1",
      offersOriginal: 1
    )
    let page = try TiebaPicturePageDecoder.page(
      from: response(total: 3, pictures: [first, second]),
      expectedForumID: forumID
    )

    XCTAssertEqual(page.forumID, forumID)
    XCTAssertEqual(page.forumName, "minecraft")
    XCTAssertEqual(page.totalPictureCount, 3)
    XCTAssertEqual(page.pictures.count, 2)
    XCTAssertFalse(page.hasPrevious)
    XCTAssertTrue(page.hasNext)
    XCTAssertEqual(page.pictures[0].pictureID, pictureID("a"))
    XCTAssertEqual(page.pictures[0].cursor.pictureID, pictureID("a"))
    XCTAssertEqual(page.pictures[0].originalURL.scheme, "https")
    XCTAssertEqual(page.pictures[0].originalURL.host, "tiebapic.baidu.com")
    XCTAssertTrue(page.pictures[0].originalURL.lastPathComponent.hasPrefix(pictureID("b")))
    XCTAssertEqual(page.pictures[0].thumbnailURL?.scheme, "https")
    XCTAssertEqual(page.pictures[0].fullSizeURL?.scheme, "https")
    XCTAssertEqual(page.pictures[0].width, 463)
    XCTAssertEqual(page.pictures[0].height, 466)
    XCTAssertEqual(page.pictures[0].originalByteCount, 308_325)
    XCTAssertEqual(page.pictures[0].postID, 131_740_410_382)
    XCTAssertFalse(page.pictures[0].isLongPicture)
    XCTAssertFalse(page.pictures[0].offersOriginal)
    XCTAssertTrue(page.pictures[1].isLongPicture)
    XCTAssertTrue(page.pictures[1].offersOriginal)
  }

  func testAcceptsObservedDecimalStringRepresentations() throws {
    let item = picture(
      overallIndex: "1",
      id: pictureID("a"),
      sourceID: pictureID("b"),
      width: "463",
      height: "466",
      size: "308325",
      postID: "131740410382",
      longPicture: false,
      offersOriginal: "true"
    )
    let page = try TiebaPicturePageDecoder.page(
      from: response(
        total: "1",
        pictures: [item],
        errorCode: "0",
        responseForumID: "2432903"
      ),
      expectedForumID: forumID
    )

    XCTAssertEqual(page.pictures.count, 1)
    XCTAssertFalse(page.hasPrevious)
    XCTAssertFalse(page.hasNext)
    XCTAssertTrue(page.pictures[0].offersOriginal)
  }

  func testBlockedPicturesAreDiscardedWithoutRequiringImagePayload() throws {
    let blocked: [String: Any] = [
      "overall_index": 1,
      "is_blocked_pic": "1",
      "post_id": 0,
      "img": "redacted",
    ]
    let page = try TiebaPicturePageDecoder.page(
      from: response(
        total: 2,
        pictures: [blocked, picture(overallIndex: 2, id: pictureID("c"))]
      ),
      expectedForumID: forumID
    )

    XCTAssertEqual(page.pictures.map(\.overallIndex), [2])
    XCTAssertFalse(page.hasPrevious)
    XCTAssertFalse(page.hasNext)
  }

  func testAllowsObservedInclusiveContinuationWindows() throws {
    let previousWindow = try TiebaPicturePageDecoder.page(
      from: response(
        total: 257,
        pictures: (20...30).map {
          picture(overallIndex: $0, id: String(format: "%040x", $0))
        }
      ),
      expectedForumID: forumID
    )
    XCTAssertEqual(previousWindow.pictures.map(\.overallIndex), Array(20...30))
    XCTAssertTrue(previousWindow.hasPrevious)
    XCTAssertTrue(previousWindow.hasNext)

    let nextWindow = try TiebaPicturePageDecoder.page(
      from: response(
        total: 257,
        pictures: (30...39).map {
          picture(overallIndex: $0, id: String(format: "%040x", $0))
        }
      ),
      expectedForumID: forumID
    )
    XCTAssertEqual(nextWindow.pictures.map(\.overallIndex), Array(30...39))
  }

  func testServerErrorDoesNotRequireSuccessPayload() throws {
    let body = try JSONSerialization.data(withJSONObject: [
      "error_code": "4",
      "error_msg": "denied",
    ])

    XCTAssertThrowsError(
      try TiebaPicturePageDecoder.page(from: body, expectedForumID: forumID)
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .server(code: 4, message: "denied"))
    }
  }

  func testRejectsMalformedEnvelopeAndBounds() throws {
    try assertInvalid(Data("not-json".utf8))
    try assertInvalid(try JSONSerialization.data(withJSONObject: ["error_msg": "missing code"]))
    try assertInvalid(response(total: 0, pictures: []))
    try assertInvalid(response(total: 10_001, pictures: []))
    try assertInvalid(response(total: 1, pictures: [], responseForumID: 1))
    try assertInvalid(response(total: 1.5, pictures: []))
    try assertInvalid(response(total: true, pictures: []))
    let thirtyPictures = (1...30).map {
      picture(overallIndex: $0, id: String(format: "%040x", $0))
    }
    let initialPage = try TiebaPicturePageDecoder.page(
      from: response(total: 257, pictures: thirtyPictures),
      expectedForumID: forumID
    )
    XCTAssertEqual(initialPage.pictures.count, 30)
    XCTAssertTrue(initialPage.hasNext)

    try assertInvalid(
      response(
        total: 51,
        pictures: (1...51).map {
          picture(overallIndex: $0, id: String(format: "%040x", $0))
        }
      )
    )
  }

  func testRejectsMalformedPictureIdentifiersIndexesAndDuplicates() throws {
    try assertInvalid(
      response(total: 1, pictures: [picture(overallIndex: 0, id: pictureID("a"))])
    )
    try assertInvalid(
      response(total: 1, pictures: [picture(overallIndex: 2, id: pictureID("a"))])
    )
    try assertInvalid(
      response(total: 1, pictures: [picture(overallIndex: 1, id: pictureID("A"))])
    )
    try assertInvalid(
      response(total: 1, pictures: [picture(overallIndex: 1, id: "short")])
    )
    let repeatedPicturePage = try TiebaPicturePageDecoder.page(
      from: response(
        total: 2,
        pictures: [
          picture(overallIndex: 1, id: pictureID("a")),
          picture(overallIndex: 2, id: pictureID("a")),
        ]
      ),
      expectedForumID: forumID
    )
    XCTAssertEqual(repeatedPicturePage.pictures.count, 2)
    XCTAssertNotEqual(repeatedPicturePage.pictures[0].id, repeatedPicturePage.pictures[1].id)
    try assertInvalid(
      response(
        total: 2,
        pictures: [
          picture(overallIndex: 1, id: pictureID("a")),
          picture(overallIndex: 1, id: pictureID("b")),
        ]
      )
    )
    try assertInvalid(
      response(
        total: 2,
        pictures: [
          picture(overallIndex: 2, id: pictureID("a")),
          picture(overallIndex: 1, id: pictureID("b")),
        ]
      )
    )
  }

  func testRejectsInvalidPostDimensionsSizeAndFlags() throws {
    try assertInvalid(
      response(total: 1, pictures: [picture(overallIndex: 1, postID: 0)])
    )
    try assertInvalid(
      response(total: 1, pictures: [picture(overallIndex: 1, width: 0)])
    )
    try assertInvalid(
      response(total: 1, pictures: [picture(overallIndex: 1, height: 100_001)])
    )
    try assertInvalid(
      response(total: 1, pictures: [picture(overallIndex: 1, size: -1)])
    )
    try assertInvalid(
      response(total: 1, pictures: [picture(overallIndex: 1, size: 1_073_741_825)])
    )
    try assertInvalid(
      response(total: 1, pictures: [picture(overallIndex: 1, offersOriginal: 2)])
    )
  }

  func testRejectsUntrustedMediaEvenWhenFieldIsNotSelected() throws {
    try assertInvalid(
      response(
        total: 1,
        pictures: [
          picture(
            overallIndex: 1,
            originalSource: "http://example.com/forum/pic/item/\(pictureID("a")).jpg"
          )
        ]
      )
    )
    try assertInvalid(
      response(
        total: 1,
        pictures: [
          picture(
            overallIndex: 1,
            originalSource: "https://example.com/forum/pic/item/\(pictureID("a")).jpg"
          )
        ]
      )
    )

    var item = picture(overallIndex: 1)
    var image = try XCTUnwrap(item["img"] as? [String: Any])
    var medium = try XCTUnwrap(image["medium"] as? [String: Any])
    medium["waterurl"] = "http://example.com/unused.jpg"
    image["medium"] = medium
    item["img"] = image
    try assertInvalid(response(total: 1, pictures: [item]))
  }

  private func assertInvalid(
    _ body: Data,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    XCTAssertThrowsError(
      try TiebaPicturePageDecoder.page(from: body, expectedForumID: forumID),
      file: file,
      line: line
    ) { error in
      XCTAssertEqual(error as? TiebaClientError, .invalidJSON, file: file, line: line)
    }
  }

  private func response(
    total: Any,
    pictures: [[String: Any]],
    errorCode: Any = 0,
    responseForumID: Any = 2_432_903
  ) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "error_code": errorCode,
      "error_msg": "success",
      "forum": ["id": responseForumID, "name": "minecraft"],
      "pic_amount": total,
      "pic_list": pictures,
    ])
  }

  private func picture(
    overallIndex: Any,
    id: String? = nil,
    sourceID: String? = nil,
    width: Any = 463,
    height: Any = 466,
    size: Any = 308_325,
    postID: Any? = 131_740_410_382,
    longPicture: Any? = nil,
    offersOriginal: Any? = nil,
    originalSource: String? = nil
  ) -> [String: Any] {
    let id = id ?? pictureID("a")
    let sourceID = sourceID ?? pictureID("b")
    var original: [String: Any] = [
      "id": id,
      "width": width,
      "height": height,
      "size": size,
      "original_src": originalSource
        ?? "http://tiebapic.baidu.com/forum/pic/item/\(sourceID).jpg?tbpicau=fixture_1",
      "url": "http://tiebapic.baidu.com/forum/pic/item/\(sourceID).jpg?tbpicau=fixture_2",
      "big_cdn_src": "http://c.hiphotos.baidu.com/forum/w%3D960/sign=fixture/\(id).jpg?tbpicau=fixture_3",
    ]
    original["waterurl"] =
      "http://tiebapic.baidu.com/forum/pic/item/\(id).jpg?tbpicau=fixture_4"
    var result: [String: Any] = [
      "overall_index": overallIndex,
      "img": [
        "original": original,
        "medium": [
          "id": id,
          "width": 194,
          "height": 195,
          "size": 0,
          "url": "http://tiebapic.baidu.com/forum/w%3D194/sign=fixture/\(id).jpg?tbpicau=fixture_5",
        ],
      ],
    ]
    if let postID { result["post_id"] = postID }
    if let longPicture { result["is_long_pic"] = longPicture }
    if let offersOriginal { result["show_original_btn"] = offersOriginal }
    return result
  }

  private func pictureID(_ character: Character) -> String {
    String(repeating: String(character), count: 40)
  }
}

final class TiebaPicturePageClientTests: XCTestCase {
  func testClientSendsRequestAndDecodesResponse() async throws {
    let id = String(repeating: "a", count: 40)
    let sourceID = String(repeating: "b", count: 40)
    let response = try JSONSerialization.data(withJSONObject: [
      "error_code": 0,
      "error_msg": "success",
      "forum": ["id": 1, "name": "swift"],
      "pic_amount": 1,
      "pic_list": [[
        "overall_index": 1,
        "post_id": 3,
        "img": ["original": [
          "id": id,
          "width": 100,
          "height": 200,
          "size": 300,
          "original_src": "http://tiebapic.baidu.com/forum/pic/item/\(sourceID).jpg",
        ]],
      ]],
    ])
    let transport = PicturePageCapturingTransport(body: response)
    let client = TiebaClient(transport: transport)
    let cursor = try XCTUnwrap(
      TiebaPicturePageCursor(
        imageURL: XCTUnwrap(
          URL(string: "https://tiebapic.baidu.com/forum/pic/item/\(id).jpg")
        )
      )
    )

    let page = try await client.getPicturePage(
      forumID: 1,
      forumName: "swift",
      threadID: 2,
      cursor: cursor
    )

    XCTAssertEqual(page.pictures.map(\.pictureID), [id])
    let request = await transport.lastRequest()
    XCTAssertEqual(request?.url?.host, "c.tieba.baidu.com")
    XCTAssertFalse(request?.httpShouldHandleCookies ?? true)
  }

  func testClientAppliesHTTPBodyAndDecodeErrors() async throws {
    let cursor = try XCTUnwrap(
      TiebaPicturePageCursor(
        imageURL: XCTUnwrap(
          URL(
            string:
              "https://tiebapic.baidu.com/forum/pic/item/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg"
          )
        )
      )
    )
    let oversized = TiebaClient(
      transport: PicturePageCapturingTransport(
        body: Data(count: TiebaPicturePagePolicy.maximumResponseBodyBytes + 1)
      )
    )
    await assertClientError(
      .responseTooLarge(maximumBytes: TiebaPicturePagePolicy.maximumResponseBodyBytes)
    ) {
      _ = try await oversized.getPicturePage(
        forumID: 1, forumName: "x", threadID: 2, cursor: cursor)
    }

    let badStatus = TiebaClient(
      transport: PicturePageCapturingTransport(body: Data(), statusCode: 503)
    )
    await assertClientError(.httpStatus(503)) {
      _ = try await badStatus.getPicturePage(
        forumID: 1, forumName: "x", threadID: 2, cursor: cursor)
    }

    let malformed = TiebaClient(
      transport: PicturePageCapturingTransport(body: Data("bad".utf8))
    )
    await assertClientError(.invalidJSON) {
      _ = try await malformed.getPicturePage(
        forumID: 1, forumName: "x", threadID: 2, cursor: cursor)
    }
  }

  func testClientDispatchesBodyLimitToTransportRequirement() async throws {
    let id = String(repeating: "a", count: 40)
    let sourceID = String(repeating: "b", count: 40)
    let body = try JSONSerialization.data(withJSONObject: [
      "error_code": 0,
      "error_msg": "success",
      "forum": ["id": 1, "name": "swift"],
      "pic_amount": 1,
      "pic_list": [[
        "overall_index": 1,
        "post_id": 3,
        "img": ["original": [
          "id": id,
          "width": 100,
          "height": 200,
          "size": 300,
          "original_src": "http://tiebapic.baidu.com/forum/pic/item/\(sourceID).jpg",
        ]],
      ]],
    ])
    let transport = PicturePageLimitDispatchTransport(body: body)
    let client = TiebaClient(transport: transport)
    let cursor = try XCTUnwrap(
      TiebaPicturePageCursor(serverPictureID: id, overallIndex: 1)
    )

    _ = try await client.getPicturePage(
      forumID: 1,
      forumName: "swift",
      threadID: 2,
      cursor: cursor
    )

    let calls = await transport.callSnapshot()
    XCTAssertEqual(calls.unbounded, 0)
    XCTAssertEqual(calls.bounded, [TiebaPicturePagePolicy.maximumResponseBodyBytes])
  }

  func testURLSessionTransportCancelsAnUnknownLengthResponseAtNPlusOne() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [PicturePageBoundedURLProtocol.self]
    let transport = URLSessionTiebaTransport(configuration: configuration)
    let exactRequest = URLRequest(
      url: try XCTUnwrap(URL(string: "https://bounded-picture-page.test/exact"))
    )
    let request = URLRequest(
      url: try XCTUnwrap(URL(string: "https://bounded-picture-page.test/oversize"))
    )

    let exactResponse = try await transport.send(exactRequest, maximumBodyBytes: 8)
    XCTAssertEqual(exactResponse.body.count, 8)

    do {
      _ = try await transport.send(request, maximumBodyBytes: 8)
      XCTFail("Expected the bounded transport to stop the response")
    } catch let error as TiebaClientError {
      XCTAssertEqual(error, .responseTooLarge(maximumBytes: 8))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    XCTAssertTrue(
      BoundedTiebaResponseTaskDelegate.exceedsLimit(
        totalBytesWritten: 9,
        totalBytesExpected: -1,
        maximumResponseBytes: 8
      )
    )
    XCTAssertFalse(
      BoundedTiebaResponseTaskDelegate.exceedsLimit(
        totalBytesWritten: 8,
        totalBytesExpected: -1,
        maximumResponseBytes: 8
      )
    )
  }

  private func assertClientError(
    _ expected: TiebaClientError,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      XCTFail("Expected \(expected)")
    } catch let error as TiebaClientError {
      XCTAssertEqual(error, expected)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }
}

private actor PicturePageCapturingTransport: TiebaTransport {
  private let body: Data
  private let statusCode: Int
  private var request: URLRequest?

  init(body: Data, statusCode: Int = 200) {
    self.body = body
    self.statusCode = statusCode
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    self.request = request
    return TiebaHTTPResponse(body: body, statusCode: statusCode)
  }

  func lastRequest() -> URLRequest? { request }
}

private actor PicturePageLimitDispatchTransport: TiebaTransport {
  private let body: Data
  private var unboundedCalls = 0
  private var boundedCalls = [Int?]()

  init(body: Data) {
    self.body = body
  }

  func send(_ request: URLRequest) async throws -> TiebaHTTPResponse {
    unboundedCalls += 1
    throw URLError(.badServerResponse)
  }

  func send(
    _ request: URLRequest,
    maximumBodyBytes: Int?
  ) async throws -> TiebaHTTPResponse {
    boundedCalls.append(maximumBodyBytes)
    return TiebaHTTPResponse(body: body, statusCode: 200)
  }

  func callSnapshot() -> (unbounded: Int, bounded: [Int?]) {
    (unboundedCalls, boundedCalls)
  }
}

private final class PicturePageBoundedURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "bounded-picture-page.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    guard
      let url = request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"]
      )
    else {
      client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
      return
    }
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let bodySize = url.path == "/exact" ? 8 : 9
    client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: bodySize))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private func formFields(_ request: URLRequest) throws -> [String: String] {
  let body = try XCTUnwrap(request.httpBody)
  var components = URLComponents()
  components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
    .replacingOccurrences(of: "+", with: "%20")
  return Dictionary(
    uniqueKeysWithValues: components.queryItems?.compactMap { item in
      item.value.map { (item.name, $0) }
    } ?? []
  )
}
