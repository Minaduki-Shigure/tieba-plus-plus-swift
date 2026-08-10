import SwiftUI
import UIKit

struct ImageGalleryItem: Identifiable, Equatable, Sendable {
  enum ID: Hashable, Sendable {
    case local(postID: Int64?, contentOffset: Int)
    case remote(overallIndex: Int, pictureID: String, postID: Int64)
  }

  let id: ID
  let contentOffset: Int
  let url: URL
  let width: Int
  let height: Int

  init(contentOffset: Int, url: URL, width: Int = 0, height: Int = 0) {
    id = .local(postID: nil, contentOffset: contentOffset)
    self.contentOffset = contentOffset
    self.url = url
    self.width = width
    self.height = height
  }

  init(
    id: ID,
    contentOffset: Int,
    url: URL,
    width: Int = 0,
    height: Int = 0
  ) {
    self.id = id
    self.contentOffset = contentOffset
    self.url = url
    self.width = width
    self.height = height
  }
}

struct ImageGalleryPresentation: Identifiable, Equatable, Sendable {
  let items: [ImageGalleryItem]
  let initialIndex: Int

  var id: ImageGalleryItem.ID { items[initialIndex].id }

  init?(contents: [BrowseContent], selectedContentOffset: Int) {
    let items: [ImageGalleryItem] = contents.enumerated().compactMap { pair -> ImageGalleryItem? in
      let (offset, content) = pair
      guard
        case .image(
          let thumbnail,
          let fullSize,
          let original,
          let dynamic,
          let width,
          let height
        ) = content
      else {
        return nil
      }
      return ImageGalleryItem(
        contentOffset: offset,
        url: BrowseContentImageSourceResolver.galleryURL(
          thumbnail: thumbnail,
          fullSize: fullSize,
          original: original,
          dynamic: dynamic
        ),
        width: width,
        height: height
      )
    }
    guard let initialIndex = items.firstIndex(where: {
      $0.contentOffset == selectedContentOffset
    }) else {
      return nil
    }

    self.items = items
    self.initialIndex = initialIndex
  }
}

enum ImageZoomGeometry {
  static func clampedScale(_ scale: CGFloat) -> CGFloat {
    guard !scale.isNaN else { return 1 }
    return min(max(scale, 1), 5)
  }

  static func allowsPanning(at scale: CGFloat) -> Bool {
    clampedScale(scale) > 1.001
  }

  static func clampedOffset(
    _ offset: CGSize,
    scale: CGFloat,
    viewportSize: CGSize,
    fittedImageSize: CGSize? = nil
  ) -> CGSize {
    let scale = clampedScale(scale)
    guard scale > 1 else { return .zero }
    guard let limits = panLimits(
      scale: scale,
      viewportSize: viewportSize,
      fittedImageSize: fittedImageSize
    ) else { return .zero }
    return CGSize(
      width: min(max(offset.width, -limits.horizontal), limits.horizontal),
      height: min(max(offset.height, -limits.vertical), limits.vertical)
    )
  }

  static func panLimits(
    scale: CGFloat,
    viewportSize: CGSize,
    fittedImageSize: CGSize? = nil
  ) -> ImageZoomPanLimits? {
    guard
      scale.isFinite,
      scale >= 1,
      scale <= 5,
      viewportSize.width.isFinite,
      viewportSize.height.isFinite,
      viewportSize.width > 0,
      viewportSize.height > 0
    else { return nil }

    let fittedImageSize = fittedImageSize ?? viewportSize
    guard
      fittedImageSize.width.isFinite,
      fittedImageSize.height.isFinite,
      fittedImageSize.width > 0,
      fittedImageSize.height > 0
    else { return nil }

    let scaledWidth = fittedImageSize.width * scale
    let scaledHeight = fittedImageSize.height * scale
    guard scaledWidth.isFinite, scaledHeight.isFinite else { return nil }
    return ImageZoomPanLimits(
      horizontal: max(0, scaledWidth - viewportSize.width) / 2,
      vertical: max(0, scaledHeight - viewportSize.height) / 2
    )
  }

  static func fittedImageSize(
    width: Int,
    height: Int,
    viewportSize: CGSize
  ) -> CGSize {
    let viewportWidth = max(0, viewportSize.width)
    let viewportHeight = max(0, viewportSize.height)
    guard width > 0, height > 0, viewportWidth > 0, viewportHeight > 0 else {
      return CGSize(width: viewportWidth, height: viewportHeight)
    }

    let imageAspectRatio = CGFloat(width) / CGFloat(height)
    let viewportAspectRatio = viewportWidth / viewportHeight
    if imageAspectRatio > viewportAspectRatio {
      return CGSize(width: viewportWidth, height: viewportWidth / imageAspectRatio)
    }
    return CGSize(width: viewportHeight * imageAspectRatio, height: viewportHeight)
  }
}

struct ImageZoomPanLimits: Equatable, Sendable {
  let horizontal: CGFloat
  let vertical: CGFloat
}

enum ImageZoomPanOwnership: Equatable, Sendable {
  case image
  case pager
}

enum ImageZoomPanOwnershipPolicy {
  static func resolve(
    limits: ImageZoomPanLimits?,
    offset: CGSize,
    velocity: CGSize,
    translation: CGSize,
    displayScale: CGFloat
  ) -> ImageZoomPanOwnership {
    guard
      let limits,
      isFinite(offset),
      isFinite(velocity),
      isFinite(translation),
      limits.horizontal.isFinite,
      limits.vertical.isFinite,
      limits.horizontal >= 0,
      limits.vertical >= 0,
      displayScale.isFinite,
      displayScale > 0
    else { return .image }

    let movement: CGSize
    if velocity.width != 0 || velocity.height != 0 {
      movement = velocity
    } else if translation.width != 0 || translation.height != 0 {
      movement = translation
    } else {
      return .image
    }

    // TiebaLite resolves equal movement to the vertical axis.
    let usesHorizontalAxis = abs(movement.width) > abs(movement.height)
    let limit = usesHorizontalAxis ? limits.horizontal : limits.vertical
    let primaryOffset = usesHorizontalAxis ? offset.width : offset.height
    let primaryMovement = usesHorizontalAxis ? movement.width : movement.height
    // zoomimage classifies scroll edges after Kotlin roundToInt pixel rounding.
    guard
      let lowerBound = kotlinRoundedPixel(-limit, displayScale: displayScale),
      let upperBound = kotlinRoundedPixel(limit, displayScale: displayScale),
      let roundedOffset = kotlinRoundedPixel(primaryOffset, displayScale: displayScale)
    else { return .image }
    guard lowerBound != upperBound else { return .pager }

    let movesPastPositiveEdge = primaryMovement > 0 && roundedOffset >= upperBound
    let movesPastNegativeEdge = primaryMovement < 0 && roundedOffset <= lowerBound
    return movesPastPositiveEdge || movesPastNegativeEdge ? .pager : .image
  }

  private static func isFinite(_ size: CGSize) -> Bool {
    size.width.isFinite && size.height.isFinite
  }

  private static func kotlinRoundedPixel(
    _ pointValue: CGFloat,
    displayScale: CGFloat
  ) -> Int? {
    let pixelValue = pointValue * displayScale
    guard pixelValue.isFinite else { return nil }
    let rounded = floor(pixelValue + 0.5)
    guard
      rounded.isFinite,
      rounded >= CGFloat(Int32.min),
      rounded <= CGFloat(Int32.max)
    else { return nil }
    return Int(rounded)
  }
}

@MainActor
struct ImageZoomPanGestureOverlay: UIViewRepresentable {
  let scale: CGFloat
  let offset: CGSize
  let viewportSize: CGSize
  let fittedImageSize: CGSize
  let displayScale: CGFloat
  let onChanged: (CGSize) -> Void
  let onEnded: (CGSize) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.backgroundColor = .clear
    view.isOpaque = false
    view.isAccessibilityElement = false
    view.accessibilityElementsHidden = true
    view.addGestureRecognizer(context.coordinator.panGestureRecognizer)
    context.coordinator.update(from: self)
    return view
  }

  func updateUIView(_ view: UIView, context: Context) {
    context.coordinator.update(from: self)
  }

  static func dismantleUIView(
    _ view: UIView,
    coordinator: Coordinator
  ) {
    view.removeGestureRecognizer(coordinator.panGestureRecognizer)
    coordinator.detach()
  }

  @MainActor
  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    private struct Configuration {
      let scale: CGFloat
      let offset: CGSize
      let viewportSize: CGSize
      let fittedImageSize: CGSize
      let displayScale: CGFloat
      let onChanged: (CGSize) -> Void
      let onEnded: (CGSize) -> Void
    }

    private var configuration: Configuration?
    private var lastImageTranslation = CGSize.zero

    lazy var panGestureRecognizer: UIPanGestureRecognizer = {
      let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
      recognizer.minimumNumberOfTouches = 1
      recognizer.maximumNumberOfTouches = 1
      recognizer.cancelsTouchesInView = false
      recognizer.delegate = self
      return recognizer
    }()

    func update(from overlay: ImageZoomPanGestureOverlay) {
      configuration = Configuration(
        scale: overlay.scale,
        offset: overlay.offset,
        viewportSize: overlay.viewportSize,
        fittedImageSize: overlay.fittedImageSize,
        displayScale: overlay.displayScale,
        onChanged: overlay.onChanged,
        onEnded: overlay.onEnded
      )
    }

    func detach() {
      configuration = nil
      lastImageTranslation = .zero
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard
        gestureRecognizer === panGestureRecognizer,
        let view = gestureRecognizer.view
      else { return true }
      let velocity = panGestureRecognizer.velocity(in: view)
      let translation = panGestureRecognizer.translation(in: view)
      return shouldImagePanBegin(
        velocity: CGSize(width: velocity.x, height: velocity.y),
        translation: CGSize(width: translation.x, height: translation.y)
      )
    }

    func shouldImagePanBegin(
      velocity: CGSize,
      translation: CGSize
    ) -> Bool {
      guard let configuration else { return true }
      guard
        configuration.scale.isFinite,
        configuration.scale >= 1,
        configuration.scale <= 5
      else { return true }
      guard ImageZoomGeometry.allowsPanning(at: configuration.scale) else { return false }
      return ImageZoomPanOwnershipPolicy.resolve(
        limits: ImageZoomGeometry.panLimits(
          scale: configuration.scale,
          viewportSize: configuration.viewportSize,
          fittedImageSize: configuration.fittedImageSize
        ),
        offset: configuration.offset,
        velocity: velocity,
        translation: translation,
        displayScale: configuration.displayScale
      ) == .image
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      guard gestureRecognizer === panGestureRecognizer else { return false }
      return !isEnclosingPagerPan(otherGestureRecognizer, from: gestureRecognizer.view)
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      guard gestureRecognizer === panGestureRecognizer else { return false }
      return isEnclosingPagerPan(otherGestureRecognizer, from: gestureRecognizer.view)
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
      guard let configuration, let view = recognizer.view else { return }
      let translation = recognizer.translation(in: view)
      let translationSize = CGSize(width: translation.x, height: translation.y)
      switch recognizer.state {
      case .began, .changed:
        lastImageTranslation = translationSize
        configuration.onChanged(translationSize)
      case .ended:
        configuration.onEnded(translationSize)
        lastImageTranslation = .zero
      case .cancelled:
        configuration.onEnded(lastImageTranslation)
        lastImageTranslation = .zero
      case .possible, .failed:
        break
      @unknown default:
        break
      }
    }

    private func isEnclosingPagerPan(
      _ gestureRecognizer: UIGestureRecognizer,
      from view: UIView?
    ) -> Bool {
      guard
        let view,
        let scrollView = gestureRecognizer.view as? UIScrollView,
        gestureRecognizer === scrollView.panGestureRecognizer,
        view.isDescendant(of: scrollView),
        let pageViewController = enclosingPageViewController(from: scrollView),
        pageViewController.view.subviews.contains(where: { $0 === scrollView })
      else { return false }
      return true
    }

    private func enclosingPageViewController(from view: UIView) -> UIPageViewController? {
      var responder: UIResponder? = view
      while let currentResponder = responder {
        if let pageViewController = currentResponder as? UIPageViewController {
          return pageViewController
        }
        responder = currentResponder.next
      }
      return nil
    }
  }
}

enum ImageViewerLoadingPresentation: Equatable, Sendable {
  case indeterminate
  case determinate(fraction: Double, percentage: Int)
  case decoding

  static func make(
    from progress: DownsampledRemoteImageLoadProgress?
  ) -> ImageViewerLoadingPresentation {
    guard let progress else { return .indeterminate }
    switch progress {
    case .decoding:
      return .decoding
    case .downloading(let downloadProgress):
      guard
        let fraction = downloadProgress.fractionCompleted,
        let percentage = downloadProgress.percentageCompleted
      else { return .indeterminate }
      return .determinate(fraction: fraction, percentage: percentage)
    }
  }
}

struct ImageViewer: View {
  @Environment(\.dismiss) private var dismiss

  let items: [ImageGalleryItem]

  private let externalSelection: Binding<ImageGalleryItem.ID?>?
  private let displayIndexOverride: Int?
  private let totalCountOverride: Int?
  private let onLoadIfNeeded: () -> Void
  private let idMigrations: [ImageGalleryItem.ID: ImageGalleryItem.ID]

  @State private var internalSelection: ImageGalleryItem.ID?
  @State private var pagingAxis = ImageGalleryPagingAxis.horizontal
  @State private var exportTask: Task<Void, Never>?
  @StateObject private var zoomStateStore: ImageGalleryZoomStateStore
  @StateObject private var exportViewModel: RemoteImageExportViewModel

  init(
    items: [ImageGalleryItem],
    initialIndex: Int,
    exporter: any RemoteImageExporting = RemoteImageExporter.shared
  ) {
    self.items = items
    let initialIndex = items.indices.contains(initialIndex) ? initialIndex : 0
    externalSelection = nil
    displayIndexOverride = nil
    totalCountOverride = nil
    onLoadIfNeeded = {}
    idMigrations = [:]
    _internalSelection = State(
      initialValue: items.indices.contains(initialIndex) ? items[initialIndex].id : nil
    )
    _zoomStateStore = StateObject(wrappedValue: ImageGalleryZoomStateStore())
    _exportViewModel = StateObject(
      wrappedValue: RemoteImageExportViewModel(exporter: exporter)
    )
  }

  init(
    items: [ImageGalleryItem],
    selection: Binding<ImageGalleryItem.ID?>,
    displayIndex: Int?,
    totalCount: Int?,
    onLoadIfNeeded: @escaping () -> Void,
    idMigrations: [ImageGalleryItem.ID: ImageGalleryItem.ID] = [:],
    exporter: any RemoteImageExporting = RemoteImageExporter.shared
  ) {
    self.items = items
    externalSelection = selection
    displayIndexOverride = displayIndex
    totalCountOverride = totalCount
    self.onLoadIfNeeded = onLoadIfNeeded
    self.idMigrations = idMigrations
    _internalSelection = State(initialValue: nil)
    _zoomStateStore = StateObject(wrappedValue: ImageGalleryZoomStateStore())
    _exportViewModel = StateObject(
      wrappedValue: RemoteImageExportViewModel(exporter: exporter)
    )
  }

  init(
    url: URL,
    exporter: any RemoteImageExporting = RemoteImageExporter.shared
  ) {
    self.init(
      items: [ImageGalleryItem(contentOffset: 0, url: url)],
      initialIndex: 0,
      exporter: exporter
    )
  }

  private var selectedURL: URL? {
    guard let selectedIndex else { return nil }
    return items[selectedIndex].url
  }

  private var selection: Binding<ImageGalleryItem.ID?> {
    externalSelection ?? $internalSelection
  }

  private var selectedIndex: Int? {
    guard let selectedID = selection.wrappedValue else { return nil }
    return items.firstIndex(where: { $0.id == selectedID })
  }

  private var displayedIndex: Int? {
    if let displayIndexOverride, displayIndexOverride > 0 {
      return displayIndexOverride
    }
    return selectedIndex.map { $0 + 1 }
  }

  private var displayedTotalCount: Int {
    max(totalCountOverride ?? items.count, items.count)
  }

  private var showsPagingControls: Bool {
    ImageViewerControlPolicy.showsPagingControls(
      itemCount: items.count,
      totalCount: totalCountOverride
    )
  }

  private var accessibilityPageDescriptions: [ImageGalleryItem.ID: String] {
    ImageGalleryAccessibilityPolicy.pageDescriptions(
      items: items,
      selectedID: selection.wrappedValue,
      selectedDisplayIndex: displayedIndex,
      totalCount: displayedTotalCount
    )
  }

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()

      if items.isEmpty {
        Image(systemName: "photo.badge.exclamationmark")
          .font(.largeTitle)
          .foregroundStyle(.white)
          .accessibilityLabel("没有可显示的图片")
      } else {
        ImageGalleryPager(
          items: items,
          selection: selection,
          axis: pagingAxis,
          zoomStateStore: zoomStateStore,
          idMigrations: idMigrations,
          accessibilityPageDescriptions: accessibilityPageDescriptions
        )
        .id(pagingAxis)
      }

      VStack {
        HStack(spacing: 14) {
          if let selectedURL {
            Button {
              startSharing(selectedURL)
            } label: {
              if exportViewModel.state == .preparingForSharing {
                ProgressView().tint(.white)
              } else {
                Image(systemName: "square.and.arrow.up")
              }
            }
            .accessibilityLabel("分享图片")
            .disabled(exportViewModel.isBusy || exportViewModel.shareItem != nil)

            Button {
              startSaving(selectedURL)
            } label: {
              if exportViewModel.state == .savingToPhotos {
                ProgressView().tint(.white)
              } else {
                Image(systemName: "square.and.arrow.down")
              }
            }
            .accessibilityLabel("保存图片")
            .disabled(exportViewModel.isBusy || exportViewModel.shareItem != nil)
          }

          if showsPagingControls {
            Button(action: togglePagingAxis) {
              Image(systemName: pagingAxis.toggled.systemImage)
            }
            .accessibilityLabel("切换为\(pagingAxis.toggled.title)")
            .accessibilityValue(pagingAxis.title)
            .help("切换为\(pagingAxis.toggled.title)")
          }

          Spacer()

          Button {
            dismiss()
          } label: {
            Image(systemName: "xmark")
          }
          .accessibilityLabel("关闭")
        }
        .font(.headline)
        .foregroundStyle(.white)
        .padding(.horizontal)
        .padding(.top, 8)

        Spacer()

        if showsPagingControls, let selectedIndex, let displayedIndex {
          HStack(spacing: 10) {
            Button {
              selectImage(at: selectedIndex - 1)
            } label: {
              Image(systemName: pagingAxis.previousSystemImage)
            }
            .disabled(selectedIndex == items.startIndex)
            .accessibilityLabel("上一张图片")

            Text("\(displayedIndex) / \(displayedTotalCount)")
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.white)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(.black.opacity(0.65), in: Capsule())
              .accessibilityLabel("图片")
              .accessibilityValue("第 \(displayedIndex) 张，共 \(displayedTotalCount) 张")
              .accessibilityAdjustableAction { direction in
                adjustSelection(direction)
              }

            Button {
              selectImage(at: selectedIndex + 1)
            } label: {
              Image(systemName: pagingAxis.nextSystemImage)
            }
            .disabled(selectedIndex == items.index(before: items.endIndex))
            .accessibilityLabel("下一张图片")
          }
          .padding(.bottom, 12)
        }
      }
      .tint(.white)
      .buttonStyle(ImageViewerControlButtonStyle())
    }
    .accessibilityAction(.escape) {
      dismiss()
    }
    .sheet(item: $exportViewModel.shareItem, onDismiss: finishDismissedShare) { item in
      RemoteImageActivitySheet(item: item) { completed, errorMessage in
        exportViewModel.finishSharing(
          completed: completed,
          errorMessage: errorMessage
        )
      }
    }
    .alert(exportAlertTitle, isPresented: presentsExportAlert) {
      Button("好") {
        exportViewModel.resetTransientState()
      }
    } message: {
      Text(exportAlertMessage)
    }
    .onDisappear {
      exportTask?.cancel()
      exportTask = nil
    }
    .onChange(of: selection.wrappedValue) { _ in
      onLoadIfNeeded()
    }
    .onChange(of: items.map(\.id)) { _ in
      normalizeSelection()
      onLoadIfNeeded()
    }
    .task {
      normalizeSelection()
      onLoadIfNeeded()
    }
  }

  private var presentsExportAlert: Binding<Bool> {
    Binding(
      get: {
        switch exportViewModel.state {
        case .savedToPhotos, .failed:
          true
        case .idle, .preparingForSharing, .readyToShare, .savingToPhotos, .shared:
          false
        }
      },
      set: { isPresented in
        if !isPresented {
          exportViewModel.resetTransientState()
        }
      }
    )
  }

  private var exportAlertTitle: String {
    if case .savedToPhotos = exportViewModel.state {
      return "已保存"
    }
    return "图片操作失败"
  }

  private var exportAlertMessage: String {
    if case .savedToPhotos = exportViewModel.state {
      return "图片已添加到系统照片。"
    }
    return exportViewModel.errorMessage ?? "无法完成图片操作。"
  }

  private func startSharing(_ url: URL) {
    exportTask?.cancel()
    exportTask = Task { @MainActor in
      await exportViewModel.prepareForSharing(from: url)
      exportTask = nil
    }
  }

  private func startSaving(_ url: URL) {
    exportTask?.cancel()
    exportTask = Task { @MainActor in
      await exportViewModel.saveToPhotos(from: url)
      exportTask = nil
    }
  }

  private func finishDismissedShare() {
    guard exportViewModel.state == .readyToShare else { return }
    exportViewModel.finishSharing(completed: false, errorMessage: nil)
  }

  private func adjustSelection(_ direction: AccessibilityAdjustmentDirection) {
    guard let selectedIndex else { return }
    switch direction {
    case .increment:
      selectImage(at: selectedIndex + 1)
    case .decrement:
      selectImage(at: selectedIndex - 1)
    @unknown default:
      break
    }
  }

  private func togglePagingAxis() {
    pagingAxis = pagingAxis.toggled
    UIAccessibility.post(
      notification: .announcement,
      argument: "已切换为\(pagingAxis.title)"
    )
  }

  private func selectImage(at index: Int) {
    guard items.indices.contains(index) else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      selection.wrappedValue = items[index].id
    }
  }

  private func normalizeSelection() {
    guard !items.isEmpty else {
      selection.wrappedValue = nil
      return
    }
    guard
      let selectedID = selection.wrappedValue,
      items.contains(where: { $0.id == selectedID })
    else {
      selection.wrappedValue = items[0].id
      return
    }
  }
}

struct ZoomableRemoteImage: View {
  let item: ImageGalleryItem
  let animationPlaybackEnabled: Bool
  let onZoomStateChange: (ImageGalleryItem.ID, ImageGalleryZoomState) -> Void

  @Environment(\.displayScale) private var displayScale
  @State private var scale: CGFloat
  @State private var committedScale: CGFloat
  @State private var offset: CGSize
  @State private var committedOffset: CGSize
  @State private var lastPublishedZoomState: ImageGalleryZoomState

  init(
    item: ImageGalleryItem,
    initialZoomState: ImageGalleryZoomState = .identity,
    animationPlaybackEnabled: Bool,
    onZoomStateChange: @escaping (
      ImageGalleryItem.ID,
      ImageGalleryZoomState
    ) -> Void = { _, _ in }
  ) {
    self.item = item
    self.animationPlaybackEnabled = animationPlaybackEnabled
    self.onZoomStateChange = onZoomStateChange
    _scale = State(initialValue: initialZoomState.scale)
    _committedScale = State(initialValue: initialZoomState.scale)
    _offset = State(initialValue: initialZoomState.offset)
    _committedOffset = State(initialValue: initialZoomState.offset)
    _lastPublishedZoomState = State(initialValue: initialZoomState)
  }

  var body: some View {
    GeometryReader { proxy in
      DownsampledRemoteImage(
        url: item.url,
        maxPixelSize: 4_096,
        fetchPolicy: .allowNetwork(.original)
      ) { phase, progress in
        switch phase {
        case .success(let asset, let pixelSize):
          RemoteImageAssetView(
            asset: asset,
            contentMode: .fit,
            animationPlaybackEnabled: animationPlaybackEnabled
          )
            .scaleEffect(scale)
            .offset(offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
              ImageZoomPanGestureOverlay(
                scale: scale,
                offset: offset,
                viewportSize: proxy.size,
                fittedImageSize: fittedImageSize(
                  in: proxy.size,
                  imagePixelSize: pixelSize
                ),
                displayScale: displayScale,
                onChanged: { translation in
                  updatePan(
                    translation: translation,
                    viewportSize: proxy.size,
                    imagePixelSize: pixelSize
                  )
                },
                onEnded: { translation in
                  endPan(
                    translation: translation,
                    viewportSize: proxy.size,
                    imagePixelSize: pixelSize
                  )
                }
              )
              .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .simultaneousGesture(
              magnificationGesture(viewportSize: proxy.size, imagePixelSize: pixelSize)
            )
            .onTapGesture(count: 2) {
              toggleZoom(viewportSize: proxy.size, imagePixelSize: pixelSize)
            }
            .accessibilityAction(
              named: Text(
                ImageZoomGeometry.allowsPanning(at: scale) ? "重置缩放" : "放大图片"
              )
            ) {
              toggleZoom(viewportSize: proxy.size, imagePixelSize: pixelSize)
            }
            .onAppear {
              clampZoomOffset(
                viewportSize: proxy.size,
                imagePixelSize: pixelSize
              )
            }
            .onChange(of: proxy.size) { viewportSize in
              clampZoomOffset(
                viewportSize: viewportSize,
                imagePixelSize: pixelSize
              )
            }
            .accessibilityLabel("大图")
        case .failure:
          Image(systemName: "photo.badge.exclamationmark")
            .font(.largeTitle)
            .foregroundStyle(.white)
            .accessibilityLabel("图片加载失败")
        default:
          ImageViewerLoadingIndicator(
            presentation: ImageViewerLoadingPresentation.make(from: progress)
          )
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear {
      publishZoomState(force: true)
    }
  }

  private func magnificationGesture(
    viewportSize: CGSize,
    imagePixelSize: CGSize
  ) -> some Gesture {
    MagnificationGesture()
      .onChanged { value in
        scale = ImageZoomGeometry.clampedScale(committedScale * value)
        offset = ImageZoomGeometry.clampedOffset(
          committedOffset,
          scale: scale,
          viewportSize: viewportSize,
          fittedImageSize: fittedImageSize(
            in: viewportSize,
            imagePixelSize: imagePixelSize
          )
        )
        publishZoomState()
      }
      .onEnded { _ in
        committedScale = scale
        committedOffset = offset
        publishZoomState()
      }
  }

  private func updatePan(
    translation: CGSize,
    viewportSize: CGSize,
    imagePixelSize: CGSize
  ) {
    offset = resolvedPanOffset(
      translation: translation,
      viewportSize: viewportSize,
      imagePixelSize: imagePixelSize
    )
    publishZoomState()
  }

  private func endPan(
    translation: CGSize,
    viewportSize: CGSize,
    imagePixelSize: CGSize
  ) {
    offset = resolvedPanOffset(
      translation: translation,
      viewportSize: viewportSize,
      imagePixelSize: imagePixelSize
    )
    committedOffset = offset
    publishZoomState()
  }

  private func resolvedPanOffset(
    translation: CGSize,
    viewportSize: CGSize,
    imagePixelSize: CGSize
  ) -> CGSize {
    ImageZoomGeometry.clampedOffset(
      CGSize(
        width: committedOffset.width + translation.width,
        height: committedOffset.height + translation.height
      ),
      scale: scale,
      viewportSize: viewportSize,
      fittedImageSize: fittedImageSize(
        in: viewportSize,
        imagePixelSize: imagePixelSize
      )
    )
  }

  private func toggleZoom(viewportSize: CGSize, imagePixelSize: CGSize) {
    withAnimation(.easeInOut(duration: 0.2)) {
      scale = ImageZoomGeometry.allowsPanning(at: scale) ? 1 : 2
      offset = ImageZoomGeometry.clampedOffset(
        .zero,
        scale: scale,
        viewportSize: viewportSize,
        fittedImageSize: fittedImageSize(
          in: viewportSize,
          imagePixelSize: imagePixelSize
        )
      )
      committedScale = scale
      committedOffset = offset
      publishZoomState()
    }
  }

  private func clampZoomOffset(viewportSize: CGSize, imagePixelSize: CGSize) {
    offset = ImageZoomGeometry.clampedOffset(
      offset,
      scale: scale,
      viewportSize: viewportSize,
      fittedImageSize: fittedImageSize(
        in: viewportSize,
        imagePixelSize: imagePixelSize
      )
    )
    committedOffset = offset
    publishZoomState()
  }

  private func publishZoomState(force: Bool = false) {
    let state = ImageGalleryZoomState(scale: scale, offset: offset)
    guard force || state != lastPublishedZoomState else { return }
    lastPublishedZoomState = state
    onZoomStateChange(item.id, state)
  }

  private func fittedImageSize(
    in viewportSize: CGSize,
    imagePixelSize: CGSize
  ) -> CGSize {
    ImageZoomGeometry.fittedImageSize(
      width: imagePixelSize.width > 0 ? Int(imagePixelSize.width) : item.width,
      height: imagePixelSize.height > 0 ? Int(imagePixelSize.height) : item.height,
      viewportSize: viewportSize
    )
  }
}

private struct ImageViewerLoadingIndicator: View {
  let presentation: ImageViewerLoadingPresentation

  var body: some View {
    Group {
      switch presentation {
      case .indeterminate:
        ProgressView()
          .accessibilityLabel("正在加载图片")
      case .decoding:
        VStack(spacing: 8) {
          ProgressView()
          Text("正在处理")
            .font(.caption)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在处理图片")
      case .determinate(let fraction, let percentage):
        VStack(spacing: 8) {
          ProgressView(value: fraction)
            .frame(width: 144)
          Text("\(percentage)%")
            .font(.subheadline.monospacedDigit())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在加载图片")
        .accessibilityValue("\(percentage)%")
      }
    }
    .tint(.white)
    .foregroundStyle(.white)
    .frame(width: 176, height: 72)
  }
}

private struct ImageViewerControlButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: 44, height: 44)
      .background(.black.opacity(0.65), in: Circle())
      .opacity(isEnabled ? (configuration.isPressed ? 0.65 : 1) : 0.45)
  }
}
