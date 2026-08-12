import SwiftUI

struct AppSettingsView: View {
  private struct ImageCacheNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
  }

  @StateObject private var historyViewModel: BrowsingHistoryViewModel
  private let imageRepository: DownsampledImageRepository
  private let persistentImageCache: any RemoteImagePersistentCacheProviding
  @State private var imageCacheUsage: RemoteImageDiskCacheUsage?
  @State private var imageCacheUsageRequestID: UUID?
  @State private var isClearingImageCache = false
  @State private var imageCacheNotice: ImageCacheNotice?
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @AppStorage(AppPreferenceKey.appearance)
  private var appearance = AppAppearance.system.rawValue
  @AppStorage(AppPreferenceKey.accentColor)
  private var accentColor = AppAccentColor.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.textSizeAdjustment)
  private var textSizeAdjustment = AppTextSizeAdjustment.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.defaultForumSort)
  private var defaultForumSort = ForumThreadSort.replyTime.rawValue
  @AppStorage(AppPreferenceKey.forumPrimaryAction)
  private var forumPrimaryAction = ForumPrimaryAction.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.homeStartDestination)
  private var homeStartDestination = AppStartDestination.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.homeShowsDiscovery)
  private var homeShowsDiscovery = AppPreferenceDefaults.homeShowsDiscovery
  @AppStorage(AppPreferenceKey.homeShowsRecentForums)
  private var homeShowsRecentForums = true
  @AppStorage(AppPreferenceKey.followedForumsLayout)
  private var followedForumsLayout = FollowedForumsLayoutMode.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.favoriteThreadsOpenOnlyAuthor)
  private var favoriteThreadsOpenOnlyAuthor =
    AppPreferenceDefaults.favoriteThreadsOpenOnlyAuthor
  @AppStorage(AppPreferenceKey.favoriteThreadsOpenDescending)
  private var favoriteThreadsOpenDescending =
    AppPreferenceDefaults.favoriteThreadsOpenDescending
  @AppStorage(AppPreferenceKey.searchSuggestionsEnabled)
  private var searchSuggestionsEnabled = false
  @AppStorage(AppPreferenceKey.personalizedFollowedForumsOnly)
  private var personalizedFollowedForumsOnly =
    AppPreferenceDefaults.personalizedFollowedForumsOnly
  @AppStorage(AppPreferenceKey.externalWebOpenMode)
  private var externalWebOpenMode = ExternalWebOpenMode.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.contentMediaLoadPolicy)
  private var contentMediaLoadPolicy = ContentMediaLoadPolicy.automatic.rawValue
  @AppStorage(AppPreferenceKey.contentImagePreviewQuality)
  private var contentImagePreviewQuality = ContentImagePreviewQuality.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.hidesThreadListMedia)
  private var hidesThreadListMedia = false
  @AppStorage(AppPreferenceKey.hidesReplyEntryPoints)
  private var hidesReplyEntryPoints = AppPreferenceDefaults.hidesReplyEntryPoints
  @AppStorage(AppPreferenceKey.showsPostAndReplyRiskNotice)
  private var showsPostAndReplyRiskNotice = AppPreferenceDefaults.showsPostAndReplyRiskNotice
  @AppStorage(AppPreferenceKey.darkensContentThumbnailsInDarkMode)
  private var darkensContentThumbnailsInDarkMode = true
  @AppStorage(AppPreferenceKey.showsBothUsernameAndNickname)
  private var showsBothUsernameAndNickname = false

  init(
    historyRepository: any BrowsingHistoryRepository,
    imageRepository: DownsampledImageRepository = .shared,
    persistentImageCache: any RemoteImagePersistentCacheProviding = RemoteImageDiskCache.shared
  ) {
    _historyViewModel = StateObject(
      wrappedValue: BrowsingHistoryViewModel(repository: historyRepository)
    )
    self.imageRepository = imageRepository
    self.persistentImageCache = persistentImageCache
  }

  var body: some View {
    List {
      Section("外观") {
        if AppDynamicTypeLayout.prefersMenuPickers(for: dynamicTypeSize) {
          appearancePicker
            .pickerStyle(.menu)
        } else {
          appearancePicker
            .pickerStyle(.segmented)
        }

        NavigationLink {
          AppAccentColorSettingsView(selection: accentColorSelection)
        } label: {
          HStack(spacing: 10) {
            Label("强调色", systemImage: "paintpalette")
            Spacer(minLength: 12)
            Circle()
              .fill(selectedAccentColor.color)
              .frame(width: 18, height: 18)
              .overlay {
                Circle()
                  .stroke(Color(uiColor: .separator), lineWidth: 0.5)
              }
              .accessibilityHidden(true)
            Text(selectedAccentColor.title)
              .foregroundStyle(.secondary)
          }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("强调色")
        .accessibilityValue(selectedAccentColor.title)
        .accessibilityIdentifier("settings-accent-color")

        Picker("应用内字号", selection: textSizeAdjustmentSelection) {
          ForEach(AppTextSizeAdjustment.allCases) { adjustment in
            Text(adjustment.title).tag(adjustment)
          }
        }
        .pickerStyle(.menu)
      }

      Section("使用习惯") {
        if AppDynamicTypeLayout.prefersMenuPickers(for: dynamicTypeSize) {
          defaultForumSortPicker
            .pickerStyle(.menu)
        } else {
          defaultForumSortPicker
            .pickerStyle(.segmented)
        }

        Picker("贴吧页主快捷操作", selection: forumPrimaryActionSelection) {
          ForEach(ForumPrimaryAction.allCases) { action in
            Text(action.title).tag(action)
          }
        }
        .pickerStyle(.menu)
        .accessibilityIdentifier("settings-forum-primary-action")

        Toggle(
          "不保存浏览记录",
          isOn: Binding(
            get: { !historyViewModel.recordingEnabled },
            set: { historyViewModel.setRecordingEnabled(!$0) }
          )
        )
        .disabled(historyViewModel.state != .loaded)

        switch historyViewModel.state {
        case .idle, .loading:
          HStack {
            Text("正在读取浏览记录设置")
              .foregroundStyle(.secondary)
            Spacer()
            ProgressView()
          }
        case .failed(let message):
          VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
              .foregroundStyle(.secondary)
            Button {
              historyViewModel.reload()
            } label: {
              Label("重试", systemImage: "arrow.clockwise")
            }
          }
        case .loaded:
          EmptyView()
        }
      }

      Section {
        Toggle("隐藏回复入口", isOn: $hidesReplyEntryPoints)
          .accessibilityIdentifier("settings-hide-reply-entry-points")

        Toggle("发帖和回复风险提示", isOn: $showsPostAndReplyRiskNotice)
          .accessibilityIdentifier("settings-post-reply-risk-notice")
      } header: {
        Text("阅读与回复")
      } footer: {
        Text(
          "开启后，会隐藏主题、楼层、楼中楼和消息列表中的回复按钮；"
            + "不会隐藏回复内容或删除草稿。风险提示默认开启，会在进入发帖或回复编辑器时显示；"
            + "关闭后，实际发送或发布前仍需逐次确认。两项设置只保存在本机，切换时不会发起网络请求。"
        )
      }

      Section {
        Picker("启动首选页", selection: homeStartDestinationSelection) {
          ForEach(AppStartDestination.allCases) { destination in
            Text(destination.title).tag(destination)
          }
        }
        .pickerStyle(.menu)

        Toggle("显示发现区", isOn: $homeShowsDiscovery)

        Toggle("显示最近访问的贴吧", isOn: $homeShowsRecentForums)

        if AppDynamicTypeLayout.prefersMenuPickers(for: dynamicTypeSize) {
          followedForumsLayoutPicker
            .pickerStyle(.menu)
        } else {
          followedForumsLayoutPicker
            .pickerStyle(.segmented)
        }
      } header: {
        Text("首页")
      } footer: {
        Text("启动首选页会在下次启动应用时生效；辅助功能字号下，关注贴吧固定使用单列。")
      }

      Section {
        Toggle("只推荐已关注的吧", isOn: $personalizedFollowedForumsOnly)
      } header: {
        Text("推荐")
      } footer: {
        Text("开启后，推荐页只显示当前账户已关注贴吧中的帖子；需要先登录并读取完整关注列表。")
      }

      Section {
        Toggle("从收藏打开时只看楼主", isOn: $favoriteThreadsOpenOnlyAuthor)

        Toggle("从收藏打开时使用倒序", isOn: $favoriteThreadsOpenDescending)
      } header: {
        Text("本地收藏")
      } footer: {
        Text(
          "这些开关只在从本地收藏进入帖子时直接覆盖模式。打开后，实际模式会按现有规则"
            + "成为该帖在收藏和浏览记录中的当前模式；关闭开关不会恢复此前值。"
        )
      }

      Section {
        Toggle("在线搜索联想", isOn: $searchSuggestionsEnabled)
      } header: {
        Text("搜索与隐私")
      } footer: {
        Text("开启后，会在您提交搜索前向百度发送输入关键词，以获取在线联想建议。")
      }

      Section {
        Picker("外部 HTTPS 链接", selection: externalWebOpenModeSelection) {
          ForEach(ExternalWebOpenMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.menu)
      } header: {
        Text("链接")
      } footer: {
        Text(
          "可识别的贴吧、帖子和用户链接始终优先在应用内打开。HTTP 链接始终交由系统处理；"
            + "应用内 Safari 使用 Safari 网站会话打开其他 HTTPS 链接。"
        )
      }

      Section {
        Toggle("同时显示用户名和昵称", isOn: $showsBothUsernameAndNickname)
      } header: {
        Text("用户名称")
      } footer: {
        Text("开启后，会在公开昵称后同时显示公开用户名；仅使用页面已经返回的公开资料，不会发起额外请求。")
      }

      Section {
        if AppDynamicTypeLayout.prefersMenuPickers(for: dynamicTypeSize) {
          contentMediaLoadPolicyPicker
            .pickerStyle(.menu)
        } else {
          contentMediaLoadPolicyPicker
            .pickerStyle(.segmented)
        }

        Picker("图片预览画质", selection: contentImagePreviewQualitySelection) {
          ForEach(ContentImagePreviewQuality.allCases) { quality in
            Text(quality.title).tag(quality)
          }
        }
        .pickerStyle(.menu)

        Toggle("收起帖子列表的图片和视频", isOn: $hidesThreadListMedia)

        Toggle("深色模式压暗缩略图", isOn: $darkensContentThumbnailsInDarkMode)

        NavigationLink {
          ContentFilterSettingsView()
        } label: {
          Label("内容屏蔽", systemImage: "hand.raised")
        }
      } header: {
        Text("内容")
      } footer: {
        Text(
          "\u{201c}节省流量\u{201d}在普通 Wi-Fi 等非昂贵、非低数据模式网络上自动加载；"
            + "在蜂窝网络、个人热点或低数据模式下需点按加载。\u{201c}点按加载\u{201d}在所有网络上"
            + "均需点按；两种模式都会直接显示内存或磁盘中已缓存的图片。这些模式控制展开后的列表媒体、"
            + "帖子正文、话题图片和视频封面，头像、图库、页面数据和其他网络请求不受影响。\n\n"
            + "图片预览画质只在服务器同时返回标准和高清地址时选择帖子正文、帖子列表和吧内搜索"
            + "所用的图片地址；高清可能使用更多流量。打开图库后仍优先加载原图，不受此选项影响。\n\n"
            + "\u{201c}收起帖子列表的图片和视频\u{201d}仅影响帖子列表和吧内搜索；收起时不会创建列表"
            + "媒体预览请求。\u{201c}深色模式压暗缩略图\u{201d}仅对已加载成功的帖子列表、吧内搜索、"
            + "正文和话题静态图片应用视觉效果，不影响下载、缓存或任何网络请求；视频封面、头像、"
            + "图库和加载占位不受影响。"
        )
      }

      Section {
        LabeledContent {
          if let imageCacheUsage {
            Text(
              "\(imageCacheUsage.entryCount) 项，"
                + formattedByteCount(imageCacheUsage.byteCount)
            )
            .foregroundStyle(.secondary)
          } else {
            ProgressView()
              .accessibilityLabel("正在统计图片缓存")
          }
        } label: {
          Label("磁盘图片缓存", systemImage: "internaldrive")
        }

        Button {
          Task { @MainActor in
            await clearImageCaches()
          }
        } label: {
          if isClearingImageCache {
            Label("正在清理图片缓存", systemImage: "trash")
          } else {
            Label("清理图片缓存", systemImage: "trash")
          }
        }
        .disabled(isClearingImageCache)
      } header: {
        Text("缓存")
      } footer: {
        Text(
          "磁盘缓存只保存已通过图片校验、且请求未携带账户 Cookie 或 Authorization 头的 HTTPS "
            + "图片字节；不保存账户响应、明文请求地址、语音或导出临时文件。清理会移除内存缓存"
            + "和磁盘缓存索引；当前显示、"
            + "播放或分享中的独立临时副本会在使用结束后释放，因此统计值不等同于立即释放的"
            + "物理空间。"
        )
      }

      Section("应用") {
        NavigationLink {
          AppAboutView()
        } label: {
          Label("关于贴吧++", systemImage: "info.circle")
        }
        .accessibilityIdentifier("settings-about")
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("设置")
    .navigationBarTitleDisplayMode(.inline)
    .task { await historyViewModel.refresh() }
    .task { await refreshImageCacheUsage() }
    .alert(
      "无法更新浏览记录设置",
      isPresented: Binding(
        get: { historyViewModel.operationError != nil },
        set: { if !$0 { historyViewModel.dismissOperationError() } }
      )
    ) {
      Button("好", action: historyViewModel.dismissOperationError)
    } message: {
      Text(historyViewModel.operationError ?? "未知错误")
    }
    .alert(item: $imageCacheNotice) { notice in
      Alert(
        title: Text(notice.title),
        message: Text(notice.message),
        dismissButton: .cancel(Text("好"))
      )
    }
  }

  @MainActor
  private func refreshImageCacheUsage() async {
    let requestID = UUID()
    imageCacheUsageRequestID = requestID
    let usage = await persistentImageCache.usage()
    guard imageCacheUsageRequestID == requestID, !isClearingImageCache else { return }
    imageCacheUsage = usage
  }

  @MainActor
  private func clearImageCaches() async {
    guard !isClearingImageCache else { return }
    isClearingImageCache = true
    imageCacheUsageRequestID = nil
    let result = await imageRepository.clearAllImageCaches(using: persistentImageCache)
    imageCacheUsage = await persistentImageCache.usage()
    isClearingImageCache = false

    if result.removedAllEntries {
      let removedDescription =
        "已从缓存索引移除 \(result.removedEntryCount) 项（"
          + "\(formattedByteCount(result.removedByteCount))）。"
      imageCacheNotice = ImageCacheNotice(
        title: "图片缓存已清理",
        message: removedDescription
          + " 当前显示或正在使用的图片副本会在使用结束后释放。"
      )
    } else {
      imageCacheNotice = ImageCacheNotice(
        title: "图片缓存未完全清理",
        message: "清理前缓存索引包含 \(result.removedEntryCount) 项（"
          + "\(formattedByteCount(result.removedByteCount))）；部分磁盘条目可能仍然存在，"
          + "请稍后重试。"
      )
    }
  }

  private func formattedByteCount(_ byteCount: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: max(0, byteCount))
  }

  private var appearanceSelection: Binding<AppAppearance> {
    Binding(
      get: { AppAppearance.resolved(appearance) },
      set: { appearance = $0.rawValue }
    )
  }

  private var appearancePicker: some View {
    Picker("外观", selection: appearanceSelection) {
      ForEach(AppAppearance.allCases) { appearance in
        Text(appearance.title).tag(appearance)
      }
    }
  }

  private var selectedAccentColor: AppAccentColor {
    AppAccentColor.resolved(accentColor)
  }

  private var accentColorSelection: Binding<AppAccentColor> {
    Binding(
      get: { selectedAccentColor },
      set: { accentColor = $0.rawValue }
    )
  }

  private var textSizeAdjustmentSelection: Binding<AppTextSizeAdjustment> {
    Binding(
      get: { AppTextSizeAdjustment.resolved(textSizeAdjustment) },
      set: { textSizeAdjustment = $0.rawValue }
    )
  }

  private var defaultForumSortSelection: Binding<ForumThreadSort> {
    Binding(
      get: { ForumThreadSort(rawValue: defaultForumSort) ?? .replyTime },
      set: { defaultForumSort = $0.rawValue }
    )
  }

  private var defaultForumSortPicker: some View {
    Picker("吧默认排序", selection: defaultForumSortSelection) {
      ForEach(ForumThreadSort.allCases) { sort in
        Text(sort.title).tag(sort)
      }
    }
  }

  private var forumPrimaryActionSelection: Binding<ForumPrimaryAction> {
    Binding(
      get: { ForumPrimaryAction.resolved(forumPrimaryAction) },
      set: { forumPrimaryAction = $0.rawValue }
    )
  }

  private var homeStartDestinationSelection: Binding<AppStartDestination> {
    Binding(
      get: { AppStartDestination.resolved(homeStartDestination) },
      set: { homeStartDestination = $0.rawValue }
    )
  }

  private var followedForumsLayoutSelection: Binding<FollowedForumsLayoutMode> {
    Binding(
      get: { FollowedForumsLayoutMode.resolved(followedForumsLayout) },
      set: { followedForumsLayout = $0.rawValue }
    )
  }

  private var followedForumsLayoutPicker: some View {
    Picker("关注贴吧布局", selection: followedForumsLayoutSelection) {
      ForEach(FollowedForumsLayoutMode.allCases) { mode in
        Text(mode.title).tag(mode)
      }
    }
  }

  private var contentMediaLoadPolicySelection: Binding<ContentMediaLoadPolicy> {
    Binding(
      get: { ContentMediaLoadPolicy.resolved(contentMediaLoadPolicy) },
      set: { contentMediaLoadPolicy = $0.rawValue }
    )
  }

  private var contentMediaLoadPolicyPicker: some View {
    Picker("媒体加载", selection: contentMediaLoadPolicySelection) {
      ForEach(ContentMediaLoadPolicy.allCases) { policy in
        Text(policy.title).tag(policy)
      }
    }
  }

  private var contentImagePreviewQualitySelection: Binding<ContentImagePreviewQuality> {
    Binding(
      get: { ContentImagePreviewQuality.resolved(contentImagePreviewQuality) },
      set: { contentImagePreviewQuality = $0.rawValue }
    )
  }

  private var externalWebOpenModeSelection: Binding<ExternalWebOpenMode> {
    Binding(
      get: { ExternalWebOpenMode.resolved(externalWebOpenMode) },
      set: { externalWebOpenMode = $0.rawValue }
    )
  }
}
