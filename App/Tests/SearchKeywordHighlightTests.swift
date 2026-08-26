import SwiftUI
import XCTest

@testable import TiebaPlusPlus

final class SearchKeywordHighlightTests: XCTestCase {
  func testCJKAndCaseInsensitiveMatchesKeepOriginalTextRanges() {
    let text = "贴吧 Swift SWIFT swiftui"
    let ranges = SearchKeywordHighlightPolicy.ranges(
      in: text,
      query: "贴吧 swift"
    )

    XCTAssertEqual(ranges.map { String(text[$0]) }, ["贴吧", "Swift", "SWIFT", "swift"])
  }

  func testWhitespaceTokenizationDeduplicatesFoldedValuesAndKeepsOrder() {
    XCTAssertEqual(
      SearchKeywordHighlightPolicy.tokens(from: "  Swift\n贴吧\tＳＷＩＦＴ  "),
      ["Swift", "贴吧"]
    )
  }

  func testRegexMetacharactersAreMatchedLiterally() {
    let text = "C++ [Swift] Cx"
    let ranges = SearchKeywordHighlightPolicy.ranges(
      in: text,
      query: "C++ ["
    )

    XCTAssertEqual(ranges.map { String(text[$0]) }, ["C++", "["])
  }

  func testOverlappingKeywordsMergeWithoutChangingOriginalCharacters() {
    let text = "SwiftUI swift"
    let ranges = SearchKeywordHighlightPolicy.ranges(
      in: text,
      query: "swift SwiftUI SWIFT"
    )

    XCTAssertEqual(ranges.map { String(text[$0]) }, ["SwiftUI", "swift"])
  }

  func testDiacriticInsensitiveMatchPreservesReceivedSpelling() {
    let text = "CAFÉ cafe"
    let ranges = SearchKeywordHighlightPolicy.ranges(in: text, query: "cafe")

    XCTAssertEqual(ranges.map { String(text[$0]) }, ["CAFÉ", "cafe"])
  }

  func testComposedQueryMatchesDecomposedReceivedGraphemeSafely() {
    let text = "Cafe\u{301}"
    let ranges = SearchKeywordHighlightPolicy.ranges(in: text, query: "CAFÉ")

    XCTAssertEqual(ranges.map { String(text[$0]) }, [text])
  }

  func testWidthInsensitiveQueryMatchesFullwidthReceivedText() {
    let text = "Ｓｗｉｆｔ 贴吧"
    let ranges = SearchKeywordHighlightPolicy.ranges(in: text, query: "swift")

    XCTAssertEqual(ranges.map { String(text[$0]) }, ["Ｓｗｉｆｔ"])
  }

  func testEmptyAndOversizedQueriesProduceNoHighlight() {
    let text = "visible text"
    XCTAssertTrue(SearchKeywordHighlightPolicy.ranges(in: text, query: " \n\t ").isEmpty)
    XCTAssertEqual(
      SearchKeywordHighlightPolicy.tokens(
        from: String(repeating: "a", count: 100)
      ).count,
      1
    )
    XCTAssertTrue(
      SearchKeywordHighlightPolicy.ranges(
        in: text,
        query: String(repeating: "a", count: 101)
      ).isEmpty
    )
  }

  func testTokenAndMatchCountsAreBounded() {
    let query = (0..<(SearchKeywordHighlightPolicy.maximumTokenCount + 5))
      .map(String.init)
      .joined(separator: " ")
    XCTAssertEqual(
      SearchKeywordHighlightPolicy.tokens(from: query).count,
      SearchKeywordHighlightPolicy.maximumTokenCount
    )

    let text = Array(
      repeating: "match",
      count: SearchKeywordHighlightPolicy.maximumMatchCount + 20
    ).joined(separator: " ")
    XCTAssertEqual(
      SearchKeywordHighlightPolicy.ranges(in: text, query: "match").count,
      SearchKeywordHighlightPolicy.maximumMatchCount
    )
  }

  func testScanningIsBoundedToVisibleSearchCardPrefix() {
    let target = "target"
    let visibleText = String(
      repeating: "x",
      count: SearchKeywordHighlightPolicy.maximumScannedTextCharacterCount - target.count
    ) + target
    XCTAssertEqual(
      SearchKeywordHighlightPolicy.ranges(in: visibleText, query: target)
        .map { String(visibleText[$0]) },
      [target]
    )

    let prefix = String(
      repeating: "x",
      count: SearchKeywordHighlightPolicy.maximumScannedTextCharacterCount
    )
    let text = prefix + " \(target)"

    XCTAssertTrue(
      SearchKeywordHighlightPolicy.ranges(in: text, query: target).isEmpty
    )
  }

  @MainActor
  func testAttributedProjectionColorsOnlyMergedMatches() {
    let color = Color.green
    let text = "SwiftUI and swift"
    let attributed = SearchKeywordHighlightPolicy.attributedText(
      text,
      query: "swift SwiftUI",
      highlightColor: color
    )

    XCTAssertEqual(String(attributed.characters), text)
    XCTAssertEqual(
      attributed.runs.compactMap { run in
        run.foregroundColor == color ? String(attributed[run.range].characters) : nil
      },
      ["SwiftUI", "swift"]
    )
  }
}
