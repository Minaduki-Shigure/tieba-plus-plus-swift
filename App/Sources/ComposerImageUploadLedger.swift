import CryptoKit
import Darwin
import Foundation
import TiebaCore

enum ComposerImageUploadContext:
  Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  case newThread(forumID: Int64, forumName: String)
  case directTopicReply(
    forumID: Int64,
    forumName: String,
    threadID: Int64,
    firstPostID: Int64
  )

  init?(newThread target: NewThreadTarget) {
    guard target.isValid else { return nil }
    self = .newThread(forumID: target.forumID, forumName: target.forumName)
  }

  init?(directTopicReply target: TextReplyTarget) {
    guard
      case .thread(let destinationFirstPostID) = target.destination,
      destinationFirstPostID == target.firstPostID
    else { return nil }
    let candidate = Self.directTopicReply(
      forumID: target.forumID,
      forumName: target.forumName,
      threadID: target.threadID,
      firstPostID: target.firstPostID
    )
    guard candidate.isValid else { return nil }
    self = candidate
  }

  var forumID: Int64 {
    switch self {
    case .newThread(let forumID, _), .directTopicReply(let forumID, _, _, _):
      forumID
    }
  }

  var forumName: String {
    switch self {
    case .newThread(_, let forumName), .directTopicReply(_, let forumName, _, _):
      forumName
    }
  }

  var description: String {
    switch self {
    case .newThread:
      "ComposerImageUploadContext.newThread(redacted)"
    case .directTopicReply:
      "ComposerImageUploadContext.directTopicReply(redacted)"
    }
  }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }

  fileprivate var isValid: Bool {
    guard
      forumID > 0,
      Self.isValidNormalizedForumName(forumName)
    else { return false }
    switch self {
    case .newThread:
      return true
    case .directTopicReply(_, _, let threadID, let firstPostID):
      return threadID > 0 && firstPostID > 0
    }
  }

  private enum CodingKeys: String, CodingKey {
    case kind
    case forumID
    case forumName
    case threadID
    case firstPostID
  }

  private enum Kind: String, Codable {
    case newThread
    case directTopicReply
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    let forumID = try container.decode(Int64.self, forKey: .forumID)
    let forumName = try container.decode(String.self, forKey: .forumName)
    switch kind {
    case .newThread:
      self = .newThread(forumID: forumID, forumName: forumName)
    case .directTopicReply:
      self = .directTopicReply(
        forumID: forumID,
        forumName: forumName,
        threadID: try container.decode(Int64.self, forKey: .threadID),
        firstPostID: try container.decode(Int64.self, forKey: .firstPostID)
      )
    }
    guard isValid else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid upload context.")
      )
    }
  }

  func encode(to encoder: any Encoder) throws {
    guard isValid else {
      throw EncodingError.invalidValue(
        self,
        .init(codingPath: encoder.codingPath, debugDescription: "Invalid upload context.")
      )
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(forumID, forKey: .forumID)
    try container.encode(forumName, forKey: .forumName)
    switch self {
    case .newThread:
      try container.encode(Kind.newThread, forKey: .kind)
    case .directTopicReply(_, _, let threadID, let firstPostID):
      try container.encode(Kind.directTopicReply, forKey: .kind)
      try container.encode(threadID, forKey: .threadID)
      try container.encode(firstPostID, forKey: .firstPostID)
    }
  }

  private static func isValidNormalizedForumName(_ value: String) -> Bool {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
      .precomposedStringWithCanonicalMapping
    return
      !value.isEmpty
      && value.count <= 100
      && value.utf8.count <= TiebaStaticImageUploadPolicy.maximumForumNameUTF8Bytes
      && value.utf8.elementsEqual(normalized.utf8)
      && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
  }
}

private struct ComposerImageUploadLedgerAnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    self.intValue = nil
  }

  init?(intValue: Int) {
    self.stringValue = String(intValue)
    self.intValue = intValue
  }
}

struct ComposerImageUploadLedgerKey:
  Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let context: ComposerImageUploadContext
  let userID: Int64
  let sessionRevision: UUID
  let submissionID: UUID

  init?(
    context: ComposerImageUploadContext,
    userID: Int64,
    sessionRevision: UUID,
    submissionID: UUID
  ) {
    guard context.isValid, userID > 0 else { return nil }
    self.context = context
    self.userID = userID
    self.sessionRevision = sessionRevision
    self.submissionID = submissionID
  }

  var description: String { "ComposerImageUploadLedgerKey(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  private enum CodingKeys: CodingKey {
    case context
    case userID
    case sessionRevision
    case submissionID
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let validated = Self(
        context: try container.decode(ComposerImageUploadContext.self, forKey: .context),
        userID: try container.decode(Int64.self, forKey: .userID),
        sessionRevision: try container.decode(UUID.self, forKey: .sessionRevision),
        submissionID: try container.decode(UUID.self, forKey: .submissionID)
      )
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid upload identity.")
      )
    }
    self = validated
  }
}

struct ComposerImageUploadAttachmentSnapshot:
  Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let attachment: ComposerImageAttachment
  let watermark: TiebaStaticImageWatermark

  init?(
    attachment: ComposerImageAttachment,
    watermark: TiebaStaticImageWatermark = .forumName
  ) {
    guard Self.validatedAttachment(attachment) != nil else { return nil }
    self.attachment = attachment
    self.watermark = watermark
  }

  var id: UUID { attachment.id }
  var preservesOriginal: Bool { attachment.quality == .highQuality }
  var description: String { "ComposerImageUploadAttachmentSnapshot(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "id": attachment.id,
        "byteCount": attachment.byteCount,
        "pixelWidth": attachment.pixelWidth,
        "pixelHeight": attachment.pixelHeight,
        "preservesOriginal": preservesOriginal,
        "watermark": watermark,
      ],
      displayStyle: .struct
    )
  }

  private enum CodingKeys: CodingKey {
    case attachment
    case watermark
  }

  init(from decoder: any Decoder) throws {
    let allKeys = try decoder.container(keyedBy: ComposerImageUploadLedgerAnyCodingKey.self)
      .allKeys.map(\.stringValue)
    guard Set(allKeys) == Set(["attachment", "watermark"]) else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid upload snapshot.")
      )
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    guard
      let validated = Self(
        attachment: try container.decode(ComposerImageAttachment.self, forKey: .attachment),
        watermark: try container.decode(TiebaStaticImageWatermark.self, forKey: .watermark)
      )
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid upload snapshot.")
      )
    }
    self = validated
  }

  fileprivate func matches(
    receipt: TiebaStaticImageUploadReceipt,
    key: ComposerImageUploadLedgerKey
  ) -> Bool {
    receipt.schemaVersion == TiebaStaticImageUploadReceipt.currentSchemaVersion
      && receipt.uploadID == attachment.id
      && receipt.contentSHA256 == attachment.sha256
      && receipt.userID == key.userID
      && receipt.forumName == key.context.forumName
      && receipt.preservesOriginal == preservesOriginal
      && receipt.watermark == watermark
      && receipt.uploadedPixelWidth == attachment.pixelWidth
      && receipt.uploadedPixelHeight == attachment.pixelHeight
      && receipt.byteCount == Int(attachment.byteCount)
      && receipt.chunkCount
        == (Int(attachment.byteCount) - 1) / TiebaStaticImageUploadPolicy.chunkSize + 1
  }

  fileprivate func matches(
    upload: TiebaStaticImageUpload,
    forumName: String
  ) -> Bool {
    upload.uploadID == attachment.id
      && upload.forumName.trimmingCharacters(in: .whitespacesAndNewlines)
        .precomposedStringWithCanonicalMapping == forumName
      && upload.encodedBytes.count == Int(attachment.byteCount)
      && upload.pixelWidth == attachment.pixelWidth
      && upload.pixelHeight == attachment.pixelHeight
      && upload.preservesOriginal == preservesOriginal
      && upload.watermark == watermark
  }

  fileprivate static func validatedAttachment(
    _ attachment: ComposerImageAttachment
  ) -> ComposerImageAttachment? {
    ComposerImageAttachment(
      id: attachment.id,
      relativePrivateFilename: attachment.relativePrivateFilename,
      sha256: attachment.sha256,
      byteCount: attachment.byteCount,
      pixelWidth: attachment.pixelWidth,
      pixelHeight: attachment.pixelHeight,
      encoding: attachment.encoding,
      quality: attachment.quality
    )
  }

  fileprivate static func areValid(
    _ attachments: [ComposerImageUploadAttachmentSnapshot]
  ) -> Bool {
    guard (1...ComposerImageUploadLedger.maximumAttachments).contains(attachments.count) else {
      return false
    }
    var ids = Set<UUID>()
    var filenames = Set<String>()
    var contentDigests = Set<String>()
    return attachments.allSatisfy { snapshot in
      ComposerImageUploadAttachmentSnapshot(
        attachment: snapshot.attachment,
        watermark: snapshot.watermark
      ) != nil
        && ids.insert(snapshot.attachment.id).inserted
        && filenames.insert(snapshot.attachment.relativePrivateFilename).inserted
        && contentDigests.insert(snapshot.attachment.sha256).inserted
    }
  }
}

struct ComposerImageUploadIntentDigest:
  Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  private static let currentSchemaVersion = 1
  private static let digestByteCount = 32

  private let schemaVersion: Int
  private let digest: Data

  private init(digest: Data) {
    self.schemaVersion = Self.currentSchemaVersion
    self.digest = digest
  }

  var description: String { "ComposerImageUploadIntentDigest(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .struct) }

  private enum CodingKeys: CodingKey {
    case schemaVersion
    case digest
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    let digest = try container.decode(Data.self, forKey: .digest)
    guard
      schemaVersion == Self.currentSchemaVersion,
      digest.count == Self.digestByteCount
    else {
      throw DecodingError.dataCorrupted(
        .init(codingPath: decoder.codingPath, debugDescription: "Invalid submission intent digest.")
      )
    }
    self.schemaVersion = schemaVersion
    self.digest = digest
  }

  static func newThread(
    key: ComposerImageUploadLedgerKey,
    title: String?,
    content: String,
    attachmentSnapshots: [ComposerImageUploadAttachmentSnapshot]
  ) -> Self? {
    guard
      case .newThread = key.context,
      ComposerImageUploadAttachmentSnapshot.areValid(attachmentSnapshots)
    else { return nil }
    var canonical = ComposerImageUploadIntentCanonicalEncoder(
      domain: "TiebaPlusPlus/ComposerImageUploadIntent/NewThread/v1"
    )
    canonical.append(field: .key, bytes: canonicalKey(key))
    canonical.append(field: .titlePresence, boolean: title != nil)
    if let title {
      canonical.append(field: .title, string: title)
    }
    canonical.append(field: .content, string: content)
    append(attachmentSnapshots, to: &canonical)
    return Self(digest: Data(SHA256.hash(data: canonical.data)))
  }

  static func directTopicReply(
    key: ComposerImageUploadLedgerKey,
    content: String,
    attachmentSnapshots: [ComposerImageUploadAttachmentSnapshot]
  ) -> Self? {
    guard
      case .directTopicReply = key.context,
      ComposerImageUploadAttachmentSnapshot.areValid(attachmentSnapshots)
    else { return nil }
    var canonical = ComposerImageUploadIntentCanonicalEncoder(
      domain: "TiebaPlusPlus/ComposerImageUploadIntent/DirectTopicReply/v1"
    )
    canonical.append(field: .key, bytes: canonicalKey(key))
    canonical.append(field: .content, string: content)
    append(attachmentSnapshots, to: &canonical)
    return Self(digest: Data(SHA256.hash(data: canonical.data)))
  }

  fileprivate static func newThread(
    submission: NewThreadSubmission,
    key: ComposerImageUploadLedgerKey,
    attachmentSnapshots: [ComposerImageUploadAttachmentSnapshot]
  ) -> Self? {
    guard
      key.submissionID == submission.id,
      key.context == ComposerImageUploadContext(newThread: submission.target),
      attachmentSnapshots.map(\.attachment) == submission.attachments
    else { return nil }
    return newThread(
      key: key,
      title: submission.title,
      content: submission.content,
      attachmentSnapshots: attachmentSnapshots
    )
  }

  fileprivate static func directTopicReply(
    submission: TextReplySubmission,
    key: ComposerImageUploadLedgerKey,
    attachmentSnapshots: [ComposerImageUploadAttachmentSnapshot]
  ) -> Self? {
    guard
      key.submissionID == submission.id,
      key.context == ComposerImageUploadContext(directTopicReply: submission.target),
      attachmentSnapshots.map(\.attachment) == submission.attachments
    else { return nil }
    return directTopicReply(
      key: key,
      content: submission.content,
      attachmentSnapshots: attachmentSnapshots
    )
  }

  fileprivate var isValid: Bool {
    schemaVersion == Self.currentSchemaVersion && digest.count == Self.digestByteCount
  }

  private static func canonicalKey(_ key: ComposerImageUploadLedgerKey) -> Data {
    var canonical = ComposerImageUploadIntentCanonicalEncoder(
      domain: "TiebaPlusPlus/ComposerImageUploadIntent/Key/v1"
    )
    switch key.context {
    case .newThread(let forumID, let forumName):
      canonical.append(field: .contextKind, unsignedInteger: 1)
      canonical.append(field: .forumID, signedInteger: forumID)
      canonical.append(field: .forumName, string: forumName)
    case .directTopicReply(
      let forumID,
      let forumName,
      let threadID,
      let firstPostID
    ):
      canonical.append(field: .contextKind, unsignedInteger: 2)
      canonical.append(field: .forumID, signedInteger: forumID)
      canonical.append(field: .forumName, string: forumName)
      canonical.append(field: .threadID, signedInteger: threadID)
      canonical.append(field: .firstPostID, signedInteger: firstPostID)
    }
    canonical.append(field: .userID, signedInteger: key.userID)
    canonical.append(field: .sessionRevision, uuid: key.sessionRevision)
    canonical.append(field: .submissionID, uuid: key.submissionID)
    return canonical.data
  }

  private static func append(
    _ attachmentSnapshots: [ComposerImageUploadAttachmentSnapshot],
    to canonical: inout ComposerImageUploadIntentCanonicalEncoder
  ) {
    canonical.append(
      field: .attachmentCount,
      unsignedInteger: UInt64(attachmentSnapshots.count)
    )
    for snapshot in attachmentSnapshots {
      var attachment = ComposerImageUploadIntentCanonicalEncoder(
        domain: "TiebaPlusPlus/ComposerImageUploadIntent/Attachment/v1"
      )
      attachment.append(field: .attachmentID, uuid: snapshot.attachment.id)
      attachment.append(
        field: .relativePrivateFilename,
        string: snapshot.attachment.relativePrivateFilename
      )
      attachment.append(field: .contentSHA256, string: snapshot.attachment.sha256)
      attachment.append(
        field: .byteCount,
        signedInteger: snapshot.attachment.byteCount
      )
      attachment.append(
        field: .pixelWidth,
        signedInteger: Int64(snapshot.attachment.pixelWidth)
      )
      attachment.append(
        field: .pixelHeight,
        signedInteger: Int64(snapshot.attachment.pixelHeight)
      )
      attachment.append(field: .encoding, string: snapshot.attachment.encoding.rawValue)
      attachment.append(field: .quality, string: snapshot.attachment.quality.rawValue)
      attachment.append(
        field: .preservesOriginal,
        boolean: snapshot.preservesOriginal
      )
      attachment.append(field: .watermark, string: snapshot.watermark.rawValue)
      canonical.append(field: .attachment, bytes: attachment.data)
    }
  }
}

private struct ComposerImageUploadIntentCanonicalEncoder {
  enum Field: UInt8 {
    case key = 1
    case contextKind = 2
    case forumID = 3
    case forumName = 4
    case threadID = 5
    case firstPostID = 6
    case userID = 7
    case sessionRevision = 8
    case submissionID = 9
    case titlePresence = 10
    case title = 11
    case content = 12
    case attachmentCount = 13
    case attachment = 14
    case attachmentID = 15
    case relativePrivateFilename = 16
    case contentSHA256 = 17
    case byteCount = 18
    case pixelWidth = 19
    case pixelHeight = 20
    case encoding = 21
    case quality = 22
    case preservesOriginal = 23
    case watermark = 24
  }

  private(set) var data: Data

  init(domain: String) {
    self.data = Data()
    appendRaw(Data(domain.utf8))
  }

  mutating func append(field: Field, bytes: Data) {
    data.append(field.rawValue)
    appendRaw(bytes)
  }

  mutating func append(field: Field, string: String) {
    append(field: field, bytes: Data(string.utf8))
  }

  mutating func append(field: Field, boolean: Bool) {
    append(field: field, bytes: Data([boolean ? 1 : 0]))
  }

  mutating func append(field: Field, signedInteger: Int64) {
    var bigEndian = signedInteger.bigEndian
    append(
      field: field,
      bytes: withUnsafeBytes(of: &bigEndian) { Data($0) }
    )
  }

  mutating func append(field: Field, unsignedInteger: UInt64) {
    var bigEndian = unsignedInteger.bigEndian
    append(
      field: field,
      bytes: withUnsafeBytes(of: &bigEndian) { Data($0) }
    )
  }

  mutating func append(field: Field, uuid: UUID) {
    var bytes = uuid.uuid
    append(
      field: field,
      bytes: withUnsafeBytes(of: &bytes) { Data($0) }
    )
  }

  private mutating func appendRaw(_ bytes: Data) {
    var byteCount = UInt64(bytes.count).bigEndian
    withUnsafeBytes(of: &byteCount) { data.append(contentsOf: $0) }
    data.append(bytes)
  }
}

enum ComposerImageUploadLedgerStage:
  Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  case prepared
  case attachmentDispatchPending(nextAttachmentID: UUID)
  case uploadsComplete
  case finalSubmissionPending
  case outcomeUnknown
  case completed

  var blocksAutomaticResend: Bool {
    switch self {
    case .attachmentDispatchPending, .finalSubmissionPending, .outcomeUnknown, .completed:
      true
    case .prepared, .uploadsComplete:
      false
    }
  }

  var description: String {
    switch self {
    case .prepared:
      "prepared"
    case .attachmentDispatchPending:
      "attachmentDispatchPending(redacted)"
    case .uploadsComplete:
      "uploadsComplete"
    case .finalSubmissionPending:
      "finalSubmissionPending"
    case .outcomeUnknown:
      "outcomeUnknown"
    case .completed:
      "completed"
    }
  }
  var debugDescription: String { description }
  var customMirror: Mirror { Mirror(self, children: [:], displayStyle: .enum) }

  private enum CodingKeys: CodingKey {
    case kind
    case nextAttachmentID
  }

  private enum Kind: String, Codable {
    case prepared
    case attachmentDispatchPending
    case uploadsComplete
    case finalSubmissionPending
    case outcomeUnknown
    case completed
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .prepared:
      self = .prepared
    case .attachmentDispatchPending:
      self = .attachmentDispatchPending(
        nextAttachmentID: try container.decode(UUID.self, forKey: .nextAttachmentID)
      )
    case .uploadsComplete:
      self = .uploadsComplete
    case .finalSubmissionPending:
      self = .finalSubmissionPending
    case .outcomeUnknown:
      self = .outcomeUnknown
    case .completed:
      self = .completed
    }
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .prepared:
      try container.encode(Kind.prepared, forKey: .kind)
    case .attachmentDispatchPending(let nextAttachmentID):
      try container.encode(Kind.attachmentDispatchPending, forKey: .kind)
      try container.encode(nextAttachmentID, forKey: .nextAttachmentID)
    case .uploadsComplete:
      try container.encode(Kind.uploadsComplete, forKey: .kind)
    case .finalSubmissionPending:
      try container.encode(Kind.finalSubmissionPending, forKey: .kind)
    case .outcomeUnknown:
      try container.encode(Kind.outcomeUnknown, forKey: .kind)
    case .completed:
      try container.encode(Kind.completed, forKey: .kind)
    }
  }
}

enum ComposerImageUploadOutcomeUnknownOperation: Hashable, Sendable {
  case attachment(attachmentID: UUID)
  case finalSubmission
}

struct ComposerImageUploadLedgerRecord:
  Hashable, Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible,
  CustomReflectable
{
  let key: ComposerImageUploadLedgerKey
  let attachments: [ComposerImageUploadAttachmentSnapshot]
  let intentDigest: ComposerImageUploadIntentDigest
  let successfulReceiptPrefix: [TiebaStaticImageUploadReceipt]
  let stage: ComposerImageUploadLedgerStage

  var nextAttachment: ComposerImageUploadAttachmentSnapshot? {
    guard successfulReceiptPrefix.count < attachments.count else { return nil }
    return attachments[successfulReceiptPrefix.count]
  }

  var receipts: [TiebaStaticImageUploadReceipt] { successfulReceiptPrefix }

  var blocksAutomaticResend: Bool { stage.blocksAutomaticResend }

  var outcomeUnknownOperation: ComposerImageUploadOutcomeUnknownOperation? {
    guard stage == .outcomeUnknown else { return nil }
    if let nextAttachment {
      return .attachment(attachmentID: nextAttachment.id)
    }
    return .finalSubmission
  }

  func matchesIntent(
    newThreadSubmission submission: NewThreadSubmission,
    key candidateKey: ComposerImageUploadLedgerKey,
    attachmentSnapshots candidateAttachments: [ComposerImageUploadAttachmentSnapshot]
  ) -> Bool {
    guard
      candidateKey == key,
      candidateAttachments == attachments,
      let candidateDigest = ComposerImageUploadIntentDigest.newThread(
        submission: submission,
        key: candidateKey,
        attachmentSnapshots: candidateAttachments
      )
    else { return false }
    return candidateDigest == intentDigest
  }

  func matchesIntent(
    directTopicReplySubmission submission: TextReplySubmission,
    key candidateKey: ComposerImageUploadLedgerKey,
    attachmentSnapshots candidateAttachments: [ComposerImageUploadAttachmentSnapshot]
  ) -> Bool {
    guard
      candidateKey == key,
      candidateAttachments == attachments,
      let candidateDigest = ComposerImageUploadIntentDigest.directTopicReply(
        submission: submission,
        key: candidateKey,
        attachmentSnapshots: candidateAttachments
      )
    else { return false }
    return candidateDigest == intentDigest
  }

  var description: String { "ComposerImageUploadLedgerRecord(redacted)" }
  var debugDescription: String { description }
  var customMirror: Mirror {
    Mirror(
      self,
      children: [
        "attachmentCount": attachments.count,
        "successfulReceiptCount": successfulReceiptPrefix.count,
        "stage": stage,
      ],
      displayStyle: .struct
    )
  }

  fileprivate init(
    key: ComposerImageUploadLedgerKey,
    attachments: [ComposerImageUploadAttachmentSnapshot],
    intentDigest: ComposerImageUploadIntentDigest,
    successfulReceiptPrefix: [TiebaStaticImageUploadReceipt],
    stage: ComposerImageUploadLedgerStage
  ) {
    self.key = key
    self.attachments = attachments
    self.intentDigest = intentDigest
    self.successfulReceiptPrefix = successfulReceiptPrefix
    self.stage = stage
  }
}

enum ComposerImageUploadLedgerError: LocalizedError, Sendable, Equatable {
  case invalidIdentity
  case invalidAttachments
  case intentMismatch
  case recordAlreadyExists
  case recordNotFound
  case identityMismatch
  case invalidTransition
  case unexpectedAttachment
  case invalidReceipt
  case corruptedArchive
  case authenticationFailed
  case authenticationUnavailable
  case unsupportedSchemaVersion
  case archiveTooLarge
  case tooManyRecords
  case unsafeStorage
  case readFailed
  case writeFailed

  var errorDescription: String? {
    switch self {
    case .invalidIdentity:
      "图片上传恢复记录的提交身份无效。"
    case .invalidAttachments:
      "图片上传恢复记录的附件快照无效。"
    case .intentMismatch:
      "图片上传恢复记录与当前最终提交内容不匹配。"
    case .recordAlreadyExists:
      "图片上传恢复记录已存在，未进行覆盖。"
    case .recordNotFound:
      "没有找到图片上传恢复记录。"
    case .identityMismatch:
      "图片上传恢复记录与当前账户或提交不匹配。"
    case .invalidTransition:
      "图片上传恢复记录的状态转换无效。"
    case .unexpectedAttachment:
      "图片上传恢复记录的下一项附件不匹配。"
    case .invalidReceipt:
      "图片上传回执与已保存的提交快照不匹配。"
    case .corruptedArchive:
      "图片上传恢复记录已损坏，未进行覆盖。"
    case .authenticationFailed:
      "图片上传恢复记录未通过完整性认证，未进行覆盖。"
    case .authenticationUnavailable:
      "无法验证图片上传恢复记录，未进行覆盖。"
    case .unsupportedSchemaVersion:
      "图片上传恢复记录来自不受支持的版本，当前版本不会修改它。"
    case .archiveTooLarge:
      "图片上传恢复记录超过安全大小限制。"
    case .tooManyRecords:
      "图片上传恢复记录数量超过安全限制。"
    case .unsafeStorage:
      "图片上传恢复记录的存储位置不安全。"
    case .readFailed:
      "无法读取图片上传恢复记录。"
    case .writeFailed:
      "无法安全保存图片上传恢复记录。"
    }
  }
}

enum ComposerImageUploadLedgerDurabilityCheckpoint: Sendable, Equatable {
  case stagedFile
  case parentDirectory
}

actor ComposerImageUploadLedger {
  static let schemaVersion = 1
  static let defaultMaximumRecords = 64
  static let defaultMaximumArchiveBytes = 1 * 1_024 * 1_024
  static let maximumAttachments = TiebaStaticImageContentPolicy.maximumImageCount

  private struct Archive: Codable, Sendable {
    let schemaVersion: Int
    var records: [ComposerImageUploadLedgerRecord]

    static var empty: Self {
      Archive(schemaVersion: ComposerImageUploadLedger.schemaVersion, records: [])
    }
  }

  private struct ArchiveHeader: Decodable, Sendable {
    let schemaVersion: Int
  }

  private struct SignedEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let canonicalPayload: Data
    let authenticationCode: Data
  }

  private struct SignedEnvelopeHeader: Decodable, Sendable {
    let schemaVersion: Int
  }

  private let fileURL: URL
  private let authenticator: any ComposerImageUploadLedgerAuthenticating
  private let maximumRecords: Int
  private let maximumArchiveBytes: Int
  private let prepareStagedFile: @Sendable (URL) throws -> Void
  private let beforeDurabilitySync:
    @Sendable (ComposerImageUploadLedgerDurabilityCheckpoint) throws -> Void
  private var fileManager: FileManager { .default }

  init(
    fileURL: URL,
    authenticator: any ComposerImageUploadLedgerAuthenticating,
    maximumRecords: Int = defaultMaximumRecords,
    maximumArchiveBytes: Int = defaultMaximumArchiveBytes,
    prepareStagedFile: (@Sendable (URL) throws -> Void)? = nil,
    beforeDurabilitySync: (
      @Sendable (ComposerImageUploadLedgerDurabilityCheckpoint) throws
        -> Void
    )? = nil
  ) {
    self.fileURL = fileURL.standardizedFileURL
    self.authenticator = authenticator
    self.maximumRecords = max(maximumRecords, 1)
    self.maximumArchiveBytes = max(maximumArchiveBytes, 1_024)
    self.prepareStagedFile =
      prepareStagedFile ?? { url in
        try ComposerImageUploadLedger.applyStorageAttributes(to: url)
      }
    self.beforeDurabilitySync = beforeDurabilitySync ?? { _ in }
  }

  static func live(fileManager: FileManager = .default) -> ComposerImageUploadLedger {
    guard
      let applicationSupport = fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    else {
      return ComposerImageUploadLedger(
        fileURL: URL(fileURLWithPath: "/dev/null", isDirectory: true)
          .appendingPathComponent("composer-image-upload-ledger-unavailable.json"),
        authenticator: ComposerImageUploadLedgerHMACAuthenticator()
      )
    }
    return ComposerImageUploadLedger(
      fileURL:
        applicationSupport
        .appendingPathComponent("TiebaPlusPlus", isDirectory: true)
        .appendingPathComponent("composer-image-upload-ledger-v1.json", isDirectory: false),
      authenticator: ComposerImageUploadLedgerHMACAuthenticator()
    )
  }

  func load() throws -> [ComposerImageUploadLedgerRecord] {
    try loadArchive().records
  }

  func load(for key: ComposerImageUploadLedgerKey) throws
    -> ComposerImageUploadLedgerRecord?
  {
    try record(for: key)
  }

  func record(for key: ComposerImageUploadLedgerKey) throws
    -> ComposerImageUploadLedgerRecord?
  {
    guard Self.isValid(key) else {
      throw ComposerImageUploadLedgerError.invalidIdentity
    }
    let archive = try loadArchive()
    guard
      let record = archive.records.first(where: { $0.key.submissionID == key.submissionID })
    else { return nil }
    guard record.key == key else {
      throw ComposerImageUploadLedgerError.identityMismatch
    }
    return record
  }

  func record(
    for context: ComposerImageUploadContext,
    userID: Int64,
    sessionRevision: UUID,
    submissionID: UUID
  ) throws -> ComposerImageUploadLedgerRecord? {
    guard
      let key = ComposerImageUploadLedgerKey(
        context: context,
        userID: userID,
        sessionRevision: sessionRevision,
        submissionID: submissionID
      )
    else { throw ComposerImageUploadLedgerError.invalidIdentity }
    return try record(for: key)
  }

  @discardableResult
  func prepare(
    newThreadSubmission submission: NewThreadSubmission,
    key: ComposerImageUploadLedgerKey,
    attachmentSnapshots: [ComposerImageUploadAttachmentSnapshot]
  ) throws -> ComposerImageUploadLedgerRecord {
    guard Self.isValid(key) else {
      throw ComposerImageUploadLedgerError.invalidIdentity
    }
    guard ComposerImageUploadAttachmentSnapshot.areValid(attachmentSnapshots) else {
      throw ComposerImageUploadLedgerError.invalidAttachments
    }
    guard
      let intentDigest = ComposerImageUploadIntentDigest.newThread(
        submission: submission,
        key: key,
        attachmentSnapshots: attachmentSnapshots
      )
    else { throw ComposerImageUploadLedgerError.intentMismatch }
    return try prepare(
      key: key,
      attachments: attachmentSnapshots,
      intentDigest: intentDigest
    )
  }

  @discardableResult
  func prepare(
    directTopicReplySubmission submission: TextReplySubmission,
    key: ComposerImageUploadLedgerKey,
    attachmentSnapshots: [ComposerImageUploadAttachmentSnapshot]
  ) throws -> ComposerImageUploadLedgerRecord {
    guard Self.isValid(key) else {
      throw ComposerImageUploadLedgerError.invalidIdentity
    }
    guard ComposerImageUploadAttachmentSnapshot.areValid(attachmentSnapshots) else {
      throw ComposerImageUploadLedgerError.invalidAttachments
    }
    guard
      let intentDigest = ComposerImageUploadIntentDigest.directTopicReply(
        submission: submission,
        key: key,
        attachmentSnapshots: attachmentSnapshots
      )
    else { throw ComposerImageUploadLedgerError.intentMismatch }
    return try prepare(
      key: key,
      attachments: attachmentSnapshots,
      intentDigest: intentDigest
    )
  }

  private func prepare(
    key: ComposerImageUploadLedgerKey,
    attachments: [ComposerImageUploadAttachmentSnapshot],
    intentDigest: ComposerImageUploadIntentDigest
  ) throws -> ComposerImageUploadLedgerRecord {
    var archive = try loadArchive()
    if let existing = archive.records.first(where: { $0.key.submissionID == key.submissionID }) {
      guard existing.key == key else {
        throw ComposerImageUploadLedgerError.identityMismatch
      }
      guard
        existing.attachments == attachments,
        existing.intentDigest == intentDigest
      else { throw ComposerImageUploadLedgerError.intentMismatch }
      throw ComposerImageUploadLedgerError.recordAlreadyExists
    }
    guard archive.records.count < maximumRecords else {
      throw ComposerImageUploadLedgerError.tooManyRecords
    }
    let record = ComposerImageUploadLedgerRecord(
      key: key,
      attachments: attachments,
      intentDigest: intentDigest,
      successfulReceiptPrefix: [],
      stage: .prepared
    )
    archive.records.append(record)
    try commit(archive)
    return record
  }

  @discardableResult
  func markAttachmentDispatchPending(
    for key: ComposerImageUploadLedgerKey,
    nextAttachmentID: UUID
  ) throws -> ComposerImageUploadLedgerRecord {
    var archive = try loadArchive()
    let index = try matchingRecordIndex(for: key, in: archive)
    let current = archive.records[index]
    guard current.stage == .prepared else {
      throw ComposerImageUploadLedgerError.invalidTransition
    }
    guard current.nextAttachment?.id == nextAttachmentID else {
      throw ComposerImageUploadLedgerError.unexpectedAttachment
    }
    let updated = ComposerImageUploadLedgerRecord(
      key: current.key,
      attachments: current.attachments,
      intentDigest: current.intentDigest,
      successfulReceiptPrefix: current.successfulReceiptPrefix,
      stage: .attachmentDispatchPending(nextAttachmentID: nextAttachmentID)
    )
    archive.records[index] = updated
    // This commit must complete before the caller dispatches any network bytes.
    try commit(archive)
    return updated
  }

  /// `upload.encodedBytes` must come from a fresh validated attachment-store read.
  /// The signed ledger authenticates metadata, but it is not evidence that those bytes still exist.
  @discardableResult
  func recordBoundReceipt(
    _ receipt: TiebaStaticImageUploadReceipt,
    verifiedAgainst upload: TiebaStaticImageUpload,
    for key: ComposerImageUploadLedgerKey
  ) throws -> ComposerImageUploadLedgerRecord {
    var archive = try loadArchive()
    let index = try matchingRecordIndex(for: key, in: archive)
    let current = archive.records[index]
    guard
      case .attachmentDispatchPending(let expectedAttachmentID) = current.stage,
      let nextAttachment = current.nextAttachment,
      expectedAttachmentID == nextAttachment.id
    else { throw ComposerImageUploadLedgerError.invalidTransition }
    guard
      receipt.uploadID == expectedAttachmentID,
      !current.successfulReceiptPrefix.contains(where: { $0.picID == receipt.picID }),
      nextAttachment.matches(receipt: receipt, key: current.key),
      nextAttachment.matches(upload: upload, forumName: current.key.context.forumName),
      receipt.isBound(to: upload, expectedUserID: current.key.userID)
    else { throw ComposerImageUploadLedgerError.invalidReceipt }

    var receipts = current.successfulReceiptPrefix
    receipts.append(receipt)
    let nextStage: ComposerImageUploadLedgerStage =
      receipts.count == current.attachments.count ? .uploadsComplete : .prepared
    let updated = ComposerImageUploadLedgerRecord(
      key: current.key,
      attachments: current.attachments,
      intentDigest: current.intentDigest,
      successfulReceiptPrefix: receipts,
      stage: nextStage
    )
    archive.records[index] = updated
    try commit(archive)
    return updated
  }

  @discardableResult
  func markFinalSubmissionPending(
    for key: ComposerImageUploadLedgerKey
  ) throws -> ComposerImageUploadLedgerRecord {
    var archive = try loadArchive()
    let index = try matchingRecordIndex(for: key, in: archive)
    let current = archive.records[index]
    guard current.stage == .uploadsComplete, current.nextAttachment == nil else {
      throw ComposerImageUploadLedgerError.invalidTransition
    }
    let updated = ComposerImageUploadLedgerRecord(
      key: current.key,
      attachments: current.attachments,
      intentDigest: current.intentDigest,
      successfulReceiptPrefix: current.successfulReceiptPrefix,
      stage: .finalSubmissionPending
    )
    archive.records[index] = updated
    // This commit must complete before the caller sends the final creation request.
    try commit(archive)
    return updated
  }

  @discardableResult
  func markOutcomeUnknown(
    for key: ComposerImageUploadLedgerKey
  ) throws -> ComposerImageUploadLedgerRecord {
    var archive = try loadArchive()
    let index = try matchingRecordIndex(for: key, in: archive)
    let current = archive.records[index]
    switch current.stage {
    case .attachmentDispatchPending, .finalSubmissionPending:
      break
    case .prepared, .uploadsComplete, .outcomeUnknown, .completed:
      throw ComposerImageUploadLedgerError.invalidTransition
    }
    let updated = ComposerImageUploadLedgerRecord(
      key: current.key,
      attachments: current.attachments,
      intentDigest: current.intentDigest,
      successfulReceiptPrefix: current.successfulReceiptPrefix,
      stage: .outcomeUnknown
    )
    archive.records[index] = updated
    try commit(archive)
    return updated
  }

  @discardableResult
  func markCompleted(
    for key: ComposerImageUploadLedgerKey
  ) throws -> ComposerImageUploadLedgerRecord {
    var archive = try loadArchive()
    let index = try matchingRecordIndex(for: key, in: archive)
    let current = archive.records[index]
    guard current.stage == .finalSubmissionPending, current.nextAttachment == nil else {
      throw ComposerImageUploadLedgerError.invalidTransition
    }
    let updated = ComposerImageUploadLedgerRecord(
      key: current.key,
      attachments: current.attachments,
      intentDigest: current.intentDigest,
      successfulReceiptPrefix: current.successfulReceiptPrefix,
      stage: .completed
    )
    archive.records[index] = updated
    try commit(archive)
    return updated
  }

  func delete(for key: ComposerImageUploadLedgerKey) throws {
    guard Self.isValid(key) else {
      throw ComposerImageUploadLedgerError.invalidIdentity
    }
    var archive = try loadArchive()
    guard
      let index = archive.records.firstIndex(where: {
        $0.key.submissionID == key.submissionID
      })
    else { return }
    guard archive.records[index].key == key else {
      throw ComposerImageUploadLedgerError.identityMismatch
    }
    guard archive.records[index].stage == .completed else {
      throw ComposerImageUploadLedgerError.invalidTransition
    }
    archive.records.remove(at: index)
    try commit(archive)
  }

  private func matchingRecordIndex(
    for key: ComposerImageUploadLedgerKey,
    in archive: Archive
  ) throws -> Int {
    guard Self.isValid(key) else {
      throw ComposerImageUploadLedgerError.invalidIdentity
    }
    guard
      let index = archive.records.firstIndex(where: {
        $0.key.submissionID == key.submissionID
      })
    else { throw ComposerImageUploadLedgerError.recordNotFound }
    guard archive.records[index].key == key else {
      throw ComposerImageUploadLedgerError.identityMismatch
    }
    return index
  }

  private func loadArchive() throws -> Archive {
    try validateExistingStorageDirectory()
    guard let status = try storageItemStatus() else { return .empty }
    guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
      throw ComposerImageUploadLedgerError.unsafeStorage
    }
    guard status.st_size > 0 else {
      throw ComposerImageUploadLedgerError.corruptedArchive
    }
    guard status.st_size <= off_t(maximumArchiveBytes) else {
      throw ComposerImageUploadLedgerError.archiveTooLarge
    }

    let encodedEnvelope: Data
    do {
      encodedEnvelope = try ComposerSecureRegularFileReader.read(
        from: fileURL,
        expectedByteCount: Int64(status.st_size),
        maximumByteCount: Int64(maximumArchiveBytes),
        checksCancellation: false
      )
    } catch ComposerSecureRegularFileReadError.fileTooLarge {
      throw ComposerImageUploadLedgerError.archiveTooLarge
    } catch {
      throw ComposerImageUploadLedgerError.readFailed
    }
    guard encodedEnvelope.count <= maximumArchiveBytes else {
      throw ComposerImageUploadLedgerError.archiveTooLarge
    }
    let decoder = Self.makeDecoder()
    let envelopeHeader: SignedEnvelopeHeader
    do {
      envelopeHeader = try decoder.decode(SignedEnvelopeHeader.self, from: encodedEnvelope)
    } catch {
      throw ComposerImageUploadLedgerError.corruptedArchive
    }
    guard envelopeHeader.schemaVersion == Self.schemaVersion else {
      throw ComposerImageUploadLedgerError.unsupportedSchemaVersion
    }
    let envelope: SignedEnvelope
    do {
      envelope = try decoder.decode(SignedEnvelope.self, from: encodedEnvelope)
    } catch {
      throw ComposerImageUploadLedgerError.corruptedArchive
    }
    guard envelope.canonicalPayload.count <= maximumArchiveBytes else {
      throw ComposerImageUploadLedgerError.archiveTooLarge
    }
    let isAuthenticated: Bool
    do {
      isAuthenticated = try authenticator.isValidAuthenticationCode(
        envelope.authenticationCode,
        for: envelope.canonicalPayload
      )
    } catch {
      throw ComposerImageUploadLedgerError.authenticationUnavailable
    }
    guard isAuthenticated else {
      throw ComposerImageUploadLedgerError.authenticationFailed
    }

    let archiveHeader: ArchiveHeader
    do {
      archiveHeader = try decoder.decode(ArchiveHeader.self, from: envelope.canonicalPayload)
    } catch {
      throw ComposerImageUploadLedgerError.corruptedArchive
    }
    guard archiveHeader.schemaVersion == Self.schemaVersion else {
      throw ComposerImageUploadLedgerError.unsupportedSchemaVersion
    }
    let archive: Archive
    do {
      archive = try decoder.decode(Archive.self, from: envelope.canonicalPayload)
    } catch {
      throw ComposerImageUploadLedgerError.corruptedArchive
    }
    try validate(archive)
    let canonicalPayload: Data
    do {
      canonicalPayload = try Self.makeEncoder().encode(archive)
    } catch {
      throw ComposerImageUploadLedgerError.corruptedArchive
    }
    guard canonicalPayload == envelope.canonicalPayload else {
      throw ComposerImageUploadLedgerError.corruptedArchive
    }
    return archive
  }

  private func commit(_ proposedArchive: Archive) throws {
    var archive = proposedArchive
    archive.records.sort(by: Self.isOrderedBefore)
    try validate(archive)

    let canonicalPayload: Data
    do {
      canonicalPayload = try Self.makeEncoder().encode(archive)
    } catch {
      throw ComposerImageUploadLedgerError.writeFailed
    }
    guard canonicalPayload.count <= maximumArchiveBytes else {
      throw ComposerImageUploadLedgerError.archiveTooLarge
    }
    let authenticationCode: Data
    do {
      authenticationCode = try authenticator.authenticationCode(for: canonicalPayload)
    } catch {
      throw ComposerImageUploadLedgerError.authenticationUnavailable
    }
    let envelope = SignedEnvelope(
      schemaVersion: Self.schemaVersion,
      canonicalPayload: canonicalPayload,
      authenticationCode: authenticationCode
    )
    let encodedEnvelope: Data
    do {
      encodedEnvelope = try Self.makeEncoder().encode(envelope)
    } catch {
      throw ComposerImageUploadLedgerError.writeFailed
    }
    guard encodedEnvelope.count <= maximumArchiveBytes else {
      throw ComposerImageUploadLedgerError.archiveTooLarge
    }
    try persist(encodedEnvelope)
  }

  private func validate(_ archive: Archive) throws {
    guard archive.schemaVersion == Self.schemaVersion else {
      throw ComposerImageUploadLedgerError.unsupportedSchemaVersion
    }
    guard archive.records.count <= maximumRecords else {
      throw ComposerImageUploadLedgerError.tooManyRecords
    }
    guard archive.records.elementsEqual(archive.records.sorted(by: Self.isOrderedBefore)) else {
      throw ComposerImageUploadLedgerError.corruptedArchive
    }
    var submissionIDs = Set<UUID>()
    for record in archive.records {
      guard submissionIDs.insert(record.key.submissionID).inserted else {
        throw ComposerImageUploadLedgerError.corruptedArchive
      }
      try Self.validate(record)
    }
  }

  private static func validate(_ record: ComposerImageUploadLedgerRecord) throws {
    guard
      isValid(record.key),
      ComposerImageUploadAttachmentSnapshot.areValid(record.attachments),
      record.intentDigest.isValid,
      record.successfulReceiptPrefix.count <= record.attachments.count
    else { throw ComposerImageUploadLedgerError.corruptedArchive }
    var pictureIDs = Set<String>()
    for (snapshot, receipt) in zip(
      record.attachments,
      record.successfulReceiptPrefix
    ) {
      guard
        pictureIDs.insert(receipt.picID).inserted,
        snapshot.matches(receipt: receipt, key: record.key)
      else {
        throw ComposerImageUploadLedgerError.corruptedArchive
      }
    }
    let receiptsAreComplete =
      record.successfulReceiptPrefix.count == record.attachments.count
    switch record.stage {
    case .prepared:
      guard !receiptsAreComplete else {
        throw ComposerImageUploadLedgerError.corruptedArchive
      }
    case .attachmentDispatchPending(let nextAttachmentID):
      guard
        !receiptsAreComplete,
        record.nextAttachment?.id == nextAttachmentID
      else { throw ComposerImageUploadLedgerError.corruptedArchive }
    case .uploadsComplete, .finalSubmissionPending, .completed:
      guard receiptsAreComplete else {
        throw ComposerImageUploadLedgerError.corruptedArchive
      }
    case .outcomeUnknown:
      break
    }
  }

  private static func isValid(_ key: ComposerImageUploadLedgerKey) -> Bool {
    ComposerImageUploadLedgerKey(
      context: key.context,
      userID: key.userID,
      sessionRevision: key.sessionRevision,
      submissionID: key.submissionID
    ) != nil
  }

  private static func isOrderedBefore(
    _ lhs: ComposerImageUploadLedgerRecord,
    _ rhs: ComposerImageUploadLedgerRecord
  ) -> Bool {
    lhs.key.submissionID.uuidString < rhs.key.submissionID.uuidString
  }

  private func persist(_ data: Data) throws {
    let directoryURL = fileURL.deletingLastPathComponent()
    let stagedFilename = ".composer-image-upload-ledger-\(UUID().uuidString.lowercased()).staged"
    let stagedURL = directoryURL.appendingPathComponent(
      stagedFilename,
      isDirectory: false
    )
    let targetFilename = fileURL.lastPathComponent
    var directoryDescriptor: Int32 = -1
    var stagedDescriptor: Int32 = -1
    var didPublish = false
    do {
      try ensureStorageDirectory(directoryURL)
      guard let expectedDirectoryStatus = try storageItemStatus(at: directoryURL) else {
        throw ComposerImageUploadLedgerError.unsafeStorage
      }
      directoryDescriptor = directoryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
        guard let path else { return -1 }
        return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      }
      guard directoryDescriptor >= 0 else {
        throw ComposerImageUploadLedgerError.unsafeStorage
      }
      var directoryStatus = stat()
      guard
        Darwin.fstat(directoryDescriptor, &directoryStatus) == 0,
        (directoryStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
        directoryStatus.st_dev == expectedDirectoryStatus.st_dev,
        directoryStatus.st_ino == expectedDirectoryStatus.st_ino
      else { throw ComposerImageUploadLedgerError.unsafeStorage }

      stagedDescriptor = stagedFilename.withCString { filename in
        Darwin.openat(
          directoryDescriptor,
          filename,
          O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
          mode_t(S_IRUSR | S_IWUSR)
        )
      }
      guard stagedDescriptor >= 0 else {
        throw ComposerImageUploadLedgerError.writeFailed
      }
      try Self.writeAll(data, to: stagedDescriptor)
      try prepareStagedFile(stagedURL)
      guard
        let stagedStatus = try storageItemStatus(at: stagedURL),
        (stagedStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        stagedStatus.st_size == off_t(data.count),
        try ComposerSecureRegularFileReader.read(
          from: stagedURL,
          expectedByteCount: Int64(data.count),
          maximumByteCount: Int64(maximumArchiveBytes),
          checksCancellation: false
        ) == data
      else { throw ComposerImageUploadLedgerError.writeFailed }

      try runDurabilityHook(.stagedFile)
      try Self.synchronizeRegularFile(descriptor: stagedDescriptor)
      guard Darwin.close(stagedDescriptor) == 0 else {
        stagedDescriptor = -1
        throw ComposerImageUploadLedgerError.writeFailed
      }
      stagedDescriptor = -1

      let renameResult = stagedFilename.withCString { source in
        targetFilename.withCString { destination in
          Darwin.renameat(directoryDescriptor, source, directoryDescriptor, destination)
        }
      }
      guard renameResult == 0 else {
        throw ComposerImageUploadLedgerError.writeFailed
      }
      didPublish = true
      try runDurabilityHook(.parentDirectory)
      try Self.synchronizeWithFSync(descriptor: directoryDescriptor)
      guard targetArchiveMatches(data) else {
        throw ComposerImageUploadLedgerError.writeFailed
      }
    } catch {
      if stagedDescriptor >= 0 {
        _ = Darwin.close(stagedDescriptor)
        stagedDescriptor = -1
      }
      if !didPublish, directoryDescriptor >= 0 {
        _ = stagedFilename.withCString { filename in
          Darwin.unlinkat(directoryDescriptor, filename, 0)
        }
      }
      if directoryDescriptor >= 0 {
        _ = Darwin.close(directoryDescriptor)
        directoryDescriptor = -1
      }
      if let ledgerError = error as? ComposerImageUploadLedgerError {
        throw ledgerError
      }
      throw ComposerImageUploadLedgerError.writeFailed
    }
    if directoryDescriptor >= 0 {
      _ = Darwin.close(directoryDescriptor)
    }
  }

  private static func writeAll(_ data: Data, to descriptor: Int32) throws {
    guard !data.isEmpty else { throw ComposerImageUploadLedgerError.writeFailed }
    try data.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else {
        throw ComposerImageUploadLedgerError.writeFailed
      }
      var writtenByteCount = 0
      while writtenByteCount < buffer.count {
        let result = Darwin.write(
          descriptor,
          baseAddress.advanced(by: writtenByteCount),
          buffer.count - writtenByteCount
        )
        if result < 0, errno == EINTR { continue }
        guard result > 0 else { throw ComposerImageUploadLedgerError.writeFailed }
        writtenByteCount += result
      }
    }
  }

  private func runDurabilityHook(
    _ checkpoint: ComposerImageUploadLedgerDurabilityCheckpoint
  ) throws {
    do {
      try beforeDurabilitySync(checkpoint)
    } catch {
      throw ComposerImageUploadLedgerError.writeFailed
    }
  }

  private static func synchronizeRegularFile(descriptor: Int32) throws {
    while Darwin.fcntl(descriptor, F_FULLFSYNC) != 0 {
      if errno == EINTR { continue }
      let fullSyncError = errno
      guard
        fullSyncError == EINVAL || fullSyncError == ENOTSUP || fullSyncError == ENOTTY
      else { throw ComposerImageUploadLedgerError.writeFailed }
      try synchronizeWithFSync(descriptor: descriptor)
      return
    }
  }

  private static func synchronizeWithFSync(descriptor: Int32) throws {
    while Darwin.fsync(descriptor) != 0 {
      if errno == EINTR { continue }
      throw ComposerImageUploadLedgerError.writeFailed
    }
  }

  private func ensureStorageDirectory(_ directoryURL: URL) throws {
    guard fileURL.isFileURL, directoryURL.isFileURL else {
      throw ComposerImageUploadLedgerError.unsafeStorage
    }
    do {
      if let status = try storageItemStatus(at: directoryURL) {
        guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
          throw ComposerImageUploadLedgerError.unsafeStorage
        }
      } else {
        try fileManager.createDirectory(
          at: directoryURL,
          withIntermediateDirectories: true
        )
      }
      guard
        let status = try storageItemStatus(at: directoryURL),
        (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
      else { throw ComposerImageUploadLedgerError.unsafeStorage }
      try Self.applyStorageAttributes(to: directoryURL)
    } catch let error as ComposerImageUploadLedgerError {
      throw error
    } catch {
      throw ComposerImageUploadLedgerError.writeFailed
    }
  }

  private func validateExistingStorageDirectory() throws {
    let directoryURL = fileURL.deletingLastPathComponent()
    guard fileURL.isFileURL, directoryURL.isFileURL else {
      throw ComposerImageUploadLedgerError.unsafeStorage
    }
    guard let status = try storageItemStatus(at: directoryURL) else { return }
    guard (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
      throw ComposerImageUploadLedgerError.unsafeStorage
    }
  }

  private func storageItemStatus() throws -> stat? {
    try storageItemStatus(at: fileURL)
  }

  private func storageItemStatus(at url: URL) throws -> stat? {
    var status = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.lstat(path, &status)
    }
    if result == 0 { return status }
    if errno == ENOENT { return nil }
    throw ComposerImageUploadLedgerError.readFailed
  }

  private func targetArchiveMatches(_ expected: Data) -> Bool {
    do {
      guard
        let status = try storageItemStatus(),
        (status.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
        status.st_size == off_t(expected.count)
      else { return false }
      return try ComposerSecureRegularFileReader.read(
        from: fileURL,
        expectedByteCount: Int64(expected.count),
        maximumByteCount: Int64(maximumArchiveBytes),
        checksCancellation: false
      ) == expected
    } catch {
      return false
    }
  }

  private static func applyStorageAttributes(to fileURL: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = fileURL
    try mutableURL.setResourceValues(values)
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.complete],
        ofItemAtPath: fileURL.path
      )
    #endif
  }

  private static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
  }

  private static func makeDecoder() -> JSONDecoder {
    JSONDecoder()
  }
}
