import PhotosUI
import SwiftUI

enum AccountProfileEditInteractionPolicy {
  static func allowsTextSave(
    viewModelCanSave: Bool,
    isImportingAvatar: Bool,
    isCroppingAvatar: Bool,
    hasPendingAvatarUpload: Bool
  ) -> Bool {
    viewModelCanSave
      && !isImportingAvatar
      && !isCroppingAvatar
      && !hasPendingAvatarUpload
  }

  static func requiresNavigationInterception(
    viewModelRequiresInterception: Bool,
    isImportingAvatar: Bool,
    isCroppingAvatar: Bool,
    hasPendingAvatarUpload: Bool
  ) -> Bool {
    viewModelRequiresInterception
      || isImportingAvatar
      || isCroppingAvatar
      || hasPendingAvatarUpload
  }
}

struct AccountProfileEditView: View {
  let onSaved: @MainActor @Sendable (AccountProfileSummary) -> Void

  @Environment(\.dismiss) private var dismiss
  @StateObject private var viewModel: AccountProfileEditViewModel
  @State private var loadTask: Task<Void, Never>?
  @State private var saveTask: Task<Void, Never>?
  @State private var avatarImportTask: Task<Void, Never>?
  @State private var avatarUploadTask: Task<Void, Never>?
  @State private var loadTaskID: UUID?
  @State private var saveTaskID: UUID?
  @State private var avatarImportTaskID: UUID?
  @State private var avatarUploadTaskID: UUID?
  @State private var avatarPickerSelection: PhotosPickerItem?
  @State private var avatarCropSource: ProfileAvatarCropSource?
  @State private var activeAvatarImportFile: SecurePickedImageFile?
  @State private var avatarPreparationErrorMessage: String?

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
    .navigationBarBackButtonHidden(requiresNavigationInterception)
    .toolbar {
      if requiresNavigationInterception {
        ToolbarItem(placement: .cancellationAction) {
          Button(action: requestClose) {
            Image(systemName: "chevron.backward")
          }
          .disabled(viewModel.isSaving || viewModel.isUploadingAvatar)
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
        .disabled(!textSaveIsEnabled)
        .accessibilityLabel("保存个人资料")
        .help("保存个人资料")
        .accessibilityIdentifier("account-profile-edit-save")
      }
    }
    .onAppear(perform: beginLoad)
    .interactiveDismissDisabled(requiresNavigationInterception)
    .onReceive(NotificationCenter.default.publisher(for: .accountSessionDidChange)) { _ in
      cancelTasks()
      viewModel.invalidateForAccountSessionChange()
      dismiss()
    }
    .onDisappear {
      // Presenting the full-screen cropper may make this parent disappear
      // temporarily. Keep its source alive until the cropper completes.
      if avatarCropSource == nil {
        cancelAvatarImport()
      }
      viewModel.presentationBecameInactive()
    }
    .onChange(of: avatarPickerSelection) { selection in
      guard let selection else { return }
      avatarPickerSelection = nil
      beginAvatarImport(selection)
    }
    .fullScreenCover(item: $avatarCropSource) { source in
      ProfileAvatarCropView(
        source: source,
        onCancel: { avatarCropSource = nil },
        onPrepared: { upload in
          avatarCropSource = nil
          beginAvatarUpload(upload)
        }
      )
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
        get: {
          avatarPreparationErrorMessage != nil
            || (viewModel.errorMessage != nil && viewModel.state != .failed)
        },
        set: {
          if !$0 {
            avatarPreparationErrorMessage = nil
            viewModel.dismissError()
          }
        }
      )
    ) {
      Button("好", role: .cancel) {
        avatarPreparationErrorMessage = nil
        viewModel.dismissError()
      }
    } message: {
      Text(
        avatarPreparationErrorMessage
          ?? viewModel.errorMessage
          ?? "无法更新个人资料。"
      )
    }
  }

  @ViewBuilder
  private func profileSections(summary: AccountProfileSummary) -> some View {
    Section("账户") {
      HStack(spacing: 14) {
        PhotosPicker(
          selection: $avatarPickerSelection,
          matching: .images,
          preferredItemEncoding: .current
        ) {
          ZStack(alignment: .bottomTrailing) {
            AvatarView(url: summary.portraitURL, name: summary.preferredName, size: 64)
            avatarPickerBadge(canModifyAvatar: summary.canModifyAvatar)
          }
          .frame(width: 68, height: 68)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!avatarPickerIsEnabled)
        .accessibilityLabel(
          avatarPickerAccessibilityLabel(canModifyAvatar: summary.canModifyAvatar)
        )
        .help("选择新头像")

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

      if avatarImportTaskID != nil {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("正在安全处理头像图片。")
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
      }

      if let statusMessage = viewModel.avatarStatusMessage {
        Label(statusMessage, systemImage: avatarStatusSystemImage)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
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

  @ViewBuilder
  private func avatarPickerBadge(canModifyAvatar: Bool) -> some View {
    ZStack {
      Circle()
        .fill(canModifyAvatar ? Color.accentColor : Color.secondary)
      if avatarImportTaskID != nil || viewModel.isUploadingAvatar {
        ProgressView()
          .controlSize(.mini)
          .tint(.white)
      } else if !canModifyAvatar {
        Image(systemName: "lock.fill")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.white)
      } else {
        Image(systemName: "camera.fill")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.white)
      }
    }
    .frame(width: 24, height: 24)
    .overlay {
      Circle()
        .stroke(Color(uiColor: .systemBackground), lineWidth: 2)
    }
    .accessibilityHidden(true)
  }

  private func avatarPickerAccessibilityLabel(canModifyAvatar: Bool) -> String {
    guard canModifyAvatar else { return "当前头像不可修改" }
    if avatarImportTaskID != nil { return "正在处理新头像" }
    if viewModel.isUploadingAvatar { return "正在上传新头像" }
    return "选择新头像"
  }

  private var avatarPickerIsEnabled: Bool {
    viewModel.canUploadAvatar
      && avatarImportTaskID == nil
      && avatarUploadTaskID == nil
      && avatarCropSource == nil
  }

  private var textSaveIsEnabled: Bool {
    AccountProfileEditInteractionPolicy.allowsTextSave(
      viewModelCanSave: viewModel.canSave,
      isImportingAvatar: avatarImportTaskID != nil,
      isCroppingAvatar: avatarCropSource != nil,
      hasPendingAvatarUpload: avatarUploadTaskID != nil
    )
  }

  private var requiresNavigationInterception: Bool {
    AccountProfileEditInteractionPolicy.requiresNavigationInterception(
      viewModelRequiresInterception: viewModel.requiresNavigationInterception,
      isImportingAvatar: avatarImportTaskID != nil,
      isCroppingAvatar: avatarCropSource != nil,
      hasPendingAvatarUpload: avatarUploadTaskID != nil
    )
  }

  private var avatarStatusSystemImage: String {
    switch viewModel.avatarState {
    case .idle:
      "lock.fill"
    case .uploading:
      "arrow.up.circle.fill"
    case .confirmed:
      "checkmark.circle.fill"
    case .acceptedPendingReview:
      "clock.fill"
    }
  }

  private func requestClose() {
    cancelAvatarPreparation()
    if viewModel.requestClose() { dismiss() }
  }

  private func beginSave() {
    guard saveTask == nil, textSaveIsEnabled else { return }
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

  private func beginAvatarImport(_ item: PhotosPickerItem) {
    guard avatarPickerIsEnabled else { return }
    let taskID = UUID()
    let processor = ProfileAvatarImageProcessor()
    avatarImportTaskID = taskID
    avatarPreparationErrorMessage = nil

    avatarImportTask = Task { @MainActor in
      var importedFile: SecurePickedImageFile?
      defer {
        importedFile?.removeTemporaryCopy()
        if
          let importedFile,
          activeAvatarImportFile?.temporaryDirectoryURL
            == importedFile.temporaryDirectoryURL
        {
          activeAvatarImportFile = nil
        }
        finishAvatarImportTask(id: taskID)
      }

      do {
        guard
          let selectedFile = try await item.loadTransferable(
            type: SecurePickedImageFile.self
          )
        else { throw AccountProfileAvatarImportError.unavailableTransfer }
        importedFile = selectedFile
        activeAvatarImportFile = selectedFile
        try Task.checkCancellation()
        guard avatarImportTaskID == taskID else { return }

        let source = try await processor.prepare(fileURL: selectedFile.fileURL)
        try Task.checkCancellation()
        guard avatarImportTaskID == taskID else { return }
        avatarCropSource = source
      } catch is CancellationError {
        return
      } catch {
        guard avatarImportTaskID == taskID, !Task.isCancelled else { return }
        avatarPreparationErrorMessage =
          AccountProfileAvatarImportError.presentationMessage(for: error)
      }
    }
  }

  private func beginAvatarUpload(_ upload: AccountProfileAvatarUpload) {
    guard avatarUploadTask == nil, viewModel.canUploadAvatar else { return }
    let taskID = UUID()
    avatarUploadTaskID = taskID
    avatarUploadTask = Task { @MainActor in
      defer { finishAvatarUploadTask(id: taskID) }
      guard let result = await viewModel.uploadAvatar(upload) else { return }
      guard avatarUploadTaskID == taskID, !Task.isCancelled else { return }
      onSaved(result.profile)
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

  private func finishAvatarImportTask(id: UUID) {
    guard avatarImportTaskID == id else { return }
    avatarImportTaskID = nil
    avatarImportTask = nil
  }

  private func finishAvatarUploadTask(id: UUID) {
    guard avatarUploadTaskID == id else { return }
    avatarUploadTaskID = nil
    avatarUploadTask = nil
  }

  private func cancelAvatarImport() {
    let activeTask = avatarImportTask
    let activeFile = activeAvatarImportFile
    avatarPickerSelection = nil
    avatarImportTaskID = nil
    avatarImportTask = nil
    activeAvatarImportFile = nil
    activeTask?.cancel()
    activeFile?.removeTemporaryCopy()
  }

  private func cancelAvatarUpload() {
    let activeTask = avatarUploadTask
    avatarUploadTaskID = nil
    avatarUploadTask = nil
    activeTask?.cancel()
  }

  private func cancelAvatarPreparation() {
    cancelAvatarImport()
    avatarCropSource = nil
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
    cancelAvatarPreparation()
    cancelAvatarUpload()
  }
}

private enum AccountProfileAvatarImportError: Error, LocalizedError {
  case unavailableTransfer

  var errorDescription: String? {
    switch self {
    case .unavailableTransfer:
      "无法从照片图库读取这张图片。"
    }
  }

  static func presentationMessage(for error: Error) -> String {
    guard
      let localizedError = error as? any LocalizedError,
      let description = localizedError.errorDescription,
      !description.isEmpty
    else { return "无法安全导入选择的头像图片。" }
    return description
  }
}
