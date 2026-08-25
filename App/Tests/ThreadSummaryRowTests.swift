import Foundation
import XCTest

@testable import TiebaPlusPlus

final class ThreadSummaryRowTests: XCTestCase {
  func testFirstVideoTakesPriorityOverImagesAndPreservesItsContentOffset() throws {
    let imageURL = try XCTUnwrap(URL(string: "https://example.com/image.jpg"))
    let coverURL = try XCTUnwrap(URL(string: "https://example.com/video.jpg"))
    let video = BrowseVideoContent(
      url: nil,
      cover: coverURL,
      width: 1280,
      height: 720
    )
    let thread = makeThread(
      contents: [
        .image(
          thumbnail: imageURL,
          fullSize: nil,
          original: nil,
          width: 100,
          height: 100
        ),
        .video(video),
      ]
    )
    let expected = ThreadSummaryVideoPreview(contentOffset: 1, video: video)

    XCTAssertEqual(ThreadSummaryPresentation.media(for: thread), .video(expected))
    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: false),
      .expanded(.video(expected))
    )
    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: thread, hidesMedia: true),
      .collapsed(.video(expected))
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

  func testVideoWithoutCoverRemainsPlayableAndTakesPriorityOverLaterImages() throws {
    let videoURL = try XCTUnwrap(URL(string: "https://example.com/video.mp4"))
    let video = BrowseVideoContent(
      url: videoURL,
      cover: nil,
      width: 1280,
      height: 720
    )
    let videoOnlyThread = makeThread(
      contents: [.video(video)]
    )
    let expected = ThreadSummaryVideoPreview(contentOffset: 0, video: video)

    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: videoOnlyThread, hidesMedia: false),
      .expanded(.video(expected))
    )
    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: videoOnlyThread, hidesMedia: true),
      .collapsed(.video(expected))
    )

    let imageURL = try XCTUnwrap(URL(string: "https://example.com/image.jpg"))
    let threadWithImage = makeThread(
      contents: [
        .video(video),
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
      .expanded(.video(expected))
    )
    XCTAssertEqual(
      ThreadSummaryPresentation.mediaPresentation(for: threadWithImage, hidesMedia: true),
      .collapsed(.video(expected))
    )
  }

  func testCompletelyUnusableVideoDoesNotHideLaterImages() throws {
    let unsafeStreamURL = try XCTUnwrap(URL(string: "http://video.example/movie.mp4"))
    let unsafeCoverURL = try XCTUnwrap(URL(string: "http://video.example/cover.jpg"))
    let unsafePageURL = try XCTUnwrap(URL(string: "javascript:alert(1)"))
    let imageURL = try XCTUnwrap(URL(string: "https://example.com/image.jpg"))
    let thread = makeThread(
      contents: [
        .video(
          BrowseVideoContent(
            url: unsafeStreamURL,
            cover: unsafeCoverURL,
            width: 1280,
            height: 720,
            pageURL: unsafePageURL
          )
        ),
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
      ThreadSummaryPresentation.media(for: thread),
      .images(
        [ThreadSummaryImagePreview(contentOffset: 1, previewURL: imageURL)],
        totalCount: 1
      )
    )
  }

  func testVideoPlaybackIdentitySeparatesThreadsOffsetsAndSources() throws {
    let firstVideo = BrowseVideoContent(
      url: try XCTUnwrap(URL(string: "https://example.com/first.mp4")),
      cover: nil,
      width: 1280,
      height: 720
    )
    let secondVideo = BrowseVideoContent(
      url: try XCTUnwrap(URL(string: "https://example.com/second.mp4")),
      cover: nil,
      width: 1280,
      height: 720
    )
    let basePreview = ThreadSummaryVideoPreview(contentOffset: 2, video: firstVideo)
    let base = ThreadSummaryVideoPlaybackIdentity(threadID: 42, preview: basePreview)

    XCTAssertEqual(
      base,
      ThreadSummaryVideoPlaybackIdentity(threadID: 42, preview: basePreview)
    )
    XCTAssertNotEqual(
      base,
      ThreadSummaryVideoPlaybackIdentity(threadID: 43, preview: basePreview)
    )
    XCTAssertNotEqual(
      base,
      ThreadSummaryVideoPlaybackIdentity(
        threadID: 42,
        preview: ThreadSummaryVideoPreview(contentOffset: 3, video: firstVideo)
      )
    )
    XCTAssertNotEqual(
      base,
      ThreadSummaryVideoPlaybackIdentity(
        threadID: 42,
        preview: ThreadSummaryVideoPreview(contentOffset: 2, video: secondVideo)
      )
    )
  }

  func testVideoPageRouterKeepsTiebaInternalAndHonorsExternalPreference() throws {
    let tiebaURL = try XCTUnwrap(
      URL(string: "https://tieba.baidu.com/p/10957526376?see_lz=0#/")
    )
    let target = try XCTUnwrap(TiebaLink.target(from: tiebaURL))
    XCTAssertEqual(
      ThreadSummaryVideoPageRouter.disposition(for: tiebaURL, mode: .systemBrowser),
      .tieba(target)
    )

    let externalURL = try XCTUnwrap(URL(string: "https://video.example/watch/42"))
    XCTAssertEqual(
      ThreadSummaryVideoPageRouter.disposition(for: externalURL, mode: .systemBrowser),
      .system(externalURL)
    )
    XCTAssertEqual(
      ThreadSummaryVideoPageRouter.disposition(for: externalURL, mode: .inAppSafari),
      .inAppSafari(externalURL)
    )
  }

  func testVideoPageRouterRejectsUnsafeURLs() throws {
    let rejected = [
      "javascript:alert(1)",
      "https://user@video.example/watch/42",
      "https://video.example/watch/%0A42",
    ]

    for rawValue in rejected {
      let url = try XCTUnwrap(URL(string: rawValue))
      XCTAssertEqual(
        ThreadSummaryVideoPageRouter.disposition(for: url, mode: .inAppSafari),
        .rejected,
        rawValue
      )
    }
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

  func testThreadSummaryNavigationPolicyBuildsSeparatePrimaryAndReplyRequests() throws {
    let thread = makeThread(contents: [.text("Text")])

    let primary = try XCTUnwrap(ThreadSummaryNavigationPolicy.primaryRequest(for: thread))
    XCTAssertEqual(primary.thread, thread)
    XCTAssertNil(primary.initialFocus)
    XCTAssertNil(primary.linkRoute)
    XCTAssertEqual(primary.destinationID, "thread-summary:42:top")

    let replies = try XCTUnwrap(ThreadSummaryNavigationPolicy.repliesRequest(for: thread))
    XCTAssertEqual(replies.thread, thread)
    XCTAssertEqual(replies.initialFocus, .firstReply)
    XCTAssertEqual(replies.linkRoute?.threadID, thread.id)
    XCTAssertEqual(replies.linkRoute?.options, ThreadBrowseOptions())
    XCTAssertNil(replies.linkRoute?.postID)
    XCTAssertEqual(replies.destinationID, "thread-summary:42:replies")
  }

  func testThreadSummaryContextNavigationBuildsStrictForumAndAuthorAppURLs() throws {
    let thread = makeThread(
      contents: [.text("Text")],
      forumName: "  Swift 语言  ",
      authorID: 1_234
    )

    let forumURL = try XCTUnwrap(
      ThreadSummaryContextNavigationPolicy.forumURL(for: thread, showsForum: true)
    )
    XCTAssertEqual(forumURL.scheme, TiebaLink.appScheme)
    XCTAssertEqual(TiebaLink.target(from: forumURL), .forum("Swift 语言"))

    let authorURL = try XCTUnwrap(
      ThreadSummaryContextNavigationPolicy.authorURL(for: thread, showsAuthor: true)
    )
    XCTAssertEqual(authorURL.scheme, TiebaLink.appScheme)
    XCTAssertEqual(TiebaLink.target(from: authorURL), .user(1_234))
  }

  func testThreadSummaryContextNavigationHonorsVisibilityAndDisplayOptions() {
    let visible = makeThread(contents: [], authorID: 1_234)

    XCTAssertNil(
      ThreadSummaryContextNavigationPolicy.forumURL(for: visible, showsForum: false)
    )
    XCTAssertNil(
      ThreadSummaryContextNavigationPolicy.authorURL(for: visible, showsAuthor: false)
    )

    for visibility in [LocalContentVisibility.placeholder, .hidden] {
      let filtered = visible.withLocalVisibility(visibility)
      XCTAssertNil(
        ThreadSummaryContextNavigationPolicy.forumURL(for: filtered, showsForum: true)
      )
      XCTAssertNil(
        ThreadSummaryContextNavigationPolicy.authorURL(for: filtered, showsAuthor: true)
      )
    }

    let pinned = makeThread(contents: [], authorID: 1_234, isPinned: true)
    XCTAssertNil(
      ThreadSummaryContextNavigationPolicy.forumURL(for: pinned, showsForum: true)
    )
    XCTAssertNil(
      ThreadSummaryContextNavigationPolicy.authorURL(for: pinned, showsAuthor: true)
    )
  }

  func testThreadSummaryContextNavigationRejectsInvalidForumAndAuthorIdentity() {
    for forumName in ["", "   ", "bad/name", String(repeating: "吧", count: 101)] {
      XCTAssertNil(
        ThreadSummaryContextNavigationPolicy.forumURL(
          for: makeThread(contents: [], forumName: forumName, authorID: 1_234),
          showsForum: true
        ),
        forumName
      )
    }

    for authorID in [Int64.min, -1, 0] {
      XCTAssertNil(
        ThreadSummaryContextNavigationPolicy.authorURL(
          for: makeThread(contents: [], authorID: authorID),
          showsAuthor: true
        ),
        "authorID=\(authorID)"
      )
    }

    XCTAssertNil(
      ThreadSummaryContextNavigationPolicy.authorURL(
        for: makeThread(
          contents: [],
          authorName: " \n ",
          authorUsername: "\t",
          authorID: 1_234
        ),
        showsAuthor: true
      )
    )

    XCTAssertNotNil(
      ThreadSummaryContextNavigationPolicy.authorURL(
        for: makeThread(
          contents: [],
          authorName: "",
          authorUsername: "public-name",
          authorID: 1_234
        ),
        showsAuthor: true
      )
    )
  }

  func testThreadSummaryReplyNavigationMatchesTiebaLiteForZeroCount() throws {
    let thread = makeThread(contents: [], replyCount: 0)

    XCTAssertNotNil(ThreadSummaryNavigationPolicy.repliesRequest(for: thread))
    XCTAssertEqual(
      ThreadSummaryNavigationPolicy.repliesAccessibilityLabel(replyCount: 0),
      "打开回复区，当前 0 条回复"
    )
    XCTAssertEqual(
      ThreadSummaryNavigationPolicy.repliesAccessibilityLabel(replyCount: -3),
      "打开回复区，当前 0 条回复"
    )
    XCTAssertEqual(
      ThreadSummaryNavigationPolicy.repliesAccessibilityLabel(replyCount: 12),
      "查看 12 条回复，打开回复区"
    )
    XCTAssertNotNil(
      ThreadSummaryNavigationPolicy.repliesRequest(
        for: makeThread(contents: [], replyCount: -3)
      )
    )
  }

  func testThreadSummaryNavigationRejectsFilteredAndInvalidThreads() {
    let invalid = makeThread(contents: [], id: 0)
    XCTAssertNil(ThreadSummaryNavigationPolicy.primaryRequest(for: invalid))
    XCTAssertNil(ThreadSummaryNavigationPolicy.repliesRequest(for: invalid))
    let negativeID = makeThread(contents: [], id: -1)
    XCTAssertNil(ThreadSummaryNavigationPolicy.primaryRequest(for: negativeID))
    XCTAssertNil(ThreadSummaryNavigationPolicy.repliesRequest(for: negativeID))

    let visible = makeThread(contents: [])
    for visibility in [LocalContentVisibility.placeholder, .hidden] {
      let filtered = visible.withLocalVisibility(visibility)
      XCTAssertNil(ThreadSummaryNavigationPolicy.primaryRequest(for: filtered))
      XCTAssertNil(ThreadSummaryNavigationPolicy.repliesRequest(for: filtered))
    }
  }

  func testPinnedThreadKeepsPrimaryNavigationButHasNoReplyShortcut() {
    let thread = makeThread(contents: [], isPinned: true)

    XCTAssertNotNil(ThreadSummaryNavigationPolicy.primaryRequest(for: thread))
    XCTAssertNil(ThreadSummaryNavigationPolicy.repliesRequest(for: thread))
  }

  private func makeThread(
    contents: [BrowseContent],
    id: Int64 = 42,
    forumName: String = "swift",
    authorName: String = "Author",
    authorUsername: String = "",
    authorID: Int64 = 0,
    authorAvatarURL: URL? = nil,
    replyCount: Int = 3,
    isPinned: Bool = false
  ) -> BrowseThread {
    BrowseThread(
      id: id,
      forumID: 7,
      forumName: forumName,
      title: "Thread",
      excerpt: "Excerpt",
      authorName: authorName,
      replyCount: replyCount,
      viewCount: 10,
      createdAt: nil,
      lastReplyAt: nil,
      contents: contents,
      authorID: authorID,
      authorUsername: authorUsername,
      authorAvatarURL: authorAvatarURL,
      isPinned: isPinned
    )
  }
}
