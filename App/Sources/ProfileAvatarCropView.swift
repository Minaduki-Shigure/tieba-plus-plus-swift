import SwiftUI
import UIKit

@MainActor
struct ProfileAvatarCropView: View {
  let source: ProfileAvatarCropSource

  private let processor: ProfileAvatarImageProcessor
  private let onCancel: @MainActor @Sendable () -> Void
  private let onPrepared: @MainActor @Sendable (AccountProfileAvatarUpload) -> Void

  @State private var committedState = ProfileAvatarCropState.initial
  @State private var preparationTask: Task<Void, Never>?
  @State private var preparationID: UUID?
  @State private var isPreparing = false
  @State private var errorMessage: String?
  @State private var previewImage: UIImage?
  @GestureState private var gestureDelta = ProfileAvatarCropGestureDelta()

  init(
    source: ProfileAvatarCropSource,
    processor: ProfileAvatarImageProcessor = .init(),
    onCancel: @escaping @MainActor @Sendable () -> Void,
    onPrepared: @escaping @MainActor @Sendable (AccountProfileAvatarUpload) -> Void
  ) {
    self.source = source
    self.processor = processor
    self.onCancel = onCancel
    self.onPrepared = onPrepared
    _previewImage = State(initialValue: UIImage(data: source.data, scale: 1))
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      VStack(spacing: 0) {
        toolbar

        GeometryReader { proxy in
          let availableSide = max(
            1,
            min(proxy.size.width - 24, proxy.size.height - 24)
          )
          let geometry = ProfileAvatarCropGeometry(
            sourcePixelSize: CGSize(
              width: CGFloat(source.pixelWidth),
              height: CGFloat(source.pixelHeight)
            ),
            viewportSide: availableSide
          )
          let displayedState = geometry.applying(
            magnification: gestureDelta.magnification,
            translation: gestureDelta.translation,
            to: committedState
          )

          VStack {
            Spacer(minLength: 0)
            cropCanvas(
              side: availableSide,
              geometry: geometry,
              displayedState: displayedState
            )
            Spacer(minLength: 0)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        zoomControls
      }
    }
    .preferredColorScheme(.dark)
    .interactiveDismissDisabled(isPreparing)
    .onDisappear(perform: cancelPreparation)
    .alert(
      "头像图片",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if !$0 { errorMessage = nil } }
      )
    ) {
      Button("好", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "无法生成头像图片。")
    }
  }

  private var toolbar: some View {
    HStack(spacing: 12) {
      Button(action: requestCancel) {
        Image(systemName: "xmark")
          .frame(width: 32, height: 32)
      }
      .accessibilityLabel("取消裁剪")
      .help("取消裁剪")

      Spacer(minLength: 8)

      Text("调整头像")
        .font(.headline)
        .lineLimit(1)

      Spacer(minLength: 8)

      Button(action: beginPreparation) {
        ZStack {
          Image(systemName: "checkmark")
            .opacity(isPreparing ? 0 : 1)
          if isPreparing {
            ProgressView()
              .controlSize(.small)
          }
        }
        .frame(width: 32, height: 32)
      }
      .disabled(isPreparing || previewImage == nil)
      .accessibilityLabel(isPreparing ? "正在生成头像" : "完成裁剪")
      .help("完成裁剪")
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 16)
    .frame(height: 52)
  }

  private func cropCanvas(
    side: CGFloat,
    geometry: ProfileAvatarCropGeometry,
    displayedState: ProfileAvatarCropState
  ) -> some View {
    let imageSize = geometry.displayedImageSize(for: displayedState)
    let imageOffset = geometry.displayedImageOffset(for: displayedState)

    return ZStack {
      Color(uiColor: .secondarySystemBackground)
      if let previewImage {
        Image(uiImage: previewImage)
          .resizable()
          .interpolation(.high)
          .frame(width: imageSize.width, height: imageSize.height)
          .offset(imageOffset)
      } else {
        Image(systemName: "photo.badge.exclamationmark")
          .font(.largeTitle)
          .foregroundStyle(.secondary)
          .accessibilityLabel("头像图片不可用")
      }
      ProfileAvatarCropGuide()
    }
    .frame(width: side, height: side)
    .clipShape(Rectangle())
    .contentShape(Rectangle())
    .gesture(cropGesture(geometry: geometry))
    .allowsHitTesting(!isPreparing && previewImage != nil)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("头像裁剪区域")
    .accessibilityValue("缩放 (Int((displayedState.zoom * 100).rounded()))%")
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment:
        committedState = geometry.settingZoom(committedState.zoom + 0.1, in: committedState)
      case .decrement:
        committedState = geometry.settingZoom(committedState.zoom - 0.1, in: committedState)
      @unknown default:
        break
      }
    }
  }

  private func cropGesture(geometry: ProfileAvatarCropGeometry) -> some Gesture {
    SimultaneousGesture(
      MagnificationGesture(minimumScaleDelta: 0.005),
      DragGesture(minimumDistance: 0, coordinateSpace: .local)
    )
    .updating($gestureDelta) { value, delta, _ in
      delta.magnification = value.first ?? 1
      delta.translation = value.second?.translation ?? .zero
    }
    .onEnded { value in
      committedState = geometry.applying(
        magnification: value.first ?? 1,
        translation: value.second?.translation ?? .zero,
        to: committedState
      )
    }
  }

  private var zoomControls: some View {
    HStack(spacing: 12) {
      Image(systemName: "minus.magnifyingglass")
        .accessibilityHidden(true)

      Slider(
        value: Binding(
          get: { Double(committedState.zoom) },
          set: {
            committedState = normalizedGeometry.settingZoom(
              CGFloat($0),
              in: committedState
            )
          }
        ),
        in: Double(ProfileAvatarCropGeometry.minimumZoom)...Double(
          ProfileAvatarCropGeometry.maximumZoom
        )
      )
      .disabled(isPreparing || previewImage == nil)
      .accessibilityLabel("头像缩放")

      Image(systemName: "plus.magnifyingglass")
        .accessibilityHidden(true)

      Button {
        withAnimation(.easeInOut(duration: 0.2)) {
          committedState = .initial
        }
      } label: {
        Image(systemName: "arrow.counterclockwise")
          .frame(width: 32, height: 32)
      }
      .disabled(isPreparing || committedState == .initial)
      .accessibilityLabel("重置裁剪")
      .help("重置裁剪")
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 20)
    .frame(height: 64)
  }

  private func beginPreparation() {
    guard preparationTask == nil, previewImage != nil else { return }
    let requestID = UUID()
    let source = source
    let state = committedState
    let processor = processor
    preparationID = requestID
    isPreparing = true
    errorMessage = nil

    preparationTask = Task { @MainActor in
      do {
        let upload = try await processor.makeUpload(source: source, state: state)
        try Task.checkCancellation()
        guard preparationID == requestID else { return }
        finishPreparation(id: requestID)
        onPrepared(upload)
      } catch is CancellationError {
        finishPreparation(id: requestID)
      } catch {
        guard preparationID == requestID else { return }
        finishPreparation(id: requestID)
        errorMessage = Self.presentationMessage(for: error)
      }
    }
  }

  private var normalizedGeometry: ProfileAvatarCropGeometry {
    ProfileAvatarCropGeometry(
      sourcePixelSize: CGSize(
        width: CGFloat(source.pixelWidth),
        height: CGFloat(source.pixelHeight)
      ),
      viewportSide: 1
    )
  }

  private func requestCancel() {
    cancelPreparation()
    onCancel()
  }

  private func cancelPreparation() {
    preparationID = nil
    isPreparing = false
    let task = preparationTask
    preparationTask = nil
    task?.cancel()
  }

  private func finishPreparation(id: UUID) {
    guard preparationID == id else { return }
    preparationID = nil
    isPreparing = false
    preparationTask = nil
  }

  private static func presentationMessage(for error: Error) -> String {
    guard
      let localizedError = error as? any LocalizedError,
      let description = localizedError.errorDescription,
      !description.isEmpty
    else { return "无法生成头像图片。" }
    return description
  }
}

private struct ProfileAvatarCropGestureDelta {
  var magnification: CGFloat = 1
  var translation: CGSize = .zero
}

private struct ProfileAvatarCropGuide: View {
  var body: some View {
    ZStack {
      Canvas { context, size in
        var mask = Path(CGRect(origin: .zero, size: size))
        mask.addEllipse(in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
        context.fill(
          mask,
          with: .color(.black.opacity(0.48)),
          style: FillStyle(eoFill: true)
        )
      }
      Circle()
        .stroke(.white.opacity(0.9), lineWidth: 1)
      Rectangle()
        .stroke(.white.opacity(0.32), lineWidth: 0.5)
    }
    .allowsHitTesting(false)
    .accessibilityHidden(true)
  }
}
