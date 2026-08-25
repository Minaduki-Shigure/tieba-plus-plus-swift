import Combine
import SwiftUI
import UIKit

struct ContentFilterSettingsView: View {
  @Environment(\.contentFilterRepository) private var repository

  var body: some View {
    ContentFilterSettingsContent(repository: repository)
  }
}

private struct ContentFilterSettingsContent: View {
  @StateObject private var viewModel: ContentFilterViewModel
  @State private var showsAddRule = false
  @State private var showsClearConfirmation = false
  @State private var showsResetConfirmation = false

  init(repository: any ContentFilterRepository) {
    _viewModel = StateObject(wrappedValue: ContentFilterViewModel(repository: repository))
  }

  var body: some View {
    List {
      Section("屏蔽内容") {
        Picker(
          "显示方式",
          selection: Binding(
            get: { viewModel.snapshot.displayMode },
            set: { mode in Task { await viewModel.setDisplayMode(mode) } }
          )
        ) {
          ForEach(ContentFilterDisplayMode.allCases) { mode in
            Text(mode.title).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier("content-filter-display-mode")

        Toggle(
          "屏蔽视频主题",
          isOn: Binding(
            get: { viewModel.snapshot.blockVideos },
            set: { blockVideos in Task { await viewModel.setBlockVideos(blockVideos) } }
          )
        )
        .accessibilityIdentifier("content-filter-block-videos")
      }

      if let message = viewModel.loadErrorMessage {
        Section("规则文件错误") {
          Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.secondary)
          Button {
            Task { await viewModel.reload() }
          } label: {
            Label("重试", systemImage: "arrow.clockwise")
          }
          Button(role: .destructive) {
            showsResetConfirmation = true
          } label: {
            Label("重置规则文件", systemImage: "trash")
          }
        }
      } else if viewModel.visibleRules.isEmpty {
        Section(viewModel.selectedList.title) {
          Label("暂无规则", systemImage: "line.3.horizontal.decrease.circle")
            .foregroundStyle(.secondary)
        }
      } else {
        Section(viewModel.selectedList.title) {
          ForEach(viewModel.visibleRules) { rule in
            ContentFilterRuleRow(rule: rule)
              .contextMenu {
                Button {
                  UIPasteboard.general.string = rule.displayValue
                } label: {
                  Label("复制", systemImage: "doc.on.doc")
                }
                Button(role: .destructive) {
                  Task { await viewModel.delete(id: rule.id) }
                } label: {
                  Label("删除", systemImage: "trash")
                }
              }
              .swipeActions {
                Button(role: .destructive) {
                  Task { await viewModel.delete(id: rule.id) }
                } label: {
                  Label("删除", systemImage: "trash")
                }
              }
          }
        }
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("内容屏蔽")
    .navigationBarTitleDisplayMode(.inline)
    .safeAreaInset(edge: .top, spacing: 0) {
      VStack(spacing: 0) {
        Picker("规则列表", selection: $viewModel.selectedList) {
          ForEach(ContentFilterList.allCases) { list in
            Text(list.title).tag(list)
          }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .accessibilityIdentifier("content-filter-list-picker")
        Divider()
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .navigationBarTrailing) {
        Button {
          showsAddRule = true
        } label: {
          Image(systemName: "plus")
        }
        .disabled(viewModel.loadErrorMessage != nil)
        .accessibilityLabel("添加规则")
        .help("添加规则")

        Button(role: .destructive) {
          showsClearConfirmation = true
        } label: {
          Image(systemName: "trash")
        }
        .disabled(viewModel.visibleRules.isEmpty || viewModel.loadErrorMessage != nil)
        .accessibilityLabel("清空当前列表")
        .help("清空当前列表")
      }
    }
    .sheet(isPresented: $showsAddRule) {
      NavigationStack {
        AddContentFilterRuleView(list: viewModel.selectedList) { rule in
          Task { await viewModel.add(rule) }
        }
      }
    }
    .confirmationDialog(
      "清空\(viewModel.selectedList.title)？",
      isPresented: $showsClearConfirmation,
      titleVisibility: .visible
    ) {
      Button("清空", role: .destructive) {
        Task { await viewModel.deleteSelectedList() }
      }
      Button("取消", role: .cancel) {}
    }
    .confirmationDialog(
      "重置本地屏蔽规则？",
      isPresented: $showsResetConfirmation,
      titleVisibility: .visible
    ) {
      Button("重置", role: .destructive) {
        Task { await viewModel.reset() }
      }
      Button("取消", role: .cancel) {}
    }
    .alert(
      "无法更新规则",
      isPresented: Binding(
        get: { viewModel.operationErrorMessage != nil },
        set: { if !$0 { viewModel.dismissOperationError() } }
      )
    ) {
      Button("好", action: viewModel.dismissOperationError)
    } message: {
      Text(viewModel.operationErrorMessage ?? "未知错误")
    }
    .task { await viewModel.loadIfNeeded() }
    .onReceive(NotificationCenter.default.publisher(for: .contentFilterDidChange)) { _ in
      Task { @MainActor in await viewModel.reload() }
    }
  }
}

private struct ContentFilterRuleRow: View {
  let rule: ContentFilterRule

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: systemImage)
        .foregroundStyle(.tint)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 3) {
        Text(rule.displayValue)
          .lineLimit(2)
        Text(ruleSubtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }

  private var systemImage: String {
    switch (rule.kind, rule.keywordMatchMode) {
    case (.keyword, .regularExpression):
      "curlybraces"
    case (.keyword, .literal):
      "text.magnifyingglass"
    case (.user, _):
      "person"
    }
  }

  private var ruleSubtitle: String {
    rule.kind == .keyword ? rule.keywordMatchMode.title : rule.kind.title
  }
}

private struct AddContentFilterRuleView: View {
  @Environment(\.dismiss) private var dismiss
  let list: ContentFilterList
  let onSave: (ContentFilterRule) -> Void

  @State private var kind = ContentFilterRuleKind.keyword
  @State private var keyword = ""
  @State private var keywordMatchMode = ContentFilterKeywordMatchMode.literal
  @State private var userID = ""
  @State private var username = ""

  var body: some View {
    Form {
      Section {
        Picker("规则类型", selection: $kind) {
          ForEach(ContentFilterRuleKind.allCases) { kind in
            Text(kind.title).tag(kind)
          }
        }
        .pickerStyle(.segmented)
      }

      switch kind {
      case .keyword:
        Section {
          Picker("匹配方式", selection: $keywordMatchMode) {
            ForEach(ContentFilterKeywordMatchMode.allCases) { mode in
              Text(mode.title).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .accessibilityIdentifier("content-filter-keyword-match-mode")

          TextField(keywordMatchMode == .literal ? "关键词" : "正则表达式", text: $keyword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("content-filter-keyword-pattern")
        } footer: {
          if
            !keyword.isEmpty,
            let validationMessage = ContentFilterKeywordPatternPolicy.validationMessage(
              for: keyword,
              mode: keywordMatchMode
            )
          {
            Text(validationMessage)
              .foregroundStyle(.red)
          }
        }
      case .user:
        Section("用户") {
          TextField("用户 ID", text: $userID)
            .keyboardType(.numberPad)
          TextField("用户名", text: $username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
      }
    }
    .navigationTitle(list == .block ? "添加屏蔽规则" : "添加白名单规则")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("取消") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("添加", action: save)
          .disabled(!isValid)
      }
    }
  }

  private var isValid: Bool {
    switch kind {
    case .keyword:
      return ContentFilterKeywordPatternPolicy.validationMessage(
        for: keyword,
        mode: keywordMatchMode
      ) == nil
    case .user:
      let name = normalized(username)
      let idText = normalized(userID)
      let parsedID = Int64(idText)
      let hasValidID = idText.isEmpty || (parsedID.map { $0 > 0 } ?? false)
      return hasValidID && name.count <= 100 && (parsedID != nil || !name.isEmpty)
    }
  }

  private func save() {
    guard isValid else { return }
    switch kind {
    case .keyword:
      guard
        let pattern = try? ContentFilterKeywordPatternPolicy.validated(
          keyword,
          mode: keywordMatchMode
        )
      else { return }
      switch keywordMatchMode {
      case .literal:
        onSave(.keyword(pattern, list: list))
      case .regularExpression:
        guard let rule = try? ContentFilterRule.regularExpression(pattern, list: list) else {
          return
        }
        onSave(rule)
      }
    case .user:
      onSave(
        .user(
          id: Int64(normalized(userID)),
          name: normalized(username),
          list: list
        )
      )
    }
    dismiss()
  }

  private func normalized(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }
}
