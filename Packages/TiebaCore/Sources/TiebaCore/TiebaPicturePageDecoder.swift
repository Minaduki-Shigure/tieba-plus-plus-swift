import Foundation

enum TiebaPicturePageDecoder {
  static func page(from body: Data, expectedForumID: Int64) throws -> TiebaPicturePage {
    let envelope: PicturePageEnvelope
    do {
      envelope = try JSONDecoder().decode(PicturePageEnvelope.self, from: body)
    } catch {
      throw TiebaClientError.invalidJSON
    }

    guard envelope.errorCode.value == 0 else {
      throw TiebaClientError.server(
        code: Int32(clamping: envelope.errorCode.value),
        message: envelope.errorMessage
      )
    }
    guard
      let forum = envelope.forum,
      let pictureCountValue = envelope.pictureCount?.value,
      let payloads = envelope.pictures,
      forum.id.value == expectedForumID,
      expectedForumID > 0,
      (1...Int64(TiebaPicturePagePolicy.maximumPictureCount)).contains(pictureCountValue),
      payloads.count <= TiebaPicturePagePolicy.maximumResponsePictureCount,
      Int64(payloads.count) <= pictureCountValue
    else {
      throw TiebaClientError.invalidJSON
    }

    let forumName = forum.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard
      !forumName.isEmpty,
      forumName.count <= 100,
      !forumName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw TiebaClientError.invalidJSON
    }

    let totalPictureCount = Int(pictureCountValue)
    var pictures = [TiebaPicturePageImage]()
    var seenIndexes = Set<Int>()
    var previousIndex = 0
    var firstResponseIndex: Int?
    var lastResponseIndex: Int?

    for payload in payloads {
      let overallIndex = try boundedInt(
        payload.overallIndex.value,
        range: 1...totalPictureCount
      )
      guard
        overallIndex > previousIndex,
        seenIndexes.insert(overallIndex).inserted
      else {
        throw TiebaClientError.invalidJSON
      }
      previousIndex = overallIndex
      firstResponseIndex = firstResponseIndex ?? overallIndex
      lastResponseIndex = overallIndex

      if payload.isBlocked?.value == true {
        continue
      }
      let picture = try mapPicture(payload, overallIndex: overallIndex)
      pictures.append(picture)
    }

    return TiebaPicturePage(
      forumID: expectedForumID,
      forumName: forumName,
      totalPictureCount: totalPictureCount,
      pictures: pictures,
      hasPrevious: firstResponseIndex.map { $0 > 1 } ?? false,
      hasNext: lastResponseIndex.map { $0 < totalPictureCount } ?? false
    )
  }

  private static func mapPicture(
    _ payload: PicturePagePicturePayload,
    overallIndex: Int
  ) throws -> TiebaPicturePageImage {
    guard
      let imageGroup = payload.image,
      let original = imageGroup.original,
      let pictureID = original.id,
      TiebaPicturePagePolicy.isValidPictureID(pictureID),
      let widthValue = original.width?.value,
      let heightValue = original.height?.value,
      let byteCountValue = original.size?.value,
      let cursor = TiebaPicturePageCursor(
        serverPictureID: pictureID,
        overallIndex: overallIndex
      )
    else {
      throw TiebaClientError.invalidJSON
    }

    let width = try boundedInt(
      widthValue,
      range: 1...TiebaPicturePagePolicy.maximumDimension
    )
    let height = try boundedInt(
      heightValue,
      range: 1...TiebaPicturePagePolicy.maximumDimension
    )
    let originalByteCount = try boundedInt(
      byteCountValue,
      range: 0...TiebaPicturePagePolicy.maximumOriginalByteCount
    )
    let postID: Int64?
    if let value = payload.postID?.value {
      guard value > 0 else { throw TiebaClientError.invalidJSON }
      postID = value
    } else {
      postID = nil
    }

    let originalURL = try requiredMediaURL(original.originalSource)
    let originalDirectURL = try optionalMediaURL(original.url)
    let originalWaterURL = try optionalMediaURL(original.waterURL)
    let bigCDNURL = try optionalMediaURL(original.bigCDNSource)
    let mediumURL = try validatedImageVariant(imageGroup.medium)
    let screenURL = try validatedImageVariant(imageGroup.screen)

    return TiebaPicturePageImage(
      cursor: cursor,
      postID: postID,
      thumbnailURL: mediumURL ?? screenURL,
      fullSizeURL: bigCDNURL ?? originalDirectURL ?? originalWaterURL,
      originalURL: originalURL,
      width: width,
      height: height,
      originalByteCount: originalByteCount,
      isLongPicture: payload.isLongPicture?.value ?? false,
      offersOriginal: payload.offersOriginal?.value ?? false
    )
  }

  private static func validatedImageVariant(_ payload: PicturePageImagePayload?) throws -> URL? {
    guard let payload else { return nil }
    if let id = payload.id, !id.isEmpty, !TiebaPicturePagePolicy.isValidPictureID(id) {
      throw TiebaClientError.invalidJSON
    }
    if let width = payload.width?.value {
      _ = try boundedInt(width, range: 1...TiebaPicturePagePolicy.maximumDimension)
    }
    if let height = payload.height?.value {
      _ = try boundedInt(height, range: 1...TiebaPicturePagePolicy.maximumDimension)
    }
    if let size = payload.size?.value {
      _ = try boundedInt(size, range: 0...TiebaPicturePagePolicy.maximumOriginalByteCount)
    }
    let url = try optionalMediaURL(payload.url)
    let waterURL = try optionalMediaURL(payload.waterURL)
    _ = try optionalMediaURL(payload.bigCDNSource)
    _ = try optionalMediaURL(payload.originalSource)
    return url ?? waterURL
  }

  private static func requiredMediaURL(_ rawValue: String?) throws -> URL {
    guard
      let rawValue,
      !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      let url = TiebaPictureMediaURLPolicy.normalizedMediaURL(from: rawValue)
    else {
      throw TiebaClientError.invalidJSON
    }
    return url
  }

  private static func optionalMediaURL(_ rawValue: String?) throws -> URL? {
    guard let rawValue else { return nil }
    guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    guard let url = TiebaPictureMediaURLPolicy.normalizedMediaURL(from: rawValue) else {
      throw TiebaClientError.invalidJSON
    }
    return url
  }

  private static func boundedInt(_ value: Int64, range: ClosedRange<Int>) throws -> Int {
    guard
      let result = Int(exactly: value),
      range.contains(result)
    else {
      throw TiebaClientError.invalidJSON
    }
    return result
  }
}

private struct PicturePageEnvelope: Decodable {
  let errorCode: PicturePageInteger
  let errorMessage: String
  let forum: PicturePageForumPayload?
  let pictureCount: PicturePageInteger?
  let pictures: [PicturePagePicturePayload]?

  enum CodingKeys: String, CodingKey {
    case errorCode = "error_code"
    case errorMessage = "error_msg"
    case forum
    case pictureCount = "pic_amount"
    case pictures = "pic_list"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    errorCode = try container.decode(PicturePageInteger.self, forKey: .errorCode)
    errorMessage = (try? container.decode(String.self, forKey: .errorMessage)) ?? ""
    if errorCode.value == 0 {
      forum = try container.decode(PicturePageForumPayload.self, forKey: .forum)
      pictureCount = try container.decode(PicturePageInteger.self, forKey: .pictureCount)
      pictures = try container.decode([PicturePagePicturePayload].self, forKey: .pictures)
    } else {
      forum = nil
      pictureCount = nil
      pictures = nil
    }
  }
}

private struct PicturePageForumPayload: Decodable {
  let id: PicturePageInteger
  let name: String
}

private struct PicturePagePicturePayload: Decodable {
  let overallIndex: PicturePageInteger
  let isLongPicture: PicturePageBoolean?
  let offersOriginal: PicturePageBoolean?
  let isBlocked: PicturePageBoolean?
  let image: PicturePageImageGroupPayload?
  let postID: PicturePageInteger?

  enum CodingKeys: String, CodingKey {
    case overallIndex = "overall_index"
    case isLongPicture = "is_long_pic"
    case offersOriginal = "show_original_btn"
    case isBlocked = "is_blocked_pic"
    case image = "img"
    case postID = "post_id"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    overallIndex = try container.decode(PicturePageInteger.self, forKey: .overallIndex)
    isBlocked = try container.decodeIfPresent(PicturePageBoolean.self, forKey: .isBlocked)
    if isBlocked?.value == true {
      isLongPicture = nil
      offersOriginal = nil
      image = nil
      postID = nil
    } else {
      isLongPicture = try container.decodeIfPresent(
        PicturePageBoolean.self,
        forKey: .isLongPicture
      )
      offersOriginal = try container.decodeIfPresent(
        PicturePageBoolean.self,
        forKey: .offersOriginal
      )
      image = try container.decodeIfPresent(PicturePageImageGroupPayload.self, forKey: .image)
      postID = try container.decodeIfPresent(PicturePageInteger.self, forKey: .postID)
    }
  }
}

private struct PicturePageImageGroupPayload: Decodable {
  let original: PicturePageImagePayload?
  let medium: PicturePageImagePayload?
  let screen: PicturePageImagePayload?
}

private struct PicturePageImagePayload: Decodable {
  let id: String?
  let width: PicturePageInteger?
  let height: PicturePageInteger?
  let size: PicturePageInteger?
  let waterURL: String?
  let bigCDNSource: String?
  let url: String?
  let originalSource: String?

  enum CodingKeys: String, CodingKey {
    case id
    case width
    case height
    case size
    case waterURL = "waterurl"
    case bigCDNSource = "big_cdn_src"
    case url
    case originalSource = "original_src"
  }
}

private struct PicturePageInteger: Decodable {
  let value: Int64

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let integer = try? container.decode(Int64.self) {
      value = integer
      return
    }
    if let string = try? container.decode(String.self), let integer = Self.parse(string) {
      value = integer
      return
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Expected a bounded decimal integer."
    )
  }

  private static func parse(_ value: String) -> Int64? {
    guard !value.isEmpty, value.utf8.count <= 20 else { return nil }
    let bytes = Array(value.utf8)
    let digits = bytes.first == 45 ? bytes.dropFirst() : bytes[...]
    guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }) else { return nil }
    return Int64(value)
  }
}

private struct PicturePageBoolean: Decodable {
  let value: Bool

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let boolean = try? container.decode(Bool.self) {
      value = boolean
      return
    }
    if let integer = try? container.decode(Int64.self), integer == 0 || integer == 1 {
      value = integer == 1
      return
    }
    if let string = try? container.decode(String.self) {
      switch string {
      case "0", "false":
        value = false
        return
      case "1", "true":
        value = true
        return
      default:
        break
      }
    }
    throw DecodingError.dataCorruptedError(
      in: container,
      debugDescription: "Expected a Boolean or an exact 0/1 representation."
    )
  }
}
