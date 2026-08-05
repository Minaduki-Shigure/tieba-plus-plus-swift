@preconcurrency import AVFoundation
import Combine
import Foundation
import SwiftUI
import UIKit

enum RemoteVoiceExportError: Error, Equatable, LocalizedError {
  case invalidAudio
  case unsupportedAudioType
  case cannotPrepareFile

  var errorDescription: String? {
    switch self {
    case .invalidAudio:
      "下载内容不是可识别的语音文件。"
    case .unsupportedAudioType:
      "该语音格式暂不支持导出。"
    case .cannotPrepareFile:
      "无法准备可分享的语音文件。"
    }
  }
}

enum RemoteVoiceFormat: Equatable, Sendable {
  case mp3
  case amr
  case amrWideband
  case aac

  var filenameExtension: String {
    switch self {
    case .mp3:
      "mp3"
    case .amr:
      "amr"
    case .amrWideband:
      "awb"
    case .aac:
      "aac"
    }
  }

  var canonicalMIMEType: String {
    switch self {
    case .mp3:
      "audio/mpeg"
    case .amr:
      "audio/amr"
    case .amrWideband:
      "audio/amr-wb"
    case .aac:
      "audio/aac"
    }
  }

  var inspectionFilenameExtension: String {
    // iOS 16 has no MIME override option and recognizes raw AMR through .amr.
    self == .amrWideband ? "amr" : filenameExtension
  }
}

struct RemoteVoiceValidationResult: Equatable, Sendable {
  let format: RemoteVoiceFormat
  let byteCount: Int64
  let duration: TimeInterval

  var filenameExtension: String { format.filenameExtension }
}

struct RemoteVoiceMediaInspection: Equatable, Sendable {
  let isPlayable: Bool
  let audioTrackCount: Int
  let videoTrackCount: Int
  let duration: TimeInterval
}

protocol RemoteVoiceMediaInspecting: Sendable {
  func inspect(fileURL: URL, format: RemoteVoiceFormat) async throws
    -> RemoteVoiceMediaInspection
}

struct AVFoundationRemoteVoiceMediaInspector: RemoteVoiceMediaInspecting, Sendable {
  func inspect(fileURL: URL, format: RemoteVoiceFormat) async throws
    -> RemoteVoiceMediaInspection
  {
    var options: [String: Any] = [
      AVURLAssetPreferPreciseDurationAndTimingKey: true,
      AVURLAssetReferenceRestrictionsKey: NSNumber(
        value: AVAssetReferenceRestrictions.forbidAll.rawValue
      ),
    ]
    if #available(iOS 17.0, *) {
      options[AVURLAssetOverrideMIMETypeKey] = format.canonicalMIMEType
    }
    let asset = AVURLAsset(
      url: fileURL,
      options: options
    )
    let loadedIsPlayable = try await asset.load(.isPlayable)
    let loadedAudioTracks = try await asset.loadTracks(withMediaType: .audio)
    let loadedVideoTracks = try await asset.loadTracks(withMediaType: .video)
    let loadedDuration = try await asset.load(.duration)
    return RemoteVoiceMediaInspection(
      isPlayable: loadedIsPlayable,
      audioTrackCount: loadedAudioTracks.count,
      videoTrackCount: loadedVideoTracks.count,
      duration: loadedDuration.seconds
    )
  }
}

enum RemoteVoiceFileValidator {
  static func validate(
    fileURL: URL,
    byteCount: Int64,
    mediaInspector: any RemoteVoiceMediaInspecting = AVFoundationRemoteVoiceMediaInspector()
  ) async throws -> RemoteVoiceValidationResult {
    try Task.checkCancellation()
    guard
      byteCount > 0,
      byteCount <= RemoteVoiceDownloadPolicy.maximumResponseBytes
    else { throw RemoteVoiceExportError.invalidAudio }

    let data: Data
    do {
      data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    } catch {
      throw RemoteVoiceExportError.invalidAudio
    }
    guard Int64(data.count) == byteCount else {
      throw RemoteVoiceExportError.invalidAudio
    }
    try Task.checkCancellation()

    guard let format = detectedFormat(in: data.prefix(64)) else {
      throw RemoteVoiceExportError.unsupportedAudioType
    }
    let structuredDuration = try validatedStructuredDuration(in: data, format: format)
    let inspectionFileURL = fileURL.deletingLastPathComponent()
      .appendingPathComponent("inspection-\(UUID().uuidString)", isDirectory: false)
      .appendingPathExtension(format.inspectionFilenameExtension)
    do {
      try FileManager.default.copyItem(at: fileURL, to: inspectionFileURL)
    } catch {
      throw RemoteVoiceExportError.invalidAudio
    }
    defer { try? FileManager.default.removeItem(at: inspectionFileURL) }
    let inspection: RemoteVoiceMediaInspection
    do {
      inspection = try await mediaInspector.inspect(fileURL: inspectionFileURL, format: format)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw RemoteVoiceExportError.invalidAudio
    }
    guard
      inspection.isPlayable,
      inspection.audioTrackCount > 0,
      inspection.videoTrackCount == 0,
      inspection.duration.isFinite,
      inspection.duration > 0,
      inspection.duration <= VoicePlaybackTime.maximumDuration
    else { throw RemoteVoiceExportError.invalidAudio }
    let duration = structuredDuration ?? inspection.duration
    guard
      duration.isFinite,
      duration > 0,
      duration <= VoicePlaybackTime.maximumDuration
    else { throw RemoteVoiceExportError.invalidAudio }
    return RemoteVoiceValidationResult(
      format: format,
      byteCount: byteCount,
      duration: duration
    )
  }

  static func detectedFormat(in header: Data) -> RemoteVoiceFormat? {
    let bytes = [UInt8](header.prefix(64))
    guard !bytes.isEmpty else { return nil }

    if bytes.count > 9, bytes.starts(with: Array("#!AMR-WB\n".utf8)) {
      return .amrWideband
    }
    if bytes.count > 6, bytes.starts(with: Array("#!AMR\n".utf8)) {
      return .amr
    }
    if isID3Header(bytes) || isMPEGFrameHeader(bytes) {
      return .mp3
    }
    if isADTSHeader(bytes) {
      return .aac
    }
    return nil
  }

  private static func isID3Header(_ bytes: [UInt8]) -> Bool {
    guard
      bytes.count >= 10,
      bytes[0...2].elementsEqual(Array("ID3".utf8)),
      bytes[3] != 0xFF,
      bytes[4] != 0xFF
    else { return false }
    return bytes[6...9].allSatisfy { $0 & 0x80 == 0 }
  }

  private static func isMPEGFrameHeader(_ bytes: [UInt8]) -> Bool {
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] & 0xE0 == 0xE0 else {
      return false
    }
    let version = (bytes[1] >> 3) & 0x03
    let layer = (bytes[1] >> 1) & 0x03
    let bitrateIndex = (bytes[2] >> 4) & 0x0F
    let sampleRateIndex = (bytes[2] >> 2) & 0x03
    return version != 0x01
      && layer == 0x01
      && bitrateIndex != 0x00
      && bitrateIndex != 0x0F
      && sampleRateIndex != 0x03
  }

  private static func isADTSHeader(_ bytes: [UInt8]) -> Bool {
    guard bytes.count >= 7, bytes[0] == 0xFF else { return false }
    let hasSyncWord = bytes[1] & 0xF6 == 0xF0
    let sampleRateIndex = (bytes[2] >> 2) & 0x0F
    return hasSyncWord && sampleRateIndex != 0x0F
  }

  static func validatedStructuredDuration(
    in data: Data,
    format: RemoteVoiceFormat
  ) throws -> TimeInterval? {
    let header: [UInt8]
    let payloadByteCounts: [Int]
    switch format {
    case .amr:
      header = Array("#!AMR\n".utf8)
      payloadByteCounts = [12, 13, 15, 17, 19, 20, 26, 31, 5]
    case .amrWideband:
      header = Array("#!AMR-WB\n".utf8)
      payloadByteCounts = [17, 23, 32, 36, 40, 46, 50, 58, 60, 5]
    case .mp3, .aac:
      return nil
    }

    let bytes = [UInt8](data)
    guard bytes.starts(with: header), bytes.count > header.count else {
      throw RemoteVoiceExportError.invalidAudio
    }
    var offset = header.count
    var frameCount = 0
    var contentFrameCount = 0
    let maximumFrameCount = Int(VoicePlaybackTime.maximumDuration / 0.02)
    while offset < bytes.count {
      let frameHeader = bytes[offset]
      guard frameHeader & 0x83 == 0 else {
        throw RemoteVoiceExportError.invalidAudio
      }
      let frameType = Int((frameHeader >> 3) & 0x0F)
      let payloadByteCount: Int
      if frameType < payloadByteCounts.count {
        payloadByteCount = payloadByteCounts[frameType]
        contentFrameCount += 1
      } else if frameType == 15 || (format == .amrWideband && frameType == 14) {
        payloadByteCount = 0
      } else {
        throw RemoteVoiceExportError.invalidAudio
      }
      offset += 1
      guard bytes.count - offset >= payloadByteCount else {
        throw RemoteVoiceExportError.invalidAudio
      }
      offset += payloadByteCount
      frameCount += 1
      if frameCount.isMultiple(of: 4_096) {
        try Task.checkCancellation()
      }
      guard frameCount <= maximumFrameCount else {
        throw RemoteVoiceExportError.invalidAudio
      }
    }
    guard offset == bytes.count, contentFrameCount > 0 else {
      throw RemoteVoiceExportError.invalidAudio
    }
    return TimeInterval(frameCount) * 0.02
  }
}

final class RemoteVoiceShareItem: Identifiable, @unchecked Sendable {
  let id = UUID()
  let fileURL: URL
  let validation: RemoteVoiceValidationResult

  private let lease: RemoteVoiceFileLease

  init(
    fileURL: URL,
    validation: RemoteVoiceValidationResult,
    lease: RemoteVoiceFileLease
  ) {
    self.fileURL = fileURL
    self.validation = validation
    self.lease = lease
  }

  func holdLeaseThroughCompletion() {
    withExtendedLifetime(lease) {}
  }
}

protocol RemoteVoiceExporting: Sendable {
  func prepareForSharing(from sourceURL: URL) async throws -> RemoteVoiceShareItem
}

struct RemoteVoiceExporter: RemoteVoiceExporting, Sendable {
  static let shared = RemoteVoiceExporter()

  private let downloader: any RemoteVoiceDownloading
  private let mediaInspector: any RemoteVoiceMediaInspecting

  init(
    downloader: any RemoteVoiceDownloading = BoundedHTTPSRemoteVoiceTransport.shared,
    mediaInspector: any RemoteVoiceMediaInspecting = AVFoundationRemoteVoiceMediaInspector()
  ) {
    self.downloader = downloader
    self.mediaInspector = mediaInspector
  }

  func prepareForSharing(from sourceURL: URL) async throws -> RemoteVoiceShareItem {
    guard VoicePlaybackURLPolicy.allows(sourceURL) else {
      throw RemoteVoiceDownloadError.invalidURL
    }
    let lease = try await downloader.download(from: sourceURL)
    try Task.checkCancellation()
    guard lease.sourceURL == sourceURL else {
      throw RemoteVoiceDownloadError.invalidResponse
    }
    let validation = try await RemoteVoiceFileValidator.validate(
      fileURL: lease.fileURL,
      byteCount: lease.byteCount,
      mediaInspector: mediaInspector
    )
    try Task.checkCancellation()
    let fileURL = try Self.prepareFile(
      from: lease,
      sourceURL: sourceURL,
      validation: validation
    )
    try Task.checkCancellation()
    return RemoteVoiceShareItem(
      fileURL: fileURL,
      validation: validation,
      lease: lease
    )
  }

  private static func prepareFile(
    from lease: RemoteVoiceFileLease,
    sourceURL: URL,
    validation: RemoteVoiceValidationResult
  ) throws -> URL {
    let parentDirectory = lease.fileURL.deletingLastPathComponent()
    let baseName = safeBaseName(
      voiceIdentifier: VoicePlaybackURLPolicy.voiceIdentifier(from: sourceURL)
    )
    var destination = parentDirectory
      .appendingPathComponent(baseName, isDirectory: false)
      .appendingPathExtension(validation.filenameExtension)
    if FileManager.default.fileExists(atPath: destination.path) {
      destination = parentDirectory
        .appendingPathComponent("\(baseName)-\(UUID().uuidString)", isDirectory: false)
        .appendingPathExtension(validation.filenameExtension)
    }
    do {
      try FileManager.default.copyItem(at: lease.fileURL, to: destination)
    } catch {
      throw RemoteVoiceExportError.cannotPrepareFile
    }
    return destination
  }

  static func safeBaseName(voiceIdentifier: String?) -> String {
    guard let voiceIdentifier else { return "tieba-voice" }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
    let sanitized = voiceIdentifier.unicodeScalars.map { scalar in
      allowed.contains(scalar) && scalar.value < 128 ? String(scalar) : "-"
    }.joined()
      .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    guard
      !sanitized.isEmpty,
      sanitized.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
    else { return "tieba-voice" }
    return "tieba-voice-\(String(sanitized.prefix(64)))"
  }
}

@MainActor
final class RemoteVoiceExportViewModel: ObservableObject {
  enum State: Equatable {
    case idle
    case preparingForSharing
    case readyToShare
    case shared
    case failed(String)
  }

  @Published private(set) var state: State = .idle
  @Published var shareItem: RemoteVoiceShareItem?

  private let exporter: any RemoteVoiceExporting

  init(exporter: any RemoteVoiceExporting = RemoteVoiceExporter.shared) {
    self.exporter = exporter
  }

  var isBusy: Bool { state == .preparingForSharing }

  var errorMessage: String? {
    guard case .failed(let message) = state else { return nil }
    return message
  }

  func prepareForSharing(from sourceURL: URL) async {
    guard !isBusy, shareItem == nil else { return }
    state = .preparingForSharing
    do {
      let item = try await exporter.prepareForSharing(from: sourceURL)
      try Task.checkCancellation()
      shareItem = item
      state = .readyToShare
    } catch is CancellationError {
      state = .idle
    } catch {
      state = .failed(error.localizedDescription)
    }
  }

  func finishSharing(completed: Bool, errorMessage: String?) {
    guard state == .readyToShare else { return }
    shareItem?.holdLeaseThroughCompletion()
    shareItem = nil
    if let errorMessage, !errorMessage.isEmpty {
      state = .failed(errorMessage)
    } else {
      state = completed ? .shared : .idle
    }
  }

  func resetTransientState() {
    switch state {
    case .shared, .failed:
      state = .idle
    case .idle, .preparingForSharing, .readyToShare:
      break
    }
  }
}

struct RemoteVoiceActivitySheet: UIViewControllerRepresentable {
  let item: RemoteVoiceShareItem
  let onCompletion: @MainActor @Sendable (Bool, String?) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(item: item, onCompletion: onCompletion)
  }

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(
      activityItems: [item.fileURL],
      applicationActivities: nil
    )
    let coordinator = context.coordinator
    controller.completionWithItemsHandler = { _, completed, _, error in
      let errorMessage = error?.localizedDescription
      Task { @MainActor in
        coordinator.finish(completed: completed, errorMessage: errorMessage)
      }
    }
    return controller
  }

  func updateUIViewController(
    _ uiViewController: UIActivityViewController,
    context: Context
  ) {}

  @MainActor
  final class Coordinator {
    private var item: RemoteVoiceShareItem?
    private let onCompletion: @MainActor @Sendable (Bool, String?) -> Void
    private var didFinish = false

    init(
      item: RemoteVoiceShareItem,
      onCompletion: @escaping @MainActor @Sendable (Bool, String?) -> Void
    ) {
      self.item = item
      self.onCompletion = onCompletion
    }

    func finish(completed: Bool, errorMessage: String?) {
      guard !didFinish else { return }
      didFinish = true
      let heldItem = item
      onCompletion(completed, errorMessage)
      heldItem?.holdLeaseThroughCompletion()
      item = nil
    }
  }
}
