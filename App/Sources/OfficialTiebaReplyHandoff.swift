import Foundation
import SwiftUI

struct OfficialTiebaReplyHandoff: Equatable, Sendable {
  enum Destination: Equatable, Sendable {
    case thread
    case parentPost(Int64)
  }

  let threadID: Int64
  let destination: Destination
  let isNestedReply: Bool
  let url: URL

  init?(target: TextReplyTarget) {
    guard target.threadID > 0 else { return nil }
    let destination: Destination
    let isNestedReply: Bool
    switch target.destination {
    case .thread(let firstPostID):
      guard firstPostID == target.firstPostID else { return nil }
      destination = .thread
      isNestedReply = false
    case .post(let postID):
      guard postID > 0 else { return nil }
      destination = .parentPost(postID)
      isNestedReply = false
    case .subpost(let parentPostID, _):
      guard parentPostID > 0 else { return nil }
      destination = .parentPost(parentPostID)
      isNestedReply = true
    }
    guard let url = Self.url(threadID: target.threadID, destination: destination) else {
      return nil
    }
    self.threadID = target.threadID
    self.destination = destination
    self.isNestedReply = isNestedReply
    self.url = url
  }

  private static func url(threadID: Int64, destination: Destination) -> URL? {
    guard threadID > 0 else { return nil }
    var components = URLComponents()
    components.scheme = "com.baidu.tieba"
    components.host = "unidispatch"
    components.path = "/pb"

    // Observed TiebaLite template; the opaque attribution fields are not an
    // authoritative iOS contract and remain a physical-device validation gate.
    var queryItems = [
      URLQueryItem(
        name: "obj_locate",
        value: destination == .thread ? "pb_reply" : "comment_lzl_cut_guide"
      ),
      URLQueryItem(name: "obj_source", value: "wise"),
      URLQueryItem(name: "obj_name", value: "index"),
      URLQueryItem(name: "obj_param2", value: "chrome"),
      URLQueryItem(name: "has_token", value: "0"),
      URLQueryItem(name: "qd", value: "scheme"),
      URLQueryItem(name: "refer", value: "tieba.baidu.com"),
      URLQueryItem(
        name: "wise_sample_id",
        value: destination == .thread ? "3000232_2-99999_9" : "3000232_2"
      ),
    ]
    if case .parentPost(let postID) = destination {
      guard postID > 0 else { return nil }
      queryItems.append(URLQueryItem(name: "hightlight_anchor_pid", value: String(postID)))
      queryItems.append(URLQueryItem(name: "is_anchor_to_comment", value: "1"))
      queryItems.append(URLQueryItem(name: "comment_sort_type", value: "0"))
    }
    queryItems.append(URLQueryItem(name: "fr", value: "bpush"))
    queryItems.append(URLQueryItem(name: "tid", value: String(threadID)))
    components.queryItems = queryItems
    return components.url
  }
}

struct OfficialTiebaReplyHandoffOpenRequest: Equatable, Sendable {
  let id: UUID
  let lifecycleID: UUID
  let handoff: OfficialTiebaReplyHandoff
}

enum OfficialTiebaReplyHandoffOpenOutcome: Equatable, Sendable {
  case accepted
  case unavailable
}

struct OfficialTiebaReplyHandoffOpenGate: Equatable, Sendable {
  private(set) var pendingRequest: OfficialTiebaReplyHandoffOpenRequest?

  var isOpening: Bool { pendingRequest != nil }

  mutating func begin(
    handoff: OfficialTiebaReplyHandoff,
    lifecycleID: UUID,
    id: UUID = UUID()
  ) -> OfficialTiebaReplyHandoffOpenRequest? {
    guard pendingRequest == nil else { return nil }
    let request = OfficialTiebaReplyHandoffOpenRequest(
      id: id,
      lifecycleID: lifecycleID,
      handoff: handoff
    )
    pendingRequest = request
    return request
  }

  mutating func complete(
    _ request: OfficialTiebaReplyHandoffOpenRequest,
    accepted: Bool
  ) -> OfficialTiebaReplyHandoffOpenOutcome? {
    guard pendingRequest == request else { return nil }
    pendingRequest = nil
    return accepted ? .accepted : .unavailable
  }

  mutating func cancel() {
    pendingRequest = nil
  }
}

@MainActor
enum OfficialTiebaReplyHandoffSystemDispatch {
  static func open(
    _ request: OfficialTiebaReplyHandoffOpenRequest,
    using openURL: OpenURLAction,
    completion: @escaping @MainActor (
      OfficialTiebaReplyHandoffOpenRequest,
      Bool
    ) -> Void
  ) {
    let coordinator = Coordinator(request: request, completion: completion)
    openURL(request.handoff.url) { accepted in
      Task { @MainActor in
        coordinator.finish(accepted: accepted)
      }
    }
  }

  @MainActor
  private final class Coordinator {
    private let request: OfficialTiebaReplyHandoffOpenRequest
    private let completion: @MainActor (
      OfficialTiebaReplyHandoffOpenRequest,
      Bool
    ) -> Void
    private var didFinish = false

    init(
      request: OfficialTiebaReplyHandoffOpenRequest,
      completion: @escaping @MainActor (
        OfficialTiebaReplyHandoffOpenRequest,
        Bool
      ) -> Void
    ) {
      self.request = request
      self.completion = completion
    }

    func finish(accepted: Bool) {
      guard !didFinish else { return }
      didFinish = true
      completion(request, accepted)
    }
  }
}

enum OfficialTiebaReplyHandoffCopy {
  static let actionTitle = "尝试使用官方客户端回帖"
  static let unavailableMessage = "未能打开贴吧官方客户端。请确认已安装，并且当前版本支持此回复入口。"

  static func disclosureMessage(for handoff: OfficialTiebaReplyHandoff) -> String {
    if handoff.isNestedReply {
      return "本地草稿不会传递，楼中楼也只能定位到父楼；请在接收应用中核对登录账号，并重新选择具体回复。"
    }
    return "本地草稿不会传递；交给系统打开后，请在接收应用中核对登录账号和回复位置。"
  }
}
