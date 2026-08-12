import Foundation
import TiebaProto

extension TiebaAuthenticatedDecoder {
  static let pollTextMaximumBytes = 16 * 1_024
  static let pollImageMaximumBytes = 4 * 1_024

  static func pollState(
    from response: PbPageResIdl,
    expectedUserID: Int64,
    forumID: Int64,
    threadID: Int64
  ) throws -> TiebaPollState {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    guard
      expectedUserID > 0,
      forumID > 0,
      threadID > 0,
      response.hasData,
      response.data.hasUser,
      response.data.hasForum,
      response.data.hasThread,
      response.data.user.isLogin == 1,
      response.data.user.id == expectedUserID,
      response.data.forum.id == forumID,
      response.data.thread.id == threadID,
      response.data.thread.fid == 0 || response.data.thread.fid == forumID
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    let poll: PollInfo
    if response.data.thread.hasPollInfo {
      poll = response.data.thread.pollInfo
    } else if
      response.data.thread.isShareThread == 0,
      Int64(
        response.data.thread.originThreadInfo.tid
          .trimmingCharacters(in: .whitespacesAndNewlines)
      ) == threadID,
      response.data.thread.originThreadInfo.hasPollInfo
    {
      // Ordinary PB pages currently mirror their poll in origin_thread_info.
      // A shared or unbound origin can never authorize a vote against the
      // outer thread.
      poll = response.data.thread.originThreadInfo.pollInfo
    } else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    return TiebaPollState(
      userID: expectedUserID,
      forumID: forumID,
      threadID: threadID,
      poll: try authoritativePoll(poll)
    )
  }

  static func checkPollWriteResponse(_ response: AddPollPostResIdl) throws {
    guard response.error.errorno == 0 else {
      throw TiebaClientError.server(
        code: response.error.errorno,
        message: response.error.errmsg
      )
    }
    guard response.hasData else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    guard response.data.errorCode == 0 else {
      throw TiebaClientError.server(
        code: response.data.errorCode,
        message: response.data.errorMsg
      )
    }
  }

  private static func authoritativePoll(_ proto: PollInfo) throws -> TiebaPoll {
    guard
      proto.type >= 0,
      (0...1).contains(proto.isMulti),
      (0...1).contains(proto.isPolled),
      proto.totalNum >= 0,
      proto.totalPoll >= 0,
      proto.options.count >= 2,
      proto.options.count <= 100,
      proto.optionsCount == 0 || proto.optionsCount == Int32(proto.options.count),
      proto.endTime >= 0,
      proto.status >= 0
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    var seenOptionIDs = Set<Int32>()
    let options = try proto.options.map { option -> TiebaPollOption in
      guard
        option.id > 0,
        seenOptionIDs.insert(option.id).inserted,
        option.num >= 0
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
      return TiebaPollOption(
        id: option.id,
        text: try boundedPollText(option.text, maximumBytes: pollTextMaximumBytes),
        voteCount: option.num,
        image: try boundedPollText(option.image, maximumBytes: pollImageMaximumBytes)
      )
    }

    let selectedOptionIDs = try parsedPollOptionIDs(proto.polledValue)
    guard
      selectedOptionIDs.isSubset(of: seenOptionIDs),
      proto.isPolled == 1 ? !selectedOptionIDs.isEmpty : selectedOptionIDs.isEmpty,
      proto.isMulti == 1 || selectedOptionIDs.count <= 1
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }

    return TiebaPoll(
      type: proto.type,
      title: try boundedPollText(proto.title, maximumBytes: pollTextMaximumBytes),
      isMultipleChoice: proto.isMulti == 1,
      isPolled: proto.isPolled == 1,
      selectedOptionIDs: selectedOptionIDs,
      tips: try boundedPollText(proto.tips, maximumBytes: pollTextMaximumBytes),
      endTimestamp: Int64(proto.endTime),
      status: proto.status,
      lastTimestamp: Int64(proto.lastTime),
      participantCount: proto.totalNum,
      totalVoteCount: proto.totalPoll,
      options: options
    )
  }

  private static func parsedPollOptionIDs(_ rawValue: String) throws -> Set<Int32> {
    guard !rawValue.isEmpty else { return [] }
    let components = rawValue.split(separator: ",", omittingEmptySubsequences: false)
    guard components.count <= 100 else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    var result = Set<Int32>()
    for component in components {
      let value = component.trimmingCharacters(in: .whitespacesAndNewlines)
      guard
        !value.isEmpty,
        let id = Int32(value),
        id > 0,
        result.insert(id).inserted
      else {
        throw TiebaClientError.invalidAuthenticatedResponse
      }
    }
    return result
  }

  private static func boundedPollText(_ rawValue: String, maximumBytes: Int) throws -> String {
    guard
      rawValue.utf8.count <= maximumBytes,
      !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw TiebaClientError.invalidAuthenticatedResponse
    }
    return rawValue.precomposedStringWithCanonicalMapping
  }
}
