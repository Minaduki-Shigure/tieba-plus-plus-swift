import SwiftUI

enum ContentRemoteImagePhase {
  case empty
  case success(DownsampledImageAsset, pixelSize: CGSize)
  case loadRequired
  case failure
}

private struct ContentMediaLoadPolicyEnvironmentKey: EnvironmentKey {
  static let defaultValue = ContentMediaLoadPolicy.automatic
}

extension EnvironmentValues {
  var contentMediaLoadPolicy: ContentMediaLoadPolicy {
    get { self[ContentMediaLoadPolicyEnvironmentKey.self] }
    set { self[ContentMediaLoadPolicyEnvironmentKey.self] = newValue }
  }
}

struct ContentRemoteImageRequestIdentity: Hashable, Sendable {
  let url: URL?
  let maxPixelSize: Int
}

struct ContentRemoteImageAuthorizedAttempt: Equatable, Sendable {
  let request: ContentRemoteImageRequestIdentity
  let generation: Int
}

struct ContentRemoteImageLoadState: Equatable, Sendable {
  private(set) var authorizedAttempt: ContentRemoteImageAuthorizedAttempt?
  private(set) var failedRequest: ContentRemoteImageRequestIdentity?
  private(set) var lastObservedPolicy: ContentMediaLoadPolicy?
  private(set) var reloadAttempt = 0

  var authorizedRequest: ContentRemoteImageRequestIdentity? {
    authorizedAttempt?.request
  }

  mutating func synchronizePolicy(_ policy: ContentMediaLoadPolicy) {
    guard lastObservedPolicy != policy else { return }
    authorizedAttempt = nil
    failedRequest = nil
    lastObservedPolicy = policy
  }

  mutating func requestChanged() {
    authorizedAttempt = nil
    failedRequest = nil
  }

  mutating func authorize(
    request: ContentRemoteImageRequestIdentity,
    policy: ContentMediaLoadPolicy,
    behavior: ContentMediaLoadBehavior
  ) {
    guard ContentRemoteImageLoadDecision.permitsManualAction(
      behavior: behavior,
      request: request
    ) else { return }
    lastObservedPolicy = policy
    failedRequest = nil
    reloadAttempt &+= 1
    authorizedAttempt = ContentRemoteImageAuthorizedAttempt(
      request: request,
      generation: reloadAttempt
    )
  }

  mutating func attemptCompleted(
    _ outcome: DownsampledRemoteImageAttemptOutcome,
    attempt: ContentRemoteImageAuthorizedAttempt?
  ) {
    guard let attempt, attempt == authorizedAttempt else { return }
    switch outcome {
    case .success:
      authorizedAttempt = nil
      failedRequest = nil
    case .failure, .cancelled:
      authorizedAttempt = nil
      failedRequest = attempt.request
    }
  }
}

enum ContentRemoteImageLoadDecision {
  enum StoredFailurePresentation: Equatable, Sendable {
    case loading
    case loadRequired
    case retry
    case failure
  }

  static func fetchPolicy(
    policy: ContentMediaLoadPolicy,
    behavior: ContentMediaLoadBehavior,
    lastObservedPolicy: ContentMediaLoadPolicy?,
    request: ContentRemoteImageRequestIdentity,
    authorizedRequest: ContentRemoteImageRequestIdentity?
  ) -> DownsampledImageFetchPolicy {
    if lastObservedPolicy == policy, authorizedRequest == request {
      return .allowNetwork(.preview)
    }

    switch behavior {
    case .automatic:
      return .allowNetwork(.preview)
    case .economicalNetworkOnly:
      return .allowEconomicalNetwork(.preview)
    case .userInitiated:
      return .cacheOnly(.preview)
    }
  }

  static func permitsManualAction(
    behavior: ContentMediaLoadBehavior,
    request: ContentRemoteImageRequestIdentity
  ) -> Bool {
    behavior == .userInitiated
      && request.url.map(RemoteImageURLPolicy.allows) == true
  }

  static func reloadID(
    attempt: Int,
    behavior: ContentMediaLoadBehavior,
    hasCurrentAuthorization: Bool
  ) -> Int {
    let variant: Int
    if hasCurrentAuthorization {
      variant = 3
    } else {
      switch behavior {
      case .automatic:
        variant = 0
      case .economicalNetworkOnly:
        variant = 1
      case .userInitiated:
        variant = 2
      }
    }
    return (attempt &* 4) &+ variant
  }

  static func storedFailurePresentation(
    policy: ContentMediaLoadPolicy,
    behavior: ContentMediaLoadBehavior,
    request: ContentRemoteImageRequestIdentity,
    state: ContentRemoteImageLoadState
  ) -> StoredFailurePresentation {
    guard permitsManualAction(behavior: behavior, request: request) else {
      return .failure
    }
    if state.failedRequest == request {
      return .retry
    }
    if state.lastObservedPolicy == policy, state.authorizedRequest == request {
      return .loading
    }
    return .loadRequired
  }
}

struct ContentRemoteImage<Content: View>: View {
  @Environment(\.contentMediaLoadPolicy) private var policy
  @Environment(\.contentMediaLoadBehavior) private var behavior

  let url: URL?
  let maxPixelSize: Int
  let loadAccessibilityLabel: String
  @ViewBuilder let content: (ContentRemoteImagePhase) -> Content

  @State private var loadState = ContentRemoteImageLoadState()

  init(
    url: URL?,
    maxPixelSize: Int,
    loadAccessibilityLabel: String,
    @ViewBuilder content: @escaping (ContentRemoteImagePhase) -> Content
  ) {
    self.url = url
    self.maxPixelSize = maxPixelSize
    self.loadAccessibilityLabel = loadAccessibilityLabel
    self.content = content
  }

  private var request: ContentRemoteImageRequestIdentity {
    ContentRemoteImageRequestIdentity(url: url, maxPixelSize: maxPixelSize)
  }

  private var fetchPolicy: DownsampledImageFetchPolicy {
    ContentRemoteImageLoadDecision.fetchPolicy(
      policy: policy,
      behavior: behavior,
      lastObservedPolicy: loadState.lastObservedPolicy,
      request: request,
      authorizedRequest: loadState.authorizedRequest
    )
  }

  private var effectiveReloadID: Int {
    ContentRemoteImageLoadDecision.reloadID(
      attempt: loadState.reloadAttempt,
      behavior: behavior,
      hasCurrentAuthorization: loadState.lastObservedPolicy == policy
        && loadState.authorizedRequest == request
    )
  }

  private var effectiveAccessibilityLabel: String {
    let label = loadAccessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    return label.isEmpty ? "加载图片" : label
  }

  var body: some View {
    let activeAttempt = loadState.authorizedAttempt
    DownsampledRemoteImage(
      url: url,
      maxPixelSize: maxPixelSize,
      fetchPolicy: fetchPolicy,
      reloadID: effectiveReloadID,
      onAttemptCompletion: { outcome in
        loadState.attemptCompleted(outcome, attempt: activeAttempt)
      }
    ) { phase in
      let contentPhase = mappedPhase(phase)
      if presentsManualAction(for: contentPhase) {
        Button(action: authorizeAndReload) {
          content(contentPhase)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(manualActionAccessibilityLabel(for: contentPhase))
      } else {
        content(contentPhase)
      }
    }
    .onAppear {
      loadState.synchronizePolicy(policy)
    }
    .onChange(of: policy) { updatedPolicy in
      loadState.synchronizePolicy(updatedPolicy)
    }
    .onChange(of: request) { _ in
      loadState.requestChanged()
    }
  }

  private func mappedPhase(_ phase: DownsampledRemoteImagePhase) -> ContentRemoteImagePhase {
    switch phase {
    case .empty:
      if ContentRemoteImageLoadDecision.storedFailurePresentation(
        policy: policy,
        behavior: behavior,
        request: request,
        state: loadState
      ) == .retry {
        return .failure
      }
      return .empty
    case .success(let asset, let pixelSize):
      return .success(asset, pixelSize: pixelSize)
    case .failure:
      switch ContentRemoteImageLoadDecision.storedFailurePresentation(
        policy: policy,
        behavior: behavior,
        request: request,
        state: loadState
      ) {
      case .loading:
        return .empty
      case .loadRequired:
        return .loadRequired
      case .retry, .failure:
        return .failure
      }
    }
  }

  private func presentsManualAction(for phase: ContentRemoteImagePhase) -> Bool {
    guard
      ContentRemoteImageLoadDecision.permitsManualAction(
        behavior: behavior,
        request: request
      )
    else { return false }
    switch phase {
    case .loadRequired, .failure:
      return true
    case .empty, .success:
      return false
    }
  }

  private func manualActionAccessibilityLabel(
    for phase: ContentRemoteImagePhase
  ) -> String {
    if case .failure = phase {
      return "重试：\(effectiveAccessibilityLabel)"
    }
    return effectiveAccessibilityLabel
  }

  private func authorizeAndReload() {
    guard
      ContentRemoteImageLoadDecision.permitsManualAction(
        behavior: behavior,
        request: request
      )
    else { return }
    loadState.authorize(request: request, policy: policy, behavior: behavior)
  }
}
