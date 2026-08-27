import Combine
import SwiftUI

@MainActor
final class LocalFavoriteControlModel: ObservableObject {
  @Published private(set) var isFavorite = false
  @Published private(set) var isWorking = true
  @Published private(set) var errorMessage: String?

  private let repository: any LocalFavoritesRepository

  init(repository: any LocalFavoritesRepository) {
    self.repository = repository
  }

  func reload(target: LocalFavoriteTarget) async {
    isWorking = true
    defer { isWorking = false }
    do {
      isFavorite = try await repository.contains(id: target.storageKey)
    } catch is CancellationError {
      return
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func toggle(target: LocalFavoriteTarget) {
    guard !isWorking else { return }
    isWorking = true
    let wasFavorite = isFavorite
    isFavorite.toggle()
    Task {
      defer { isWorking = false }
      do {
        if wasFavorite {
          try await repository.delete(id: target.storageKey)
        } else {
          try await repository.save(target)
        }
      } catch is CancellationError {
        isFavorite = wasFavorite
      } catch {
        isFavorite = wasFavorite
        errorMessage = error.localizedDescription
      }
    }
  }

  func dismissError() {
    errorMessage = nil
  }
}

struct LocalFavoriteButton: View {
  let target: LocalFavoriteTarget
  @StateObject private var model: LocalFavoriteControlModel

  init(
    target: LocalFavoriteTarget,
    repository: any LocalFavoritesRepository
  ) {
    self.target = target
    _model = StateObject(
      wrappedValue: LocalFavoriteControlModel(repository: repository)
    )
  }

  var body: some View {
    LocalFavoriteToolbarButton(target: target, model: model)
      .task(id: target.storageKey) { await model.reload(target: target) }
      .localFavoriteErrorAlert(model: model)
  }
}

struct LocalFavoriteToolbarButton: View {
  let target: LocalFavoriteTarget
  @ObservedObject var model: LocalFavoriteControlModel

  var body: some View {
    LocalFavoriteControl(
      target: target,
      model: model,
      presentation: .toolbar
    )
  }
}

struct LocalFavoriteMenuItem: View {
  let target: LocalFavoriteTarget
  @ObservedObject var model: LocalFavoriteControlModel

  var body: some View {
    LocalFavoriteControl(
      target: target,
      model: model,
      presentation: .menu
    )
  }
}

private enum LocalFavoriteControlPresentation: Equatable {
  case toolbar
  case menu
}

private struct LocalFavoriteControl: View {
  let target: LocalFavoriteTarget
  @ObservedObject var model: LocalFavoriteControlModel
  let presentation: LocalFavoriteControlPresentation

  var body: some View {
    Button(
      role: presentation == .menu && model.isFavorite ? .destructive : nil,
      action: { model.toggle(target: target) }
    ) {
      switch presentation {
      case .toolbar:
        Group {
          if model.isWorking {
            ProgressView()
              .controlSize(.small)
          } else {
            Image(systemName: model.isFavorite ? "bookmark.fill" : "bookmark")
          }
        }
        .frame(width: 24, height: 24)
      case .menu:
        Label(menuTitle, systemImage: menuSystemImage)
      }
    }
    .disabled(model.isWorking)
    .accessibilityLabel(
      model.isFavorite ? "从本地收藏移除" : "添加到本地收藏"
    )
    .help(model.isFavorite ? "从本地收藏移除" : "添加到本地收藏")
    .accessibilityIdentifier(
      presentation == .toolbar
        ? "thread-local-favorite"
        : "thread-local-favorite-menu-item"
    )
  }

  private var menuTitle: String {
    if model.isWorking { return "正在读取本地收藏" }
    return model.isFavorite ? "从本地收藏移除" : "添加到本地收藏"
  }

  private var menuSystemImage: String {
    if model.isWorking { return "hourglass" }
    return model.isFavorite ? "bookmark.fill" : "bookmark"
  }
}

private struct LocalFavoriteErrorAlertModifier: ViewModifier {
  @ObservedObject var model: LocalFavoriteControlModel

  func body(content: Content) -> some View {
    content.alert(
      "无法更新本地收藏",
      isPresented: Binding(
        get: { model.errorMessage != nil },
        set: { if !$0 { model.dismissError() } }
      )
    ) {
      Button("好") { model.dismissError() }
    } message: {
      Text(model.errorMessage ?? "未知错误")
    }
  }
}

extension View {
  func localFavoriteErrorAlert(
    model: LocalFavoriteControlModel
  ) -> some View {
    modifier(LocalFavoriteErrorAlertModifier(model: model))
  }
}
