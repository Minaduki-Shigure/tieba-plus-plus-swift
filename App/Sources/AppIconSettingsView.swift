import SwiftUI
import UIKit

enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
  case classic
  case light
  case dark

  var id: String { rawValue }

  var title: String {
    switch self {
    case .classic: "经典蓝"
    case .light: "浅色"
    case .dark: "深色"
    }
  }

  var alternateIconName: String? {
    switch self {
    case .classic: nil
    case .light: "AppIconLight"
    case .dark: "AppIconDark"
    }
  }

  var previewAssetName: String {
    switch self {
    case .classic: "AppIconPreviewClassic"
    case .light: "AppIconPreviewLight"
    case .dark: "AppIconPreviewDark"
    }
  }

  static func from(alternateIconName: String?) -> Self? {
    allCases.first { $0.alternateIconName == alternateIconName }
  }
}

@MainActor
protocol AppIconSystem: AnyObject {
  var supportsAlternateIcons: Bool { get }
  var alternateIconName: String? { get }
  var isActive: Bool { get }
  func setAlternateIconName(_ name: String?) async throws
}

@MainActor
final class UIApplicationIconSystem: AppIconSystem {
  private let application: UIApplication

  init(application: UIApplication) {
    self.application = application
  }

  var supportsAlternateIcons: Bool { application.supportsAlternateIcons }
  var alternateIconName: String? { application.alternateIconName }
  var isActive: Bool { application.applicationState == .active }

  func setAlternateIconName(_ name: String?) async throws {
    // UIKit's async API resumes on this actor even though its completion
    // handler is not guaranteed to run on the main queue.
    try await application.setAlternateIconName(name)
  }
}

enum AppIconChangeIssue: String, Identifiable {
  case unavailable
  case inactive
  case failed
  case notApplied

  var id: String { rawValue }

  var message: String {
    switch self {
    case .unavailable:
      "当前安装方式不支持更换应用图标。"
    case .inactive:
      "请返回应用后再试。"
    case .failed:
      "系统未能完成图标切换，请稍后重试。"
    case .notApplied:
      "系统尚未使用所选图标，请确认主屏幕上的图标后再试。"
    }
  }
}

@MainActor
final class AppIconModel: ObservableObject {
  // A shared model also serializes requests from different settings screens.
  static let shared = AppIconModel(system: UIApplicationIconSystem(application: .shared))

  @Published private(set) var selectedChoice: AppIconChoice?
  @Published private(set) var supportsAlternateIcons = false
  @Published private(set) var requestedChoice: AppIconChoice?
  @Published private(set) var issue: AppIconChangeIssue?

  private let system: any AppIconSystem

  init(system: any AppIconSystem) {
    self.system = system
    refresh()
  }

  func refresh() {
    // iOS persists this choice. Do not maintain a second preference that can
    // diverge after an error, an app reinstall, or a host-side change.
    supportsAlternateIcons = system.supportsAlternateIcons
    selectedChoice = AppIconChoice.from(alternateIconName: system.alternateIconName)
  }

  func clearIssue() {
    issue = nil
  }

  func select(_ choice: AppIconChoice) async {
    guard requestedChoice == nil, !Task.isCancelled else { return }
    refresh()
    issue = nil
    guard supportsAlternateIcons else {
      issue = .unavailable
      return
    }
    guard system.isActive else {
      issue = .inactive
      return
    }
    guard selectedChoice != choice else { return }

    requestedChoice = choice
    defer { requestedChoice = nil }
    do {
      try await system.setAlternateIconName(choice.alternateIconName)
      refresh()
      if selectedChoice != choice { issue = .notApplied }
    } catch {
      refresh()
      issue = .failed
    }
  }
}

struct AppIconSettingsView: View {
  @ObservedObject var model: AppIconModel
  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    List {
      Section {
        ForEach(AppIconChoice.allCases) { choice in
          iconRow(choice)
        }
      } footer: {
        Text("更换主屏幕上的应用图标。图标选择独立于应用内的浅色或深色外观，切换时可能出现系统提示。在 LiveContainer 中，主屏幕图标能否更换取决于宿主支持。")
      }

      if !model.supportsAlternateIcons {
        Section {
          Text("当前安装方式不支持更换应用图标。")
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("app-icon-unavailable")
        }
      } else if model.selectedChoice == nil {
        Section {
          Text("当前使用其他图标，可在上方重新选择。")
            .foregroundStyle(.secondary)
        }
      }
    }
    .listStyle(.insetGrouped)
    .appScrollableSurface()
    .navigationTitle("应用图标")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { model.refresh() }
    .onChange(of: scenePhase) { phase in
      if phase == .active { model.refresh() }
    }
    .alert(item: Binding(get: { model.issue }, set: { _ in model.clearIssue() })) { issue in
      Alert(title: Text("未能更换图标"), message: Text(issue.message), dismissButton: .default(Text("好")))
    }
  }

  private func iconRow(_ choice: AppIconChoice) -> some View {
    let isSelected = model.selectedChoice == choice
    let isPending = model.requestedChoice == choice
    return Button {
      Task { await model.select(choice) }
    } label: {
      HStack(spacing: 14) {
        Image(choice.previewAssetName)
          .resizable()
          .scaledToFit()
          .frame(width: 52, height: 52)
          .clipShape(RoundedRectangle(cornerRadius: 11))
          .overlay {
            RoundedRectangle(cornerRadius: 11)
              .stroke(Color(uiColor: .separator), lineWidth: 0.5)
          }
          .accessibilityHidden(true)
        Text(choice.title)
          .foregroundStyle(.primary)
        Spacer(minLength: 12)
        Group {
          if isPending {
            ProgressView()
          } else {
            Image(systemName: "checkmark")
              .foregroundStyle(.tint)
              .opacity(isSelected ? 1 : 0)
          }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
      }
      .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!model.supportsAlternateIcons || model.requestedChoice != nil)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(choice.title)
    .accessibilityValue(isPending ? "正在切换" : (isSelected ? "当前使用" : ""))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityIdentifier("app-icon-option-\(choice.rawValue)")
  }
}
