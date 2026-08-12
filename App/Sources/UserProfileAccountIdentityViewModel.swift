import Combine
import Foundation

@MainActor
final class UserProfileAccountIdentityViewModel: ObservableObject {
  @Published private(set) var userID: Int64?
  @Published private(set) var isResolved = false

  private var generation = 0

  func resolve(access: AccountAccess?) async {
    let token = beginResolution()
    await resolve(access: access, ifCurrent: token)
  }

  @discardableResult
  func beginResolution() -> Int {
    generation &+= 1
    userID = nil
    isResolved = false
    return generation
  }

  func resolve(access: AccountAccess?, ifCurrent token: Int) async {
    guard token == generation else { return }
    guard let access else {
      guard token == generation else { return }
      isResolved = true
      return
    }
    do {
      let session = try await access.vault.activeSession()
      try Task.checkCancellation()
      guard token == generation else { return }
      userID = session?.id
      isResolved = true
    } catch is CancellationError {
      return
    } catch {
      guard token == generation else { return }
      userID = nil
      isResolved = false
    }
  }

  func invalidate() {
    _ = beginResolution()
  }
}
