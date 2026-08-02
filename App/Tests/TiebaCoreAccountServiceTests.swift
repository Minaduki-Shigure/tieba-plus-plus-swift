import Foundation
import TiebaCore
import XCTest

@testable import TiebaPlusPlus

final class TiebaCoreAccountServiceTests: XCTestCase {
  func testServerErrorDoesNotExposeResponseMessage() throws {
    let secret = String(repeating: "b", count: 192)
    let error = TiebaCoreAccountService.accountError(
      TiebaClientError.server(code: 1, message: "request bdusstoken=\(secret)")
    )

    let message = try XCTUnwrap(error.errorDescription)
    XCTAssertEqual(message, "账户验证失败（错误码 1）。")
    XCTAssertFalse(message.contains(secret))
    XCTAssertFalse(message.contains("bdusstoken"))
  }

  func testUnknownErrorDoesNotExposeLocalizedDescription() throws {
    let secret = "sensitive diagnostic"
    let error = TiebaCoreAccountService.accountError(SensitiveAccountError(message: secret))

    let message = try XCTUnwrap(error.errorDescription)
    XCTAssertEqual(message, "账户请求失败，请稍后重试。")
    XCTAssertFalse(message.contains(secret))
  }

  func testAccountErrorUsesOnlyFixedMessagesAndNumericStatus() throws {
    let cases: [(TiebaClientError, String)] = [
      (.invalidArgument("secret"), "账户凭据格式无效。"),
      (.invalidEndpoint, "无法建立安全的账户请求。"),
      (.network(code: -1009), "网络连接失败，请检查网络后重试。"),
      (.transportFailure, "网络响应异常，请稍后重试。"),
      (.invalidHTTPResponse, "网络响应异常，请稍后重试。"),
      (.httpStatus(503), "贴吧服务暂时不可用（HTTP 503）。"),
      (.invalidProtobuf, "贴吧返回了无法识别的数据，接口可能已经更新。"),
      (.invalidJSON, "贴吧返回了无法识别的数据，接口可能已经更新。"),
    ]

    for (source, expected) in cases {
      XCTAssertEqual(
        TiebaCoreAccountService.accountError(source).errorDescription,
        expected
      )
    }
  }
}

private struct SensitiveAccountError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}
