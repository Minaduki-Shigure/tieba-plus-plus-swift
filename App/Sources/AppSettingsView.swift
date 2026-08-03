import SwiftUI

struct AppSettingsView: View {
  @StateObject private var historyViewModel: BrowsingHistoryViewModel
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @AppStorage(AppPreferenceKey.appearance)
  private var appearance = AppAppearance.system.rawValue
  @AppStorage(AppPreferenceKey.textSizeAdjustment)
  private var textSizeAdjustment = AppTextSizeAdjustment.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.defaultForumSort)
  private var defaultForumSort = ForumThreadSort.replyTime.rawValue
  @AppStorage(AppPreferenceKey.homeStartDestination)
  private var homeStartDestination = AppStartDestination.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.homeShowsDiscovery)
  private var homeShowsDiscovery = AppPreferenceDefaults.homeShowsDiscovery
  @AppStorage(AppPreferenceKey.homeShowsRecentForums)
  private var homeShowsRecentForums = true
  @AppStorage(AppPreferenceKey.favoriteThreadsOpenOnlyAuthor)
  private var favoriteThreadsOpenOnlyAuthor =
    AppPreferenceDefaults.favoriteThreadsOpenOnlyAuthor
  @AppStorage(AppPreferenceKey.favoriteThreadsOpenDescending)
  private var favoriteThreadsOpenDescending =
    AppPreferenceDefaults.favoriteThreadsOpenDescending
  @AppStorage(AppPreferenceKey.searchSuggestionsEnabled)
  private var searchSuggestionsEnabled = false
  @AppStorage(AppPreferenceKey.externalWebOpenMode)
  private var externalWebOpenMode = ExternalWebOpenMode.defaultValue.rawValue
  @AppStorage(AppPreferenceKey.contentMediaLoadPolicy)
  private var contentMediaLoadPolicy = ContentMediaLoadPolicy.automatic.rawValue
  @AppStorage(AppPreferenceKey.hidesThreadListMedia)
  private var hidesThreadListMedia = false
  @AppStorage(AppPreferenceKey.darkensContentThumbnailsInDarkMode)
  private var darkensContentThumbnailsInDarkMode = true
  @AppStorage(AppPreferenceKey.showsBothUsernameAndNickname)
  private var showsBothUsernameAndNickname = false

  init(historyRepository: any BrowsingHistoryRepository) {
    _historyViewModel = StateObject(
      wrappedValue: BrowsingHistoryViewModel(repository: historyRepository)
    )
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
        Picker("启动首选页", selection: homeStartDestinationSelection) {
          ForEach(AppStartDestination.allCases) { destination in
            Text(destination.title).tag(destination)
          }
        }
        .pickerStyle(.menu)

        Toggle("显示发现区", isOn: $homeShowsDiscovery)

        Toggle("显示最近访问的贴吧", isOn: $homeShowsRecentForums)
      } header: {
        Text("首页")
      } footer: {
        Text("启动首选页会在下次启动应用时生效。")
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
            + "均需点按；两种模式都会直接显示进程内缓存的图片。这些模式控制展开后的列表媒体、"
            + "帖子正文、话题图片和视频封面，头像、图库、页面数据和其他网络请求不受影响。\n\n"
            + "\u{201c}收起帖子列表的图片和视频\u{201d}仅影响帖子列表和吧内搜索；收起时不会创建列表"
            + "媒体预览请求。\u{201c}深色模式压暗缩略图\u{201d}仅对已加载成功的帖子列表、吧内搜索、"
            + "正文和话题静态图片应用视觉效果，不影响下载、缓存或任何网络请求；视频封面、头像、"
            + "图库和加载占位不受影响。"
        )
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("设置")
    .navigationBarTitleDisplayMode(.inline)
    .task { await historyViewModel.refresh() }
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

  private var homeStartDestinationSelection: Binding<AppStartDestination> {
    Binding(
      get: { AppStartDestination.resolved(homeStartDestination) },
      set: { homeStartDestination = $0.rawValue }
    )
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

  private var externalWebOpenModeSelection: Binding<ExternalWebOpenMode> {
    Binding(
      get: { ExternalWebOpenMode.resolved(externalWebOpenMode) },
      set: { externalWebOpenMode = $0.rawValue }
    )
  }
}
