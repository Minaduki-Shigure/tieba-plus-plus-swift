import SwiftUI
import UIKit
import XCTest

@testable import TiebaPlusPlus

final class UserActivityReplyRowTests: XCTestCase {
  @MainActor
  func testLongReplyRetainsEveryReturnedLineAtNarrowWidthsAndLargeTextSizes() {
    let shortText = Array(repeating: "回复文字", count: 4).joined(separator: "\n")
    let longText = Array(repeating: "回复文字", count: 10).joined(separator: "\n")

    for width: CGFloat in [160, 320] {
      for textSize in [DynamicTypeSize.large, .accessibility5] {
        let shortRow = fittedSize(row(text: shortText), width: width, textSize: textSize)
        let longRow = fittedSize(row(text: longText), width: width, textSize: textSize)
        let shortBody = fittedSize(Text(shortText).font(.body), width: width, textSize: textSize)
        let longBody = fittedSize(Text(longText).font(.body), width: width, textSize: textSize)
        let context = "width=\(width), textSize=\(textSize)"

        XCTAssertEqual(longRow.width, width, accuracy: 0.5, context)
        XCTAssertGreaterThan(longBody.height, shortBody.height, context)
        // Metadata and the original-thread button are identical. Every extra
        // body line must contribute its full native Text height to the row.
        XCTAssertEqual(
          longRow.height - shortRow.height,
          longBody.height - shortBody.height,
          accuracy: 1,
          context
        )
      }
    }
  }

  @MainActor
  private func row(text: String) -> some View {
    UserActivityReplyRow(
      reply: BrowseUserReply(
        threadID: 10,
        postID: 100,
        forumID: 42,
        forumName: "swift",
        threadTitle: "原主题",
        excerpt: text,
        createdAt: nil,
        authorID: 7,
        authorName: "测试用户",
        authorUsername: "fixture-user",
        target: .post
      ),
      onNavigate: { _ in }
    )
  }

  @MainActor
  private func fittedSize<Content: View>(
    _ content: Content,
    width: CGFloat,
    textSize: DynamicTypeSize
  ) -> CGSize {
    let host = UIHostingController(
      rootView: content
        .environment(\.dynamicTypeSize, textSize)
        .frame(width: width)
    )
    return host.sizeThatFits(in: CGSize(width: width, height: 10_000))
  }
}
