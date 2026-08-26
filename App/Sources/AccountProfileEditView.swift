import SwiftUI

struct AccountProfileEditView: View {
  let onSaved: @MainActor @Sendable (AccountProfileSummary) -> Void

  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel: AccountProfileEditViewModel
  @State private var loadTask: Task<Void, Never>?
  @State private var saveTask: Task<Void, Never>?
  @State private var loadTaskID: UUID?
  @State private var saveTaskID: UUID?

  init(
    userID: Int64,
    service: any AccountService,
    vault: any AccountVault,
    onSaved: @escaping @MainActor @Sendable (AccountProfileSummary) -> Void
  ) {
    self.onSaved = onSaved
    _viewModel = StateObject(
      wrappedValue: AccountProfileEditViewModel(
        expectedUserID: userID,
        service: service,
        vault: vault
      )
    )
  }

  var body: some View {
    Form {
      switch viewModel.state {
      case .idle, .loading:
        Section {
          HStack {
            Spacer()
            ProgressView("正在读取个人资料")
            Spacer()
          }
          .frame(minHeight: 72)
        }
      case .failed:
        Section {
          ErrorStateView(message: viewModel.errorMessage ?? "无法读取个人资料。") {
            beginReload()
          }
        }
      case .ready, .saving:
        if let summary = viewModel.summary {
          profileSections(summary: summary)
        }
      }
    }
    .appScrollableSurface()
    .navigationTitle("编辑个人资料")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(viewModel.requiresNavigationInterception)
    .toolbar {
      if viewModel.requiresNavigationInterception {
        ToolbarItem(placement: .cancellationAction) {
          Button(action: requestClose) {
            Image(systemName: "chevron.backward")
          }
          .disabled(viewModel.isSaving)
          .accessibilityLabel("返回")
          .help("返回")
        }
      }

      ToolbarItem(placement: .confirmationAction) {
        Button(action: beginSave) {
          ZStack {
            Image(systemName: "checkmark")
              .opacity(viewModel.isSaving ? 0 : 1)
            if viewModel.isSaving {
              ProgressView()
                .controlSize(.small)
            }
          }
        }
        .frame(width: 32, height: 32)
        .disabled(!viewModel.canSave)
        .accessibilityLabel("保存个人资料")
        .help("保存个人资料")
        .accessibilityIdentifier("account-profile-edit-save")
      }
    }
    .onAppear(perform: beginLoad)
    .interactiveDismissDisabled(viewModel.requiresNavigationInterception)
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      cancelTasks()
      viewModel.invalidateForAccountSessionChange()
      dismiss()
    }
    .onDisappear {
      viewModel.presentationBecameInactive()
    }
    .confirmationDialog(
      "放弃未保存的修改？",
      isPresented: Binding(
        get: { viewModel.showsDiscardConfirmation },
        set: { if !$0 { viewModel.cancelDiscard() } }
      ),
      titleVisibility: .visible
    ) {
      Button("放弃修改", role: .destructive) {
        guard viewModel.confirmDiscard() else { return }
        dismiss()
      }
      Button("继续编辑", role: .cancel) { viewModel.cancelDiscard() }
    } message: {
      Text("昵称、性别或简介的修改尚未保存。")
    }
    .alert(
      "个人资料",
      isPresented: Binding(
        get: { viewModel.errorMessage != nil && viewModel.state != .failed },
        set: { if !$0 { viewModel.dismissError() } }
      )
    ) {
      Button("好", role: .cancel) { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage ?? "无法保存个人资料。")
    }
  }

  @ViewBuilder
  private func profileSections(summary: AccountProfileSummary) -> some View {
    Section("账户") {
      HStack(spacing: 14) {
        AvatarView(url: summary.portraitURL, name: summary.preferredName, size: 64)
        VStack(alignment: .leading, spacing: 4) {
          Text(summary.preferredName)
            .font(.headline)
            .lineLimit(2)
          Text(summary.username)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
      }
      .padding(.vertical, 4)
    }

    Section("身份") {
      TextField("昵称", text: displayNameBinding)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .disabled(!viewModel.isEditingEnabled)
        .accessibilityIdentifier("account-profile-edit-display-name")

      Picker("性别", selection: sexBinding) {
        Text(AccountProfileSex.unspecified.title)
          .tag(AccountProfileSex.unspecified)
          .disabled(true)
        ForEach(AccountProfileSex.userSelectableCases) { sex in
          Text(sex.title).tag(sex)
        }
      }
      .pickerStyle(.menu)
      .disabled(!viewModel.isEditingEnabled)
      .accessibilityIdentifier("account-profile-edit-sex")
    }

    Section {
      TextEditor(text: biographyBinding)
        .frame(minHeight: 116)
        .disabled(!viewModel.isEditingEnabled)
        .accessibilityLabel("简介")
        .accessibilityIdentifier("account-profile-edit-biography")
    } header: {
      Text("简介")
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        Text(
          "\(viewModel.biographyNonWhitespaceCharacterCount) / "
            + "\(AccountProfileEditPolicy.maximumBiographyNonWhitespaceCharacters)"
        )
        .monospacedDigit()
        if let message = viewModel.validationMessage {
          Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  private var displayNameBinding: Binding<String> {
    Binding(
      get: { viewModel.draft.displayName },
      set: { viewModel.setDisplayName($0) }
    )
  }

  private var biographyBinding: Binding<String> {
    Binding(
      get: { viewModel.draft.biography },
      set: { viewModel.setBiography($0) }
    )
  }

  private var sexBinding: Binding<AccountProfileSex> {
    Binding(
      get: { viewModel.draft.sex },
      set: { viewModel.setSex($0) }
    )
  }

  private func requestClose() {
    if viewModel.requestClose() { dismiss() }
  }

  private func beginSave() {
    guard saveTask == nil else { return }
    let taskID = UUID()
    saveTaskID = taskID
    saveTask = Task { @MainActor in
      defer { finishSaveTask(id: taskID) }
      guard let saved = await viewModel.save() else { return }
      onSaved(saved)
      if AccountProfileEditCompletionPolicy.dismissesEditor(after: saved) {
        dismiss()
      }
    }
  }

  private func beginLoad() {
    guard loadTask == nil else { return }
    let taskID = UUID()
    loadTaskID = taskID
    loadTask = Task { @MainActor in
      defer { finishLoadTask(id: taskID) }
      await viewModel.loadIfNeeded()
    }
  }

  private func beginReload() {
    guard loadTask == nil else { return }
    let taskID = UUID()
    loadTaskID = taskID
    loadTask = Task { @MainActor in
      defer { finishLoadTask(id: taskID) }
      await viewModel.reload()
    }
  }

  private func finishLoadTask(id: UUID) {
    guard loadTaskID == id else { return }
    loadTaskID = nil
    loadTask = nil
  }

  private func finishSaveTask(id: UUID) {
    guard saveTaskID == id else { return }
    saveTaskID = nil
    saveTask = nil
  }

  private func cancelTasks() {
    let activeLoad = loadTask
    let activeSave = saveTask
    loadTaskID = nil
    saveTaskID = nil
    loadTask = nil
    saveTask = nil
    activeLoad?.cancel()
    activeSave?.cancel()
  }
}
