import SwiftUI

struct ThreadImageGalleryRoute: Identifiable {
  let id: UUID
  let viewModel: ThreadImageGalleryViewModel

  init(id: UUID = UUID(), viewModel: ThreadImageGalleryViewModel) {
    self.id = id
    self.viewModel = viewModel
  }
}

struct UnavailableThreadPictureGalleryService: ThreadPictureGalleryService {
  func picturePage(for request: ThreadPicturePageRequest) async throws -> ThreadPicturePage {
    throw BrowseError.unavailable("当前浏览服务不支持整帖图片浏览。")
  }
}

struct ThreadImageGalleryView: View {
  @ObservedObject var viewModel: ThreadImageGalleryViewModel

  var body: some View {
    ImageViewer(
      items: galleryItems,
      selection: selection,
      displayIndex: viewModel.selectedDisplayIndex,
      totalCount: viewModel.totalCount,
      onLoadIfNeeded: viewModel.loadIfNeeded
    )
    .overlay(alignment: .bottom) {
      loadStatus
        .padding(.horizontal, 18)
        .padding(.bottom, 62)
    }
    .onDisappear {
      viewModel.cancel()
    }
  }

  private var galleryItems: [ImageGalleryItem] {
    viewModel.occurrences.map { occurrence in
      let contentOffset: Int
      switch occurrence.id {
      case .local(_, let offset):
        contentOffset = offset
      case .remote(let overallIndex, _, _):
        contentOffset = overallIndex
      }
      return ImageGalleryItem(
        id: galleryID(occurrence.id),
        contentOffset: contentOffset,
        url: occurrence.url,
        width: occurrence.width,
        height: occurrence.height
      )
    }
  }

  private var selection: Binding<ImageGalleryItem.ID?> {
    Binding(
      get: { viewModel.selectedID.map(galleryID) },
      set: { newValue in
        viewModel.select(newValue.flatMap(occurrenceID))
      }
    )
  }

  @ViewBuilder
  private var loadStatus: some View {
    if let message = viewModel.bootstrapError {
      retryStatus(message: message, accessibilityLabel: "重试扩展整帖图片") {
        viewModel.retryBootstrap()
      }
    } else if viewModel.previousError != nil, viewModel.nextError != nil {
      HStack(spacing: 10) {
        Text("前后图片加载均失败")
          .font(.caption)
          .foregroundStyle(.white)

        retryButton(systemImage: "arrow.left", accessibilityLabel: "重试加载更早图片") {
          viewModel.retryPrevious()
        }
        retryButton(systemImage: "arrow.right", accessibilityLabel: "重试加载后续图片") {
          viewModel.retryNext()
        }
      }
      .padding(.leading, 12)
      .padding(.trailing, 7)
      .padding(.vertical, 7)
      .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 6))
    } else if let message = viewModel.previousError {
      retryStatus(message: message, accessibilityLabel: "重试加载更早图片") {
        viewModel.retryPrevious()
      }
    } else if let message = viewModel.nextError {
      retryStatus(message: message, accessibilityLabel: "重试加载后续图片") {
        viewModel.retryNext()
      }
    } else if
      viewModel.isBootstrapping || viewModel.isLoadingPrevious || viewModel.isLoadingNext
    {
      ProgressView()
        .tint(.white)
        .padding(9)
        .background(.black.opacity(0.72), in: Circle())
        .accessibilityLabel("正在加载整帖图片")
    }
  }

  private func retryStatus(
    message: String,
    accessibilityLabel: String,
    retry: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 10) {
      Text(message)
        .font(.caption)
        .foregroundStyle(.white)
        .lineLimit(2)
        .frame(maxWidth: 320, alignment: .leading)

      Button(action: retry) {
        Image(systemName: "arrow.clockwise")
          .frame(width: 30, height: 30)
      }
      .foregroundStyle(.white)
      .background(.white.opacity(0.14), in: Circle())
      .accessibilityLabel(accessibilityLabel)
    }
    .padding(.leading, 12)
    .padding(.trailing, 7)
    .padding(.vertical, 7)
    .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 6))
  }

  private func retryButton(
    systemImage: String,
    accessibilityLabel: String,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .frame(width: 30, height: 30)
    }
    .foregroundStyle(.white)
    .background(.white.opacity(0.14), in: Circle())
    .accessibilityLabel(accessibilityLabel)
  }

  private func galleryID(_ id: ThreadPictureOccurrenceID) -> ImageGalleryItem.ID {
    switch id {
    case .local(let postID, let contentOffset):
      .local(postID: postID, contentOffset: contentOffset)
    case .remote(let overallIndex, let pictureID, let postID):
      .remote(overallIndex: overallIndex, pictureID: pictureID, postID: postID)
    }
  }

  private func occurrenceID(_ id: ImageGalleryItem.ID) -> ThreadPictureOccurrenceID? {
    switch id {
    case .local(let postID, let contentOffset):
      guard let postID else { return nil }
      return .local(postID: postID, contentOffset: contentOffset)
    case .remote(let overallIndex, let pictureID, let postID):
      return .remote(overallIndex: overallIndex, pictureID: pictureID, postID: postID)
    }
  }
}
