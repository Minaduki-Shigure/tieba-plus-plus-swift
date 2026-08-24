import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ThreadSummaryRowTests: XCTestCase {
  func testThreadPreviewImageRoleOnlyDarkensStaticImages() {
    XCTAssertTrue(ThreadPreviewImageRole.staticImage.appliesContentThumbnailDimming)
    XCTAssertFalse(ThreadPreviewImageRole.videoCover.appliesContentThumbnailDimming)
  }

  func testVideoCoverTakesPriorityOverImages() throws {
    let imageURL = try XCTUnwrap(URL(string: "https://example.com/image.jpg"))
    let coverURL = try XCTUnwrap(URL(string: "https://example.com/video.jpg"))
    let thread = makeThread(
      contents: [
        .image(
          thumbnail: imageURL,
          fullSize: nil,
          original: nil,
          width: 100,
          height: 100
        ),
        .video(url: nil, cover: coverURL, width: 1280, height: 720),
      ]
    )

    XCTAssertEqual(ThreadSummaryPresentation.media(for: thread), .video(coverURL))
    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: false),
      .expanded(.video(coverURL))
    )
    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: true),
      .collapsed(.video(coverURL))
    )
  }

  func testImagePreviewIsBoundedToFirstThreeImages() throws {
    let urls = try (1...4).map { index in
      try XCTUnwrap(URL(string: "https://example.com/\(index).jpg"))
    }
    let thread = makeThread(
      contents: urls.map {
        .image(thumbnail: $0, fullSize: nil, original: nil, width: 100, height: 100)
      }
    )

    XCTAssertEqual(
      ThreadSummaryPresentation.media(for: thread),
      .images(
        Array(urls.prefix(3).enumerated()).map {
          ThreadSummaryImagePreview(contentOffset: $0.offset, previewURL: $0.element)
        },
        totalCount: 4
      )
    )
    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: false),
      .expanded(
        .images(
          Array(urls.prefix(3).enumerated()).map {
            ThreadSummaryImagePreview(contentOffset: $0.offset, previewURL: $0.element)
          },
          totalCount: 4
        )
      )
    )
    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: true),
      .collapsed(
        .images(
          Array(urls.prefix(3).enumerated()).map {
            ThreadSummaryImagePreview(contentOffset: $0.offset, previewURL: $0.element)
          },
          totalCount: 4
        )
      )
    )
  }

  func testImagePreviewKeepsOriginalContentOffsetsAcrossInlineText() throws {
    let repeatedThumbnail = try XCTUnwrap(URL(string: "https://example.com/repeated.jpg"))
    let highDefinition = try XCTUnwrap(URL(string: "https://example.com/high-definition.jpg"))
    let thread = makeThread(
      contents: [
        .text("before"),
        .image(
          thumbnail: repeatedThumbnail,
          fullSize: highDefinition,
          original: nil,
          width: 100,
          height: 100
        ),
        .text("between"),
        .image(
          thumbnail: repeatedThumbnail,
          fullSize: nil,
          original: nil,
          width: 100,
          height: 100
        ),
      ]
    )

    XCTAssertEqual(
      ThreadSummaryPresentation.media(for: thread, quality: .standard),
      .images(
        [
          ThreadSummaryImagePreview(contentOffset: 1, previewURL: repeatedThumbnail),
          ThreadSummaryImagePreview(contentOffset: 3, previewURL: repeatedThumbnail),
        ],
        totalCount: 2
      )
    )
    XCTAssertEqual(
      ThreadSummaryPresentation.media(for: thread, quality: .highDefinition),
      .images(
        [
          ThreadSummaryImagePreview(contentOffset: 1, previewURL: highDefinition),
          ThreadSummaryImagePreview(contentOffset: 3, previewURL: repeatedThumbnail),
        ],
        totalCount: 2
      )
    )
  }

  func testImagePreviewQualitySelectsHighDefinitionWithoutChangingCount() throws {
    let thumbnail = try XCTUnwrap(URL(string: "https://example.com/standard.jpg"))
    let fullSize = try XCTUnwrap(URL(string: "https://example.com/high-definition.jpg"))
    let thread = makeThread(
      contents: [
        .image(
          thumbnail: thumbnail,
          fullSize: fullSize,
          original: try XCTUnwrap(URL(string: "https://example.com/original.jpg")),
          width: 100,
          height: 100
        )
      ]
    )

    XCTAssertEqual(
      ThreadSummaryPresentation.media(for: thread, quality: .standard),
      .images(
        [ThreadSummaryImagePreview(contentOffset: 0, previewURL: thumbnail)],
        totalCount: 1
      )
    )
    XCTAssertEqual(
      ThreadSummaryPresentation.media(for: thread, quality: .highDefinition),
      .images(
        [ThreadSummaryImagePreview(contentOffset: 0, previewURL: fullSize)],
        totalCount: 1
      )
    )
    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(
        for: thread,
        hidesMedia: true,
        quality: .highDefinition
      ),
      .collapsed(
        .images(
          [ThreadSummaryImagePreview(contentOffset: 0, previewURL: fullSize)],
          totalCount: 1
        )
      )
    )
  }

  func testCollapsedImageCountPreservesDuplicateURLs() throws {
    let repeatedURL = try XCTUnwrap(URL(string: "https://example.com/repeated.jpg"))
    let thread = makeThread(
      contents: (0..<4).map { _ in
        .image(
          thumbnail: repeatedURL,
          fullSize: nil,
          original: nil,
          width: 100,
          height: 100
        )
      }
    )

    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: true),
      .collapsed(
        .images(
          (0..<3).map {
            ThreadSummaryImagePreview(contentOffset: $0, previewURL: repeatedURL)
          },
          totalCount: 4
        )
      )
    )
    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: false),
      .expanded(
        .images(
          (0..<3).map {
            ThreadSummaryImagePreview(contentOffset: $0, previewURL: repeatedURL)
          },
          totalCount: 4
        )
      )
    )
  }

  func testVideoWithoutCoverDoesNotCreateNewMediaSemantics() throws {
    let videoURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
    let videoOnlyThread = makeThread(
      contents: [.video(url: videoURL, cover: nil, width: 1280, height: 720)]
    )

    XCTAssertNil(
      ThreadSummaryPresentation.mediaPresentation(for: videoOnlyThread, hidesMedia: false)
    )
    XCTAssertNil(
      ThreadSummaryPresentation.mediaPresentation(for: videoOnlyThread, hidesMedia: true)
    )

    let imageURL = try XCTUnwrap(URL(string: "https://example.com/image.jpg"))
    let threadWithImage = makeThread(
      contents: [
        .video(url: videoURL, cover: nil, width: 1280, height: 720),
        .image(
          thumbnail: imageURL,
          fullSize: nil,
          original: nil,
          width: 100,
          height: 100
        ),
      ]
    )

    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: threadWithImage, hidesMedia: false),
      .expanded(
        .images(
          [ThreadSummaryImagePreview(contentOffset: 1, previewURL: imageURL)],
          totalCount: 1
        )
      )
    )
    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: threadWithImage, hidesMedia: true),
      .collapsed(
        .images(
          [ThreadSummaryImagePreview(contentOffset: 1, previewURL: imageURL)],
          totalCount: 1
        )
      )
    )
  }

  func testPinnedThreadNeverLoadsInlineMedia() throws {
    let imageURL = try XCTUnwrap(URL(string: "https://example.com/image.jpg"))
    let thread = makeThread(
      contents: [
        .image(
          thumbnail: imageURL,
          fullSize: nil,
          original: nil,
          width: 100,
          height: 100
        )
      ],
      isPinned: true
    )

    XCTAssertNil(ThreadSummaryPresentation.media(for: thread))
    XCTAssertNil(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: false)
    )
    XCTAssertNil(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: true)
    )
  }

  func testThreadWithoutMediaHasNoPresentationInEitherMode() {
    let thread = makeThread(contents: [.text("Text only")])

    XCTAssertNil(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: false)
    )
    XCTAssertNil(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: true)
    )
  }

  func testAuthorAvatarOnlyLoadsForVisibleOrdinaryRowsThatShowAuthors() throws {
    let avatarURL = try XCTUnwrap(
      URL(string: "https://himg.bdimg.com/sys/portraitn/item/author-token")
    )
    let visible = makeThread(contents: [.text("Text")], authorAvatarURL: avatarURL)

    XCTAssertEqual(
      ThreadSummaryPresentation.authorAvatarURL(for: visible, showsAuthor: true),
      avatarURL
    )
    XCTAssertNil(ThreadSummaryPresentation.authorAvatarURL(for: visible, showsAuthor: false))
    XCTAssertNil(
      ThreadSummaryPresentation.authorAvatarURL(
        for: visible.withLocalVisibility(.placeholder),
        showsAuthor: true
      )
    )
    XCTAssertNil(
      ThreadSummaryPresentation.authorAvatarURL(
        for: visible.withLocalVisibility(.hidden),
        showsAuthor: true
      )
    )

    let pinned = makeThread(
      contents: [.text("Pinned")],
      authorAvatarURL: avatarURL,
      isPinned: true
    )
    XCTAssertNil(ThreadSummaryPresentation.authorAvatarURL(for: pinned, showsAuthor: true))

    let identityless = makeThread(
      contents: [.text("No author")],
      authorName: "",
      authorUsername: "",
      authorAvatarURL: avatarURL
    )
    XCTAssertNil(ThreadSummaryPresentation.authorAvatarURL(for: identityless, showsAuthor: true))
  }

  func testThreadModelRejectsUnsafeAuthorAvatarURL() throws {
    let unsafeURL = try XCTUnwrap(URL(string: "http://example.com/avatar.jpg"))
    let thread = makeThread(contents: [], authorAvatarURL: unsafeURL)

    XCTAssertNil(thread.authorAvatarURL)
    XCTAssertNil(ThreadSummaryPresentation.authorAvatarURL(for: thread, showsAuthor: true))
  }

  private func makeThread(
    contents: [BrowseContent],
    authorName: String = "Author",
    authorUsername: String = "",
    authorAvatarURL: URL? = nil,
    isPinned: Bool = false
  ) -> BrowseThread {
    BrowseThread(
      id: 42,
      forumID: 7,
      forumName: "swift",
      title: "Thread",
      excerpt: "Excerpt",
      authorName: authorName,
      replyCount: 3,
      viewCount: 10,
      createdAt: nil,
      lastReplyAt: nil,
      contents: contents,
      authorUsername: authorUsername,
      authorAvatarURL: authorAvatarURL,
      isPinned: isPinned
    )
  }
}
