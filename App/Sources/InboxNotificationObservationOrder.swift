import Foundation

/// Shared by every unread-summary reader that can update the notification baseline.
/// Reserve a token immediately before starting the server request, not on completion:
/// a slower older response must not overwrite a newer post-inbox-read summary.
@MainActor
final class InboxNotificationObservationOrder {
  private var current: UUID?

  func begin() -> UUID {
    let token = UUID()
    current = token
    return token
  }

  func accepts(_ token: UUID) -> Bool {
    current == token
  }

  /// Account and preference changes invalidate pending observations without reviving
  /// an older request when the most recent request fails or is cancelled.
  func invalidate() {
    current = nil
  }
}
