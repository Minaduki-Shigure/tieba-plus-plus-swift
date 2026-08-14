import Foundation

enum TiebaStaticImageUploadDecoder {
  static func decodeChunkResponse(
    from body: Data,
    plan: TiebaStaticImageUploadPlan,
    chunkNumber: Int
  ) throws -> TiebaStaticImageChunkDecodeResult {
    guard body.count <= TiebaStaticImageUploadPolicy.maximumResponseBodyBytes else {
      throw TiebaClientError.responseTooLarge(
        maximumBytes: TiebaStaticImageUploadPolicy.maximumResponseBodyBytes
      )
    }
    guard (1...plan.chunkCount).contains(chunkNumber) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let object: [String: Any]
    do {
      guard
        let decoded = try JSONSerialization.jsonObject(with: body) as? [String: Any]
      else {
        throw TiebaClientError.invalidJSON
      }
      object = decoded
    } catch let error as TiebaClientError {
      throw error
    } catch {
      throw TiebaClientError.invalidJSON
    }

    let errorCode = try canonicalInt32(try requiredString(object["error_code"], maximumBytes: 12))
    let errorMessage = try boundedString(object["error_msg"], maximumBytes: 4 * 1_024)
    if errorCode != 0 {
      if let resourceID = try optionalString(object["resourceId"], maximumBytes: 128),
        resourceID != plan.resourceID
      {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      if let responseChunkNumber = try optionalString(object["chunkNo"], maximumBytes: 10),
        try canonicalPositiveInt(responseChunkNumber) != chunkNumber
      {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      throw TiebaClientError.server(code: errorCode, message: errorMessage)
    }
    guard
      try requiredString(object["resourceId"], maximumBytes: 128) == plan.resourceID,
      try canonicalPositiveInt(try requiredString(object["chunkNo"], maximumBytes: 10))
        == chunkNumber
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard chunkNumber == plan.chunkCount else { return .accepted }
    let picID = try requiredString(object["picId"], maximumBytes: 40)
    guard TiebaPicturePagePolicy.isValidPictureID(picID) else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard
      let pictureInfo = object["picInfo"] as? [String: Any],
      let originPicture = pictureInfo["originPic"] as? [String: Any]
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    let width = try boundedDimension(originPicture["width"])
    let height = try boundedDimension(originPicture["height"])
    return .completed(
      TiebaStaticImageUploadReceipt(
        uploadID: plan.upload.uploadID,
        contentSHA256: plan.contentSHA256,
        userID: plan.expectedUserID,
        forumName: plan.normalizedForumName,
        preservesOriginal: plan.upload.preservesOriginal,
        watermark: plan.upload.watermark,
        uploadedPixelWidth: plan.upload.pixelWidth,
        uploadedPixelHeight: plan.upload.pixelHeight,
        resourceID: plan.resourceID,
        picID: picID,
        width: width,
        height: height,
        byteCount: plan.byteCount,
        chunkCount: plan.chunkCount
      )
    )
  }

  private static func requiredString(_ value: Any?, maximumBytes: Int) throws -> String {
    let value = try boundedString(value, maximumBytes: maximumBytes)
    guard !value.isEmpty else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return value
  }

  private static func boundedString(_ value: Any?, maximumBytes: Int) throws -> String {
    guard
      let value = value as? String,
      value.utf8.count <= maximumBytes,
      !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return value
  }

  private static func optionalString(_ value: Any?, maximumBytes: Int) throws -> String? {
    guard let value, !(value is NSNull) else { return nil }
    return try requiredString(value, maximumBytes: maximumBytes)
  }

  private static func canonicalInt32(_ value: String) throws -> Int32 {
    guard let parsed = Int32(value), String(parsed) == value else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return parsed
  }

  private static func canonicalPositiveInt(_ value: String) throws -> Int {
    guard let parsed = Int(value), parsed > 0, String(parsed) == value else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return parsed
  }

  private static func boundedDimension(_ value: Any?) throws -> Int {
    let parsed = try canonicalPositiveInt(try requiredString(value, maximumBytes: 5))
    guard parsed <= TiebaStaticImageUploadPolicy.maximumPixelDimension else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return parsed
  }
}
