import SwiftUI

struct LocalFavoriteButton: View {
  let target: LocalFavoriteTarget
  let repository: any LocalFavoritesRepository

  @State private var isFavorite = false
  @State private var isWorking = true
  @State private var errorMessage: String?

  var body: some View {
    Button(action: toggle) {
      Group {
        if isWorking {
          ProgressView()
            .controlSize(.small)
        } else {
          Image(systemName: isFavorite ? "bookmark.fill" : "bookmark")
        }
      }
      .frame(width: 24, height: 24)
    }
    .disabled(isWorking)
    .accessibilityLabel(isFavorite ? "从本地收藏移除" : "添加到本地收藏")
    .help(isFavorite ? "从本地收藏移除" : "添加到本地收藏")
    .task(id: target.storageKey) { await reload() }
    .alert(
      "无法更新本地收藏",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("好") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "未知错误")
    }
  }

  private func reload() async {
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

  private func toggle() {
    guard !isWorking else { return }
    isWorking = true
    let wasFavorite = isFavorite
    isFavorite.toggle()
    let repository = repository
    let target = target
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
}
