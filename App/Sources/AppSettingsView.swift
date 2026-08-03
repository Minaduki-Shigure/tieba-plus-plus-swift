import SwiftUI

struct AppSettingsView: View {
  @StateObject private var historyViewModel: BrowsingHistoryViewModel
  @AppStorage(AppPreferenceKey.appearance)
  private var appearance = AppAppearance.system.rawValue
  @AppStorage(AppPreferenceKey.defaultForumSort)
  private var defaultForumSort = ForumThreadSort.replyTime.rawValue
  @AppStorage(AppPreferenceKey.homeShowsRecentForums)
  private var homeShowsRecentForums = true
  @AppStorage(AppPreferenceKey.searchSuggestionsEnabled)
  private var searchSuggestionsEnabled = false
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
        Picker("外观", selection: appearanceSelection) {
          ForEach(AppAppearance.allCases) { appearance in
            Text(appearance.title).tag(appearance)
          }
        }
        .pickerStyle(.segmented)
      }

      Section("使用习惯") {
        Picker("吧默认排序", selection: defaultForumSortSelection) {
          ForEach(ForumThreadSort.allCases) { sort in
            Text(sort.title).tag(sort)
          }
        }
        .pickerStyle(.segmented)

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

      Section("首页") {
        Toggle("显示最近访问的贴吧", isOn: $homeShowsRecentForums)
      }

      Section {
        Toggle("在线搜索联想", isOn: $searchSuggestionsEnabled)
      } header: {
        Text("搜索与隐私")
      } footer: {
        Text("开启后，会在您提交搜索前向百度发送输入关键词，以获取在线联想建议。")
      }

      Section {
        Toggle("同时显示用户名和昵称", isOn: $showsBothUsernameAndNickname)
      } header: {
        Text("用户名称")
      } footer: {
        Text("开启后，会在公开昵称后同时显示公开用户名；仅使用页面已经返回的公开资料，不会发起额外请求。")
      }

      Section {
        Picker("媒体加载", selection: contentMediaLoadPolicySelection) {
          ForEach(ContentMediaLoadPolicy.allCases) { policy in
            Text(policy.title).tag(policy)
          }
        }
        .pickerStyle(.segmented)

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
          "\u{201c}收起帖子列表的图片和视频\u{201d}仅影响帖子列表和吧内搜索；"
            + "收起时不会创建列表媒体预览请求。\u{201c}点按加载\u{201d}控制展开后的列表媒体、"
            + "帖子正文、话题图片和视频封面的自动下载，头像和图库不受影响。"
            + "在\u{201c}点按加载\u{201d}模式下，进程内已经缓存的图片会直接显示，"
            + "页面数据等其他网络请求仍会正常进行。\u{201c}深色模式压暗缩略图\u{201d}仅对已加载成功的"
            + "帖子列表、吧内搜索、正文和话题静态图片应用视觉效果，不影响下载、缓存或任何网络请求；"
            + "视频封面、头像、图库和加载占位不受影响。"
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

  private var defaultForumSortSelection: Binding<ForumThreadSort> {
    Binding(
      get: { ForumThreadSort(rawValue: defaultForumSort) ?? .replyTime },
      set: { defaultForumSort = $0.rawValue }
    )
  }

  private var contentMediaLoadPolicySelection: Binding<ContentMediaLoadPolicy> {
    Binding(
      get: { ContentMediaLoadPolicy.resolved(contentMediaLoadPolicy) },
      set: { contentMediaLoadPolicy = $0.rawValue }
    )
  }
}
