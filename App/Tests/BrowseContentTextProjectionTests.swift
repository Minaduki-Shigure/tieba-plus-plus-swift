import Foundation
import SwiftUI
import XCTest

@testable import TiebaPlusPlus

final class BrowseContentTextProjectionTests: XCTestCase {
  @MainActor
  func testPlainInlineTextProjectsNonInteractiveFragments() {
    let text = BrowseContentView.plainInlineText([
      .text("before"),
      .emoticon(name: "滑稽", url: nil),
      .text("middle"),
      .emoticon(name: "unknown", url: nil),
      .unsupported(label: "unsupported"),
      .text("after"),
    ])

    XCTAssertEqual(text, "before#(滑稽)middleunknown[unsupported]after")
  }

  @MainActor
  func testPlainInlineTextRejectsInteractiveFragments() throws {
    let linkURL = try XCTUnwrap(URL(string: "https://example.com/thread"))

    XCTAssertNil(
      BrowseContentView.plainInlineText([
        .text("before"),
        .mention(name: "reader", userID: 77),
        .text("after"),
      ])
    )
    XCTAssertNil(
      BrowseContentView.plainInlineText([
        .text("before"),
        .link(label: "thread", url: linkURL),
        .text("after"),
      ])
    )
    XCTAssertNil(
      BrowseContentView.plainInlineText([
        .text("before"),
        .image(
          thumbnail: linkURL,
          fullSize: nil,
          original: nil,
          width: 100,
          height: 100
        ),
        .text("after"),
      ])
    )
  }

  @MainActor
  func testPlainInlineTextMatchesAttributedInlineTextOutput() throws {
    let fixtures: [[BrowseContent]] = [
      [],
      [.text("")],
      [.text("plain text")],
      [.emoticon(name: "滑稽", url: nil)],
      [.emoticon(name: "unknown", url: nil)],
      [.unsupported(label: "unsupported")],
      [
        .text("before"),
        .emoticon(name: "滑稽", url: nil),
        .unsupported(label: "unsupported"),
        .text("after"),
      ],
    ]

    for contents in fixtures {
      let plainText = try XCTUnwrap(BrowseContentView.plainInlineText(contents))
      let attributedText = BrowseContentView.inlineText(contents)

      XCTAssertEqual(plainText, String(attributedText.characters))
    }
  }

  func testRenderPlanCachesPlainAndLinkedTextProjections() throws {
    let url = try XCTUnwrap(URL(string: "https://example.com/thread"))
    let contents: [BrowseContent] = [
      .text("plain"),
      .image(
        thumbnail: url,
        fullSize: nil,
        original: nil,
        width: 100,
        height: 100
      ),
      .mention(name: "reader", userID: 77),
      .text(" and "),
      .link(label: "thread", url: url),
    ]

    let plan = BrowseContentRenderPlan(contents: contents)

    XCTAssertEqual(plan.contents, contents)
    XCTAssertTrue(plan.containsImage)
    XCTAssertEqual(plan.blocks.count, 3)
    XCTAssertEqual(plan.plainInlineTextByBlockID[.inline(0)], "plain")
    let linked = try XCTUnwrap(plan.linkedInlineTextByBlockID[.inline(2)])
    XCTAssertEqual(String(linked.characters), "@reader and thread")
  }

  func testRenderPlanKeepsTextOnlyContentOutOfImagePresentationPath() {
    let plan = BrowseContentRenderPlan(contents: [.text("long body")])

    XCTAssertFalse(plan.containsImage)
    XCTAssertEqual(plan.plainInlineTextByBlockID[.inline(0)], "long body")
    XCTAssertTrue(plan.linkedInlineTextByBlockID.isEmpty)
  }

  func testRenderPlanFallsBackForMentionWithoutRoutableUserID() {
    let plan = BrowseContentRenderPlan(
      contents: [.mention(name: "unknown", userID: 0)]
    )

    XCTAssertNil(plan.plainInlineTextByBlockID[.inline(0)])
    XCTAssertNil(plan.linkedInlineTextByBlockID[.inline(0)])
  }
}
