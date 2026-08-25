import Foundation
import UIKit
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
    var truncatedFrame = header
    truncatedFrame.append(0x04)
    truncatedFrame.append(Data(repeating: 0, count: 11))
    var invalidPadding = header
    invalidPadding.append(0x84)
    invalidPadding.append(Data(repeating: 0, count: 12))
    var reservedFrameType = header
    reservedFrameType.append(0x4C)
    var trailingByte = amrData(frameCount: 1)
    trailingByte.append(0x00)
    let malformedPayloads: [Data] = [
      truncatedFrame,
      invalidPadding,
      reservedFrameType,
      trailingByte,
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

  func testExporterCreatesSanitizedMP3AndReleasesLeaseAfterExportItem() async throws {
    let downloader = RemoteVoiceDownloaderSpy(data: id3Data())
    let exporter = RemoteVoiceExporter(
      downloader: downloader,
      mediaInspector: validMediaInspector
    )
    var item: RemoteVoiceExportItem? = try await exporter.prepareForExport(
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
      _ = try await exporter.prepareForExport(from: invalidURL)
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
      _ = try await exporter.prepareForExport(from: voiceURL("invalid-media"))
      XCTFail("Expected validation failure")
    } catch {
      XCTAssertEqual(error as? RemoteVoiceExportError, .invalidAudio)
    }
    await Task.yield()
    let recordedDirectory = await downloader.lastLeaseDirectory()
    let directory = try XCTUnwrap(recordedDirectory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testExportViewModelCompletesShareAndFilesUsingTheSamePreparedLease() async throws {
    let cases: [(RemoteVoiceExportIntent, RemoteVoiceExportOutcome)] = [
      (.share, .shared),
      (.saveToFiles, .savedToFiles),
    ]

    for (index, entry) in cases.enumerated() {
      let (intent, outcome) = entry
      let sourceURL = voiceURL("ready-\(index)")
      var preparedItem: RemoteVoiceExportItem? = try makePreparedExportItem(
        identifier: "ready-\(index)"
      )
      let preparedFileURL = try XCTUnwrap(preparedItem).fileURL
      let preparedDirectory = preparedFileURL.deletingLastPathComponent()
      let exporter = RemoteVoiceExportingSpy(item: try XCTUnwrap(preparedItem))
      preparedItem = nil
      let viewModel = RemoteVoiceExportViewModel(exporter: exporter)
      let request = try XCTUnwrap(
        viewModel.start(intent: intent, from: sourceURL)
      )

      try await waitForRemoteVoiceExportTest {
        viewModel.presentation?.request == request
      }

      XCTAssertEqual(viewModel.state, .ready(request))
      XCTAssertEqual(viewModel.presentation?.item.fileURL, preparedFileURL)
      XCTAssertTrue(FileManager.default.fileExists(atPath: preparedFileURL.path))
      viewModel.systemPresentationDidAppear(request: request)

      viewModel.finish(request: request, outcome: outcome)

      let expectedState: RemoteVoiceExportViewModel.State =
        intent == .share ? .shared(request) : .savedToFiles(request)
      XCTAssertEqual(viewModel.state, expectedState)
      XCTAssertNil(viewModel.notice)
      XCTAssertNil(viewModel.presentation)
      XCTAssertFalse(viewModel.canStart)
      XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDirectory.path))
      viewModel.systemPresentationDidDismiss()
      if intent == .share {
        XCTAssertEqual(viewModel.state, .idle)
        XCTAssertNil(viewModel.notice)
      } else {
        XCTAssertEqual(viewModel.state, .savedToFiles(request))
        XCTAssertEqual(viewModel.notice, .savedToFiles(request))
      }
      XCTAssertTrue(viewModel.canStart)
      viewModel.resetTransientState()
      XCTAssertEqual(viewModel.state, .idle)
    }
  }

  func testOutcomeBetweenDismissalStartAndOnDismissWaitsBeforePublishingNotice()
    async throws
  {
    let cases: [(RemoteVoiceExportIntent, RemoteVoiceExportOutcome)] = [
      (.share, .shared),
      (.saveToFiles, .savedToFiles),
      (.share, .failed("system export failed")),
      (.saveToFiles, .cancelled),
    ]

    for (index, entry) in cases.enumerated() {
      let identifier = "dismissal-start-\(index)"
      var item: RemoteVoiceExportItem? = try makePreparedExportItem(identifier: identifier)
      let directory = try XCTUnwrap(item).fileURL.deletingLastPathComponent()
      let viewModel = RemoteVoiceExportViewModel(
        exporter: RemoteVoiceExportingSpy(item: try XCTUnwrap(item))
      )
      item = nil
      let request = try XCTUnwrap(
        viewModel.start(intent: entry.0, from: voiceURL(identifier))
      )
      try await waitForRemoteVoiceExportTest {
        viewModel.presentation?.request == request
      }
      viewModel.systemPresentationDidAppear(request: request)

      viewModel.systemPresentationDismissalStarted(request: request)

      XCTAssertNil(viewModel.presentation)
      XCTAssertEqual(viewModel.state, .ready(request))
      XCTAssertNil(viewModel.notice)
      XCTAssertFalse(viewModel.canStart)
      XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

      viewModel.finish(request: request, outcome: entry.1)

      XCTAssertEqual(viewModel.state, terminalState(for: entry.1, request: request))
      XCTAssertNil(viewModel.notice)
      XCTAssertFalse(viewModel.canStart)
      XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

      viewModel.systemPresentationDidDismiss()

      XCTAssertEqual(viewModel.state, completedState(for: entry.1, request: request))
      XCTAssertEqual(viewModel.notice, completedNotice(for: entry.1, request: request))
      XCTAssertTrue(viewModel.canStart)
      viewModel.resetTransientState()
      XCTAssertEqual(viewModel.state, .idle)
    }
  }

  func testOutcomeAfterOnDismissCompletesTheRetainedRequest() async throws {
    let cases: [(RemoteVoiceExportIntent, RemoteVoiceExportOutcome)] = [
      (.share, .shared),
      (.saveToFiles, .savedToFiles),
      (.share, .failed("system export failed")),
      (.saveToFiles, .cancelled),
    ]

    for (index, entry) in cases.enumerated() {
      let identifier = "on-dismiss-first-\(index)"
      var item: RemoteVoiceExportItem? = try makePreparedExportItem(identifier: identifier)
      let directory = try XCTUnwrap(item).fileURL.deletingLastPathComponent()
      let viewModel = RemoteVoiceExportViewModel(
        exporter: RemoteVoiceExportingSpy(item: try XCTUnwrap(item))
      )
      item = nil
      let request = try XCTUnwrap(
        viewModel.start(intent: entry.0, from: voiceURL(identifier))
      )
      try await waitForRemoteVoiceExportTest {
        viewModel.presentation?.request == request
      }
      viewModel.systemPresentationDidAppear(request: request)

      viewModel.systemPresentationDidDismiss()

      XCTAssertNil(viewModel.presentation)
      XCTAssertEqual(viewModel.state, .ready(request))
      XCTAssertNil(viewModel.notice)
      XCTAssertFalse(viewModel.canStart)
      XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

      viewModel.finish(request: request, outcome: entry.1)

      XCTAssertEqual(viewModel.state, completedState(for: entry.1, request: request))
      XCTAssertEqual(viewModel.notice, completedNotice(for: entry.1, request: request))
      XCTAssertTrue(viewModel.canStart)
      XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
      viewModel.resetTransientState()
      XCTAssertEqual(viewModel.state, .idle)
    }
  }

  func testDismissalWithoutACompletedPresentationCancelsTheRequest() async throws {
    let identifier = "not-presented"
    var item: RemoteVoiceExportItem? = try makePreparedExportItem(identifier: identifier)
    let directory = try XCTUnwrap(item).fileURL.deletingLastPathComponent()
    let viewModel = RemoteVoiceExportViewModel(
      exporter: RemoteVoiceExportingSpy(item: try XCTUnwrap(item))
    )
    item = nil
    let request = try XCTUnwrap(
      viewModel.start(intent: .saveToFiles, from: voiceURL(identifier))
    )
    try await waitForRemoteVoiceExportTest {
      viewModel.presentation?.request == request
    }

    viewModel.systemPresentationDismissalStarted(request: request)
    viewModel.systemPresentationDidDismiss()

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.presentation)
    XCTAssertNil(viewModel.notice)
    XCTAssertTrue(viewModel.canStart)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testExportViewModelCancellationAndFailureReleaseThePreparedLease() async throws {
    var preparedItem: RemoteVoiceExportItem? = try makePreparedExportItem(
      identifier: "cancelled"
    )
    let preparedDirectory = try XCTUnwrap(preparedItem).fileURL.deletingLastPathComponent()
    let exporter = RemoteVoiceExportingSpy(item: try XCTUnwrap(preparedItem))
    preparedItem = nil
    let viewModel = RemoteVoiceExportViewModel(exporter: exporter)
    let request = try XCTUnwrap(
      viewModel.start(intent: .saveToFiles, from: voiceURL("cancelled"))
    )
    try await waitForRemoteVoiceExportTest {
      viewModel.presentation?.request == request
    }
    viewModel.systemPresentationDidAppear(request: request)

    viewModel.finish(request: request, outcome: .cancelled)
    viewModel.systemPresentationDidDismiss()

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.presentation)
    XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDirectory.path))

    let failure = RemoteVoiceExportingSpy(
      error: RemoteVoiceExportTestError(message: "download failed")
    )
    let failingViewModel = RemoteVoiceExportViewModel(exporter: failure)
    let failedRequest = try XCTUnwrap(
      failingViewModel.start(intent: .saveToFiles, from: voiceURL("failed"))
    )
    try await waitForRemoteVoiceExportTest {
      failingViewModel.errorMessage != nil
    }
    XCTAssertEqual(
      failingViewModel.state,
      .failed(failedRequest, "download failed")
    )
    XCTAssertEqual(failingViewModel.failedRequest, failedRequest)
    XCTAssertEqual(failingViewModel.errorMessage, "download failed")
    XCTAssertEqual(
      failingViewModel.notice,
      .failed(failedRequest, "download failed")
    )
    failingViewModel.resetTransientState()
    XCTAssertEqual(failingViewModel.state, .idle)
  }

  func testExportViewModelRejectsPreparedItemForAnotherSource() async throws {
    var preparedItem: RemoteVoiceExportItem? = try makePreparedExportItem(
      identifier: "wrong-source"
    )
    let directory = try XCTUnwrap(preparedItem).fileURL.deletingLastPathComponent()
    let exporter = RemoteVoiceExportingSpy(item: try XCTUnwrap(preparedItem))
    preparedItem = nil
    let viewModel = RemoteVoiceExportViewModel(exporter: exporter)
    let request = try XCTUnwrap(
      viewModel.start(intent: .saveToFiles, from: voiceURL("expected-source"))
    )

    try await waitForRemoteVoiceExportTest {
      viewModel.errorMessage != nil
    }

    XCTAssertEqual(
      viewModel.state,
      .failed(request, "语音文件与当前请求不匹配。")
    )
    XCTAssertEqual(
      viewModel.notice,
      .failed(request, "语音文件与当前请求不匹配。")
    )
    XCTAssertNil(viewModel.presentation)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testReadySystemFailureRetainsMessageAndReleasesLease() async throws {
    var preparedItem: RemoteVoiceExportItem? = try makePreparedExportItem(
      identifier: "system-failure"
    )
    let directory = try XCTUnwrap(preparedItem).fileURL.deletingLastPathComponent()
    let exporter = RemoteVoiceExportingSpy(item: try XCTUnwrap(preparedItem))
    preparedItem = nil
    let viewModel = RemoteVoiceExportViewModel(exporter: exporter)
    let request = try XCTUnwrap(
      viewModel.start(intent: .share, from: voiceURL("system-failure"))
    )
    try await waitForRemoteVoiceExportTest {
      viewModel.presentation?.request == request
    }
    viewModel.systemPresentationDidAppear(request: request)

    viewModel.finish(request: request, outcome: .failed("system export failed"))

    XCTAssertEqual(
      viewModel.state,
      .failed(request, "system export failed")
    )
    XCTAssertEqual(viewModel.errorMessage, "system export failed")
    XCTAssertNil(viewModel.notice)
    XCTAssertNil(viewModel.presentation)
    XCTAssertFalse(viewModel.canStart)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    viewModel.systemPresentationDidDismiss()
    XCTAssertEqual(
      viewModel.notice,
      .failed(request, "system export failed")
    )
    XCTAssertTrue(viewModel.canStart)
  }

  func testExportViewModelRejectsOverlapMismatchedRequestsAndWrongOutcomes() async throws {
    var preparedItem: RemoteVoiceExportItem? = try makePreparedExportItem(identifier: "exact")
    let preparedDirectory = try XCTUnwrap(preparedItem).fileURL.deletingLastPathComponent()
    let exporter = RemoteVoiceExportingSpy(item: try XCTUnwrap(preparedItem))
    preparedItem = nil
    let viewModel = RemoteVoiceExportViewModel(exporter: exporter)
    let sourceURL = voiceURL("exact")
    let request = try XCTUnwrap(
      viewModel.start(intent: .saveToFiles, from: sourceURL)
    )
    XCTAssertNil(viewModel.start(intent: .share, from: sourceURL))
    try await waitForRemoteVoiceExportTest {
      viewModel.presentation?.request == request
    }
    let requestCount = await exporter.requestCount()
    XCTAssertEqual(requestCount, 1)
    viewModel.resetTransientState()
    XCTAssertEqual(viewModel.state, .ready(request))

    let mismatches = [
      RemoteVoiceExportRequest(id: UUID(), intent: request.intent, sourceURL: sourceURL),
      RemoteVoiceExportRequest(id: request.id, intent: .share, sourceURL: sourceURL),
      RemoteVoiceExportRequest(
        id: request.id,
        intent: request.intent,
        sourceURL: voiceURL("different")
      ),
    ]
    for mismatch in mismatches {
      viewModel.finish(request: mismatch, outcome: .savedToFiles)
      viewModel.cancel(request: mismatch)
      XCTAssertEqual(viewModel.state, .ready(request))
    }
    viewModel.finish(request: request, outcome: .shared)
    XCTAssertEqual(viewModel.state, .ready(request))
    XCTAssertTrue(FileManager.default.fileExists(atPath: preparedDirectory.path))

    viewModel.systemPresentationDidAppear(request: request)
    viewModel.finish(request: request, outcome: .savedToFiles)
    XCTAssertEqual(viewModel.state, .savedToFiles(request))
    XCTAssertNil(viewModel.notice)
    XCTAssertFalse(viewModel.canStart)
    viewModel.finish(request: request, outcome: .failed("late"))
    XCTAssertEqual(viewModel.state, .savedToFiles(request))
    XCTAssertFalse(FileManager.default.fileExists(atPath: preparedDirectory.path))
    viewModel.systemPresentationDidDismiss()
    XCTAssertEqual(viewModel.notice, .savedToFiles(request))
    XCTAssertTrue(viewModel.canStart)
  }

  func testCancelAllAllowsNewRequestAndRejectsLateUncooperativePreparation() async throws {
    let exporter = RemoteVoiceSuspendingExportingSpy()
    let viewModel = RemoteVoiceExportViewModel(exporter: exporter)
    let firstRequest = try XCTUnwrap(
      viewModel.start(intent: .share, from: voiceURL("first"))
    )
    try await waitForRemoteVoiceExportTest { await exporter.requestCount() == 1 }
    viewModel.resetTransientState()
    XCTAssertEqual(viewModel.state, .preparing(firstRequest))
    viewModel.cancel(
      request: RemoteVoiceExportRequest(
        id: UUID(),
        intent: firstRequest.intent,
        sourceURL: firstRequest.sourceURL
      )
    )
    XCTAssertEqual(viewModel.state, .preparing(firstRequest))

    viewModel.cancelAll()
    XCTAssertEqual(viewModel.state, .idle)
    let secondRequest = try XCTUnwrap(
      viewModel.start(intent: .saveToFiles, from: voiceURL("second"))
    )
    try await waitForRemoteVoiceExportTest { await exporter.requestCount() == 2 }

    var secondItem: RemoteVoiceExportItem? = try makePreparedExportItem(identifier: "second")
    let secondDirectory = try XCTUnwrap(secondItem).fileURL.deletingLastPathComponent()
    await exporter.resumeRequest(at: 1, with: try XCTUnwrap(secondItem))
    secondItem = nil
    try await waitForRemoteVoiceExportTest {
      viewModel.presentation?.request == secondRequest
    }

    var firstItem: RemoteVoiceExportItem? = try makePreparedExportItem(identifier: "first")
    let firstDirectory = try XCTUnwrap(firstItem).fileURL.deletingLastPathComponent()
    await exporter.resumeRequest(at: 0, with: try XCTUnwrap(firstItem))
    firstItem = nil
    try await waitForRemoteVoiceExportTest {
      !FileManager.default.fileExists(atPath: firstDirectory.path)
    }

    XCTAssertNotEqual(firstRequest, secondRequest)
    XCTAssertEqual(viewModel.state, .ready(secondRequest))
    XCTAssertEqual(viewModel.presentation?.request, secondRequest)
    XCTAssertTrue(FileManager.default.fileExists(atPath: secondDirectory.path))
    viewModel.cancelAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: secondDirectory.path))
  }

  func testExactPreparingCancellationRejectsLateUncooperativePreparation() async throws {
    let exporter = RemoteVoiceSuspendingExportingSpy()
    let viewModel = RemoteVoiceExportViewModel(exporter: exporter)
    let request = try XCTUnwrap(
      viewModel.start(intent: .saveToFiles, from: voiceURL("exact-cancel"))
    )
    try await waitForRemoteVoiceExportTest { await exporter.requestCount() == 1 }

    viewModel.cancel(request: request)

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertTrue(viewModel.canStart)
    var item: RemoteVoiceExportItem? = try makePreparedExportItem(identifier: "exact-cancel")
    let directory = try XCTUnwrap(item).fileURL.deletingLastPathComponent()
    await exporter.resumeRequest(at: 0, with: try XCTUnwrap(item))
    item = nil
    try await waitForRemoteVoiceExportTest {
      !FileManager.default.fileExists(atPath: directory.path)
    }

    XCTAssertEqual(viewModel.state, .idle)
    XCTAssertNil(viewModel.presentation)
    XCTAssertNil(viewModel.notice)
  }

  func testDocumentPickerCoordinatorRetainsLeaseAndCompletesExactlyOnce() throws {
    var item: RemoteVoiceExportItem? = try makePreparedExportItem()
    let fileURL = try XCTUnwrap(item).fileURL
    let directory = fileURL.deletingLastPathComponent()
    let request = RemoteVoiceExportRequest(
      intent: .saveToFiles,
      sourceURL: voiceURL("coordinator")
    )
    var presentation: RemoteVoiceExportPresentation? = RemoteVoiceExportPresentation(
      request: request,
      item: try XCTUnwrap(item)
    )
    let probe = RemoteVoiceExportCompletionProbe(directory: directory)
    let coordinator = RemoteVoiceDocumentPicker.Coordinator(
      presentation: try XCTUnwrap(presentation)
    ) { completedRequest, outcome in
      probe.record(request: completedRequest, outcome: outcome)
    }
    item = nil
    presentation = nil
    let controller = UIDocumentPickerViewController(
      forExporting: [fileURL],
      asCopy: true
    )

    XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
    coordinator.documentPicker(
      controller,
      didPickDocumentsAt: [try XCTUnwrap(URL(string: "file:///tmp/saved.mp3"))]
    )
    coordinator.documentPickerWasCancelled(controller)
    RemoteVoiceDocumentPicker.dismantleUIViewController(
      controller,
      coordinator: coordinator
    )

    XCTAssertEqual(probe.requests, [request])
    XCTAssertEqual(probe.outcomes, [.savedToFiles])
    XCTAssertEqual(probe.fileExistenceDuringCallbacks, [true])
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testCoordinatorCompletionDrivesExactViewModelRequest() async throws {
    var item: RemoteVoiceExportItem? = try makePreparedExportItem(identifier: "coordinated")
    let directory = try XCTUnwrap(item).fileURL.deletingLastPathComponent()
    let exporter = RemoteVoiceExportingSpy(item: try XCTUnwrap(item))
    item = nil
    let viewModel = RemoteVoiceExportViewModel(exporter: exporter)
    let request = try XCTUnwrap(
      viewModel.start(intent: .saveToFiles, from: voiceURL("coordinated"))
    )
    try await waitForRemoteVoiceExportTest {
      viewModel.presentation?.request == request
    }
    let presentation = try XCTUnwrap(viewModel.presentation)
    viewModel.systemPresentationDidAppear(request: request)
    let coordinator = RemoteVoiceExportCompletionCoordinator(
      presentation: presentation
    ) { completedRequest, outcome in
      viewModel.finish(request: completedRequest, outcome: outcome)
    }

    coordinator.finish(.savedToFiles)
    coordinator.finish(.cancelled)

    XCTAssertEqual(viewModel.state, .savedToFiles(request))
    XCTAssertNil(viewModel.notice)
    XCTAssertFalse(viewModel.canStart)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    viewModel.systemPresentationDidDismiss()
    XCTAssertEqual(viewModel.notice, .savedToFiles(request))
    XCTAssertTrue(viewModel.canStart)
  }

  func testDocumentPickerOutcomeRequiresASelectedDestinationURL() throws {
    XCTAssertEqual(
      RemoteVoiceDocumentPicker.outcome(forPickedDocuments: []),
      .cancelled
    )
    XCTAssertEqual(
      RemoteVoiceDocumentPicker.outcome(
        forPickedDocuments: [try XCTUnwrap(URL(string: "file:///tmp/saved.mp3"))]
      ),
      .savedToFiles
    )
  }

  func testExporterPreservesEveryValidatedAudioExtensionForFiles() async throws {
    let fixtures: [(String, Data, String)] = [
      ("mp3", id3Data(), "mp3"),
      ("amr", amrData(frameCount: 1), "amr"),
      ("wideband", amrWidebandData(frameCount: 1, includesSpeechLostFrame: false), "awb"),
      ("aac", Data([0xFF, 0xF1, 0x50, 0x80, 0x00, 0x1F, 0xFC]), "aac"),
    ]

    for (identifier, data, expectedExtension) in fixtures {
      let exporter = RemoteVoiceExporter(
        downloader: RemoteVoiceDownloaderSpy(data: data),
        mediaInspector: validMediaInspector
      )
      var item: RemoteVoiceExportItem? = try await exporter.prepareForExport(
        from: voiceURL(identifier)
      )
      let directory = try XCTUnwrap(item).fileURL.deletingLastPathComponent()
      XCTAssertEqual(item?.fileURL.pathExtension, expectedExtension, identifier)
      item = nil
      XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), identifier)
    }
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

  private func makePreparedExportItem(
    identifier: String = "prepared"
  ) throws -> RemoteVoiceExportItem {
    let directory = try temporaryDirectory()
    let fileURL = directory.appendingPathComponent("prepared.mp3")
    let data = id3Data()
    try data.write(to: fileURL)
    let lease = RemoteVoiceFileLease(
      fileURL: fileURL,
      cleanupDirectoryURL: directory,
      sourceURL: voiceURL(identifier),
      byteCount: Int64(data.count)
    )
    return RemoteVoiceExportItem(
      fileURL: fileURL,
      validation: RemoteVoiceValidationResult(
        format: .mp3,
        byteCount: Int64(data.count),
        duration: 1
      ),
      lease: lease
    )
  }

  private func terminalState(
    for outcome: RemoteVoiceExportOutcome,
    request: RemoteVoiceExportRequest
  ) -> RemoteVoiceExportViewModel.State {
    switch outcome {
    case .shared:
      .shared(request)
    case .savedToFiles:
      .savedToFiles(request)
    case .cancelled:
      .idle
    case .failed(let message):
      .failed(request, message)
    }
  }

  private func completedState(
    for outcome: RemoteVoiceExportOutcome,
    request: RemoteVoiceExportRequest
  ) -> RemoteVoiceExportViewModel.State {
    switch outcome {
    case .shared, .cancelled:
      .idle
    case .savedToFiles:
      .savedToFiles(request)
    case .failed(let message):
      .failed(request, message)
    }
  }

  private func completedNotice(
    for outcome: RemoteVoiceExportOutcome,
    request: RemoteVoiceExportRequest
  ) -> RemoteVoiceExportViewModel.Notice? {
    switch outcome {
    case .shared, .cancelled:
      nil
    case .savedToFiles:
      .savedToFiles(request)
    case .failed(let message):
      .failed(request, message)
    }
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

  private static let silentMP3Base64 = [
    "SUQzBAAAAAAAI1RTU0UAAAAPAAADTGF2ZjU4Ljc2LjEwMAAAAAAAAAAAAAAA/+M4xAAAAANIAAAAAExBTUUzLjEwMFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+M4xDQAAANI",
    "AAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    "VVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+M4xDQAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    "VVVVVVVVVVVVVVVVVVVVVVVV/+M4xDQAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4xMDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+M4xDQAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVMQU1FMy4x",
    "MDBVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV/+M4xDQAAANIAAAAAFVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
    "VVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVVV",
  ].joined()
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
  private var item: RemoteVoiceExportItem?
  private let error: RemoteVoiceExportTestError?
  private var sourceURLs: [URL] = []

  init(
    item: RemoteVoiceExportItem? = nil,
    error: RemoteVoiceExportTestError? = nil
  ) {
    self.item = item
    self.error = error
  }

  func prepareForExport(from sourceURL: URL) async throws -> RemoteVoiceExportItem {
    sourceURLs.append(sourceURL)
    if let error { throw error }
    guard let item else {
      throw RemoteVoiceExportTestError(message: "missing export item")
    }
    self.item = nil
    return item
  }

  func requestCount() -> Int { sourceURLs.count }
}

private actor RemoteVoiceSuspendingExportingSpy: RemoteVoiceExporting {
  private var sourceURLs: [URL] = []
  private var continuations:
    [CheckedContinuation<RemoteVoiceExportItem, any Error>?] = []

  func prepareForExport(from sourceURL: URL) async throws -> RemoteVoiceExportItem {
    sourceURLs.append(sourceURL)
    return try await withCheckedThrowingContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func requestCount() -> Int { sourceURLs.count }

  func resumeRequest(at index: Int, with item: RemoteVoiceExportItem) {
    guard continuations.indices.contains(index), let continuation = continuations[index] else {
      return
    }
    continuations[index] = nil
    continuation.resume(returning: item)
  }
}

@MainActor
private final class RemoteVoiceExportCompletionProbe {
  let directory: URL
  private(set) var requests: [RemoteVoiceExportRequest] = []
  private(set) var outcomes: [RemoteVoiceExportOutcome] = []
  private(set) var fileExistenceDuringCallbacks: [Bool] = []

  init(directory: URL) {
    self.directory = directory
  }

  func record(request: RemoteVoiceExportRequest, outcome: RemoteVoiceExportOutcome) {
    requests.append(request)
    outcomes.append(outcome)
    fileExistenceDuringCallbacks.append(
      FileManager.default.fileExists(atPath: directory.path)
    )
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

@MainActor
private func waitForRemoteVoiceExportTest(
  timeout: TimeInterval = 2,
  condition: @escaping @MainActor () async -> Bool
) async throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !(await condition()) {
    guard Date() < deadline else {
      XCTFail("Timed out waiting for remote-voice export state")
      return
    }
    await Task.yield()
  }
}
