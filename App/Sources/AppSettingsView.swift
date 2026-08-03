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

      Section("内容") {
        NavigationLink {
          ContentFilterSettingsView()
        } label: {
          Label("内容屏蔽", systemImage: "hand.raised")
        }
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
}
