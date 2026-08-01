import TiebaProto
import XCTest

@testable import TiebaCore

final class TiebaProtoMapperTests: XCTestCase {
  func testPostPagePrefersNewTotalPageAndMapsCursorPostIDs() {
    let fixture = ProtoFixtures.postPage().data

    let result = TiebaProtoMapper.postPage(fixture)

    XCTAssertEqual(fixture.page.lzTotalFloor, 33)
    XCTAssertEqual(result.pagination.totalPages, 6)
    XCTAssertEqual(result.thread.pagePostIDs, [301, 302])
  }

  func testPostPageFallsBackToLegacyTotalPage() {
    var fixture = ProtoFixtures.postPage().data
    fixture.page.newTotalPage = 0

    let result = TiebaProtoMapper.postPage(fixture)

    XCTAssertEqual(result.pagination.totalPages, 4)
  }
}
