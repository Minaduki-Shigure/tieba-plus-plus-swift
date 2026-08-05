import Foundation
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class RemoteVoiceExportTests: XCTestCase {
  func testDetectsSupportedVoiceFormatsByBytes() {
    XCTAssertEqual(
      RemoteVoiceFileValidator.detectedFormat(in: id3Data()),
      .mp3
    )
    XCTAssertEqual(
      RemoteVoiceFileValidator.detectedFormat(
        in: Data([0xFF, 0xFB, 0x90, 0x64, 0x00])
      ),
      .mp3
    )
    XCTAssertEqual(
      RemoteVoiceFileValidator.detectedFormat(
        in: Data("#!AMR\n".utf8) + Data([0x3C])
      ),
      .amr
    )
    XCTAssertEqual(
      RemoteVoiceFileValidator.detectedFormat(
        in: Data("#!AMR-WB\n".utf8) + Data([0x1C])
      ),
      .amrWideband
    )
    XCTAssertEqual(
      RemoteVoiceFileValidator.detectedFormat(
        in: Data([0xFF, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC])
      ),
      .aac
    )
  }

  func testRejectsMalformedHeadersAndFalseFrameSync() {
    let invalidHeaders = [
      Data("<html>not audio</html>".utf8),
      Data("ID3".utf8),
      Data([0xFF, 0xE8, 0x00, 0x00]),
      Data([0xFF, 0xF1, 0x3C, 0x00, 0x00, 0x00]),
      Data("#!AMR\n".utf8),
    ]

    for header in invalidHeaders {
      XCTAssertNil(RemoteVoiceFileValidator.detectedFormat(in: header))
    }
  }

  func testValidatorRejectsUnknownPayloadAndMismatchedByteCount() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("voice")
    let html = Data("<!doctype html><title>error</title>".utf8)
    try html.write(to: fileURL)
    do {
      _ = try await RemoteVoiceFileValidator.validate(
        fileURL: fileURL,
        byteCount: Int64(html.count),
        mediaInspector: validMediaInspector
      )
      XCTFail("Expected an unknown payload rejection")
    } catch {
      XCTAssertEqual(error as? RemoteVoiceExportError, .unsupportedAudioType)
    }

    let data = id3Data()
    try data.write(to: fileURL)
    do {
      _ = try await RemoteVoiceFileValidator.validate(
        fileURL: fileURL,
        byteCount: Int64(data.count + 1),
        mediaInspector: validMediaInspector
      )
      XCTFail("Expected a byte-count mismatch rejection")
    } catch {
      XCTAssertEqual(error as? RemoteVoiceExportError, .invalidAudio)
    }
  }

  func testValidatorAcceptsSupportedFormatsAfterMediaInspection() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("voice")
    let data = id3Data()
    try data.write(to: fileURL)

    let mp3 = try await RemoteVoiceFileValidator.validate(
      fileURL: fileURL,
      byteCount: Int64(data.count),
      mediaInspector: validMediaInspector
    )
    XCTAssertEqual(mp3.format, .mp3)

    let amr = amrData(frameCount: 50)
    try amr.write(to: fileURL)
    let validatedAMR = try await RemoteVoiceFileValidator.validate(
      fileURL: fileURL,
      byteCount: Int64(amr.count),
      mediaInspector: validMediaInspector
    )
    XCTAssertEqual(validatedAMR.format, .amr)
    XCTAssertEqual(validatedAMR.duration, 1, accuracy: 0.000_1)
  }

  func testValidatorRejectsMalformedAMRStorageFrames() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("voice")
    let header = Data("#!AMR\n".utf8)
    let malformedPayloads = [
      header + Data([0x04]) + Data(repeating: 0, count: 11),
      header + Data([0x84]) + Data(repeating: 0, count: 12),
      header + Data([0x4C]),
      amrData(frameCount: 1) + Data([0x00]),
    ]

    for data in malformedPayloads {
      try data.write(to: fileURL)
      do {
        _ = try await RemoteVoiceFileValidator.validate(
          fileURL: fileURL,
          byteCount: Int64(data.count),
          mediaInspector: validMediaInspector
        )
        XCTFail("Expected malformed AMR storage rejection")
      } catch {
        XCTAssertEqual(error as? RemoteVoiceExportError, .invalidAudio)
      }
    }
  }

  func testValidatorAcceptsWidebandSpeechLostFrameAndUsesCompatibleInspectionSuffix()
    async throws
  {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("voice")
    let data = amrWidebandData(frameCount: 1, includesSpeechLostFrame: true)
    try data.write(to: fileURL)

    let validation = try await RemoteVoiceFileValidator.validate(
      fileURL: fileURL,
      byteCount: Int64(data.count),
      mediaInspector: RemoteVoiceExtensionCheckingInspector(
        expectedExtension: "amr",
        expectedFormat: .amrWideband,
        inspection: validMediaInspection
      )
    )

    XCTAssertEqual(validation.format, .amrWideband)
    XCTAssertEqual(validation.filenameExtension, "awb")
    XCTAssertEqual(validation.duration, 0.04, accuracy: 0.000_1)
  }

  func testAMRParserCooperativelyCancelsLargeNoDataStream() async throws {
    var data = amrData(frameCount: 1)
    data.append(Data(repeating: 0x7C, count: 10_000))

    let task = Task {
      try RemoteVoiceFileValidator.validatedStructuredDuration(
        in: data,
        format: .amr
      )
    }
    task.cancel()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch is CancellationError {
      // Expected.
    }
  }

  func testValidatorRequiresAudioOnlyTrackAndBoundedPositiveDuration() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("voice")
    let data = id3Data()
    try data.write(to: fileURL)
    let invalidInspections = [
      RemoteVoiceMediaInspection(
        isPlayable: false, audioTrackCount: 1, videoTrackCount: 0, duration: 1
      ),
      RemoteVoiceMediaInspection(
        isPlayable: true, audioTrackCount: 0, videoTrackCount: 0, duration: 1
      ),
      RemoteVoiceMediaInspection(
        isPlayable: true, audioTrackCount: 1, videoTrackCount: 1, duration: 1
      ),
      RemoteVoiceMediaInspection(
        isPlayable: true, audioTrackCount: 1, videoTrackCount: 0, duration: 0
      ),
      RemoteVoiceMediaInspection(
        isPlayable: true,
        audioTrackCount: 1,
        videoTrackCount: 0,
        duration: VoicePlaybackTime.maximumDuration + 1
      ),
      RemoteVoiceMediaInspection(
        isPlayable: true, audioTrackCount: 1, videoTrackCount: 0, duration: .infinity
      ),
    ]

    for inspection in invalidInspections {
      do {
        _ = try await RemoteVoiceFileValidator.validate(
          fileURL: fileURL,
          byteCount: Int64(data.count),
          mediaInspector: RemoteVoiceMediaInspectorSpy(inspection: inspection)
        )
        XCTFail("Expected invalid media inspection: \(inspection)")
      } catch {
        XCTAssertEqual(error as? RemoteVoiceExportError, .invalidAudio)
      }
    }
  }

  func testAVFoundationInspectorAcceptsRealMP3AndRejectsHeaderOnlyPayload() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("voice.mp3")
    let validMP3 = try XCTUnwrap(Data(base64Encoded: Self.silentMP3Base64))
    try validMP3.write(to: fileURL)

    let validation = try await RemoteVoiceFileValidator.validate(
      fileURL: fileURL,
      byteCount: Int64(validMP3.count)
    )

    XCTAssertEqual(validation.format, .mp3)
    XCTAssertGreaterThan(validation.duration, 0)
    XCTAssertLessThanOrEqual(validation.duration, VoicePlaybackTime.maximumDuration)

    let headerOnly = id3Data()
    try headerOnly.write(to: fileURL)
    do {
      _ = try await RemoteVoiceFileValidator.validate(
        fileURL: fileURL,
        byteCount: Int64(headerOnly.count)
      )
      XCTFail("Expected AVFoundation to reject a header-only payload")
    } catch {
      XCTAssertEqual(error as? RemoteVoiceExportError, .invalidAudio)
    }
  }

  func testAVFoundationInspectorAcceptsSyntheticAMRStorageFile() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("download")
    let data = amrData(frameCount: 50)
    try data.write(to: fileURL)

    let validation = try await RemoteVoiceFileValidator.validate(
      fileURL: fileURL,
      byteCount: Int64(data.count)
    )

    XCTAssertEqual(validation.format, .amr)
    XCTAssertEqual(validation.filenameExtension, "amr")
    XCTAssertEqual(validation.duration, 1, accuracy: 0.000_1)
  }

  func testAVFoundationInspectorAcceptsSyntheticAMRWidebandStorageFile() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("download")
    let data = amrWidebandData(frameCount: 50, includesSpeechLostFrame: false)
    try data.write(to: fileURL)

    let validation = try await RemoteVoiceFileValidator.validate(
      fileURL: fileURL,
      byteCount: Int64(data.count)
    )

    XCTAssertEqual(validation.format, .amrWideband)
    XCTAssertEqual(validation.filenameExtension, "awb")
    XCTAssertEqual(validation.duration, 1, accuracy: 0.000_1)
  }

  func testExporterCreatesSanitizedMP3AndReleasesLeaseAfterShareItem() async throws {
    let downloader = RemoteVoiceDownloaderSpy(data: id3Data())
    let exporter = RemoteVoiceExporter(
      downloader: downloader,
      mediaInspector: validMediaInspector
    )
    var item: RemoteVoiceShareItem? = try await exporter.prepareForSharing(
      from: voiceURL("abc/../../xyz")
    )
    let fileURL = try XCTUnwrap(item?.fileURL)
    let leaseDirectory = fileURL.deletingLastPathComponent()

    XCTAssertEqual(fileURL.pathExtension, "mp3")
    XCTAssertEqual(fileURL.lastPathComponent, "tieba-voice-abc-------xyz.mp3")
    XCTAssertEqual(item?.validation.format, .mp3)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: leaseDirectory.path))

    item = nil

    XCTAssertFalse(FileManager.default.fileExists(atPath: leaseDirectory.path))
  }

  func testExporterRejectsInvalidSourceBeforeCallingDownloader() async throws {
    let downloader = RemoteVoiceDownloaderSpy(data: id3Data())
    let exporter = RemoteVoiceExporter(
      downloader: downloader,
      mediaInspector: validMediaInspector
    )
    let invalidURL = try XCTUnwrap(URL(string: "https://example.com/voice.mp3"))

    do {
      _ = try await exporter.prepareForSharing(from: invalidURL)
      XCTFail("Expected invalid URL")
    } catch RemoteVoiceDownloadError.invalidURL {
      // Expected.
    }

    let downloadCount = await downloader.downloadCount()
    XCTAssertEqual(downloadCount, 0)
  }

  func testExporterCleansTemporaryLeaseWhenValidationFails() async throws {
    let downloader = RemoteVoiceDownloaderSpy(data: id3Data())
    let exporter = RemoteVoiceExporter(
      downloader: downloader,
      mediaInspector: RemoteVoiceRejectingInspector()
    )

    do {
      _ = try await exporter.prepareForSharing(from: voiceURL("invalid-media"))
      XCTFail("Expected validation failure")
    } catch {
      XCTAssertEqual(error as? RemoteVoiceExportError, .invalidAudio)
    }
    await Task.yield()
    let recordedDirectory = await downloader.lastLeaseDirectory()
    let directory = try XCTUnwrap(recordedDirectory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testExportViewModelTracksCompletionFailureAndLeaseRelease() async throws {
    var preparedItem: RemoteVoiceShareItem? = try makePreparedShareItem()
    let preparedFileURL = try XCTUnwrap(preparedItem).fileURL
    let preparedDirectory = preparedFileURL.deletingLastPathComponent()
    let successfulExporter = RemoteVoiceExportingSpy(item: try XCTUnwrap(preparedItem))
    preparedItem = nil
    let viewModel = RemoteVoiceExportViewModel(exporter: successfulExporter)

    await viewModel.prepareForSharing(from: voiceURL("ready"))

    XCTAssertEqual(viewModel.state, .readyToShare)
    XCTAssertNotNil(viewModel.shareItem)
    XCTAssertTrue(FileManager.default.fileExists(atPath: preparedFileURL.path))

    viewModel.finishSharing(completed: false, errorMessage: nil)

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.shareItem)
    XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDirectory.path))

    let failure = RemoteVoiceExportingSpy(
      error: RemoteVoiceExportTestError(message: "download failed")
    )
    let failingViewModel = RemoteVoiceExportViewModel(exporter: failure)
    await failingViewModel.prepareForSharing(from: voiceURL("failed"))
    XCTAssertEqual(failingViewModel.state, .failed("download failed"))
    XCTAssertEqual(failingViewModel.errorMessage, "download failed")
    failingViewModel.resetTransientState()
    XCTAssertEqual(failingViewModel.state, .idle)
  }

  func testFilenamePolicyIsBoundedAndFallsBackForUnsafeIdentifier() {
    XCTAssertEqual(
      RemoteVoiceExporter.safeBaseName(voiceIdentifier: nil),
      "tieba-voice"
    )
    XCTAssertEqual(
      RemoteVoiceExporter.safeBaseName(voiceIdentifier: "\n/../"),
      "tieba-voice"
    )
    let longName = RemoteVoiceExporter.safeBaseName(
      voiceIdentifier: String(repeating: "a", count: 200)
    )
    XCTAssertEqual(longName, "tieba-voice-" + String(repeating: "a", count: 64))
    XCTAssertEqual(RemoteVoiceFormat.amrWideband.filenameExtension, "awb")
  }

  private func id3Data() -> Data {
    Data([0x49, 0x44, 0x33, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01])
  }

  private func amrData(frameCount: Int) -> Data {
    var data = Data("#!AMR\n".utf8)
    let frame = Data([0x04]) + Data(repeating: 0, count: 12)
    for _ in 0..<frameCount {
      data.append(frame)
    }
    return data
  }

  private func amrWidebandData(
    frameCount: Int,
    includesSpeechLostFrame: Bool
  ) -> Data {
    var data = Data("#!AMR-WB\n".utf8)
    let frame = Data([0x04]) + Data(repeating: 0, count: 17)
    for _ in 0..<frameCount {
      data.append(frame)
    }
    if includesSpeechLostFrame {
      data.append(0x74)
    }
    return data
  }

  private func voiceURL(_ identifier: String) -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = "tiebac.baidu.com"
    components.path = "/c/p/voice"
    components.queryItems = [
      URLQueryItem(name: "voice_md5", value: identifier),
      URLQueryItem(name: "play_from", value: "pb_voice_play"),
    ]
    return components.url!
  }

  private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RemoteVoiceExportTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }

  private func makePreparedShareItem() throws -> RemoteVoiceShareItem {
    let directory = try temporaryDirectory()
    let fileURL = directory.appendingPathComponent("prepared.mp3")
    let data = id3Data()
    try data.write(to: fileURL)
    let lease = RemoteVoiceFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: directory,
      sourceURL: voiceURL("prepared"),
      byteCount: Int64(data.count)
    )
    return RemoteVoiceShareItem(
      fileURL: fileURL,
      validation: RemoteVoiceValidationResult(
        format: .mp3,
        byteCount: Int64(data.count),
        duration: 1
      ),
      lease: lease
    )
  }

  private var validMediaInspector: RemoteVoiceMediaInspectorSpy {
    RemoteVoiceMediaInspectorSpy(
      inspection: validMediaInspection
    )
  }

  private var validMediaInspection: RemoteVoiceMediaInspection {
    RemoteVoiceMediaInspection(
      isPlayable: true,
      audioTrackCount: 1,
      videoTrackCount: 0,
      duration: 88
    )
  }

  private static let silentMP3Base64 =
    "SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjU4Ljc2LjEwMAAAAAAAAAAAAAAA/+M4wAAAAAAAAAAAAEluZm8AAAAPAAAABQAAAkAAgICAgICAgICAgICAgICAgICAgKCgoKCgoKCgoKCgoKCgoKCgoKCgwMDAwMDAwMDAwMDAwMDAwMDAwMDg4ODg4ODg4ODg4ODg4ODg4ODg4P//////////////////////////AAAAAExhdmM1OC4xMwAAAAAAAAAAAAAAACQCwAAAAAAAAAJAvfcGtAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/+MYxAAAAANIAAAAAExBTUUzLjEwMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVV/+MYxDsAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MYxHYAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MYxLEAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+MYxMQAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV"
}

private actor RemoteVoiceDownloaderSpy: RemoteVoiceDownloading {
  private let data: Data
  private var downloads = 0
  private var leaseDirectory: URL?

  init(data: Data) {
    self.data = data
  }

  func download(from url: URL) async throws -> RemoteVoiceFileLease {
    downloads += 1
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("RemoteVoiceDownloaderSpy", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    leaseDirectory = directory
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    let fileURL = directory.appendingPathComponent("download")
    try data.write(to: fileURL)
    return RemoteVoiceFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: directory,
      sourceURL: url,
      byteCount: Int64(data.count)
    )
  }

  func downloadCount() -> Int { downloads }
  func lastLeaseDirectory() -> URL? { leaseDirectory }
}

private actor RemoteVoiceExportingSpy: RemoteVoiceExporting {
  private var item: RemoteVoiceShareItem?
  private let error: RemoteVoiceExportTestError?

  init(
    item: RemoteVoiceShareItem? = nil,
    error: RemoteVoiceExportTestError? = nil
  ) {
    self.item = item
    self.error = error
  }

  func prepareForSharing(from sourceURL: URL) async throws -> RemoteVoiceShareItem {
    if let error { throw error }
    guard let item else {
      throw RemoteVoiceExportTestError(message: "missing share item")
    }
    self.item = nil
    return item
  }
}

private struct RemoteVoiceExportTestError: LocalizedError, Sendable {
  let message: String
  var errorDescription: String? { message }
}

private struct RemoteVoiceMediaInspectorSpy: RemoteVoiceMediaInspecting {
  let inspection: RemoteVoiceMediaInspection

  func inspect(fileURL: URL, format: RemoteVoiceFormat) async throws
    -> RemoteVoiceMediaInspection
  {
    inspection
  }
}

private struct RemoteVoiceExtensionCheckingInspector: RemoteVoiceMediaInspecting {
  let expectedExtension: String
  let expectedFormat: RemoteVoiceFormat
  let inspection: RemoteVoiceMediaInspection

  func inspect(fileURL: URL, format: RemoteVoiceFormat) async throws
    -> RemoteVoiceMediaInspection
  {
    guard
      fileURL.pathExtension == expectedExtension,
      format == expectedFormat
    else {
      throw RemoteVoiceExportTestError(message: "unexpected inspection hint")
    }
    return inspection
  }
}

private struct RemoteVoiceRejectingInspector: RemoteVoiceMediaInspecting {
  func inspect(fileURL: URL, format: RemoteVoiceFormat) async throws
    -> RemoteVoiceMediaInspection
  {
    throw RemoteVoiceExportTestError(message: "invalid media")
  }
}
