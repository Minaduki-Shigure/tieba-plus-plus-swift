import Foundation

enum SafeContentFilterRegexError: LocalizedError, Equatable, Sendable {
  case emptyPattern
  case patternTooLong(maximum: Int)
  case unexpectedToken(position: Int)
  case unexpectedClosingParenthesis(position: Int)
  case unterminatedGroup(position: Int)
  case emptyGroup(position: Int)
  case emptyAlternative(position: Int)
  case invalidEscape(position: Int)
  case unterminatedCharacterClass(position: Int)
  case emptyCharacterClass(position: Int)
  case invalidCharacterRange(position: Int)
  case invalidQuantifier(position: Int)
  case repeatCountTooLarge(maximum: Int, position: Int)
  case stateLimitExceeded(maximum: Int)

  var errorDescription: String? {
    switch self {
    case .emptyPattern:
      "正则表达式不能为空。"
    case .patternTooLong(let maximum):
      "正则表达式不能超过 \(maximum) 个字符。"
    case .unexpectedToken(let position):
      "正则表达式第 \(position + 1) 个字符无法识别。"
    case .unexpectedClosingParenthesis(let position):
      "正则表达式第 \(position + 1) 个字符存在多余的右括号。"
    case .unterminatedGroup(let position):
      "正则表达式第 \(position + 1) 个字符开始的分组没有结束。"
    case .emptyGroup(let position):
      "正则表达式第 \(position + 1) 个字符开始的分组不能为空。"
    case .emptyAlternative(let position):
      "正则表达式第 \(position + 1) 个字符附近存在空分支。"
    case .invalidEscape(let position):
      "正则表达式第 \(position + 1) 个字符使用了不支持的转义。"
    case .unterminatedCharacterClass(let position):
      "正则表达式第 \(position + 1) 个字符开始的字符组没有结束。"
    case .emptyCharacterClass(let position):
      "正则表达式第 \(position + 1) 个字符开始的字符组不能为空。"
    case .invalidCharacterRange(let position):
      "正则表达式第 \(position + 1) 个字符附近的字符范围无效。"
    case .invalidQuantifier(let position):
      "正则表达式第 \(position + 1) 个字符附近的重复次数无效。"
    case .repeatCountTooLarge(let maximum, let position):
      "正则表达式第 \(position + 1) 个字符附近的重复次数不能超过 \(maximum)。"
    case .stateLimitExceeded(let maximum):
      "正则表达式编译后不能超过 \(maximum) 个状态。"
    }
  }
}

struct SafeContentFilterRegex: Hashable, Sendable {
  static let maximumPatternCharacters = 128
  static let maximumInputScalars = 8_192

  private static let maximumStates = 256
  private static let maximumRepeatCount = 256

  struct Input: Sendable {
    fileprivate let scalars: [Unicode.Scalar]
    fileprivate let followingScalar: Unicode.Scalar?

    init(_ text: String) {
      var scalars = [Unicode.Scalar]()
      scalars.reserveCapacity(256)
      var followingScalar: Unicode.Scalar?
      for scalar in text.unicodeScalars {
        if scalars.count < SafeContentFilterRegex.maximumInputScalars {
          scalars.append(scalar)
        } else {
          followingScalar = scalar
          break
        }
      }
      self.scalars = scalars
      self.followingScalar = followingScalar
    }
  }

  struct Workspace {
    fileprivate var seeds: [Int]
    fileprivate var nextSeeds: [Int]
    fileprivate var stack: [Int]
    fileprivate var active: [Int]
    fileprivate var visited: [Bool]
    fileprivate var touched: [Int]

    init() {
      var seeds = [Int]()
      var nextSeeds = [Int]()
      var stack = [Int]()
      var active = [Int]()
      var touched = [Int]()
      seeds.reserveCapacity(SafeContentFilterRegex.maximumStates)
      nextSeeds.reserveCapacity(SafeContentFilterRegex.maximumStates)
      stack.reserveCapacity(SafeContentFilterRegex.maximumStates)
      active.reserveCapacity(SafeContentFilterRegex.maximumStates)
      touched.reserveCapacity(SafeContentFilterRegex.maximumStates)

      self.seeds = seeds
      self.nextSeeds = nextSeeds
      self.stack = stack
      self.active = active
      self.visited = Array(
        repeating: false,
        count: SafeContentFilterRegex.maximumStates
      )
      self.touched = touched
    }
  }

  enum MatchResult: Equatable, Sendable {
    case matched
    case notMatched
    case budgetExhausted
  }

  private let pattern: String
  private let program: SafeContentFilterRegexProgram

  init(_ pattern: String) throws {
    guard !pattern.isEmpty else {
      throw SafeContentFilterRegexError.emptyPattern
    }

    var scalars = [Unicode.Scalar]()
    scalars.reserveCapacity(Self.maximumPatternCharacters)
    for scalar in pattern.unicodeScalars {
      guard scalars.count < Self.maximumStates else {
        throw SafeContentFilterRegexError.stateLimitExceeded(
          maximum: Self.maximumStates
        )
      }
      scalars.append(scalar)
    }
    guard pattern.count <= Self.maximumPatternCharacters else {
      throw SafeContentFilterRegexError.patternTooLong(
        maximum: Self.maximumPatternCharacters
      )
    }

    var parser = SafeContentFilterRegexParser(
      scalars: scalars,
      maximumRepeatCount: Self.maximumRepeatCount
    )
    let expression = try parser.parse()
    var compiler = SafeContentFilterRegexCompiler(maximumStates: Self.maximumStates)
    let program = try compiler.compile(expression)

    self.pattern = pattern
    self.program = program
  }

  func matches(in text: String) -> Bool {
    let input = Input(text)
    var workspace = Workspace()
    var remainingSteps = Int.max
    return match(
      in: input,
      workspace: &workspace,
      remainingSteps: &remainingSteps
    ) == .matched
  }

  func match(
    in input: Input,
    workspace: inout Workspace,
    remainingSteps: inout Int
  ) -> MatchResult {
    program.match(
      in: input,
      workspace: &workspace,
      remainingSteps: &remainingSteps
    )
  }
}

private indirect enum SafeContentFilterRegexExpression: Hashable, Sendable {
  case empty
  case atom(SafeContentFilterRegexAtom)
  case concatenation([Self])
  case alternation([Self])
  case repetition(Self, minimum: Int, maximum: Int?)

  var isSyntacticallyEmpty: Bool {
    switch self {
    case .empty:
      true
    case .concatenation(let expressions):
      expressions.isEmpty
    case .atom, .alternation, .repetition:
      false
    }
  }

  var isDirectAssertion: Bool {
    guard case .atom(.assertion(_)) = self else { return false }
    return true
  }
}

private enum SafeContentFilterRegexAtom: Hashable, Sendable {
  case matcher(SafeContentFilterRegexScalarMatcher)
  case assertion(SafeContentFilterRegexAssertion)
}

private enum SafeContentFilterRegexAssertion: Hashable, Sendable {
  case start
  case end
  case wordBoundary
  case nonWordBoundary
}

private enum SafeContentFilterRegexPredefinedClass: Hashable, Sendable {
  case digit
  case word
  case whitespace
}

private enum SafeContentFilterRegexClassMember: Hashable, Sendable {
  case scalar(UInt32)
  case range(ClosedRange<UInt32>)
  case predefined(SafeContentFilterRegexPredefinedClass, inverted: Bool)

  func matches(_ scalar: Unicode.Scalar) -> Bool {
    switch self {
    case .scalar(let value):
      scalar.value == value
    case .range(let range):
      range.contains(scalar.value)
    case .predefined(let value, let inverted):
      SafeContentFilterRegexScalarMatcher.predefined(value, matches: scalar) != inverted
    }
  }
}

private enum SafeContentFilterRegexScalarMatcher: Hashable, Sendable {
  case literal(UInt32)
  case any
  case predefined(SafeContentFilterRegexPredefinedClass, inverted: Bool)
  case characterClass([SafeContentFilterRegexClassMember], inverted: Bool)

  var matchWorkCost: Int {
    switch self {
    case .literal, .any, .predefined:
      1
    case .characterClass(let members, _):
      max(members.count, 1)
    }
  }

  func matches(_ scalar: Unicode.Scalar) -> Bool {
    switch self {
    case .literal(let value):
      scalar.value == value
    case .any:
      !Self.isLineTerminator(scalar)
    case .predefined(let value, let inverted):
      Self.predefined(value, matches: scalar) != inverted
    case .characterClass(let members, let inverted):
      members.contains(where: { $0.matches(scalar) }) != inverted
    }
  }

  static func predefined(
    _ value: SafeContentFilterRegexPredefinedClass,
    matches scalar: Unicode.Scalar
  ) -> Bool {
    switch value {
    case .digit:
      CharacterSet.decimalDigits.contains(scalar)
    case .word:
      scalar.value == 0x5F
        || CharacterSet.alphanumerics.contains(scalar)
        || CharacterSet.nonBaseCharacters.contains(scalar)
    case .whitespace:
      CharacterSet.whitespacesAndNewlines.contains(scalar)
    }
  }

  static func isWord(_ scalar: Unicode.Scalar?) -> Bool {
    guard let scalar else { return false }
    return predefined(.word, matches: scalar)
  }

  private static func isLineTerminator(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x0A, 0x0D, 0x85, 0x2028, 0x2029:
      true
    default:
      false
    }
  }
}

private struct SafeContentFilterRegexParser {
  private enum ClassElement {
    case scalar(UInt32)
    case predefined(SafeContentFilterRegexPredefinedClass, inverted: Bool)

    var member: SafeContentFilterRegexClassMember {
      switch self {
      case .scalar(let value):
        .scalar(value)
      case .predefined(let value, let inverted):
        .predefined(value, inverted: inverted)
      }
    }

    var scalarValue: UInt32? {
      guard case .scalar(let value) = self else { return nil }
      return value
    }
  }

  let scalars: [Unicode.Scalar]
  let maximumRepeatCount: Int
  private(set) var index = 0

  mutating func parse() throws -> SafeContentFilterRegexExpression {
    let expression = try parseAlternation()
    guard index == scalars.count else {
      if peek == ")" {
        throw SafeContentFilterRegexError.unexpectedClosingParenthesis(position: index)
      }
      throw SafeContentFilterRegexError.unexpectedToken(position: index)
    }
    return expression
  }

  private mutating func parseAlternation() throws -> SafeContentFilterRegexExpression {
    var branches = [try parseConcatenation()]
    while peek == "|" {
      let separatorPosition = index
      advance()
      let branch = try parseConcatenation()
      guard !branches.last!.isSyntacticallyEmpty, !branch.isSyntacticallyEmpty else {
        throw SafeContentFilterRegexError.emptyAlternative(position: separatorPosition)
      }
      branches.append(branch)
    }
    if branches.count == 1 { return branches[0] }
    return .alternation(branches)
  }

  private mutating func parseConcatenation() throws -> SafeContentFilterRegexExpression {
    var expressions = [SafeContentFilterRegexExpression]()
    while let scalar = peek, scalar != "|", scalar != ")" {
      expressions.append(try parseRepetition())
    }
    if expressions.isEmpty { return .empty }
    if expressions.count == 1 { return expressions[0] }
    return .concatenation(expressions)
  }

  private mutating func parseRepetition() throws -> SafeContentFilterRegexExpression {
    let atomPosition = index
    var expression = try parseAtom()
    guard let scalar = peek else { return expression }

    let bounds: (minimum: Int, maximum: Int?)?
    switch scalar {
    case "?":
      advance()
      bounds = (0, 1)
    case "*":
      advance()
      bounds = (0, nil)
    case "+":
      advance()
      bounds = (1, nil)
    case "{":
      bounds = try parseBoundedQuantifier()
    default:
      bounds = nil
    }

    guard let bounds else { return expression }
    guard !expression.isDirectAssertion else {
      throw SafeContentFilterRegexError.invalidQuantifier(position: atomPosition)
    }
    if let next = peek, next == "?" || next == "*" || next == "+" || next == "{" {
      throw SafeContentFilterRegexError.invalidQuantifier(position: index)
    }
    expression = .repetition(
      expression,
      minimum: bounds.minimum,
      maximum: bounds.maximum
    )
    return expression
  }

  private mutating func parseAtom() throws -> SafeContentFilterRegexExpression {
    guard let scalar = peek else {
      throw SafeContentFilterRegexError.unexpectedToken(position: index)
    }
    let position = index
    advance()

    switch scalar {
    case "(":
      let expression = try parseAlternation()
      guard peek == ")" else {
        throw SafeContentFilterRegexError.unterminatedGroup(position: position)
      }
      advance()
      guard !expression.isSyntacticallyEmpty else {
        throw SafeContentFilterRegexError.emptyGroup(position: position)
      }
      return expression
    case ")":
      throw SafeContentFilterRegexError.unexpectedClosingParenthesis(position: position)
    case "[":
      return .atom(.matcher(try parseCharacterClass(openingPosition: position)))
    case "]", "}", "?", "*", "+", "|":
      throw SafeContentFilterRegexError.unexpectedToken(position: position)
    case "{":
      throw SafeContentFilterRegexError.invalidQuantifier(position: position)
    case ".":
      return .atom(.matcher(.any))
    case "^":
      return .atom(.assertion(.start))
    case "$":
      return .atom(.assertion(.end))
    case "\\":
      return .atom(try parseEscapedAtom(backslashPosition: position))
    default:
      return .atom(.matcher(.literal(scalar.value)))
    }
  }

  private mutating func parseEscapedAtom(
    backslashPosition: Int
  ) throws -> SafeContentFilterRegexAtom {
    guard let scalar = peek else {
      throw SafeContentFilterRegexError.invalidEscape(position: backslashPosition)
    }
    advance()
    return switch scalar {
    case "d":
      .matcher(.predefined(.digit, inverted: false))
    case "D":
      .matcher(.predefined(.digit, inverted: true))
    case "w":
      .matcher(.predefined(.word, inverted: false))
    case "W":
      .matcher(.predefined(.word, inverted: true))
    case "s":
      .matcher(.predefined(.whitespace, inverted: false))
    case "S":
      .matcher(.predefined(.whitespace, inverted: true))
    case "b":
      .assertion(.wordBoundary)
    case "B":
      .assertion(.nonWordBoundary)
    case "\\", ".", "[", "]", "(", ")", "{", "}", "?", "*", "+", "|", "^", "$", "-":
      .matcher(.literal(scalar.value))
    default:
      throw SafeContentFilterRegexError.invalidEscape(position: backslashPosition)
    }
  }

  private mutating func parseCharacterClass(
    openingPosition: Int
  ) throws -> SafeContentFilterRegexScalarMatcher {
    var inverted = false
    if peek == "^" {
      inverted = true
      advance()
    }

    var members = [SafeContentFilterRegexClassMember]()
    while let scalar = peek {
      if scalar == "]" {
        advance()
        guard !members.isEmpty else {
          throw SafeContentFilterRegexError.emptyCharacterClass(position: openingPosition)
        }
        return .characterClass(members, inverted: inverted)
      }

      let elementPosition = index
      let first = try parseClassElement(openingPosition: openingPosition)
      if peek == "-" {
        let hyphenPosition = index
        advance()
        if peek == "]" {
          members.append(first.member)
          members.append(.scalar(0x2D))
          continue
        }
        guard peek != nil else {
          throw SafeContentFilterRegexError.unterminatedCharacterClass(
            position: openingPosition
          )
        }
        let second = try parseClassElement(openingPosition: openingPosition)
        guard
          let lower = first.scalarValue,
          let upper = second.scalarValue,
          lower <= upper
        else {
          throw SafeContentFilterRegexError.invalidCharacterRange(
            position: hyphenPosition
          )
        }
        members.append(.range(lower...upper))
      } else {
        members.append(first.member)
      }

      guard index > elementPosition else {
        throw SafeContentFilterRegexError.unexpectedToken(position: elementPosition)
      }
    }

    throw SafeContentFilterRegexError.unterminatedCharacterClass(position: openingPosition)
  }

  private mutating func parseClassElement(
    openingPosition: Int
  ) throws -> ClassElement {
    guard let scalar = peek else {
      throw SafeContentFilterRegexError.unterminatedCharacterClass(position: openingPosition)
    }
    let position = index
    advance()
    guard scalar == "\\" else { return .scalar(scalar.value) }
    guard let escaped = peek else {
      throw SafeContentFilterRegexError.invalidEscape(position: position)
    }
    advance()
    switch escaped {
    case "d":
      return .predefined(.digit, inverted: false)
    case "D":
      return .predefined(.digit, inverted: true)
    case "w":
      return .predefined(.word, inverted: false)
    case "W":
      return .predefined(.word, inverted: true)
    case "s":
      return .predefined(.whitespace, inverted: false)
    case "S":
      return .predefined(.whitespace, inverted: true)
    case "\\", ".", "[", "]", "(", ")", "{", "}", "?", "*", "+", "|", "^", "$", "-":
      return .scalar(escaped.value)
    default:
      throw SafeContentFilterRegexError.invalidEscape(position: position)
    }
  }

  private mutating func parseBoundedQuantifier() throws -> (minimum: Int, maximum: Int?) {
    let openingPosition = index
    advance()
    let minimum = try parseRepeatCount(quantifierPosition: openingPosition)

    if peek == "}" {
      advance()
      return (minimum, minimum)
    }
    guard peek == "," else {
      throw SafeContentFilterRegexError.invalidQuantifier(position: openingPosition)
    }
    advance()
    let maximum = try parseRepeatCount(quantifierPosition: openingPosition)
    guard peek == "}", minimum <= maximum else {
      throw SafeContentFilterRegexError.invalidQuantifier(position: openingPosition)
    }
    advance()
    return (minimum, maximum)
  }

  private mutating func parseRepeatCount(quantifierPosition: Int) throws -> Int {
    var value = 0
    var parsedDigit = false
    while let scalar = peek, (0x30...0x39).contains(scalar.value) {
      parsedDigit = true
      let digit = Int(scalar.value - 0x30)
      guard value <= (maximumRepeatCount - digit) / 10 else {
        throw SafeContentFilterRegexError.repeatCountTooLarge(
          maximum: maximumRepeatCount,
          position: quantifierPosition
        )
      }
      value = value * 10 + digit
      advance()
    }
    guard parsedDigit else {
      throw SafeContentFilterRegexError.invalidQuantifier(position: quantifierPosition)
    }
    return value
  }

  private var peek: Unicode.Scalar? {
    guard index < scalars.count else { return nil }
    return scalars[index]
  }

  private mutating func advance() {
    index += 1
  }
}

private enum SafeContentFilterRegexState: Hashable, Sendable {
  case consume(SafeContentFilterRegexScalarMatcher, next: Int)
  case split(Int, Int)
  case assertion(SafeContentFilterRegexAssertion, next: Int)
  case accept
  case placeholder
}

private struct SafeContentFilterRegexProgram: Hashable, Sendable {
  let states: [SafeContentFilterRegexState]
  let start: Int

  func match(
    in input: SafeContentFilterRegex.Input,
    workspace: inout SafeContentFilterRegex.Workspace,
    remainingSteps: inout Int
  ) -> SafeContentFilterRegex.MatchResult {
    workspace.seeds.removeAll(keepingCapacity: true)
    workspace.nextSeeds.removeAll(keepingCapacity: true)

    for position in 0...input.scalars.count {
      workspace.seeds.append(start)
      switch fillEpsilonClosure(
        at: position,
        in: input,
        workspace: &workspace,
        remainingSteps: &remainingSteps
      ) {
      case .matched:
        return .matched
      case .budgetExhausted:
        return .budgetExhausted
      case .notMatched:
        break
      }
      guard position < input.scalars.count else { break }

      workspace.nextSeeds.removeAll(keepingCapacity: true)
      let scalar = input.scalars[position]
      for stateIndex in workspace.active {
        guard case .consume(let matcher, let next) = states[stateIndex] else { continue }
        guard takeSteps(matcher.matchWorkCost, from: &remainingSteps) else {
          return .budgetExhausted
        }
        if matcher.matches(scalar) {
          workspace.nextSeeds.append(next)
        }
      }
      let previousSeeds = workspace.seeds
      workspace.seeds = workspace.nextSeeds
      workspace.nextSeeds = previousSeeds
    }
    return .notMatched
  }

  private func fillEpsilonClosure(
    at position: Int,
    in input: SafeContentFilterRegex.Input,
    workspace: inout SafeContentFilterRegex.Workspace,
    remainingSteps: inout Int
  ) -> SafeContentFilterRegex.MatchResult {
    workspace.stack.removeAll(keepingCapacity: true)
    workspace.stack.append(contentsOf: workspace.seeds)
    workspace.active.removeAll(keepingCapacity: true)
    workspace.touched.removeAll(keepingCapacity: true)

    while let stateIndex = workspace.stack.popLast() {
      guard
        states.indices.contains(stateIndex),
        !workspace.visited[stateIndex]
      else {
        continue
      }
      guard takeStep(from: &remainingSteps) else {
        clearVisited(in: &workspace)
        return .budgetExhausted
      }
      workspace.visited[stateIndex] = true
      workspace.touched.append(stateIndex)

      switch states[stateIndex] {
      case .consume:
        workspace.active.append(stateIndex)
      case .accept:
        clearVisited(in: &workspace)
        return .matched
      case .split(let first, let second):
        workspace.stack.append(second)
        workspace.stack.append(first)
      case .assertion(let assertion, let next):
        if assertionHolds(
          assertion,
          at: position,
          in: input.scalars,
          followingScalar: input.followingScalar
        ) {
          workspace.stack.append(next)
        }
      case .placeholder:
        continue
      }
    }
    clearVisited(in: &workspace)
    return .notMatched
  }

  private func clearVisited(
    in workspace: inout SafeContentFilterRegex.Workspace
  ) {
    for stateIndex in workspace.touched {
      workspace.visited[stateIndex] = false
    }
  }

  private func takeStep(from remainingSteps: inout Int) -> Bool {
    takeSteps(1, from: &remainingSteps)
  }

  private func takeSteps(_ count: Int, from remainingSteps: inout Int) -> Bool {
    guard count > 0, remainingSteps >= count else { return false }
    remainingSteps -= count
    return true
  }

  private func assertionHolds(
    _ assertion: SafeContentFilterRegexAssertion,
    at position: Int,
    in scalars: [Unicode.Scalar],
    followingScalar: Unicode.Scalar?
  ) -> Bool {
    switch assertion {
    case .start:
      position == 0
    case .end:
      position == scalars.count && followingScalar == nil
    case .wordBoundary, .nonWordBoundary:
      let previous = position > 0 ? scalars[position - 1] : nil
      let next = position < scalars.count ? scalars[position] : followingScalar
      let isBoundary = SafeContentFilterRegexScalarMatcher.isWord(previous)
        != SafeContentFilterRegexScalarMatcher.isWord(next)
      return assertion == .wordBoundary ? isBoundary : !isBoundary
    }
  }
}

private struct SafeContentFilterRegexCompiler {
  let maximumStates: Int
  private var states = [SafeContentFilterRegexState]()

  init(maximumStates: Int) {
    self.maximumStates = maximumStates
  }

  mutating func compile(
    _ expression: SafeContentFilterRegexExpression
  ) throws -> SafeContentFilterRegexProgram {
    let accept = try append(.accept)
    let start = try compile(expression, continuingAt: accept)
    guard !states.contains(.placeholder) else {
      throw SafeContentFilterRegexError.stateLimitExceeded(maximum: maximumStates)
    }
    return SafeContentFilterRegexProgram(states: states, start: start)
  }

  private mutating func compile(
    _ expression: SafeContentFilterRegexExpression,
    continuingAt continuation: Int
  ) throws -> Int {
    switch expression {
    case .empty:
      return continuation
    case .atom(let atom):
      switch atom {
      case .matcher(let matcher):
        return try append(.consume(matcher, next: continuation))
      case .assertion(let assertion):
        return try append(.assertion(assertion, next: continuation))
      }
    case .concatenation(let expressions):
      var start = continuation
      for expression in expressions.reversed() {
        start = try compile(expression, continuingAt: start)
      }
      return start
    case .alternation(let expressions):
      guard let last = expressions.last else { return continuation }
      var start = try compile(last, continuingAt: continuation)
      for expression in expressions.dropLast().reversed() {
        let branch = try compile(expression, continuingAt: continuation)
        start = try append(.split(branch, start))
      }
      return start
    case .repetition(let expression, let minimum, let maximum):
      return try compileRepetition(
        expression,
        minimum: minimum,
        maximum: maximum,
        continuingAt: continuation
      )
    }
  }

  private mutating func compileRepetition(
    _ expression: SafeContentFilterRegexExpression,
    minimum: Int,
    maximum: Int?,
    continuingAt continuation: Int
  ) throws -> Int {
    guard let maximum else {
      let loop = try append(.placeholder)
      let repeated = try compile(expression, continuingAt: loop)
      states[loop] = .split(repeated, continuation)
      if minimum == 0 { return loop }
      return repeated
    }

    var start = continuation
    if maximum > minimum {
      for _ in 0..<(maximum - minimum) {
        let optional = try compile(expression, continuingAt: start)
        start = try append(.split(optional, start))
      }
    }
    if minimum > 0 {
      for _ in 0..<minimum {
        start = try compile(expression, continuingAt: start)
      }
    }
    return start
  }

  private mutating func append(_ state: SafeContentFilterRegexState) throws -> Int {
    guard states.count < maximumStates else {
      throw SafeContentFilterRegexError.stateLimitExceeded(maximum: maximumStates)
    }
    let index = states.count
    states.append(state)
    return index
  }
}
