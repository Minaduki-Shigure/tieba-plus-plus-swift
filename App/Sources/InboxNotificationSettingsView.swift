import SwiftUI
import UIKit

struct InboxNotificationSettingsView: View {
  @ObservedObject var runtime: InboxNotificationRuntime
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    List {
      Section {
        Toggle("未读消息提醒", isOn: enabledSelection)
          .disabled(runtime.isChangingPreference)
          .accessibilityIdentifier("settings-inbox-notifications-enabled")
      } footer: {
        Text("默认关闭。开启后检查未读数量，提醒只显示数量，不包含消息正文。")
      }

      Section("当前状态") {
        Text(runtime.statusMessage)
          .foregroundStyle(.secondary)
          .accessibilityIdentifier("settings-inbox-notifications-status")

        Button {
          guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
            return
          }
          openURL(settingsURL)
        } label: {
          Label("打开系统设置", systemImage: "gear")
        }
        .accessibilityIdentifier("settings-inbox-notifications-system-settings")
      } footer: {
        Text("可在系统设置中调整通知权限和后台 App 刷新。")
      }

      Section("后台检查") {
        Text("后台检查由 iOS 安排，没有固定间隔，也不能保证实时提醒。设备锁定时，检查可能延后至解锁后。")
        Text("通过 SideStore 安装或在 LiveContainer 中运行时，后台检查还取决于系统设置与宿主支持。")
      }
      .foregroundStyle(.secondary)
    }
    .listStyle(.insetGrouped)
    .appScrollableSurface()
    .navigationTitle("消息提醒")
    .navigationBarTitleDisplayMode(.inline)
    .task { await runtime.refreshStatus() }
    .onChange(of: scenePhase) { phase in
      guard phase == .active else { return }
      Task { await runtime.refreshStatus() }
    }
  }

  private var enabledSelection: Binding<Bool> {
    Binding(
      get: { runtime.isEnabled },
      set: { enabled in
        Task { await runtime.setEnabled(enabled) }
      }
    )
  }
}
