import SwiftUI

struct ForumBatchCheckInView: View {
  @StateObject private var viewModel: ForumBatchCheckInViewModel
  @State private var showsStartConfirmation = false
  @State private var acceptedStartConfirmation = false

  init(access: AccountAccess) {
    _viewModel = StateObject(wrappedValue: ForumBatchCheckInViewModel(access: access))
  }

  var body: some View {
    content
      .navigationTitle("一键签到")
      .navigationBarTitleDisplayMode(.inline)
      .task { await viewModel.loadIfNeeded() }
      .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
        showsStartConfirmation = false
        Task { @MainActor in await viewModel.accountSessionDidChange() }
      }
      .onDisappear(perform: presentationDidDisappear)
      .confirmationDialog(
        confirmationTitle,
        isPresented: startConfirmationPresented,
        titleVisibility: .visible
      ) {
        if let confirmation = viewModel.pendingConfirmation {
          Button("开始签到") {
            acceptedStartConfirmation = true
            Task { @MainActor in
              await viewModel.confirmStart()
              acceptedStartConfirmation = false
            }
          }
          .accessibilityLabel("开始为 \(confirmation.targetCount) 个贴吧签到")
        }
        Button("取消", role: .cancel, action: cancelStartConfirmation)
      } message: {
        Text(confirmationMessage)
      }
      .alert(
        "一键签到遇到问题",
        isPresented: Binding(
          get: { viewModel.errorMessage != nil },
          set: { if !$0 { viewModel.dismissError() } }
        )
      ) {
        Button("好", role: .cancel) { viewModel.dismissError() }
      } message: {
        Text(viewModel.errorMessage ?? "未能完成一键签到。")
      }
  }

  @ViewBuilder
  private var content: some View {
    switch viewModel.state {
    case .idle, .loading:
      loadingView
    case .signedOut:
      EmptyStateView(title: "请先登录贴吧账户", systemImage: "person.crop.circle.badge.exclamationmark")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .ready(let summary):
      resultList(summary: summary, phase: .ready)
    case .running(let progress):
      progressList(progress: progress, isStopping: false)
    case .stopping(let progress):
      progressList(progress: progress, isStopping: true)
    case .completed(let summary):
      resultList(summary: summary, phase: .completed)
    case .needsReview(let summary):
      resultList(summary: summary, phase: .needsReview)
    case .failed(let summary):
      if let summary {
        resultList(summary: summary, phase: .failed)
      } else {
        ErrorStateView(
          message: viewModel.errorMessage ?? "无法读取当前账户的一键签到状态。",
          retry: reload
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var loadingView: some View {
    ProgressView("正在读取签到状态")
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityLabel("正在读取一键签到状态")
  }

  private func resultList(
    summary: ForumBatchCheckInSummary,
    phase: ForumBatchCheckInPresentationPhase
  ) -> some View {
    List {
      Section {
        summaryHeader(summary: summary, phase: phase)

        switch phase {
        case .ready:
          if summary.pending > 0 {
            Button(action: requestStartConfirmation) {
              Label("开始签到", systemImage: "checkmark.seal")
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("开始为 \(summary.pending) 个贴吧签到")
            .accessibilityHint("确认后会在当前页面发起官方一键签到")
          }
        case .needsReview:
          Label(
            "部分请求已派发，但贴吧未能权威确认结果。应用没有自动重试，请先重新读取状态。",
            systemImage: "exclamationmark.shield"
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityLabel("部分签到结果待核对")
          .accessibilityHint("应用没有自动重试；请重新读取状态后再核对")

          reloadButton
        case .completed, .failed:
          reloadButton
        }
      }

      entrySection
    }
    .listStyle(.insetGrouped)
    .refreshable {
      guard phase != .ready || viewModel.pendingConfirmation == nil else { return }
      await viewModel.reload()
    }
  }

  private var reloadButton: some View {
    Button(action: reload) {
      Label("重新读取签到状态", systemImage: "arrow.clockwise")
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.bordered)
    .accessibilityHint("只重新读取状态，不会发送签到请求")
  }

  private func progressList(
    progress: ForumBatchCheckInProgress,
    isStopping: Bool
  ) -> some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 12) {
          HStack(alignment: .firstTextBaseline) {
            Text(isStopping ? "正在停止后续签到" : "正在签到")
              .font(.headline)
            Spacer(minLength: 12)
            Text("\(progress.processed) / \(progress.total)")
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.secondary)
          }

          ProgressView(
            value: Double(min(max(progress.processed, 0), max(progress.total, 0))),
            total: Double(max(progress.total, 1))
          )
          .accessibilityLabel("一键签到进度")
          .accessibilityValue("已处理 \(progress.processed) 个，共 \(progress.total) 个")

          if let currentForumName = progress.currentForumName, !currentForumName.isEmpty {
            Text("当前：\(currentForumName)吧")
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .accessibilityLabel("当前正在处理 \(currentForumName)吧")
          }

          outcomeCounts(
            succeeded: progress.succeeded,
            failed: progress.failed,
            unconfirmed: progress.unconfirmed,
            skipped: progress.skipped,
            stopped: progress.stopped
          )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)

        if isStopping {
          Label("已请求停止，正在确认已发出的签到结果", systemImage: "stop.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Button(role: .destructive) {
            viewModel.requestStop()
          } label: {
            Label("停止后续签到", systemImage: "stop.circle")
              .frame(maxWidth: .infinity, minHeight: 44)
          }
          .buttonStyle(.bordered)
          .accessibilityHint("不会撤回已经发出的签到请求")
        }
      }

      entrySection
    }
    .listStyle(.insetGrouped)
  }

  private func summaryHeader(
    summary: ForumBatchCheckInSummary,
    phase: ForumBatchCheckInPresentationPhase
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(phase.title(for: summary), systemImage: phase.systemImage(for: summary))
        .font(.headline)
        .foregroundStyle(phase.color(for: summary))
        .fixedSize(horizontal: false, vertical: true)

      HStack(spacing: 0) {
        summaryMetric(
          title: phase == .ready ? "关注" : "已处理",
          value: phase == .ready ? summary.total : summary.processed
        )
        summaryMetric(
          title: phase == .ready ? "待签到" : "成功",
          value: phase == .ready ? summary.pending : summary.succeeded
        )
        summaryMetric(
          title: summaryThirdMetricTitle(summary: summary, phase: phase),
          value: summaryThirdMetricValue(summary: summary, phase: phase)
        )
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(summaryAccessibilityValue(summary, phase: phase))

      if shouldShowSupplementalCounts(summary: summary, phase: phase) {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 16) {
            supplementalCountLabels(summary: summary, phase: phase)
          }
          VStack(alignment: .leading, spacing: 6) {
            supplementalCountLabels(summary: summary, phase: phase)
          }
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
      }
    }
    .padding(.vertical, 4)
  }

  private func shouldShowSupplementalCounts(
    summary: ForumBatchCheckInSummary,
    phase: ForumBatchCheckInPresentationPhase
  ) -> Bool {
    (phase != .ready && summary.unconfirmed > 0 && summary.failed > 0)
      || summary.skipped > 0
      || summary.stopped > 0
  }

  private func summaryMetric(title: String, value: Int) -> some View {
    VStack(spacing: 3) {
      Text(max(value, 0).formatted())
        .font(.headline.monospacedDigit())
      Text(title)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .accessibilityHidden(true)
  }

  private func outcomeCounts(
    succeeded: Int,
    failed: Int,
    unconfirmed: Int,
    skipped: Int,
    stopped: Int
  ) -> some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 16) {
        outcomeCountLabels(
          succeeded: succeeded,
          failed: failed,
          unconfirmed: unconfirmed,
          skipped: skipped,
          stopped: stopped
        )
      }
      VStack(alignment: .leading, spacing: 6) {
        outcomeCountLabels(
          succeeded: succeeded,
          failed: failed,
          unconfirmed: unconfirmed,
          skipped: skipped,
          stopped: stopped
        )
      }
    }
    .font(.caption)
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func outcomeCountLabels(
    succeeded: Int,
    failed: Int,
    unconfirmed: Int,
    skipped: Int,
    stopped: Int
  ) -> some View {
    Label("成功 \(max(succeeded, 0))", systemImage: "checkmark.circle.fill")
      .foregroundStyle(.green)
    Label("失败 \(max(failed, 0))", systemImage: "exclamationmark.triangle.fill")
      .foregroundStyle(failed > 0 ? Color.red : Color.secondary)
    if unconfirmed > 0 {
      Label("待核对 \(unconfirmed)", systemImage: "questionmark.circle.fill")
        .foregroundStyle(.orange)
    }
    if skipped > 0 {
      Label("已跳过 \(skipped)", systemImage: "minus.circle")
        .foregroundStyle(.secondary)
    }
    if stopped > 0 {
      Label("未执行 \(stopped)", systemImage: "stop.circle")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private func supplementalCountLabels(
    summary: ForumBatchCheckInSummary,
    phase: ForumBatchCheckInPresentationPhase
  ) -> some View {
    if phase != .ready, summary.unconfirmed > 0, summary.failed > 0 {
      Label("失败 \(summary.failed)", systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
    }
    if summary.skipped > 0 {
      Label("已跳过 \(summary.skipped)", systemImage: "minus.circle")
        .foregroundStyle(.secondary)
    }
    if summary.stopped > 0 {
      Label("未执行 \(summary.stopped)", systemImage: "stop.circle")
        .foregroundStyle(.secondary)
    }
  }

  @ViewBuilder
  private var entrySection: some View {
    if !viewModel.entries.isEmpty {
      Section("贴吧") {
        ForEach(viewModel.entries) { entry in
          ForumBatchCheckInEntryRow(entry: entry)
        }
      }
    }
  }

  private var confirmationTitle: String {
    guard let confirmation = viewModel.pendingConfirmation else { return "开始一键签到？" }
    return "为 \(confirmation.targetCount) 个贴吧签到？"
  }

  private var startConfirmationPresented: Binding<Bool> {
    Binding(
      get: { showsStartConfirmation },
      set: { isPresented in
        showsStartConfirmation = isPresented
        if !isPresented, !acceptedStartConfirmation {
          viewModel.cancelStartConfirmation()
        }
      }
    )
  }

  private var confirmationMessage: String {
    guard let confirmation = viewModel.pendingConfirmation else {
      return "本次签到只会在当前页面前台启动，不会创建后台或定时任务。"
    }

    var parts = [
      "将使用当前贴吧账户开始一键签到。",
      "本次只在当前页面前台启动，不会创建后台或定时任务。"
    ]
    if
      confirmation.officialBatchEligibleCount > 0,
      let minimumLevel = confirmation.minimumOfficialLevel,
      let maximumCount = confirmation.maximumOfficialCount
    {
      parts.insert(
        "等级 \(minimumLevel) 及以上的贴吧会先使用官方批签，最多 \(maximumCount) 个；本次符合条件 \(confirmation.officialBatchEligibleCount) 个，其余待签到贴吧将逐个处理。",
        at: 1
      )
    } else {
      parts.insert("本次待签到贴吧将逐个处理。", at: 1)
    }
    parts.append("停止或离开页面不会撤回已经发出的请求。")
    return parts.joined(separator: " ")
  }

  private func summaryAccessibilityValue(
    _ summary: ForumBatchCheckInSummary,
    phase: ForumBatchCheckInPresentationPhase
  ) -> String {
    switch phase {
    case .ready:
      return "共关注 \(summary.total) 个贴吧，待签到 \(summary.pending) 个，可官方批签 \(summary.eligible) 个，已跳过 \(summary.skipped) 个"
    case .completed, .needsReview, .failed:
      return "共关注 \(summary.total) 个贴吧，本次已处理 \(summary.processed) 个，成功 \(summary.succeeded) 个，失败 \(summary.failed) 个，待核对 \(summary.unconfirmed) 个，已跳过 \(summary.skipped) 个，未执行 \(summary.stopped) 个"
    }
  }

  private func summaryThirdMetricTitle(
    summary: ForumBatchCheckInSummary,
    phase: ForumBatchCheckInPresentationPhase
  ) -> String {
    if phase == .ready { return "可批签" }
    return summary.unconfirmed > 0 ? "待核对" : "失败"
  }

  private func summaryThirdMetricValue(
    summary: ForumBatchCheckInSummary,
    phase: ForumBatchCheckInPresentationPhase
  ) -> Int {
    if phase == .ready { return summary.eligible }
    return summary.unconfirmed > 0 ? summary.unconfirmed : summary.failed
  }

  private func requestStartConfirmation() {
    viewModel.requestStartConfirmation()
    showsStartConfirmation = viewModel.pendingConfirmation != nil
  }

  private func cancelStartConfirmation() {
    acceptedStartConfirmation = false
    showsStartConfirmation = false
    viewModel.cancelStartConfirmation()
  }

  private func presentationDidDisappear() {
    acceptedStartConfirmation = false
    showsStartConfirmation = false
    viewModel.cancelStartConfirmation()
    viewModel.cancel()
  }

  private func reload() {
    Task { @MainActor in await viewModel.reload() }
  }
}

private enum ForumBatchCheckInPresentationPhase: Equatable {
  case ready
  case completed
  case needsReview
  case failed

  func title(for summary: ForumBatchCheckInSummary) -> String {
    switch self {
    case .ready:
      if summary.pending > 0 { return "有 \(summary.pending) 个贴吧待签到" }
      return summary.skipped > 0 ? "今日没有可执行的签到" : "今日没有待签到贴吧"
    case .completed:
      if summary.failed == 0, summary.unconfirmed == 0, summary.stopped == 0 {
        return "一键签到已完成"
      }
      if summary.stopped > 0 { return "已停止后续签到" }
      return "一键签到已结束"
    case .needsReview:
      return "部分签到结果待核对"
    case .failed:
      return summary.processed > 0 ? "部分签到失败" : "一键签到未能开始"
    }
  }

  func systemImage(for summary: ForumBatchCheckInSummary) -> String {
    switch self {
    case .ready:
      if summary.pending > 0 { return "checkmark.seal" }
      return summary.skipped > 0 ? "minus.circle" : "checkmark.seal.fill"
    case .completed:
      return summary.failed == 0 && summary.unconfirmed == 0 && summary.stopped == 0
        ? "checkmark.circle.fill"
        : "exclamationmark.circle"
    case .needsReview:
      return "questionmark.circle.fill"
    case .failed:
      return "exclamationmark.triangle.fill"
    }
  }

  func color(for summary: ForumBatchCheckInSummary) -> Color {
    switch self {
    case .ready:
      return summary.pending == 0 && summary.skipped == 0 ? .green : .primary
    case .completed:
      return summary.failed == 0 && summary.unconfirmed == 0 && summary.stopped == 0
        ? .green
        : .primary
    case .needsReview:
      return .orange
    case .failed:
      return .red
    }
  }
}

private struct ForumBatchCheckInEntryRow: View {
  let entry: ForumBatchCheckInEntry

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      outcomeIcon
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 4) {
        Text("\(entry.forumName)吧")
          .font(.body)
          .lineLimit(2)
        Text("等级 \(max(entry.level, 0))")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 8)

      outcomeText
        .font(.subheadline)
        .multilineTextAlignment(.trailing)
        .foregroundStyle(outcomeColor)
    }
    .padding(.vertical, 3)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(entry.forumName)吧，等级 \(max(entry.level, 0))")
    .accessibilityValue(outcomeAccessibilityValue)
  }

  @ViewBuilder
  private var outcomeIcon: some View {
    switch entry.outcome {
    case .inProgress:
      ProgressView()
        .controlSize(.small)
    default:
      Image(systemName: outcomeSystemImage)
        .foregroundStyle(outcomeColor)
    }
  }

  @ViewBuilder
  private var outcomeText: some View {
    switch entry.outcome {
    case .failed(let message):
      outcomeDetail(title: "失败", message: message)
    case .unconfirmed(let message):
      outcomeDetail(title: "待核对", message: message)
    case .skipped(let message):
      outcomeDetail(title: "已跳过", message: message)
    default:
      Text(outcomeAccessibilityValue)
    }
  }

  private func outcomeDetail(title: String, message: String) -> some View {
    VStack(alignment: .trailing, spacing: 2) {
      Text(title)
      if !message.isEmpty {
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(3)
      }
    }
  }

  private var outcomeSystemImage: String {
    switch entry.outcome {
    case .pending: return "clock"
    case .inProgress: return "clock.arrow.circlepath"
    case .succeeded: return "checkmark.circle.fill"
    case .failed: return "exclamationmark.triangle.fill"
    case .unconfirmed: return "questionmark.circle.fill"
    case .skipped: return "minus.circle"
    case .stopped: return "stop.circle"
    }
  }

  private var outcomeColor: Color {
    switch entry.outcome {
    case .succeeded: return .green
    case .failed: return .red
    case .unconfirmed: return .orange
    case .pending, .inProgress, .skipped, .stopped: return .secondary
    }
  }

  private var outcomeAccessibilityValue: String {
    switch entry.outcome {
    case .pending: return "待签到"
    case .inProgress: return "正在签到"
    case .succeeded: return "签到成功"
    case .failed(let message): return message.isEmpty ? "签到失败" : "签到失败，\(message)"
    case .unconfirmed(let message):
      return message.isEmpty
        ? "签到结果待核对，应用未自动重试"
        : "签到结果待核对，应用未自动重试，\(message)"
    case .skipped(let message): return message.isEmpty ? "已跳过" : "已跳过，\(message)"
    case .stopped: return "未执行"
    }
  }
}
