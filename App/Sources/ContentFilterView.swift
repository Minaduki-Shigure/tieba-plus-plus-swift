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
    .appScrollableSurface()
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
        .appRegularMaterialSurface()
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
        AddContentFilterRuleView(
          list: viewModel.selectedList,
          existingRules: viewModel.snapshot.rules,
          onSave: { try await viewModel.add($0) },
          onSaveBatch: { try await viewModel.add($0) }
        )
      }
      .appNavigationSurface()
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
  let existingRules: [ContentFilterRule]
  let onSave: (ContentFilterRule) async throws -> Void
  let onSaveBatch: ([ContentFilterRule]) async throws -> Void

  @State private var kind = ContentFilterRuleKind.keyword
  @State private var keyword = ""
  @State private var keywordMatchMode = ContentFilterKeywordMatchMode.literal
  @State private var keywordInputMode = ContentFilterKeywordInputMode.single
  @State private var userID = ""
  @State private var username = ""
  @State private var isSaving = false
  @State private var saveErrorMessage: String?

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

          if keywordMatchMode == .literal {
            Picker("输入方式", selection: $keywordInputMode) {
              ForEach(ContentFilterKeywordInputMode.allCases) { mode in
                Text(mode.title).tag(mode)
              }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("content-filter-keyword-input-mode")
          }

          if isBatchInput {
            TextEditor(text: $keyword)
              .frame(minHeight: 120)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityLabel("批量关键词，以空格或换行分隔")
              .accessibilityIdentifier("content-filter-keyword-batch-input")
            if let preview = try? batchPreview() {
              Text("将新增 \(preview.newKeywords.count) 条规则，跳过 \(preview.existingCount) 条已有规则")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("content-filter-keyword-batch-preview")
            }
          } else {
            TextField(keywordMatchMode == .literal ? "关键词" : "正则表达式", text: $keyword)
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .accessibilityIdentifier("content-filter-keyword-pattern")
          }
        } footer: {
          VStack(alignment: .leading, spacing: 4) {
            if isBatchInput {
              Text("以空格、换行或制表符分隔；重复关键词仅保留一次，每个词单独成为规则，匹配任意一个即生效。含空格的短语请使用“单个词 / 短语”。")
              Text("每个关键词最多 \(SafeContentFilterRegex.maximumPatternCharacters) 个字符，屏蔽列表与白名单合计最多 \(FileContentFilterStore.defaultMaximumRules) 条规则。白名单仍优先于屏蔽关键词。")
            }
            if !keyword.isEmpty, let keywordValidationMessage {
              Text(keywordValidationMessage)
                .foregroundStyle(.red)
            }
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
    .disabled(isSaving)
    .navigationTitle(list == .block ? "添加屏蔽规则" : "添加白名单规则")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("取消") { dismiss() }
          .disabled(isSaving)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button(isSaving ? "保存中…" : "添加", action: save)
          .disabled(!isValid || isSaving)
      }
    }
    .interactiveDismissDisabled(isSaving)
    .alert(
      "无法保存规则",
      isPresented: Binding(
        get: { saveErrorMessage != nil },
        set: { if !$0 { saveErrorMessage = nil } }
      )
    ) {
      Button("好") { saveErrorMessage = nil }
    } message: {
      Text(saveErrorMessage ?? "未知错误")
    }
  }

  private var isBatchInput: Bool {
    keywordMatchMode == .literal && keywordInputMode == .batch
  }

  private func batchPreview() throws -> ContentFilterKeywordBatchPreview {
    try ContentFilterKeywordInputPolicy.batchPreview(
      keyword,
      list: list,
      existingRules: existingRules
    )
  }

  private var keywordValidationMessage: String? {
    do {
      if isBatchInput {
        let preview = try batchPreview()
        if preview.newKeywords.isEmpty { return "这些关键词均已存在，没有需要新增的规则。" }
      } else {
        _ = try ContentFilterKeywordInputPolicy.validatedPatterns(
          keyword,
          matchMode: keywordMatchMode,
          inputMode: keywordInputMode
        )
      }
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  private var isValid: Bool {
    switch kind {
    case .keyword:
      return keywordValidationMessage == nil
    case .user:
      let name = normalized(username)
      let idText = normalized(userID)
      let parsedID = Int64(idText)
      let hasValidID = idText.isEmpty || (parsedID.map { $0 > 0 } ?? false)
      return hasValidID && name.count <= 100 && (parsedID != nil || !name.isEmpty)
    }
  }

  private func save() {
    guard isValid, !isSaving else { return }
    isSaving = true
    Task { @MainActor in
      defer { isSaving = false }
      do {
        switch kind {
        case .keyword:
          if isBatchInput {
            let preview = try batchPreview()
            try await onSaveBatch(preview.newKeywords.map { .keyword($0, list: list) })
          } else {
            let pattern = try ContentFilterKeywordPatternPolicy.validated(
              keyword,
              mode: keywordMatchMode
            )
            switch keywordMatchMode {
            case .literal:
              try await onSave(.keyword(pattern, list: list))
            case .regularExpression:
              try await onSave(.regularExpression(pattern, list: list))
            }
          }
        case .user:
          try await onSave(
            .user(
              id: Int64(normalized(userID)),
              name: normalized(username),
              list: list
            )
          )
        }
        dismiss()
      } catch {
        saveErrorMessage = error.localizedDescription
      }
    }
  }

  private func normalized(_ value: String) -> String {
    value
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
  }
}
