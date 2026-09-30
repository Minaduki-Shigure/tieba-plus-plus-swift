import SwiftUI

struct AutomaticForumCheckInSettingsView: View {
  @ObservedObject private var runtime = AutomaticForumCheckInRuntime.shared

  var body: some View {
    List {
      Section {
        // Xcode 16.4 crashes in IRGen when a bound MainActor Bool method is
        // passed as the setter. Explicit closures avoid that reabstraction thunk.
        Toggle(
          "每日自动签到",
          isOn: Binding(get: { runtime.isEnabled }, set: { runtime.setEnabled($0) })
        )
        .accessibilityIdentifier("automatic-check-in-enabled")

        DatePicker(
          "签到时间（北京时间）", selection: selectedTime, displayedComponents: .hourAndMinute
        )
        .environment(\.calendar, AutomaticForumCheckInSchedule.calendar)
        .environment(\.timeZone, AutomaticForumCheckInSchedule.calendar.timeZone)
        .accessibilityIdentifier("automatic-check-in-time")

        Toggle(
          "尝试后台补签",
          isOn: Binding(
            get: { runtime.usesBackgroundRefresh }, set: { runtime.setUsesBackgroundRefresh($0) }
          )
        )
        .accessibilityIdentifier("automatic-check-in-background")
      } footer: {
        Text(
          "默认关闭。开启后，每天到设定时间会为当前登录账号关注的贴吧签到；"
            + "错过时间后，打开 App 会尝试补签。切换账号后按新账号分别记录进度。"
            + "关闭开关会停止后续请求，已经发出的请求可能仍会完成。"
        )
      }

      Section {
        if runtime.isRunning {
          HStack(spacing: 12) {
            ProgressView()
            Text(runtime.statusMessage)
          }
        } else {
          Text(runtime.statusMessage)
        }
        if let summary = runtime.summary {
          Text(
            "成功 \(summary.succeeded) · 失败 \(summary.failed) · 待确认 \(summary.unconfirmed)"
          )
          .font(.subheadline)
          .foregroundStyle(.secondary)
        }
        Button("核对今日结果") { runtime.reconcile() }
          .disabled(runtime.isRunning)
          .accessibilityIdentifier("automatic-check-in-reconcile")
      } header: {
        if let day = runtime.resultDay {
          Text("最近结果 · \(day)（北京时间）")
        } else {
          Text("当前账号的自动签到")
        }
      } footer: {
        Text(
          "核对只读取今天的服务器状态，不会重新签到。结果不明或失败时会暂停当天的自动任务，"
            + "避免重复发送。尚未发送的任务会在下次运行时继续。"
        )
      }

      if !runtime.entries.isEmpty {
        Section("签到结果") {
          ForEach(runtime.entries) { entry in
            VStack(alignment: .leading, spacing: 4) {
              Text(entry.forumName)
                .font(.body)
              Text(outcomeText(entry.outcome))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
        }
      }

      Section {
        if let message = runtime.schedulingMessage {
          Text(message)
        }
        Text(
          "后台补签由 iOS 决定何时运行，无法保证准点。系统关闭后台刷新、设备锁定或"
            + "运行环境不支持时，可在设定时间后打开 App 补签；不需要开启消息通知。"
        )
        .foregroundStyle(.secondary)
      } header: {
        Text("后台运行")
      } footer: {
        Text("自动签到使用一键签到的间隔与官方批签设置；发生失败时始终停止。")
      }
    }
    .navigationTitle("每日自动签到")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var selectedTime: Binding<Date> {
    Binding(
      get: {
        AutomaticForumCheckInSchedule(minuteOfDay: runtime.minuteOfDay)
          .scheduledDate(on: Date()) ?? Date()
      },
      set: { date in
        let components = AutomaticForumCheckInSchedule.calendar.dateComponents(
          [.hour, .minute], from: date
        )
        guard let hour = components.hour, let minute = components.minute else { return }
        runtime.setMinuteOfDay(hour * 60 + minute)
      }
    )
  }

  private func outcomeText(_ outcome: ForumBatchCheckInEntryOutcome) -> String {
    switch outcome {
    case .pending: "等待签到"
    case .inProgress: "正在签到"
    case .succeeded: "已确认签到成功"
    case .failed(let message): "失败：\(message)"
    case .unconfirmed(let message): "待确认：\(message)"
    case .skipped(let message): "已跳过：\(message)"
    case .stopped: "尚未发送，已暂停"
    }
  }
}
