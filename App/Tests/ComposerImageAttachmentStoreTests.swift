import CryptoKit
import Darwin
import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest

@testable import TiebaPlusPlus

@MainActor
final class ComposerImageAttachmentStoreTests: XCTestCase {
  func testImportFromTemporaryURLStoresOnlyPrivateMetadataAndValidatedData() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let sourceURL = environment.rootURL.appendingPathComponent(
      "secret-filename-location-asset-identifier.png"
    )
    let sourceData = try imageData(width: 80, height: 40)
    try sourceData.write(to: sourceURL)
    let store = environment.makeStore()
    let id = UUID()

    let attachment = try await store.importImage(
      at: sourceURL,
      quality: .standard,
      id: id
    )
    let storedData = try await store.validatedData(for: attachment)

    XCTAssertEqual(
      attachment.relativePrivateFilename,
      "\(id.uuidString.lowercased()).jpg"
    )
    XCTAssertFalse(attachment.relativePrivateFilename.contains("secret"))
    XCTAssertEqual(attachment.sha256, sha256(of: storedData))
    XCTAssertEqual(attachment.byteCount, Int64(storedData.count))
    XCTAssertEqual(attachment.pixelWidth, 80)
    XCTAssertEqual(attachment.pixelHeight, 40)
    XCTAssertEqual(attachment.encoding, .jpeg)
    XCTAssertNotEqual(storedData, sourceData)

    let storedURL = environment.storeURL.appendingPathComponent(
      attachment.relativePrivateFilename
    )
    XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path))
    XCTAssertEqual(
      try storedURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
      true
    )
    XCTAssertEqual(
      try environment.storeURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        .isExcludedFromBackup,
      true
    )
    #if os(iOS)
      let attributes = try FileManager.default.attributesOfItem(atPath: storedURL.path)
      let protection = attributes[.protectionKey] as? FileProtectionType
      #if targetEnvironment(simulator)
        if let protection {
          XCTAssertEqual(protection, .complete)
        }
      #else
        XCTAssertEqual(protection, .complete)
      #endif
    #endif
  }

  func testImportFromDataRoundTripsStrictCodableMetadata() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let store = environment.makeStore()

    let attachment = try await store.importImage(
      data: imageData(width: 64, height: 32),
      quality: .highQuality
    )
    let encoded = try JSONEncoder().encode(attachment)
    let decoded = try JSONDecoder().decode(ComposerImageAttachment.self, from: encoded)
    let validatedData = try await store.validatedData(for: decoded)

    XCTAssertEqual(decoded, attachment)
    XCTAssertEqual(validatedData.count, Int(decoded.byteCount))
  }

  func testAttachmentInitializerAndDecoderRejectMaliciousRelativePaths() throws {
    let id = UUID()
    let digest = String(repeating: "a", count: 64)
    XCTAssertNil(
      ComposerImageAttachment(
        id: id,
        relativePrivateFilename: "../outside.jpg",
        sha256: digest,
        byteCount: 100,
        pixelWidth: 10,
        pixelHeight: 10,
        encoding: .jpeg,
        quality: .standard
      )
    )
    XCTAssertNil(
      ComposerImageAttachment(
        id: id,
        relativePrivateFilename: "folder\\outside.jpg",
        sha256: digest,
        byteCount: 100,
        pixelWidth: 10,
        pixelHeight: 10,
        encoding: .jpeg,
        quality: .standard
      )
    )
    XCTAssertNil(
      ComposerImageAttachment(
        id: id,
        sha256: digest.uppercased(),
        byteCount: 100,
        pixelWidth: 10,
        pixelHeight: 10,
        quality: .standard
      )
    )
    XCTAssertNil(
      ComposerImageAttachment(
        id: id,
        sha256: digest,
        byteCount: ComposerImageAttachmentQuality.standard.maximumByteCount + 1,
        pixelWidth: 10,
        pixelHeight: 10,
        quality: .standard
      )
    )
    XCTAssertNil(
      ComposerImageAttachment(
        id: id,
        sha256: digest,
        byteCount: 100,
        pixelWidth: ComposerImageAttachmentQuality.standard.maximumPixelSize + 1,
        pixelHeight: 10,
        quality: .standard
      )
    )

    let valid = try XCTUnwrap(
      ComposerImageAttachment(
        id: id,
        sha256: digest,
        byteCount: 100,
        pixelWidth: 10,
        pixelHeight: 10,
        quality: .standard
      )
    )
    var object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any]
    )
    object["relativePrivateFilename"] = "../../outside.jpg"
    let malicious = try JSONSerialization.data(withJSONObject: object)

    XCTAssertThrowsError(
      try JSONDecoder().decode(ComposerImageAttachment.self, from: malicious)
    )
  }

  func testValidatedDataRejectsSizeHashDimensionAndDecodeTampering() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let store = environment.makeStore()
    let attachment = try await store.importImage(
      data: imageData(width: 60, height: 30),
      quality: .standard
    )
    let storedURL = environment.storeURL.appendingPathComponent(
      attachment.relativePrivateFilename
    )
    let originalData = try Data(contentsOf: storedURL)

    var modifiedHash = attachment.sha256
    modifiedHash.replaceSubrange(
      modifiedHash.startIndex...modifiedHash.startIndex,
      with: attachment.sha256.hasPrefix("a") ? "b" : "a"
    )
    let wrongHash = try XCTUnwrap(
      ComposerImageAttachment(
        id: attachment.id,
        sha256: modifiedHash,
        byteCount: attachment.byteCount,
        pixelWidth: attachment.pixelWidth,
        pixelHeight: attachment.pixelHeight,
        quality: attachment.quality
      )
    )
    await assertStoredFileTampered(store: store, attachment: wrongHash)

    let wrongDimensions = try XCTUnwrap(
      ComposerImageAttachment(
        id: attachment.id,
        sha256: attachment.sha256,
        byteCount: attachment.byteCount,
        pixelWidth: attachment.pixelWidth - 1,
        pixelHeight: attachment.pixelHeight,
        quality: attachment.quality
      )
    )
    await assertStoredFileTampered(store: store, attachment: wrongDimensions)

    try Data(originalData.dropLast()).write(to: storedURL)
    await assertStoredFileTampered(store: store, attachment: attachment)

    try originalData.write(to: storedURL)
    var corrupted = originalData
    corrupted[corrupted.startIndex] ^= 0xFF
    try corrupted.write(to: storedURL)
    await assertStoredFileTampered(store: store, attachment: attachment)
  }

  func testMissingStoredFileIsReportedSeparately() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let store = environment.makeStore()
    let attachment = try await store.importImage(
      data: imageData(width: 20, height: 10),
      quality: .standard
    )
    try FileManager.default.removeItem(
      at: environment.storeURL.appendingPathComponent(attachment.relativePrivateFilename)
    )

    do {
      _ = try await store.validatedData(for: attachment)
      XCTFail("Expected a missing-file error.")
    } catch {
      XCTAssertEqual(error as? ComposerImageAttachmentStoreError, .storedFileMissing)
    }
  }

  func testValidatedDataRejectsAHashMatchingJPEGWithPrivateMetadata() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let store = environment.makeStore()
    let id = UUID()
    let data = try jpegDataWithPrivateMetadata(width: 20, height: 10)
    let attachment = try XCTUnwrap(
      ComposerImageAttachment(
        id: id,
        sha256: sha256(of: data),
        byteCount: Int64(data.count),
        pixelWidth: 20,
        pixelHeight: 10,
        quality: .standard
      )
    )
    try data.write(
      to: environment.storeURL.appendingPathComponent(attachment.relativePrivateFilename)
    )

    await assertStoredFileTampered(store: store, attachment: attachment)
  }

  func testPreparationFailureLeavesNoPublishedOrStagedFile() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let store = environment.makeStore(
      prepareStagedFile: { _ in throw StoreTestFailure.injected }
    )

    do {
      _ = try await store.importImage(
        data: imageData(width: 20, height: 10),
        quality: .standard
      )
      XCTFail("Expected injected preparation failure.")
    } catch {
      XCTAssertEqual(error as? ComposerImageAttachmentStoreError, .storageUnavailable)
    }

    XCTAssertEqual(try directoryChildren(at: environment.storeURL), [])
  }

  func testCancellationBeforePublicationLeavesNoPublishedOrStagedFile() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let gate = StoreAsyncGate()
    let store = environment.makeStore(beforePublication: { await gate.wait() })
    let input = try imageData(width: 20, height: 10)
    let task = Task {
      try await store.importImage(data: input, quality: .standard)
    }
    let didEnterPublicationGate = await gate.waitUntilEntered()
    XCTAssertTrue(didEnterPublicationGate)

    task.cancel()
    await gate.open()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation.")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
    XCTAssertEqual(try directoryChildren(at: environment.storeURL), [])
  }

  func testQueuedImportCancellationReturnsBeforePermitAndReleasesStableID() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let gate = StoreAsyncGate()
    let probe = ProcessingConcurrencyProbe()
    let store = environment.makeStore(
      beforePublication: { await gate.wait() },
      processingDidStart: { probe.enterAndBrieflyHold() },
      processingDidFinish: { probe.leave() }
    )
    let input = try imageData(width: 40, height: 20)
    let firstTask = Task {
      try await store.importImage(data: input, quality: .standard)
    }
    guard await gate.waitUntilEntered() else {
      firstTask.cancel()
      await gate.open()
      _ = try? await firstTask.value
      XCTFail("The first import did not acquire the processing permit.")
      return
    }

    let stableID = UUID()
    let cancellationOutcome = AsyncTaskOutcomeRecorder()
    let cancelledTask = Task {
      do {
        _ = try await store.importImage(
          data: input,
          quality: .standard,
          id: stableID
        )
        await cancellationOutcome.record(.success)
      } catch is CancellationError {
        await cancellationOutcome.record(.cancelled)
      } catch {
        await cancellationOutcome.record(.otherError)
      }
    }
    guard await waitForProcessingWaiter(in: store) else {
      cancelledTask.cancel()
      await gate.open()
      _ = try? await firstTask.value
      await cancelledTask.value
      XCTFail("The second import did not enter the limiter queue.")
      return
    }
    cancelledTask.cancel()

    let cancelledBeforePermitRelease = await waitForOutcome(cancellationOutcome)
    guard cancelledBeforePermitRelease else {
      await gate.open()
      _ = try? await firstTask.value
      await cancelledTask.value
      XCTFail("Queued cancellation waited for the current processing operation.")
      return
    }
    let queuedImportOutcome = await cancellationOutcome.value()
    XCTAssertEqual(queuedImportOutcome, .cancelled)
    let importWaiterCountAfterCancellation = await store.processingWaiterCountForTesting()
    XCTAssertEqual(importWaiterCountAfterCancellation, 0)
    XCTAssertEqual(probe.started, 1)

    let replacementTask = Task {
      try await store.importImage(
        data: input,
        quality: .standard,
        id: stableID
      )
    }
    guard await waitForProcessingWaiter(in: store) else {
      replacementTask.cancel()
      await gate.open()
      _ = try? await firstTask.value
      _ = try? await replacementTask.value
      XCTFail("The replacement import did not reuse the released stable ID.")
      return
    }
    XCTAssertEqual(probe.started, 1)

    await gate.open()
    _ = try await firstTask.value
    _ = try await replacementTask.value
    await cancelledTask.value
    XCTAssertEqual(probe.peak, 1)
    XCTAssertEqual(probe.active, 0)
    XCTAssertEqual(probe.started, 2)
  }

  func testQueuedValidatedDataCancellationReturnsBeforeCurrentImport() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let input = try imageData(width: 40, height: 20)
    let setupStore = environment.makeStore()
    let existingAttachment = try await setupStore.importImage(
      data: input,
      quality: .standard
    )
    let gate = StoreAsyncGate()
    let store = environment.makeStore(beforePublication: { await gate.wait() })
    let blockingImport = Task {
      try await store.importImage(data: input, quality: .standard)
    }
    guard await gate.waitUntilEntered() else {
      blockingImport.cancel()
      await gate.open()
      _ = try? await blockingImport.value
      XCTFail("The blocking import did not acquire the processing permit.")
      return
    }

    let cancellationOutcome = AsyncTaskOutcomeRecorder()
    let validationTask = Task {
      do {
        _ = try await store.validatedData(for: existingAttachment)
        await cancellationOutcome.record(.success)
      } catch is CancellationError {
        await cancellationOutcome.record(.cancelled)
      } catch {
        await cancellationOutcome.record(.otherError)
      }
    }
    guard await waitForProcessingWaiter(in: store) else {
      validationTask.cancel()
      await gate.open()
      _ = try? await blockingImport.value
      await validationTask.value
      XCTFail("Stored-data validation did not enter the limiter queue.")
      return
    }
    validationTask.cancel()

    let cancelledBeforePermitRelease = await waitForOutcome(cancellationOutcome)
    guard cancelledBeforePermitRelease else {
      await gate.open()
      _ = try? await blockingImport.value
      await validationTask.value
      XCTFail("Queued validation cancellation waited for the current import.")
      return
    }
    let queuedValidationOutcome = await cancellationOutcome.value()
    XCTAssertEqual(queuedValidationOutcome, .cancelled)
    let validationWaiterCountAfterCancellation =
      await store.processingWaiterCountForTesting()
    XCTAssertEqual(validationWaiterCountAfterCancellation, 0)

    await gate.open()
    _ = try await blockingImport.value
    await validationTask.value
    let validated = try await store.validatedData(for: existingAttachment)
    XCTAssertEqual(sha256(of: validated), existingAttachment.sha256)
  }

  func testValidatedDataCancellationDuringDecodeNeverReturnsDataOrLeaksPermit() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let input = try imageData(width: 80, height: 40)
    let setupStore = environment.makeStore()
    let attachment = try await setupStore.importImage(
      data: input,
      quality: .standard
    )
    let decodeGate = SynchronousDecodeGate()
    let processor = ComposerImageAttachmentProcessor {
      decodeGate.blockUntilOpen()
    }
    let store = environment.makeStore(processor: processor)
    let outcome = AsyncTaskOutcomeRecorder()
    let validationTask = Task {
      do {
        _ = try await store.validatedData(for: attachment)
        await outcome.record(.success)
      } catch is CancellationError {
        await outcome.record(.cancelled)
      } catch {
        await outcome.record(.otherError)
      }
    }
    guard await waitForDecodeGate(decodeGate) else {
      validationTask.cancel()
      decodeGate.open()
      await validationTask.value
      XCTFail("Stored JPEG validation did not reach the full-decode boundary.")
      return
    }

    validationTask.cancel()
    decodeGate.open()
    await validationTask.value
    let validationOutcome = await outcome.value()
    XCTAssertEqual(validationOutcome, .cancelled)

    let validated = try await store.validatedData(for: attachment)
    XCTAssertEqual(sha256(of: validated), attachment.sha256)
  }

  func testDuplicateStableIDNeverOverwritesExistingFile() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let store = environment.makeStore()
    let id = UUID()
    let first = try await store.importImage(
      data: imageData(width: 30, height: 15, color: .systemBlue),
      quality: .standard,
      id: id
    )
    let original = try await store.validatedData(for: first)

    do {
      _ = try await store.importImage(
        data: imageData(width: 30, height: 15, color: .systemRed),
        quality: .standard,
        id: id
      )
      XCTFail("Expected duplicate attachment ID rejection.")
    } catch {
      XCTAssertEqual(error as? ComposerImageAttachmentStoreError, .attachmentAlreadyExists)
    }
    let retained = try await store.validatedData(for: first)
    XCTAssertEqual(retained, original)
  }

  func testConcurrentImportsNeverExceedOneProcessingOperation() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let probe = ProcessingConcurrencyProbe()
    let store = environment.makeStore(
      processingDidStart: { probe.enterAndBrieflyHold() },
      processingDidFinish: { probe.leave() }
    )
    let firstInput = try imageData(width: 320, height: 160, color: .systemBlue)
    let secondInput = try imageData(width: 320, height: 160, color: .systemRed)

    async let first = store.importImage(data: firstInput, quality: .standard)
    async let second = store.importImage(data: secondInput, quality: .standard)
    _ = try await (first, second)

    XCTAssertEqual(probe.peak, 1)
    XCTAssertEqual(probe.active, 0)
    XCTAssertEqual(probe.started, 2)
  }

  func testRemoveDeletesOnlyPrivateFileAndNeverFollowsSymlink() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let store = environment.makeStore()
    let attachment = try await store.importImage(
      data: imageData(width: 20, height: 10),
      quality: .standard
    )
    let storedURL = environment.storeURL.appendingPathComponent(
      attachment.relativePrivateFilename
    )
    try FileManager.default.removeItem(at: storedURL)
    let outsideURL = environment.rootURL.appendingPathComponent("outside-must-survive")
    let outsideData = Data("outside".utf8)
    try outsideData.write(to: outsideURL)
    try FileManager.default.createSymbolicLink(
      at: storedURL,
      withDestinationURL: outsideURL
    )

    try await store.remove(attachment)

    XCTAssertFalse(FileManager.default.fileExists(atPath: storedURL.path))
    XCTAssertEqual(try Data(contentsOf: outsideURL), outsideData)
  }

  func testSymlinkStorageRootIsRejectedWithoutWritingThroughIt() async throws {
    let environment = try StoreTestEnvironment(createsStoreDirectory: false)
    defer { environment.remove() }
    let outsideURL = environment.rootURL.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: environment.storeURL,
      withDestinationURL: outsideURL
    )
    let store = environment.makeStore()

    do {
      _ = try await store.importImage(
        data: imageData(width: 20, height: 10),
        quality: .standard
      )
      XCTFail("Expected unsafe storage root rejection.")
    } catch {
      XCTAssertEqual(error as? ComposerImageAttachmentStoreError, .unsafeStorageDirectory)
    }
    XCTAssertEqual(try directoryChildren(at: outsideURL), [])
  }

  func testValidatedDataRejectsFIFOWithoutBlocking() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let store = environment.makeStore()
    let attachment = try await store.importImage(
      data: imageData(width: 20, height: 10),
      quality: .standard
    )
    let storedURL = environment.storeURL.appendingPathComponent(
      attachment.relativePrivateFilename
    )
    try FileManager.default.removeItem(at: storedURL)
    let result = storedURL.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.mkfifo(path, mode_t(S_IRUSR | S_IWUSR))
    }
    XCTAssertEqual(result, 0)

    await assertStoredFileTampered(store: store, attachment: attachment)
  }

  func testAncestorSymlinkBelowTrustedRootIsRejected() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerImageAttachmentAncestorTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let trustedRoot = root.appendingPathComponent("trusted", isDirectory: true)
    let outside = root.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: trustedRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let alias = trustedRoot.appendingPathComponent("alias", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
    let store = ComposerImageAttachmentStore(
      directoryURL: alias.appendingPathComponent("attachments", isDirectory: true),
      trustedRootURL: trustedRoot
    )

    do {
      _ = try await store.importImage(
        data: imageData(width: 20, height: 10),
        quality: .standard
      )
      XCTFail("Expected an unsafe ancestor rejection.")
    } catch {
      XCTAssertEqual(error as? ComposerImageAttachmentStoreError, .unsafeStorageDirectory)
    }
    XCTAssertEqual(try directoryChildren(at: outside), [])
  }

  func testEnsureRemovesOldStagingInBoundedBatchesButPreservesUUIDJPEGs() async throws {
    let environment = try StoreTestEnvironment()
    defer { environment.remove() }
    let oldDate = Date().addingTimeInterval(-48 * 60 * 60)
    for index in 0..<40 {
      let stagedURL = environment.storeURL.appendingPathComponent(
        String(format: ".staged-old-%02d", index)
      )
      try Data("stale".utf8).write(to: stagedURL)
      try FileManager.default.setAttributes(
        [.modificationDate: oldDate],
        ofItemAtPath: stagedURL.path
      )
    }
    let orphanFilename = "\(UUID().uuidString.lowercased()).jpg"
    let orphanURL = environment.storeURL.appendingPathComponent(orphanFilename)
    let orphanData = Data("draft-manifest-owns-this-file".utf8)
    try orphanData.write(to: orphanURL)
    let store = environment.makeStore()

    let attachment = try await store.importImage(
      data: imageData(width: 20, height: 10),
      quality: .standard
    )
    let afterFirstEnsure = try directoryChildren(at: environment.storeURL)
      .filter { $0.hasPrefix(".staged-") }
    XCTAssertEqual(afterFirstEnsure.count, 8)
    XCTAssertEqual(try Data(contentsOf: orphanURL), orphanData)

    _ = try await store.validatedData(for: attachment)
    let afterSecondEnsure = try directoryChildren(at: environment.storeURL)
      .filter { $0.hasPrefix(".staged-") }
    XCTAssertEqual(afterSecondEnsure, [])
    XCTAssertEqual(try Data(contentsOf: orphanURL), orphanData)
  }

  private func assertStoredFileTampered(
    store: ComposerImageAttachmentStore,
    attachment: ComposerImageAttachment,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await store.validatedData(for: attachment)
      XCTFail("Expected stored-file tampering rejection.", file: file, line: line)
    } catch {
      XCTAssertEqual(
        error as? ComposerImageAttachmentStoreError,
        .storedFileTampered,
        file: file,
        line: line
      )
    }
  }

  private func waitForOutcome(
    _ recorder: AsyncTaskOutcomeRecorder,
    timeout: Duration = .seconds(1)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await recorder.isCompleted()), clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(10))
      } catch {
        return false
      }
    }
    return await recorder.isCompleted()
  }

  private func waitForDecodeGate(
    _ gate: SynchronousDecodeGate,
    timeout: Duration = .seconds(1)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !gate.hasEntered, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(10))
      } catch {
        return false
      }
    }
    return gate.hasEntered
  }

  private func waitForProcessingWaiter(
    in store: ComposerImageAttachmentStore,
    timeout: Duration = .seconds(1)
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await store.processingWaiterCountForTesting() == 0, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(10))
      } catch {
        return false
      }
    }
    return await store.processingWaiterCountForTesting() > 0
  }

  private func imageData(
    width: Int,
    height: Int,
    color: UIColor = .systemBlue
  ) throws -> Data {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: CGFloat(width), height: CGFloat(height)),
      format: format
    ).image { context in
      color.setFill()
      context.fill(
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
      )
    }
    return try XCTUnwrap(image.pngData())
  }

  private func jpegDataWithPrivateMetadata(width: Int, height: Int) throws -> Data {
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(
      size: CGSize(width: CGFloat(width), height: CGFloat(height)),
      format: format
    ).image { context in
      UIColor.systemBlue.setFill()
      context.fill(
        CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
      )
    }
    let data = NSMutableData()
    let destination = try XCTUnwrap(
      CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    )
    let privateMetadata: [CFString: Any] = [
      kCGImagePropertyGPSDictionary: [
        kCGImagePropertyGPSLatitudeRef: "N",
        kCGImagePropertyGPSLatitude: 31.2304,
      ],
      kCGImagePropertyExifDictionary: [
        kCGImagePropertyExifUserComment: "private-comment"
      ],
    ]
    CGImageDestinationAddImage(
      destination,
      try XCTUnwrap(image.cgImage),
      privateMetadata as CFDictionary
    )
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let result = data as Data
    let source = try XCTUnwrap(CGImageSourceCreateWithData(result as CFData, nil))
    let properties = try XCTUnwrap(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
    XCTAssertNotNil(properties[kCGImagePropertyGPSDictionary])
    return result
  }

  private func sha256(of data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  private func directoryChildren(at url: URL) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
  }
}

private struct StoreTestEnvironment {
  let rootURL: URL
  let storeURL: URL

  init(createsStoreDirectory: Bool = true) throws {
    rootURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComposerImageAttachmentStoreTests", isDirectory: true)
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    storeURL = rootURL.appendingPathComponent("attachments", isDirectory: true)
    try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    if createsStoreDirectory {
      try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
    }
  }

  func makeStore(
    processor: ComposerImageAttachmentProcessor = .init(),
    prepareStagedFile: (@Sendable (URL) throws -> Void)? = nil,
    beforePublication: (@Sendable () async -> Void)? = nil,
    processingDidStart: @escaping @Sendable () -> Void = {},
    processingDidFinish: @escaping @Sendable () -> Void = {}
  ) -> ComposerImageAttachmentStore {
    ComposerImageAttachmentStore(
      directoryURL: storeURL,
      trustedRootURL: rootURL,
      processor: processor,
      prepareStagedFile: prepareStagedFile,
      beforePublication: beforePublication,
      processingDidStart: processingDidStart,
      processingDidFinish: processingDidFinish
    )
  }

  func remove() {
    try? FileManager.default.removeItem(at: rootURL)
  }
}

private enum StoreTestFailure: Error {
  case injected
}

private actor StoreAsyncGate {
  private var continuation: CheckedContinuation<Void, Never>?
  private var isOpen = false

  func wait() async {
    await withCheckedContinuation { continuation in
      if isOpen {
        continuation.resume()
      } else {
        self.continuation = continuation
      }
    }
  }

  func waitUntilEntered(timeout: Duration = .seconds(2)) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while continuation == nil, !isOpen, clock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(10))
      } catch {
        return false
      }
    }
    return continuation != nil || isOpen
  }

  func open() {
    isOpen = true
    continuation?.resume()
    continuation = nil
  }
}

private enum AsyncTaskOutcome: Equatable, Sendable {
  case success
  case cancelled
  case otherError
}

private actor AsyncTaskOutcomeRecorder {
  private var outcome: AsyncTaskOutcome?

  func record(_ outcome: AsyncTaskOutcome) {
    guard self.outcome == nil else { return }
    self.outcome = outcome
  }

  func value() -> AsyncTaskOutcome? {
    outcome
  }

  func isCompleted() -> Bool {
    outcome != nil
  }
}

private final class SynchronousDecodeGate: @unchecked Sendable {
  private let condition = NSCondition()
  private var entered = false
  private var openState = false

  var hasEntered: Bool {
    condition.withLock { entered }
  }

  func blockUntilOpen() {
    condition.lock()
    entered = true
    condition.broadcast()
    while !openState {
      condition.wait()
    }
    condition.unlock()
  }

  func open() {
    condition.withLock {
      openState = true
      condition.broadcast()
    }
  }
}

private final class ProcessingConcurrencyProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var activeCount = 0
  private var peakCount = 0
  private var startedCount = 0

  var active: Int {
    lock.withLock { activeCount }
  }

  var peak: Int {
    lock.withLock { peakCount }
  }

  var started: Int {
    lock.withLock { startedCount }
  }

  func enterAndBrieflyHold() {
    lock.withLock {
      activeCount += 1
      startedCount += 1
      peakCount = max(peakCount, activeCount)
    }
    usleep(100_000)
  }

  func leave() {
    lock.withLock { activeCount -= 1 }
  }
}
