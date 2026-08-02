import Foundation
import TiebaProto

enum ProtoFixtures {
  static func threadPage() -> FrsPageResIdl {
    var forum = FrsPageResIdl.DataRes.ForumInfo()
    forum.id = 42
    forum.name = "swift"
    forum.firstClass = "technology"
    forum.secondClass = "programming"
    forum.memberNum = 1_000
    forum.threadNum = 200
    forum.postNum = 3_000
    forum.managers = [FrsPageResIdl.DataRes.ForumInfo.Manager()]
    forum.avatar = "https://img.example/forum.png"
    forum.slogan = "A forum for Swift"
    var classification = FrsPageResIdl.DataRes.ForumInfo.Classify()
    classification.classID = 9
    classification.className = "Tutorials"
    forum.goodClassify = [classification]

    var page = Page()
    page.pageSize = 30
    page.currentPage = 1
    page.totalPage = 3
    page.totalCount = 61
    page.hasMore_p = 1

    var user = User()
    user.id = 7
    user.name = "author"
    user.nameShow = "Swift Author"
    user.portrait = "portrait-token?t=1234567890"
    user.levelID = 12
    user.userGrowth.levelID = 5
    user.gender = 2
    user.ipAddress = "Shanghai"
    user.isBawu = 1
    user.newTshowIcon = [User.TshowInfo.with { $0.name = "vip" }]
    user.iconinfo = [User.Icon.with { $0.name = "contributor" }]

    var text = PbContent()
    text.type = 0
    text.text = "Hello "
    var mention = PbContent()
    mention.type = 4
    mention.text = "@reader"
    mention.uid = 8
    var image = PbContent()
    image.type = 3
    image.cdnSrc = "//img.example/thumb.jpg"
    image.bigCdnSrc = "https://img.example/full.jpg"
    image.originSrc = "https://img.example/original.jpg"
    image.bsize = "640,480"

    var thread = ThreadInfo()
    thread.id = 100
    thread.firstPostID = 101
    thread.title = "A test thread"
    thread.authorID = user.id
    thread.threadType = 0
    thread.replyNum = 12
    thread.viewNum = 345
    thread.createTime = 1_700_000_000
    thread.lastTimeInt = 1_700_000_100
    thread.isTop = 1
    thread.firstPostContent = [text, mention, image]
    thread.agree.agreeNum = 9

    var tab = FrsTabInfo()
    tab.tabID = 3
    tab.tabName = "Latest"

    var data = FrsPageResIdl.DataRes()
    data.forum = forum
    data.page = page
    data.threadList = [thread]
    data.userList = [user]
    data.navTabInfo.tab = [tab]
    data.forumRule.hasForumRule_p = 1

    var response = FrsPageResIdl()
    response.data = data
    return response
  }

  static func postPage() -> PbPageResIdl {
    let author = makeUser(id: 7, name: "thread-author")
    let commenter = makeUser(id: 8, name: "commenter")

    var forum = SimpleForum()
    forum.id = 42
    forum.name = "swift"
    forum.memberNum = 1_000
    forum.postNum = 3_000

    var page = Page()
    page.pageSize = 30
    page.currentPage = 2
    page.totalPage = 4
    page.newTotalPage = 6
    page.totalCount = 100
    page.lzTotalFloor = 33
    page.hasMore_p = 1
    page.hasPrev_p = 1

    var thread = ThreadInfo()
    thread.id = 100
    thread.postID = 101
    thread.title = "A test thread"
    thread.author = author
    thread.authorID = author.id
    thread.replyNum = 99
    thread.pids = "301, invalid, 0, 302,"

    var inlineImage = PbContent()
    inlineImage.type = 3
    inlineImage.cdnSrc = "https://img.example/duplicate-thumb.jpg"
    inlineImage.bigCdnSrc = "https://img.example/duplicate-full.jpg"
    var inlineVideo = PbContent()
    inlineVideo.type = 5
    inlineVideo.link = "https://video.example/duplicate.mp4"
    inlineVideo.width = 640
    var inlineVoice = PbContent()
    inlineVoice.type = 10
    inlineVoice.voiceMd5 = "duplicate-voice"

    var media = Media()
    media.waterPic = "https://img.example/thread-thumb.jpg"
    media.smallPic = "https://img.example/thread-full.jpg"
    media.bigPic = "https://img.example/thread-original.jpg"
    media.width = 640
    media.height = 480

    var video = VideoInfo()
    video.videoURL = "https://video.example/thread.mp4"
    video.thumbnailURL = "https://img.example/video-cover.jpg"
    video.videoWidth = 1280
    video.videoHeight = 720

    var voice = Voice()
    voice.voiceMd5 = "thread-voice"
    voice.duringTime = 2_500

    thread.originThreadInfo.content = [text("Opening post"), inlineImage, inlineVideo, inlineVoice]
    thread.originThreadInfo.media = [media]
    thread.originThreadInfo.videoInfo = video
    thread.originThreadInfo.voiceInfo = [voice]

    var nested = SubPostList()
    nested.id = 202
    nested.authorID = commenter.id
    nested.content = [text("Nested reply")]
    nested.time = 1_700_000_200
    nested.agree.agreeNum = 3

    var post = Post()
    post.id = 201
    post.tid = thread.id
    post.floor = 2
    post.authorID = author.id
    post.content = [text("Floor content")]
    post.subPostNumber = 1
    post.subPostList.subPostList = [nested]
    post.signature.content = [
      Post.SignatureData.SignatureContent.with {
        $0.type = 0
        $0.text = "Sent from fixture"
      }
    ]
    post.agree.agreeNum = 5
    post.time = 1_700_000_150

    var data = PbPageResIdl.DataRes()
    data.forum = forum
    data.page = page
    data.thread = thread
    data.postList = [post]
    data.userList = [author, commenter]
    data.threadFreqNum = 500

    var response = PbPageResIdl()
    response.data = data
    return response
  }

  static func postPageWithoutExpandedUsers() -> PbPageResIdl {
    var response = postPage()
    var data = response.data
    data.userList = []
    data.thread.author = User()

    var post = data.postList[0]
    post.author = User()
    var comment = post.subPostList.subPostList[0]
    comment.author = User()
    comment.authorID = data.thread.authorID
    post.subPostList.subPostList = [comment]
    data.postList = [post]
    response.data = data
    return response
  }

  static func threadPageWithUnsafeLink() -> FrsPageResIdl {
    var response = threadPage()
    var data = response.data
    var thread = data.threadList[0]
    var link = PbContent()
    link.type = 1
    link.text = "local file"
    link.link = "file:///private/account-data"
    thread.firstPostContent.append(link)
    data.threadList = [thread]
    response.data = data
    return response
  }

  static func commentPage() -> PbFloorResIdl {
    let author = makeUser(id: 7, name: "thread-author")
    let commenter = makeUser(id: 8, name: "commenter")

    var forum = SimpleForum()
    forum.id = 42
    forum.name = "swift"

    var thread = ThreadInfo()
    thread.id = 100
    thread.title = "A test thread"
    thread.author = author
    thread.authorID = author.id

    var parent = Post()
    parent.id = 201
    parent.floor = 2
    parent.author = author
    parent.authorID = author.id
    parent.content = [text("Parent")]

    var replyPrefix = PbContent()
    replyPrefix.type = 0
    replyPrefix.text = "回复 "
    var replyMention = PbContent()
    replyMention.type = 4
    replyMention.text = "@thread-author"
    replyMention.uid = author.id

    var comment = SubPostList()
    comment.id = 202
    comment.author = commenter
    comment.authorID = commenter.id
    comment.content = [replyPrefix, replyMention, text(" :Nested reply")]
    comment.time = 1_700_000_200

    var page = Page()
    page.pageSize = 20
    page.currentPage = 1
    page.totalPage = 1
    page.totalCount = 1

    var data = PbFloorResIdl.DataRes()
    data.forum = forum
    data.thread = thread
    data.post = parent
    data.subpostList = [comment]
    data.page = page

    var response = PbFloorResIdl()
    response.data = data
    return response
  }

  static func userProfile() -> ProfileResIdl {
    var user = User()
    user.id = 957_339_815
    user.name = "profile-user"
    user.nameShow = "Profile User"
    user.portrait = "profile-portrait?t=1234567890"
    user.userGrowth.levelID = 12
    user.sex = 2
    user.fansNum = 345
    user.concernNum = 67
    user.myLikeNum = 23
    user.intro = "Legacy introduction"
    user.displayIntro = "Public biography"
    user.postNum = 890
    user.threadNum = 123
    user.tbAge = "14.2"
    user.tiebaUid = "123456789"
    user.ipAddress = "上海"
    user.iconinfo = [User.Icon.with { $0.name = "fixture badge" }]
    user.newTshowIcon = [User.TshowInfo.with { $0.name = "vip" }]
    user.newGodData.status = 1

    var data = ProfileResIdl.DataRes()
    data.user = user
    data.userAgreeInfo.totalAgreeNum = 12_345
    data.antiStat.blockStat = 1
    data.antiStat.hideStat = 1
    data.antiStat.daysTofree = 31

    var response = ProfileResIdl()
    response.data = data
    return response
  }

  static func userThreadPage() -> UserPostResIdl {
    var duplicateImage = PbContent()
    duplicateImage.type = 3
    duplicateImage.cdnSrc = "https://img.example/duplicate.jpg"

    var media = Media()
    media.waterPic = "https://img.example/user-thread-thumb.jpg"
    media.smallPic = "https://img.example/user-thread-full.jpg"
    media.bigPic = "https://img.example/user-thread-original.jpg"
    media.width = 800
    media.height = 600

    var thread = PostInfoList()
    thread.forumID = 42
    thread.threadID = 700
    thread.postID = 701
    thread.createTime = 1_700_100_000
    thread.forumName = "swift"
    thread.title = "A public user thread"
    thread.userName = "profile-user"
    thread.userID = 957_339_815
    thread.userPortrait = "profile-portrait?t=1234567890"
    thread.nameShow = "Profile User"
    thread.replyNum = 19
    thread.freqNum = 456
    thread.threadType = 0
    thread.firstPostContent = [text("Public activity"), duplicateImage]
    thread.media = [media]
    thread.agree.agreeNum = 8

    var data = UserPostResIdl.DataRes()
    data.postList = [thread]

    var response = UserPostResIdl()
    response.data = data
    return response
  }

  static func forumOverview() -> GetForumDetailResIdl {
    var forum = GetForumDetailResIdl.DataRes.RecommendForumInfo()
    forum.forumID = 42
    forum.forumName = "swift"
    forum.avatar = "https://img.example/forum-small.png"
    forum.avatarOrigin = "https://img.example/forum-original.png"
    forum.memberCount = 1_000
    forum.threadCount = 3_000
    forum.slogan = "A short forum slogan"
    forum.content = [text("A public forum introduction")]
    forum.lv1Name = "technology"

    var data = GetForumDetailResIdl.DataRes()
    data.forumInfo = forum
    data.electionTab.newStrategyText = "已有吧主"

    var response = GetForumDetailResIdl()
    response.data = data
    return response
  }

  static func forumModerators() -> GetBawuInfoResIdl {
    var moderator =
      GetBawuInfoResIdl.DataRes.BawuTeam.BawuRoleDes.BawuRoleInfoPub()
    moderator.userID = 7
    moderator.userName = "forum-owner"
    moderator.nameShow = "Forum Owner"
    moderator.portrait = "moderator-portrait?t=1234567890"
    moderator.userLevel = 16

    var role = GetBawuInfoResIdl.DataRes.BawuTeam.BawuRoleDes()
    role.roleName = "吧主"
    role.roleInfo = [moderator]

    var data = GetBawuInfoResIdl.DataRes()
    data.bawuTeamInfo.totalNum = 1
    data.bawuTeamInfo.bawuTeamList = [role]

    var response = GetBawuInfoResIdl()
    response.data = data
    return response
  }

  static func forumRules() -> ForumRuleDetailResIdl {
    var forum = ForumRuleDetailResIdl.DataRes.ForumInfo()
    forum.forumID = 42
    forum.forumName = "swift"
    forum.avatar = "https://img.example/forum.png"
    forum.postNum = "3000"
    forum.concernNum = "1000"

    var rule = ForumRuleDetailResIdl.DataRes.ForumRule()
    rule.title = "Be constructive"
    rule.content = [text("Read before posting"), text(" and respect other members")]
    rule.status = 1

    var author = ForumRuleDetailResIdl.DataRes.Moderator()
    author.userID = 7
    author.roleName = "吧主"
    author.userName = "forum-owner"
    author.nameShow = "Forum Owner"
    author.portrait = "moderator-portrait?t=1234567890"
    author.userLevel = 16

    var data = ForumRuleDetailResIdl.DataRes()
    data.forum = forum
    data.title = "Swift 吧规"
    data.preface = "Welcome"
    data.rules = [rule]
    data.publishTime = "2026-08-02"
    data.bazhu = author

    var response = ForumRuleDetailResIdl()
    response.data = data
    return response
  }

  static func serverError(code: Int32, message: String) -> FrsPageResIdl {
    var response = FrsPageResIdl()
    response.error.errorno = code
    response.error.errmsg = message
    return response
  }

  private static func makeUser(id: Int64, name: String) -> User {
    var user = User()
    user.id = id
    user.name = name
    user.nameShow = name
    return user
  }

  private static func text(_ value: String) -> PbContent {
    var content = PbContent()
    content.type = 0
    content.text = value
    return content
  }
}
