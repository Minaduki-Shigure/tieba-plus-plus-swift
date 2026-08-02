import Foundation
import TiebaProto

enum TiebaProtoMapper {
  static func threadPage(_ data: FrsPageResIdl.DataRes) -> TiebaThreadPage {
    let forumProto = data.forum
    let forum = TiebaForum(
      id: forumProto.id,
      name: forumProto.name,
      category: forumProto.firstClass,
      subcategory: forumProto.secondClass,
      memberCount: Int(forumProto.memberNum),
      threadCount: Int(forumProto.threadNum),
      postCount: Int(forumProto.postNum),
      hasModerators: !forumProto.managers.isEmpty,
      hasRules: data.forumRule.hasForumRule_p != 0,
      avatar: forumProto.avatar,
      slogan: forumProto.slogan,
      featuredClassifications: forumProto.goodClassify.compactMap { classification in
        let name =
          classification.className.isEmpty
          ? classification.name
          : classification.className
        guard classification.classID > 0, !name.isEmpty else { return nil }
        return TiebaForumClassification(id: Int(classification.classID), name: name)
      }
    )
    let users = userLookup(data.userList)

    var threads = data.threadList.map {
      thread($0, forum: forum, author: users[$0.authorID] ?? optionalUser($0.author))
    }
    if threads.isEmpty {
      threads = data.pageData.feedList.compactMap { layout -> TiebaThread? in
        guard layout.layout == "feed" else { return nil }
        return feedThread(layout.feed, forum: forum, users: users)
      }
    }

    let tabs = data.navTabInfo.tab.reduce(into: [String: Int]()) {
      guard !$1.tabName.isEmpty else { return }
      $0[$1.tabName] = Int($1.tabID)
    }
    return TiebaThreadPage(
      forum: forum,
      threads: threads,
      pagination: pagination(data.page),
      tabs: tabs
    )
  }

  static func postPage(_ data: PbPageResIdl.DataRes) -> TiebaPostPage {
    let forum = forum(data.forum)
    let threadAuthor = optionalUser(data.thread.author)
    let mappedThread = thread(
      data.thread,
      forum: forum,
      author: threadAuthor,
      viewCountOverride: data.threadFreqNum > 0 ? Int(data.threadFreqNum) : nil,
      usesPostPageLayout: true
    )
    let users = userLookup(data.userList)
    let threadAuthorID =
      data.thread.authorID != 0 ? data.thread.authorID : mappedThread.author?.id ?? 0

    let posts = data.postList.compactMap { proto -> TiebaPost? in
      guard proto.chatContent.botUk.isEmpty else { return nil }
      return post(
        proto,
        threadID: mappedThread.id,
        threadAuthorID: threadAuthorID,
        users: users
      )
    }
    return TiebaPostPage(
      forum: forum,
      thread: mappedThread,
      posts: posts,
      pagination: pagination(data.page),
      originThread: originThread(data.thread),
      poll: threadPoll(data.thread)
    )
  }

  static func commentPage(_ data: PbFloorResIdl.DataRes) -> TiebaCommentPage {
    let forum = forum(data.forum)
    let mappedThread = thread(data.thread, forum: forum, author: optionalUser(data.thread.author))
    let threadAuthorID =
      data.thread.authorID != 0 ? data.thread.authorID : mappedThread.author?.id ?? 0
    let parentPost = post(
      data.post,
      threadID: mappedThread.id,
      threadAuthorID: threadAuthorID,
      users: [:]
    )
    let comments = data.subpostList.map {
      comment(
        $0,
        threadID: mappedThread.id,
        parentPostID: parentPost.id,
        parentFloor: parentPost.floor,
        threadAuthorID: threadAuthorID,
        users: [:]
      )
    }
    return TiebaCommentPage(
      forum: forum,
      thread: mappedThread,
      parentPost: parentPost,
      comments: comments,
      pagination: pagination(data.page)
    )
  }

  static func userProfile(_ data: ProfileResIdl.DataRes) -> TiebaUserProfile? {
    guard let user = optionalUser(data.user), user.id > 0 else { return nil }
    let rawTiebaUID = Int64(data.user.tiebaUid) ?? 0
    let biography =
      data.user.displayIntro.isEmpty
      ? data.user.intro
      : data.user.displayIntro
    let responseAgreeCount = data.userAgreeInfo.totalAgreeNum
    let userAgreeCount = Int64(data.user.totalAgreeNum)
    let anti = data.antiStat
    return TiebaUserProfile(
      user: user,
      tiebaUID: rawTiebaUID > 0 ? rawTiebaUID : nil,
      biography: biography,
      tiebaAge: data.user.tbAge,
      threadCount: Int(data.user.threadNum),
      postCount: Int(data.user.postNum),
      followerCount: Int(data.user.fansNum),
      followingCount: Int(data.user.concernNum),
      followedForumCount: Int(data.user.myLikeNum),
      totalAgreeCount: max(responseAgreeCount, userAgreeCount),
      isBlocked: anti.blockStat != 0 && anti.hideStat != 0 && anti.daysTofree > 30
    )
  }

  static func userThreadPage(
    _ data: UserPostResIdl.DataRes,
    userID: Int64,
    requestedPage: Int,
    pageSize: Int
  ) -> TiebaUserThreadPage {
    let threads = data.postList.compactMap(userThread)
    return TiebaUserThreadPage(
      userID: userID,
      threads: threads,
      pagination: TiebaPagination(
        pageSize: pageSize,
        currentPage: requestedPage,
        totalPages: 0,
        totalCount: 0,
        hasMore: !data.postList.isEmpty,
        hasPrevious: requestedPage > 1
      ),
      isHidden: data.hidePost != 0
    )
  }

  static func forumOverview(_ data: GetForumDetailResIdl.DataRes) -> TiebaForumOverview? {
    let proto = data.forumInfo
    guard let forumID = Int64(exactly: proto.forumID), forumID > 0 else { return nil }
    let forum = TiebaForum(
      id: forumID,
      name: proto.forumName,
      category: proto.lv1Name,
      subcategory: "",
      memberCount: Int(proto.memberCount),
      threadCount: 0,
      // This endpoint's thread_count is the displayed post total (aiotieba's post_num).
      postCount: Int(proto.threadCount),
      hasModerators: data.electionTab.newStrategyText == "已有吧主",
      hasRules: false,
      avatar: proto.avatar,
      slogan: proto.slogan
    )
    return TiebaForumOverview(
      forum: forum,
      introduction: content(proto.content).plainText,
      originalAvatar: proto.avatarOrigin
    )
  }

  static func forumModeratorRoles(
    _ data: GetBawuInfoResIdl.DataRes
  ) -> [TiebaForumModeratorRole] {
    data.bawuTeamInfo.bawuTeamList.compactMap { role -> TiebaForumModeratorRole? in
      let moderators = role.roleInfo.compactMap {
        forumModerator(
          id: $0.userID,
          username: $0.userName,
          displayName: $0.nameShow,
          portrait: $0.portrait,
          level: $0.userLevel,
          roleName: role.roleName
        )
      }
      guard !role.roleName.isEmpty || !moderators.isEmpty else { return nil }
      return TiebaForumModeratorRole(name: role.roleName, moderators: moderators)
    }
  }

  static func forumRules(
    _ data: ForumRuleDetailResIdl.DataRes,
    requestedForumID: Int64
  ) -> TiebaForumRules {
    let mappedRules = data.rules.map {
      TiebaForumRule(
        title: $0.title,
        content: content($0.content),
        status: Int($0.status)
      )
    }
    let author = forumModerator(
      id: data.bazhu.userID,
      username: data.bazhu.userName,
      displayName: data.bazhu.nameShow,
      portrait: data.bazhu.portrait,
      level: data.bazhu.userLevel,
      roleName: data.bazhu.roleName
    )
    let responseForumID = Int64(data.forum.forumID)
    let forum = TiebaForum(
      id: responseForumID > 0 ? responseForumID : requestedForumID,
      name: data.forum.forumName,
      category: "",
      subcategory: "",
      memberCount: Int(data.forum.concernNum) ?? 0,
      threadCount: 0,
      postCount: Int(data.forum.postNum) ?? 0,
      hasModerators: author != nil,
      hasRules: !mappedRules.isEmpty,
      avatar: data.forum.avatar
    )
    return TiebaForumRules(
      forum: forum,
      title: data.title,
      preface: data.preface,
      rules: mappedRules,
      publishTime: data.publishTime,
      author: author
    )
  }

  private static func pagination(_ proto: Page) -> TiebaPagination {
    let pageSize = Int(proto.pageSize)
    let currentPage = proto.currentPage == 0 && pageSize > 0 ? 1 : Int(proto.currentPage)
    let totalPages = Int(proto.newTotalPage > 0 ? proto.newTotalPage : proto.totalPage)
    let hasMore = proto.hasMore_p != 0 || (totalPages > 0 && currentPage < totalPages)
    let hasPrevious = proto.hasPrev_p != 0 || currentPage > 1
    return TiebaPagination(
      pageSize: pageSize,
      currentPage: currentPage,
      totalPages: totalPages,
      totalCount: Int(proto.totalCount),
      hasMore: hasMore,
      hasPrevious: hasPrevious
    )
  }

  private static func forum(_ proto: SimpleForum) -> TiebaForum {
    TiebaForum(
      id: proto.id,
      name: proto.name,
      category: proto.firstClass,
      subcategory: proto.secondClass,
      memberCount: Int(proto.memberNum),
      threadCount: 0,
      postCount: Int(proto.postNum),
      hasModerators: false,
      hasRules: false
    )
  }

  private static func userLookup(_ protos: [User]) -> [Int64: TiebaUser] {
    protos.reduce(into: [Int64: TiebaUser]()) {
      guard let user = optionalUser($1) else { return }
      $0[user.id] = user
    }
  }

  private static func optionalUser(_ proto: User) -> TiebaUser? {
    guard proto.id != 0 || !proto.name.isEmpty || !proto.nameShow.isEmpty || !proto.portrait.isEmpty
    else {
      return nil
    }
    let rawGender = proto.gender == 0 ? proto.sex : proto.gender
    return TiebaUser(
      id: proto.id,
      username: proto.name,
      displayName: proto.nameShow,
      portrait: normalizedPortrait(proto.portrait),
      level: Int(proto.levelID),
      growthLevel: Int(proto.userGrowth.levelID),
      gender: TiebaGender(rawValue: rawGender) ?? .unknown,
      ipLocation: proto.ipAddress,
      badges: proto.iconinfo.map(\.name).filter { !$0.isEmpty },
      isModerator: proto.isBawu != 0,
      isVIP: !proto.newTshowIcon.isEmpty || proto.vipInfo.vStatus != 0,
      isVerifiedCreator: proto.newGodData.status != 0
    )
  }

  private static func forumModerator(
    id: Int64,
    username: String,
    displayName: String,
    portrait: String,
    level: Int32,
    roleName: String
  ) -> TiebaForumModerator? {
    guard id != 0 || !username.isEmpty || !displayName.isEmpty || !portrait.isEmpty else {
      return nil
    }
    return TiebaForumModerator(
      id: id,
      username: username,
      displayName: displayName,
      portrait: normalizedPortrait(portrait),
      level: Int(level),
      roleName: roleName
    )
  }

  private static func normalizedPortrait(_ portrait: String) -> String {
    portrait
      .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
      .first
      .map(String.init) ?? portrait
  }

  private static func userThread(_ proto: PostInfoList) -> TiebaThread? {
    guard
      let threadID = Int64(exactly: proto.threadID), threadID > 0,
      let forumID = Int64(exactly: proto.forumID),
      let firstPostID = Int64(exactly: proto.postID)
    else { return nil }

    var authorProto = User()
    authorProto.id = proto.userID
    authorProto.name = proto.userName
    authorProto.nameShow = proto.nameShow
    authorProto.portrait = proto.userPortrait

    let mappedContent = assembledContent(
      contentProtos: proto.firstPostContent,
      mediaProtos: proto.media,
      video: proto.videoInfo,
      voices: proto.voiceInfo
    )

    return TiebaThread(
      id: threadID,
      firstPostID: firstPostID,
      forumID: forumID,
      forumName: proto.forumName,
      title: proto.title,
      content: mappedContent,
      author: optionalUser(authorProto),
      kind: TiebaThreadKind(rawValue: Int32(clamping: proto.threadType)),
      tabID: 0,
      viewCount: Int(proto.freqNum),
      replyCount: Int(proto.replyNum),
      shareCount: Int(proto.shareNum),
      agreeCount: Int(proto.agree.agreeNum),
      disagreeCount: Int(proto.agree.disagreeNum),
      createdAt: date(Int64(proto.createTime)),
      lastReplyAt: nil,
      isPinned: false,
      isFeatured: false,
      isShared: proto.isShareThread != 0,
      isHidden: false,
      isLive: false
    )
  }

  private static func thread(
    _ proto: ThreadInfo,
    forum: TiebaForum,
    author: TiebaUser?,
    viewCountOverride: Int? = nil,
    usesPostPageLayout: Bool = false
  ) -> TiebaThread {
    let origin = proto.originThreadInfo
    var contentProtos: [PbContent]
    var mediaProtos = [Media]()

    if usesPostPageLayout {
      contentProtos = origin.content
      mediaProtos = origin.media
      if contentProtos.isEmpty && mediaProtos.isEmpty {
        contentProtos = proto.firstPostContent
      }
    } else if proto.firstPostContent.isEmpty {
      contentProtos = origin.content
      mediaProtos = origin.media
    } else {
      contentProtos = proto.firstPostContent
    }

    let preferredVideo = usesPostPageLayout ? origin.videoInfo : proto.videoInfo
    let fallbackVideo = usesPostPageLayout ? proto.videoInfo : origin.videoInfo
    let video = hasVideo(preferredVideo) ? preferredVideo : fallbackVideo
    let voices =
      usesPostPageLayout
      ? (origin.voiceInfo.isEmpty ? proto.voiceInfo : origin.voiceInfo)
      : (proto.voiceInfo.isEmpty ? origin.voiceInfo : proto.voiceInfo)

    return TiebaThread(
      id: proto.id,
      firstPostID: proto.firstPostID == 0 ? proto.postID : proto.firstPostID,
      forumID: forum.id,
      forumName: forum.name,
      title: proto.title,
      content: assembledContent(
        contentProtos: contentProtos,
        mediaProtos: mediaProtos,
        video: video,
        voices: voices
      ),
      author: author,
      kind: TiebaThreadKind(rawValue: proto.threadType),
      tabID: Int(proto.tabID),
      viewCount: viewCountOverride ?? Int(proto.viewNum),
      replyCount: Int(proto.replyNum),
      shareCount: Int(proto.shareNum),
      agreeCount: Int(proto.agree.agreeNum),
      disagreeCount: Int(proto.agree.disagreeNum),
      createdAt: date(Int64(proto.createTime)),
      lastReplyAt: date(Int64(proto.lastTimeInt)),
      isPinned: proto.isTop != 0,
      isFeatured: proto.isGood != 0,
      isShared: proto.isShareThread != 0,
      isHidden: proto.isFrsMask != 0,
      isLive: proto.isLivepost != 0,
      pagePostIDs: proto.pids.split(separator: ",").compactMap {
        guard let postID = Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)), postID > 0
        else { return nil }
        return postID
      }
    )
  }

  private static func originThread(_ proto: ThreadInfo) -> TiebaOriginThread? {
    guard proto.isShareThread == 1 else { return nil }
    let origin = proto.originThreadInfo
    let rawThreadID = origin.tid.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      let threadID = Int64(rawThreadID),
      threadID > 0,
      threadID != proto.id
    else { return nil }

    return TiebaOriginThread(
      id: threadID,
      firstPostID: max(origin.pid, 0),
      forumID: max(origin.fid, 0),
      forumName: origin.fname.trimmingCharacters(in: .whitespacesAndNewlines),
      title: origin.title.trimmingCharacters(in: .whitespacesAndNewlines),
      content: assembledContent(
        contentProtos: origin.content,
        mediaProtos: origin.media,
        video: origin.videoInfo,
        voices: origin.voiceInfo
      ),
      poll: poll(origin.pollInfo)
    )
  }

  private static func threadPoll(_ proto: ThreadInfo) -> TiebaPoll? {
    if let directPoll = poll(proto.pollInfo) {
      return directPoll
    }
    guard proto.isShareThread == 0 else { return nil }
    return poll(proto.originThreadInfo.pollInfo)
  }

  private static func poll(_ proto: PollInfo) -> TiebaPoll? {
    let options = proto.options.map { option in
      TiebaPollOption(
        text: option.text.trimmingCharacters(in: .whitespacesAndNewlines),
        voteCount: max(option.num, 0)
      )
    }
    guard !options.isEmpty else { return nil }

    return TiebaPoll(
      title: proto.title.trimmingCharacters(in: .whitespacesAndNewlines),
      isMultipleChoice: proto.isMulti == 1,
      participantCount: max(proto.totalNum, 0),
      totalVoteCount: max(proto.totalPoll, 0),
      options: options
    )
  }

  private static func assembledContent(
    contentProtos: [PbContent],
    mediaProtos: [Media],
    video: VideoInfo,
    voices: [Voice]
  ) -> TiebaContent {
    var contentProtos = contentProtos
    contentProtos.removeAll { content in
      switch content.type {
      case 3, 20:
        !mediaProtos.isEmpty
      case 5:
        hasVideo(video)
      case 10:
        !voices.isEmpty
      default:
        false
      }
    }

    var fragments = content(contentProtos).fragments
    fragments.append(contentsOf: mediaProtos.map(mediaFragment))
    if hasVideo(video) {
      fragments.append(.video(videoFragment(video)))
    }
    fragments.append(
      contentsOf: voices.filter { !$0.voiceMd5.isEmpty }.map {
        .voice(TiebaVoice(md5: $0.voiceMd5, duration: TimeInterval($0.duringTime) / 1_000))
      })
    return TiebaContent(fragments: fragments)
  }

  private static func feedThread(
    _ proto: PageData.LayoutFactory.FeedLayout,
    forum: TiebaForum,
    users: [Int64: TiebaUser]
  ) -> TiebaThread? {
    let values = proto.businessInfo.reduce(into: [String: String]()) { $0[$1.key] = $1.value }
    guard let threadID = Int64(values["thread_id"] ?? ""), threadID > 0 else { return nil }

    var fragments = [TiebaContentFragment]()
    for component in proto.components {
      switch component.component {
      case "feed_abstract":
        for resource in component.feedAbstract.data {
          switch resource.type {
          case 1:
            fragments.append(.text(resource.textInfo.text))
          case 3:
            fragments.append(
              .emoji(identifier: resource.emojiInfo.name, description: resource.emojiInfo.c)
            )
          default:
            fragments.append(.unknown(type: UInt32(max(resource.type, 0)), text: ""))
          }
        }
      case "feed_pic":
        fragments.append(
          contentsOf: component.feedPic.pics.map {
            .image(
              TiebaImage(
                thumbnailURL: remoteURL($0.smallPicURL),
                fullSizeURL: remoteURL($0.bigPicURL),
                originalURL: remoteURL($0.originPicURL),
                width: Int($0.width),
                height: Int($0.height),
                originalByteCount: 0
              )
            )
          })
      default:
        continue
      }
    }

    let authorID = Int64(values["user_id"] ?? "") ?? 0
    let rawKind = Int32(values["thread_type"] ?? "") ?? -1
    return TiebaThread(
      id: threadID,
      firstPostID: 0,
      forumID: forum.id,
      forumName: forum.name,
      title: values["title"] ?? "",
      content: TiebaContent(fragments: fragments),
      author: users[authorID],
      kind: TiebaThreadKind(rawValue: rawKind),
      tabID: Int(values["inner_tab_id"] ?? "") ?? 0,
      viewCount: Int(values["view_num"] ?? "") ?? 0,
      replyCount: 0,
      shareCount: 0,
      agreeCount: 0,
      disagreeCount: 0,
      createdAt: date(Int64(values["create_time"] ?? "") ?? 0),
      lastReplyAt: nil,
      isPinned: false,
      isFeatured: false,
      isShared: false,
      isHidden: false,
      isLive: false
    )
  }

  private static func post(
    _ proto: Post,
    threadID: Int64,
    threadAuthorID: Int64,
    users: [Int64: TiebaUser]
  ) -> TiebaPost {
    let author = users[proto.authorID] ?? optionalUser(proto.author)
    let authorID = proto.authorID != 0 ? proto.authorID : author?.id ?? 0
    let comments = proto.subPostList.subPostList.map {
      comment(
        $0,
        threadID: threadID,
        parentPostID: proto.id,
        parentFloor: Int(proto.floor),
        threadAuthorID: threadAuthorID,
        users: users
      )
    }
    let signature = proto.signature.content
      .filter { $0.type == 0 }
      .map(\.text)
      .joined()
    return TiebaPost(
      id: proto.id,
      threadID: threadID,
      floor: Int(proto.floor),
      author: author,
      content: content(proto.content),
      signature: signature,
      comments: comments,
      commentCount: Int(proto.subPostNumber),
      agreeCount: Int(clamping: proto.agree.agreeNum),
      disagreeCount: Int(clamping: proto.agree.disagreeNum),
      createdAt: date(Int64(proto.time)),
      isThreadAuthor: threadAuthorID != 0 && authorID == threadAuthorID,
      isAIMeme: proto.spriteMemeInfo.memeID != 0,
      agreeScore: agreeScore(proto.agree)
    )
  }

  private static func comment(
    _ proto: SubPostList,
    threadID: Int64,
    parentPostID: Int64,
    parentFloor: Int,
    threadAuthorID: Int64,
    users: [Int64: TiebaUser]
  ) -> TiebaComment {
    let author = users[proto.authorID] ?? optionalUser(proto.author)
    let authorID = proto.authorID != 0 ? proto.authorID : author?.id ?? 0
    let replyTarget = replyTarget(in: proto.content)
    return TiebaComment(
      id: proto.id,
      threadID: threadID,
      parentPostID: parentPostID,
      floor: parentFloor,
      author: author,
      replyToUserID: replyTarget?.id,
      content: content(proto.content),
      agreeCount: Int(clamping: proto.agree.agreeNum),
      disagreeCount: Int(clamping: proto.agree.disagreeNum),
      createdAt: date(Int64(proto.time)),
      isThreadAuthor: threadAuthorID != 0 && authorID == threadAuthorID,
      agreeScore: agreeScore(proto.agree),
      replyToUserName: replyTarget?.name ?? ""
    )
  }

  private static func replyTarget(in content: [PbContent]) -> (id: Int64, name: String)? {
    let mention: PbContent?
    if let first = content.first, first.type == 4, first.uid > 0 {
      mention = first
    } else if content.count >= 2,
      content[0].text.trimmingCharacters(in: .whitespacesAndNewlines) == "回复",
      content[1].type == 4,
      content[1].uid > 0
    {
      mention = content[1]
    } else {
      mention = nil
    }
    guard let mention else { return nil }

    let name = mention.text.trimmingCharacters(
      in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "@"))
    )
    return (mention.uid, name)
  }

  private static func agreeScore(_ proto: Agree) -> Int {
    if proto.diffAgreeNum != 0 {
      return Int(clamping: proto.diffAgreeNum)
    }
    let (score, overflow) = proto.agreeNum.subtractingReportingOverflow(proto.disagreeNum)
    guard overflow else { return Int(clamping: score) }
    return proto.agreeNum >= 0 ? Int.max : Int.min
  }

  private static func content(_ protos: [PbContent]) -> TiebaContent {
    TiebaContent(fragments: protos.map(fragment))
  }

  private static func fragment(_ proto: PbContent) -> TiebaContentFragment {
    switch proto.type {
    case 0, 9, 18, 27, 40:
      .text(proto.text)
    case 2, 11:
      .emoji(identifier: proto.text, description: proto.c)
    case 3, 20:
      .image(image(proto))
    case 4:
      .mention(TiebaMention(text: proto.text, userID: proto.uid))
    case 1:
      .link(TiebaLink(text: proto.link, title: proto.text, url: remoteURL(proto.link)))
    case 5:
      .video(
        TiebaVideo(
          streamURL: remoteURL(proto.link),
          coverURL: remoteURL(proto.src),
          duration: TimeInterval(proto.duringTime),
          width: Int(proto.width),
          height: Int(proto.height),
          viewCount: Int(proto.count)
        )
      )
    case 10:
      .voice(TiebaVoice(md5: proto.voiceMd5, duration: TimeInterval(proto.duringTime) / 1_000))
    case 35, 36, 37:
      .tiebaPlus(
        description: proto.tiebaplusInfo.desc,
        url: remoteURL(proto.tiebaplusInfo.jumpURL)
      )
    default:
      .unknown(type: proto.type, text: proto.text)
    }
  }

  private static func image(_ proto: PbContent) -> TiebaImage {
    let dimensions = proto.bsize.split(separator: ",", maxSplits: 1).compactMap { Int($0) }
    return TiebaImage(
      thumbnailURL: remoteURL(proto.cdnSrc),
      fullSizeURL: remoteURL(proto.bigCdnSrc),
      originalURL: remoteURL(proto.originSrc),
      width: dimensions.first ?? Int(proto.width),
      height: dimensions.count > 1 ? dimensions[1] : Int(proto.height),
      originalByteCount: Int(proto.originSize)
    )
  }

  private static func mediaFragment(_ proto: Media) -> TiebaContentFragment {
    .image(
      TiebaImage(
        thumbnailURL: remoteURL(proto.waterPic),
        fullSizeURL: remoteURL(proto.smallPic),
        originalURL: remoteURL(proto.bigPic.isEmpty ? proto.originPic : proto.bigPic),
        width: Int(proto.width),
        height: Int(proto.height),
        originalByteCount: Int(proto.originSize)
      )
    )
  }

  private static func videoFragment(_ proto: VideoInfo) -> TiebaVideo {
    TiebaVideo(
      streamURL: remoteURL(proto.videoURL),
      coverURL: remoteURL(proto.thumbnailURL),
      duration: TimeInterval(proto.videoDuration),
      width: Int(proto.videoWidth),
      height: Int(proto.videoHeight),
      viewCount: Int(proto.playCount)
    )
  }

  private static func hasVideo(_ proto: VideoInfo) -> Bool {
    !proto.videoURL.isEmpty || proto.videoWidth != 0
  }

  private static func remoteURL(_ rawValue: String) -> URL? {
    guard !rawValue.isEmpty else { return nil }
    if rawValue.hasPrefix("//") {
      return URL(string: "https:\(rawValue)")
    }
    guard let url = URL(string: rawValue), let scheme = url.scheme?.lowercased() else {
      return nil
    }
    return scheme == "http" || scheme == "https" ? url : nil
  }

  private static func date(_ timestamp: Int64) -> Date? {
    guard timestamp > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(timestamp))
  }
}
