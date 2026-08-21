import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import TiebaCore
import UniformTypeIdentifiers

enum ComposerImagePickerPolicy {
  static let thumbnailSideLength: CGFloat = 76
  static let maximumAttachmentCount = ComposerImageDraftPolicy.maximumAttachmentCount
  static let qualityOptions: [ComposerImageAttachmentQuality] = [.standard, .highQuality]
  static let watermarkOptions: [TiebaStaticImageWatermark] = [
    .forumName,
    .username,
    .none,
  ]

  static func remainingCapacity(existingCount: Int) -> Int {
    maximumAttachmentCount - min(max(existingCount, 0), maximumAttachmentCount)
  }

  static func acceptedSelectionCount(requestedCount: Int, existingCount: Int) -> Int {
    min(max(requestedCount, 0), remainingCapacity(existingCount: existingCount))
  }

  static func canMove<Item>(_ items: [Item], from sourceIndex: Int, by offset: Int) -> Bool {
    let destinationIndex = sourceIndex + offset
    return items.indices.contains(sourceIndex) && items.indices.contains(destinationIndex)
  }

  static func moving<Item>(_ items: [Item], from sourceIndex: Int, by offset: Int) -> [Item] {
    guard canMove(items, from: sourceIndex, by: offset) else { return items }
    var result = items
    let item = result.remove(at: sourceIndex)
    result.insert(item, at: sourceIndex + offset)
    return result
  }

  static func restoring<Item: Equatable>(
    _ item: Item,
    at index: Int,
    currentItems: [Item],
    expectedItems: [Item]
  ) -> [Item]? {
    guard
      currentItems == expectedItems,
      index >= expectedItems.startIndex,
      index <= expectedItems.endIndex
    else { return nil }
    var restoredItems = expectedItems
    restoredItems.insert(item, at: index)
    return restoredItems
  }

  static func label(for quality: ComposerImageAttachmentQuality) -> String {
    switch quality {
    case .standard:
      "标准"
    case .highQuality:
      "高清"
    }
  }

  static func label(for watermark: TiebaStaticImageWatermark) -> String {
    switch watermark {
    case .forumName:
      "吧名"
    case .username:
      "用户名"
    case .none:
      "无水印"
    }
  }
}

struct ComposerImageCleanupCandidates: Equatable {
  private var attachmentsByUserID: [Int64: [ComposerImageAttachment]] = [:]

  var userIDs: [Int64] { attachmentsByUserID.keys.sorted() }

  func attachments(for userID: Int64) -> [ComposerImageAttachment] {
    attachmentsByUserID[userID] ?? []
  }

  mutating func observe(_ attachment: ComposerImageAttachment, userID: Int64) {
    guard userID > 0 else { return }
    var attachments = attachmentsByUserID[userID] ?? []
    guard !attachments.contains(where: { $0.id == attachment.id }) else { return }
    attachments.append(attachment)
    attachmentsByUserID[userID] = attachments
  }

  mutating func markPersisted(
    _ persistedAttachments: [ComposerImageAttachment],
    userID: Int64
  ) {
    let persistedIDs = Set(persistedAttachments.map(\.id))
    guard !persistedIDs.isEmpty, var attachments = attachmentsByUserID[userID] else { return }
    attachments.removeAll { persistedIDs.contains($0.id) }
    if attachments.isEmpty {
      attachmentsByUserID.removeValue(forKey: userID)
    } else {
      attachmentsByUserID[userID] = attachments
    }
  }
}

enum ComposerImageImportDrainPolicy {
  static let pollIntervalNanoseconds: UInt64 = 25_000_000
  static let maximumPollCount = 80

  static func shouldContinueWaiting(
    isBusy: Bool,
    completedPollCount: Int
  ) -> Bool {
    isBusy && completedPollCount >= 0 && completedPollCount < maximumPollCount
  }
}

@MainActor
final class ComposerImageImportCancellationController {
  private var activeImportID: UUID?
  private var cancellation: (@MainActor () -> Void)?

  var hasActiveImport: Bool { activeImportID != nil }

  func register(
    id: UUID,
    cancellation: @escaping @MainActor () -> Void
  ) {
    cancel()
    activeImportID = id
    self.cancellation = cancellation
  }

  func finish(id: UUID) {
    guard activeImportID == id else { return }
    activeImportID = nil
    cancellation = nil
  }

  func cancel() {
    let cancellation = cancellation
    activeImportID = nil
    self.cancellation = nil
    cancellation?()
  }
}

enum ComposerImageRemovalCoordinator {
  @MainActor
  static func persistRemovalThenCleanCandidate(
    removedAttachment: ComposerImageAttachment,
    remainingAttachments: [ComposerImageAttachment],
    persist: @MainActor ([ComposerImageAttachment]) async throws -> Void,
    cleanCandidate: @MainActor ([ComposerImageAttachment]) async -> Void
  ) async throws {
    try await persist(remainingAttachments)
    await cleanCandidate([removedAttachment])
  }

  @MainActor
  static func cleanCandidatesBestEffort(
    _ attachments: [ComposerImageAttachment],
    cleanCandidates: @MainActor ([ComposerImageAttachment]) async -> Void
  ) async {
    guard !attachments.isEmpty else { return }
    await cleanCandidates(attachments)
  }
}

@MainActor
struct ComposerImagePickerView: View {
  @Binding private var attachments: [ComposerImageAttachment]
  @Binding private var quality: ComposerImageAttachmentQuality
  @Binding private var watermark: TiebaStaticImageWatermark
  @Binding private var importIsBusy: Bool
  @Binding private var errorMessage: String?

  private let attachmentStore: ComposerImageAttachmentStore
  private let importCancellationController: ComposerImageImportCancellationController
  private let isEnabled: Bool
  private let onAttachmentImported: @MainActor (ComposerImageAttachment) -> Void
  private let onAttachmentRemovalRequested:
    @MainActor (
      ComposerImageAttachment,
      [ComposerImageAttachment]
    ) async throws -> Void

  @State private var pickerSelection: [PhotosPickerItem] = []
  @State private var thumbnails: [UUID: ComposerImagePickerThumbnail] = [:]
  @State private var activeImportTask: Task<Void, Never>?
  @State private var activeImportID: UUID?
  @State private var activeRemovalID: UUID?
  @State private var isImporting = false
  @State private var isRemovingAttachment = false

  init(
    attachments: Binding<[ComposerImageAttachment]>,
    quality: Binding<ComposerImageAttachmentQuality>,
    watermark: Binding<TiebaStaticImageWatermark>,
    attachmentStore: ComposerImageAttachmentStore,
    importCancellationController: ComposerImageImportCancellationController,
    isEnabled: Bool = true,
    importIsBusy: Binding<Bool>,
    errorMessage: Binding<String?>,
    onAttachmentImported: @escaping @MainActor (ComposerImageAttachment) -> Void,
    onAttachmentRemovalRequested: @escaping @MainActor (
      ComposerImageAttachment,
      [ComposerImageAttachment]
    ) async throws -> Void
  ) {
    _attachments = attachments
    _quality = quality
    _watermark = watermark
    self.attachmentStore = attachmentStore
    self.importCancellationController = importCancellationController
    self.isEnabled = isEnabled
    _importIsBusy = importIsBusy
    _errorMessage = errorMessage
    self.onAttachmentImported = onAttachmentImported
    self.onAttachmentRemovalRequested = onAttachmentRemovalRequested
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      selectionBar

      if !attachments.isEmpty {
        thumbnailTray
      }

      optionControls
    }
    .task(
      id: ComposerImagePickerThumbnailRefreshID(
        attachmentIDs: attachments.map(\.id),
        importsAreRunning: isImporting
      )
    ) {
      await refreshMissingThumbnails()
    }
    .onChange(of: pickerSelection) { selection in
      beginImport(selection)
    }
    .onDisappear {
      importCancellationController.cancel()
    }
  }

  private var remainingCapacity: Int {
    ComposerImagePickerPolicy.remainingCapacity(existingCount: attachments.count)
  }

  private var controlsAreDisabled: Bool {
    !isEnabled || isImporting || isRemovingAttachment || importIsBusy
  }

  private var selectionBar: some View {
    HStack(spacing: 10) {
      PhotosPicker(
        selection: $pickerSelection,
        maxSelectionCount: max(remainingCapacity, 1),
        selectionBehavior: .ordered,
        matching: .images,
        preferredItemEncoding: .current
      ) {
        Label("添加图片", systemImage: "photo.on.rectangle.angled")
      }
      .buttonStyle(.bordered)
      .disabled(controlsAreDisabled || remainingCapacity == 0)
      .accessibilityLabel("添加图片，最多还可选择 \(remainingCapacity) 张")
      .help("添加图片")

      if isImporting {
        ProgressView()
          .controlSize(.small)
          .frame(width: 20, height: 20)
          .accessibilityLabel("正在处理图片")
      }

      Spacer(minLength: 0)

      Text("\(attachments.count)/\(ComposerImagePickerPolicy.maximumAttachmentCount)")
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityLabel(
          "已添加 \(attachments.count) 张图片，最多 \(ComposerImagePickerPolicy.maximumAttachmentCount) 张"
        )
    }
    .frame(minHeight: 34)
  }

  private var thumbnailTray: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      LazyHStack(alignment: .top, spacing: 12) {
        ForEach(Array(attachments.enumerated()), id: \.element.id) { index, attachment in
          thumbnailItem(attachment, at: index)
        }
      }
      .padding(.vertical, 1)
    }
    .frame(height: 108)
  }

  private func thumbnailItem(
    _ attachment: ComposerImageAttachment,
    at index: Int
  ) -> some View {
    VStack(spacing: 5) {
      Group {
        if let thumbnail = thumbnails[attachment.id] {
          Image(decorative: thumbnail.image, scale: 1)
            .resizable()
            .scaledToFill()
        } else {
          ZStack {
            Color(uiColor: .secondarySystemBackground)
            Image(systemName: "photo")
              .font(.title3)
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(
        width: ComposerImagePickerPolicy.thumbnailSideLength,
        height: ComposerImagePickerPolicy.thumbnailSideLength
      )
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
      }
      .overlay(alignment: .topLeading) {
        Text("\(index + 1)")
          .font(.caption2.bold().monospacedDigit())
          .foregroundStyle(.primary)
          .padding(4)
          .background(.regularMaterial, in: Circle())
          .padding(4)
      }
      .accessibilityLabel(thumbnailAccessibilityLabel(attachment, at: index))

      HStack(spacing: 2) {
        attachmentActionButton(
          systemImage: "arrow.left",
          accessibilityLabel: "将第 \(index + 1) 张图片前移",
          isDisabled: controlsAreDisabled
            || !ComposerImagePickerPolicy.canMove(attachments, from: index, by: -1)
        ) {
          moveAttachment(at: index, by: -1)
        }

        attachmentActionButton(
          systemImage: "arrow.right",
          accessibilityLabel: "将第 \(index + 1) 张图片后移",
          isDisabled: controlsAreDisabled
            || !ComposerImagePickerPolicy.canMove(attachments, from: index, by: 1)
        ) {
          moveAttachment(at: index, by: 1)
        }

        attachmentActionButton(
          systemImage: "trash",
          accessibilityLabel: "移除第 \(index + 1) 张图片",
          role: .destructive,
          isDisabled: controlsAreDisabled
        ) {
          removeAttachment(at: index)
        }
      }
      .frame(width: ComposerImagePickerPolicy.thumbnailSideLength, height: 26)
    }
    .frame(width: ComposerImagePickerPolicy.thumbnailSideLength)
  }

  private func attachmentActionButton(
    systemImage: String,
    accessibilityLabel: String,
    role: ButtonRole? = nil,
    isDisabled: Bool,
    action: @escaping @MainActor () -> Void
  ) -> some View {
    Button(role: role, action: action) {
      Image(systemName: systemImage)
        .font(.caption.weight(.semibold))
        .frame(width: 22, height: 22)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .accessibilityLabel(accessibilityLabel)
    .help(accessibilityLabel)
  }

  private var optionControls: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) {
        qualityControl
          .frame(maxWidth: 250)
        Spacer(minLength: 0)
        watermarkControl
      }

      VStack(alignment: .leading, spacing: 10) {
        qualityControl
        watermarkControl
      }
    }
    .disabled(controlsAreDisabled)
  }

  private var qualityControl: some View {
    HStack(spacing: 8) {
      Text("质量")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      Picker("图片质量", selection: $quality) {
        ForEach(ComposerImagePickerPolicy.qualityOptions, id: \.self) { option in
          Text(ComposerImagePickerPolicy.label(for: option))
            .tag(option)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityLabel("图片质量")
    }
  }

  private var watermarkControl: some View {
    Menu {
      Picker("图片水印", selection: $watermark) {
        ForEach(ComposerImagePickerPolicy.watermarkOptions, id: \.self) { option in
          Text(ComposerImagePickerPolicy.label(for: option))
            .tag(option)
        }
      }
    } label: {
      Label(
        "水印：\(ComposerImagePickerPolicy.label(for: watermark))",
        systemImage: "signature"
      )
    }
    .accessibilityLabel(
      "图片水印，当前为\(ComposerImagePickerPolicy.label(for: watermark))"
    )
    .help("设置图片水印")
  }

  private func beginImport(_ selection: [PhotosPickerItem]) {
    guard !selection.isEmpty else { return }
    pickerSelection = []
    guard !isImporting, !isRemovingAttachment, !importIsBusy, isEnabled else { return }

    let acceptedCount = ComposerImagePickerPolicy.acceptedSelectionCount(
      requestedCount: selection.count,
      existingCount: attachments.count
    )
    guard acceptedCount > 0 else { return }

    let acceptedSelection = Array(selection.prefix(acceptedCount))
    let selectedQuality = quality
    let importID = UUID()
    activeImportID = importID
    isImporting = true
    importIsBusy = true
    errorMessage = nil

    let task = Task {
      await importImages(
        acceptedSelection,
        quality: selectedQuality,
        importID: importID
      )
    }
    activeImportTask = task
    importCancellationController.register(id: importID) {
      task.cancel()
    }
  }

  private func importImages(
    _ selection: [PhotosPickerItem],
    quality selectedQuality: ComposerImageAttachmentQuality,
    importID: UUID
  ) async {
    var firstFailureMessage: String?
    var failureCount = 0

    for item in selection {
      if Task.isCancelled { break }
      guard remainingCapacity > 0 else { break }

      do {
        guard
          let importedFile = try await item.loadTransferable(
            type: ComposerImagePickerImportedFile.self
          )
        else { throw ComposerImagePickerError.unavailableTransfer }
        defer { importedFile.removeTemporaryCopy() }

        let attachment = try await attachmentStore.importImage(
          at: importedFile.fileURL,
          quality: selectedQuality
        )
        if Task.isCancelled {
          try? await attachmentStore.remove(attachment)
          throw CancellationError()
        }

        var updatedAttachments = attachments
        updatedAttachments.append(attachment)
        guard ComposerImageDraftPolicy.isValid(updatedAttachments) else {
          // This newly produced file was never referenced by draft metadata.
          try? await attachmentStore.remove(attachment)
          throw ComposerImagePickerError.duplicateOrConflictingImage
        }

        onAttachmentImported(attachment)
        attachments = updatedAttachments
      } catch is CancellationError {
        break
      } catch {
        if Task.isCancelled { break }
        failureCount += 1
        if firstFailureMessage == nil {
          firstFailureMessage = ComposerImagePickerError.presentationMessage(for: error)
        }
      }
    }

    if activeImportID == importID, let firstFailureMessage {
      errorMessage =
        failureCount > 1
        ? "\(firstFailureMessage)（共 \(failureCount) 张图片未能导入。）"
        : firstFailureMessage
    }
    finishImportIfCurrent(importID)
  }

  private func cancelImportIfCurrent(_ importID: UUID) {
    guard activeImportID == importID else { return }
    activeImportTask = nil
    activeImportID = nil
    isImporting = false
    importIsBusy = false
  }

  private func finishImportIfCurrent(_ importID: UUID) {
    importCancellationController.finish(id: importID)
    cancelImportIfCurrent(importID)
  }

  private func moveAttachment(at index: Int, by offset: Int) {
    attachments = ComposerImagePickerPolicy.moving(
      attachments,
      from: index,
      by: offset
    )
  }

  private func removeAttachment(at index: Int) {
    guard attachments.indices.contains(index), !controlsAreDisabled else { return }
    var updatedAttachments = attachments
    let removedAttachment = updatedAttachments.remove(at: index)
    attachments = updatedAttachments
    thumbnails.removeValue(forKey: removedAttachment.id)
    isRemovingAttachment = true
    importIsBusy = true
    errorMessage = nil

    let removalID = UUID()
    activeRemovalID = removalID
    let task = Task { @MainActor in
      defer {
        finishRemovalIfCurrent(removalID)
      }
      do {
        try await onAttachmentRemovalRequested(removedAttachment, updatedAttachments)
      } catch is CancellationError {
        guard activeRemovalID == removalID else { return }
        restoreRemovedAttachment(
          removedAttachment,
          at: index,
          ifCurrentAttachmentsMatch: updatedAttachments
        )
      } catch {
        guard activeRemovalID == removalID else { return }
        restoreRemovedAttachment(
          removedAttachment,
          at: index,
          ifCurrentAttachmentsMatch: updatedAttachments
        )
        errorMessage = ComposerImagePickerError.presentationMessage(for: error)
      }
    }
    importCancellationController.register(id: removalID) {
      task.cancel()
    }
  }

  private func cancelRemovalIfCurrent(_ removalID: UUID) {
    guard activeRemovalID == removalID else { return }
    activeRemovalID = nil
    isRemovingAttachment = false
    importIsBusy = false
  }

  private func finishRemovalIfCurrent(_ removalID: UUID) {
    importCancellationController.finish(id: removalID)
    cancelRemovalIfCurrent(removalID)
  }

  private func restoreRemovedAttachment(
    _ attachment: ComposerImageAttachment,
    at index: Int,
    ifCurrentAttachmentsMatch expectedAttachments: [ComposerImageAttachment]
  ) {
    guard
      let restoredAttachments = ComposerImagePickerPolicy.restoring(
        attachment,
        at: index,
        currentItems: attachments,
        expectedItems: expectedAttachments
      )
    else { return }
    attachments = restoredAttachments
  }

  private func refreshMissingThumbnails() async {
    guard !isImporting else { return }
    let retainedIDs = Set(attachments.map(\.id))
    thumbnails = thumbnails.filter { retainedIDs.contains($0.key) }

    for attachment in attachments where thumbnails[attachment.id] == nil {
      if Task.isCancelled { return }
      do {
        // Validation bounds this data to the attachment quality's 5/10 MB limit
        // before ImageIO sees it.
        let data = try await attachmentStore.validatedData(for: attachment)
        guard
          !Task.isCancelled,
          let thumbnail = await ComposerImagePickerThumbnailLoader.thumbnail(data: data),
          attachments.contains(where: { $0.id == attachment.id })
        else { continue }
        thumbnails[attachment.id] = thumbnail
      } catch is CancellationError {
        return
      } catch {
        if errorMessage == nil {
          errorMessage = "无法读取一张已保存图片的预览，请移除后重新选择。"
        }
      }
    }
  }

  private func thumbnailAccessibilityLabel(
    _ attachment: ComposerImageAttachment,
    at index: Int
  ) -> String {
    let qualityLabel = ComposerImagePickerPolicy.label(for: attachment.quality)
    return
      "第 \(index + 1) 张图片，\(attachment.pixelWidth) 乘 \(attachment.pixelHeight) 像素，\(qualityLabel)"
  }
}

private enum ComposerImagePickerError: Error, LocalizedError {
  case unavailableTransfer
  case duplicateOrConflictingImage

  var errorDescription: String? {
    switch self {
    case .unavailableTransfer:
      "无法从照片图库读取这张图片。"
    case .duplicateOrConflictingImage:
      "这张图片与草稿中的现有图片重复，未再次添加。"
    }
  }

  static func presentationMessage(for error: Error) -> String {
    guard
      let localizedError = error as? any LocalizedError,
      let description = localizedError.errorDescription,
      !description.isEmpty
    else { return "无法安全导入选择的图片。" }
    return description
  }
}

private struct ComposerImagePickerImportedFile: Transferable, Sendable {
  let fileURL: URL
  let temporaryDirectoryURL: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(
      importedContentType: .image,
      shouldAttemptToOpenInPlace: false
    ) { receivedFile in
      let fileManager = FileManager.default
      _ = ComposerImageTemporaryDirectoryCleaner(
        rootURL: fileManager.temporaryDirectory
      ).cleanup()
      let temporaryDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(
        "tieba-composer-image-\(UUID().uuidString.lowercased())",
        isDirectory: true
      )
      let fileURL = temporaryDirectoryURL.appendingPathComponent(
        "selected-image",
        isDirectory: false
      )
      do {
        try fileManager.createDirectory(
          at: temporaryDirectoryURL,
          withIntermediateDirectories: false
        )
        try fileManager.copyItem(at: receivedFile.file, to: fileURL)
        #if os(iOS)
          try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: fileURL.path
          )
        #endif
        return Self(
          fileURL: fileURL,
          temporaryDirectoryURL: temporaryDirectoryURL
        )
      } catch {
        try? fileManager.removeItem(at: temporaryDirectoryURL)
        throw error
      }
    }
  }

  func removeTemporaryCopy() {
    try? FileManager.default.removeItem(at: temporaryDirectoryURL)
  }
}

private struct ComposerImagePickerThumbnail: @unchecked Sendable {
  let image: CGImage
}

private struct ComposerImagePickerThumbnailRefreshID: Hashable {
  let attachmentIDs: [UUID]
  let importsAreRunning: Bool
}

private enum ComposerImagePickerThumbnailLoader {
  private static let maximumPixelSize = 152

  static func thumbnail(data: Data) async -> ComposerImagePickerThumbnail? {
    await Task.detached(priority: .utility) {
      guard !Task.isCancelled else { return nil }
      let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
      guard
        let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
        let image = makeThumbnail(from: source)
      else { return nil }
      return ComposerImagePickerThumbnail(image: image)
    }.value
  }

  private static func makeThumbnail(from source: CGImageSource) -> CGImage? {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}
