import SwiftUI

struct ImageGalleryItem: Identifiable, Equatable, Sendable {
  let contentOffset: Int
  let url: URL
  let width: Int
  let height: Int

  init(contentOffset: Int, url: URL, width: Int = 0, height: Int = 0) {
    self.contentOffset = contentOffset
    self.url = url
    self.width = width
    self.height = height
  }

  var id: Int { contentOffset }
}

struct ImageGalleryPresentation: Identifiable, Equatable, Sendable {
  let items: [ImageGalleryItem]
  let initialIndex: Int

  var id: Int { items[initialIndex].contentOffset }

  init?(contents: [BrowseContent], selectedContentOffset: Int) {
    let items: [ImageGalleryItem] = contents.enumerated().compactMap { pair -> ImageGalleryItem? in
      let (offset, content) = pair
      guard case .image(let thumbnail, let original, let width, let height) = content else {
        return nil
      }
      return ImageGalleryItem(
        contentOffset: offset,
        url: original ?? thumbnail,
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
    clampedScale(scale) > 1
  }

  static func clampedOffset(
    _ offset: CGSize,
    scale: CGFloat,
    viewportSize: CGSize,
    fittedImageSize: CGSize? = nil
  ) -> CGSize {
    let scale = clampedScale(scale)
    guard scale > 1 else { return .zero }

    let viewportWidth = max(0, viewportSize.width)
    let viewportHeight = max(0, viewportSize.height)
    let fittedImageSize = fittedImageSize ?? CGSize(
      width: viewportWidth,
      height: viewportHeight
    )
    let horizontalLimit = max(0, fittedImageSize.width * scale - viewportWidth) / 2
    let verticalLimit = max(0, fittedImageSize.height * scale - viewportHeight) / 2
    return CGSize(
      width: min(max(offset.width, -horizontalLimit), horizontalLimit),
      height: min(max(offset.height, -verticalLimit), verticalLimit)
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

  @State private var selectedIndex: Int
  @State private var exportTask: Task<Void, Never>?
  @StateObject private var exportViewModel: RemoteImageExportViewModel

  init(
    items: [ImageGalleryItem],
    initialIndex: Int,
    exporter: any RemoteImageExporting = RemoteImageExporter.shared
  ) {
    self.items = items
    let initialIndex = items.indices.contains(initialIndex) ? initialIndex : 0
    _selectedIndex = State(initialValue: initialIndex)
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
    guard items.indices.contains(selectedIndex) else { return nil }
    return items[selectedIndex].url
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
        TabView(selection: $selectedIndex) {
          ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            ZoomableRemoteImage(item: item)
              .tag(index)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
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

        if !items.isEmpty {
          HStack(spacing: 10) {
            Button {
              selectImage(at: selectedIndex - 1)
            } label: {
              Image(systemName: "chevron.left")
            }
            .disabled(selectedIndex == items.startIndex)
            .accessibilityLabel("上一张图片")

            Text("\(selectedIndex + 1) / \(items.count)")
              .font(.subheadline.monospacedDigit())
              .foregroundStyle(.white)
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(.black.opacity(0.65), in: Capsule())
              .accessibilityLabel("图片")
              .accessibilityValue("第 \(selectedIndex + 1) 张，共 \(items.count) 张")
              .accessibilityAdjustableAction { direction in
                adjustSelection(direction)
              }

            Button {
              selectImage(at: selectedIndex + 1)
            } label: {
              Image(systemName: "chevron.right")
            }
            .disabled(selectedIndex == items.index(before: items.endIndex))
            .accessibilityLabel("下一张图片")
          }
          .padding(.bottom, 12)
        }
      }
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
    switch direction {
    case .increment:
      selectImage(at: selectedIndex + 1)
    case .decrement:
      selectImage(at: selectedIndex - 1)
    @unknown default:
      break
    }
  }

  private func selectImage(at index: Int) {
    guard items.indices.contains(index) else { return }
    withAnimation(.easeInOut(duration: 0.2)) {
      selectedIndex = index
    }
  }
}

private struct ZoomableRemoteImage: View {
  let item: ImageGalleryItem

  @State private var scale: CGFloat = 1
  @State private var committedScale: CGFloat = 1
  @State private var offset = CGSize.zero
  @State private var committedOffset = CGSize.zero

  var body: some View {
    GeometryReader { proxy in
      DownsampledRemoteImage(
        url: item.url,
        maxPixelSize: 4_096,
        fetchPolicy: .allowNetwork(.original)
      ) { phase, progress in
        switch phase {
        case .success(let image, let pixelSize):
          image
            .resizable()
            .scaledToFit()
            .scaleEffect(scale)
            .offset(offset)
            .contentShape(Rectangle())
            .highPriorityGesture(
              panGesture(viewportSize: proxy.size, imagePixelSize: pixelSize),
              including: ImageZoomGeometry.allowsPanning(at: scale) ? .all : .subviews
            )
            .simultaneousGesture(
              magnificationGesture(viewportSize: proxy.size, imagePixelSize: pixelSize)
            )
            .onTapGesture(count: 2) {
              toggleZoom(viewportSize: proxy.size, imagePixelSize: pixelSize)
            }
            .onChange(of: proxy.size) { viewportSize in
              offset = ImageZoomGeometry.clampedOffset(
                offset,
                scale: scale,
                viewportSize: viewportSize,
                fittedImageSize: fittedImageSize(
                  in: viewportSize,
                  imagePixelSize: pixelSize
                )
              )
              committedOffset = offset
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
      }
      .onEnded { _ in
        committedScale = scale
        committedOffset = offset
      }
  }

  private func panGesture(
    viewportSize: CGSize,
    imagePixelSize: CGSize
  ) -> some Gesture {
    DragGesture()
      .onChanged { value in
        offset = ImageZoomGeometry.clampedOffset(
          CGSize(
            width: committedOffset.width + value.translation.width,
            height: committedOffset.height + value.translation.height
          ),
          scale: scale,
          viewportSize: viewportSize,
          fittedImageSize: fittedImageSize(
            in: viewportSize,
            imagePixelSize: imagePixelSize
          )
        )
      }
      .onEnded { _ in
        committedOffset = offset
      }
  }

  private func toggleZoom(viewportSize: CGSize, imagePixelSize: CGSize) {
    withAnimation(.easeInOut(duration: 0.2)) {
      scale = scale > 1 ? 1 : 2
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
    }
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
