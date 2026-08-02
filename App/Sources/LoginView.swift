import Foundation
import SwiftUI

struct LoginView: View {
  @Environment(\.dismiss) private var dismiss

  let onSuccess: @MainActor @Sendable () -> Void

  @StateObject private var viewModel: LoginViewModel
  @State private var currentHost = "wappass.baidu.com"
  @State private var webViewID = UUID()
  @State private var validationTask: Task<Void, Never>?
  @State private var validationID: UUID?

  init(
    service: any AccountService,
    vault: any AccountVault,
    onSuccess: @escaping @MainActor @Sendable () -> Void
  ) {
    self.onSuccess = onSuccess
    _viewModel = StateObject(
      wrappedValue: LoginViewModel(service: service, vault: vault)
    )
  }

  var body: some View {
    ZStack {
      SecureTiebaLoginWebView(
        onHostChange: { currentHost = $0 },
        onCredentials: complete,
        onBlockedNavigation: viewModel.reportBlockedNavigation,
        onLoadFailure: { viewModel.errorMessage = "登录页面加载失败，请稍后重试。" }
      )
      .id(webViewID)

      if viewModel.isValidating {
        ZStack {
          Color(uiColor: .systemBackground).opacity(0.82)
          ProgressView("正在验证账户")
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .principal) {
        VStack(spacing: 1) {
          Text("登录百度账户")
            .font(.headline)
          Label(currentHost, systemImage: "lock.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      }
      ToolbarItem(placement: .cancellationAction) {
        Button("取消") { dismiss() }
          .disabled(viewModel.isValidating)
      }
    }
    .interactiveDismissDisabled(viewModel.isValidating)
    .onDisappear(perform: cancelValidation)
    .alert(
      "登录失败",
      isPresented: Binding(
        get: { viewModel.errorMessage != nil },
        set: { if !$0 { viewModel.clearError() } }
      )
    ) {
      Button("重新加载") {
        viewModel.clearError()
        webViewID = UUID()
      }
      Button("取消", role: .cancel) { viewModel.clearError() }
    } message: {
      Text(viewModel.errorMessage ?? "无法验证账户。")
    }
  }

  private func complete(_ credentials: AccountCredentials) {
    guard validationTask == nil else { return }
    let id = UUID()
    validationID = id
    validationTask = Task {
      let succeeded = await viewModel.complete(credentials: credentials)
      guard !Task.isCancelled, validationID == id else { return }
      validationTask = nil
      validationID = nil
      if succeeded {
        onSuccess()
        dismiss()
      } else {
        webViewID = UUID()
      }
    }
  }

  private func cancelValidation() {
    validationID = nil
    validationTask?.cancel()
    validationTask = nil
  }
}
