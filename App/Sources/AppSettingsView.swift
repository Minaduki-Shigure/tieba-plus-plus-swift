import SwiftUI

enum AppPreferenceKey {
  static let homeShowsRecentForums = "TiebaPlusPlus.homeShowsRecentForums"
}

struct AppSettingsView: View {
  @AppStorage(AppPreferenceKey.homeShowsRecentForums)
  private var homeShowsRecentForums = true

  var body: some View {
    List {
      Section("首页") {
        Toggle("显示最近访问的贴吧", isOn: $homeShowsRecentForums)
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
  }
}
