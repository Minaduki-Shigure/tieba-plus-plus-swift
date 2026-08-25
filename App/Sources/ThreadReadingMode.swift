import Foundation

enum ThreadReadingMode: String, CaseIterable, Equatable, Identifiable, Sendable {
  case standard
  case pure
  case immersive

  var id: Self { self }

  var title: String {
    switch self {
    case .standard:
      "标准阅读"
    case .pure:
      "纯净阅读"
    case .immersive:
      "沉浸阅读（只看楼主）"
    }
  }

  var systemImage: String {
    switch self {
    case .standard:
      "book.closed"
    case .pure:
      "book.closed.fill"
    case .immersive:
      "person.fill"
    }
  }

  var usesPurePresentation: Bool { self != .standard }
}

struct ThreadImmersiveReadingConfirmation: Equatable, Sendable {
  let threadID: Int64
  let options: ThreadBrowseOptions

  init?(threadID: Int64, options: ThreadBrowseOptions) {
    guard threadID > 0, !options.onlyThreadAuthor else { return nil }
    self.threadID = threadID
    self.options = options
  }

  func matches(threadID: Int64, options: ThreadBrowseOptions) -> Bool {
    self.threadID == threadID && self.options == options
  }
}

enum ThreadReadingModeSelection: Equatable, Sendable {
  case apply(ThreadReadingMode)
  case confirmImmersive(ThreadImmersiveReadingConfirmation)
  case ignore
}

enum ThreadReadingModePolicy {
  static func selection(
    for requestedMode: ThreadReadingMode,
    threadID: Int64,
    options: ThreadBrowseOptions
  ) -> ThreadReadingModeSelection {
    guard requestedMode == .immersive, !options.onlyThreadAuthor else {
      return .apply(requestedMode)
    }
    guard
      let confirmation = ThreadImmersiveReadingConfirmation(
        threadID: threadID,
        options: options
      )
    else { return .ignore }
    return .confirmImmersive(confirmation)
  }

  static func normalized(
    _ mode: ThreadReadingMode,
    options: ThreadBrowseOptions
  ) -> ThreadReadingMode {
    mode == .immersive && !options.onlyThreadAuthor ? .pure : mode
  }
}
