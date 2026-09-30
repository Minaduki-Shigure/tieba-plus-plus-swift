import Foundation
import SwiftProtobuf
import XCTest

@testable import TiebaProto

final class TiebaNewThreadProtocolSchemaTests: XCTestCase {
  func testRequestDecodesObservedThreadSpecificFieldNumbers() throws {
    // Literal wire keys from AddThreadRequestData, independent of generated encoders:
    // kw = 27, title = 38, is_ntitle = 41, name_show = 75, is_pictxt = 77.
    let data = try AddThreadReqIdl.DataReq(serializedBytes: [
      0xDA, 0x01, 0x05, 0x73, 0x77, 0x69, 0x66, 0x74,
      0xB2, 0x02, 0x01, 0x54,
      0xCA, 0x02, 0x01, 0x30,
      0xDA, 0x04, 0x01, 0x55,
      0xEA, 0x04, 0x01, 0x30,
    ] as [UInt8])

    XCTAssertEqual(data.kw, "swift")
    XCTAssertEqual(data.title, "T")
    XCTAssertEqual(data.isNtitle, "0")
    XCTAssertEqual(data.nameShow, "U")
    XCTAssertEqual(data.isPictxt, "0")
  }

  func testExplicitZeroCreationFlagsRemainPresentOnWire() throws {
    var data = AddThreadReqIdl.DataReq()
    XCTAssertFalse(data.hasShowCustomFigure)
    XCTAssertFalse(data.hasIsShowBless)
    data.showCustomFigure = 0
    data.isShowBless = 0

    // show_custom_figure = 80 and is_show_bless = 87, both explicitly present.
    XCTAssertEqual(try data.serializedData(), Data([0x80, 0x05, 0x00, 0xB8, 0x05, 0x00]))
    let decoded = try AddThreadReqIdl.DataReq(serializedBytes: data.serializedData())
    XCTAssertTrue(decoded.hasShowCustomFigure)
    XCTAssertTrue(decoded.hasIsShowBless)
  }

  func testThreadResponseReadsToastAtFieldTwenty() throws {
    // data.tid = "3003", data.pid = "4004", data.toast.content[0].text = "x".
    let response = try AddThreadResIdl(serializedBytes: [
      0x0A, 0x00,
      0x12, 0x14,
      0x12, 0x04, 0x33, 0x30, 0x30, 0x33,
      0x1A, 0x04, 0x34, 0x30, 0x30, 0x34,
      0xA2, 0x01, 0x05, 0x12, 0x03, 0x0A, 0x01, 0x78,
    ] as [UInt8])

    XCTAssertTrue(response.hasError)
    XCTAssertEqual(response.error.errorno, 0)
    XCTAssertTrue(response.hasData)
    XCTAssertEqual(response.data.tid, "3003")
    XCTAssertEqual(response.data.pid, "4004")
    XCTAssertTrue(response.data.hasToast)
    XCTAssertEqual(response.data.toast.content.map(\.text), ["x"])
  }

  func testThreadResponseDoesNotMisreadFieldNineteenAsPostToast() throws {
    // AddThread field 19 is invitees_number, whereas AddPost uses it for toast.
    let data = try AddThreadResIdl.DataRes(serializedBytes: [
      0x9A, 0x01, 0x01, 0x31
    ] as [UInt8])
    XCTAssertFalse(data.hasToast)
  }
}
