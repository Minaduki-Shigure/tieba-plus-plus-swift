import Foundation
import SwiftUI

struct LoginView: View {
  @Environment(\.dismiss) private var dismiss

  let onSuccess: @MainActor @Sendable () -> Void

  @StateObject private var viewModel: LoginViewModel
  @State private var currentHost = "wappass.baidu.com"
  @State private var webViewID = UUID()
  @State private var isCapturingCredentials = false
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
        onCredentialCaptureStateChange: { isCapturingCredentials = $0 },
        onCredentials: complete,
        onCredentialCaptureFailure: {
          viewModel.errorMessage = "网页登录已完成，但未能读取安全的账户凭据。请重新加载后再试。"
        },
        onBlockedNavigation: viewModel.reportBlockedNavigation,
        onLoadFailure: { viewModel.errorMessage = "登录页面加载失败，请稍后重试。" }
      )
      .id(webViewID)

      if isCapturingCredentials || viewModel.isValidating {
        ZStack {
          Color(uiColor: .systemBackground).opacity(0.82)
          ProgressView(viewModel.isValidating ? "正在验证账户" : "正在完成登录")
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
          .disabled(isCapturingCredentials || viewModel.isValidating)
      }
    }
    .interactiveDismissDisabled(isCapturingCredentials || viewModel.isValidating)
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
        isCapturingCredentials = false
        webViewID = UUID()
      }
      Button("取消", role: .cancel) { viewModel.clearError() }
    } message: {
      Text(viewModel.errorMessage ?? "无法验证账户。")
    }
  }

  private func complete(_ credentials: AccountCredentials) {
    guard validationTask == nil else { return }
    isCapturingCredentials = false
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
    isCapturingCredentials = false
    validationID = nil
    validationTask?.cancel()
    validationTask = nil
  }
}
