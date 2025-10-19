// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa

// MARK: - Perceptor

public final class Perceptor {
  // MARK: Lifecycle

  public init(
    capacity: Int = 500,
    thresholdProvider: (() -> Double)? = nil
  ) {
    self.mutCapacity = max(capacity, 1)
    self.thresholdProvider = thresholdProvider
  }

  // MARK: Public

  public struct OverrideSuggestion {
    public var candidates:
      [(
        keyArray: [String],
        value: String,
        probability: Double,
        previous: String?
      )] = []
    public var forceHighScoreOverride = false
    public var scenario: Homa.POMObservationScenario?
    public var overrideCursor: Int?

    public var isEmpty: Bool { candidates.isEmpty }
  }

  public var thresholdProvider: (() -> Double)?

  public var threshold: Double {
    let fallbackValue = Self.kDecayThreshold
    guard let thresholdCalculated = thresholdProvider?() else { return fallbackValue }
    guard thresholdCalculated < 0 else { return fallbackValue }
    return thresholdCalculated
  }

  public var capacity: Int {
    withLock { mutCapacity }
  }

  public func setCapacity(_ capacity: Int) {
    withLock {
      mutCapacity = max(capacity, 1)
      trimLRUIfNeededLocked()
    }
  }

  // MARK: Internal

  static let kDecayThreshold: Double = -13.0 // 權重最低閾值
  static let kWeightMultiplier: Double = 0.114514 // 權重計算乘數

  // MARK: Private

  private static let readingSeparator: Character = "-"

  private let lockQueue = DispatchQueue(
    label: "org.libVanguard.perceptor.lock.\(UUID().uuidString)"
  )

  private var mutCapacity: Int
  private var mutLRUKeySeqList: [String] = []
  private var mutLRUMap: [String: KeyPerceptionPair] = [:]

  @inline(__always)
  private func withLock<T>(_ operation: () -> T) -> T {
    lockQueue.sync(execute: operation)
  }

  private func trimLRUIfNeededLocked() {
    while mutLRUKeySeqList.count > mutCapacity {
      mutLRUMap.removeValue(forKey: mutLRUKeySeqList.removeLast())
    }
  }

  private func resetLRUListLocked() {
    purgeUnderscorePrefixedKeysLocked()
    mutLRUKeySeqList =
      mutLRUMap
        .sorted { $0.value.latestTimeStamp > $1.value.latestTimeStamp }
        .map(\.key)
  }
}

// MARK: Codable

extension Perceptor: Codable {
  public convenience init(from decoder: any Decoder) throws {
    self.init()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let parsed = try container.decode([KeyPerceptionPair].self, forKey: .lruList)
    loadData(from: parsed)
  }

  private enum CodingKeys: String, CodingKey {
    case lruList
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    let toEncode = getSavableData()
    try container.encode(toEncode, forKey: .lruList)
  }
}

// MARK: - Public Methods

extension Perceptor {
  public func fetchSuggestion(
    assembledResult: [Homa.GramInPath],
    cursor: Int,
    timestamp: Double
  )
    -> OverrideSuggestion {
    guard let currentNodeResult = assembledResult.findGram(at: cursor) else { return .init() }
    let keyCursorRaw = currentNodeResult.range.lowerBound
    guard let keyGenerationResult = assembledResult.generateKeyForPerception(cursor: keyCursorRaw)
    else { return .init() }
    var activeKey = keyGenerationResult.ngramKey

    return withLock {
      var suggestions = self._getSuggestion(key: activeKey, timestamp: timestamp)
      if suggestions == nil {
        for fallbackKey in self._alternateKeys(for: activeKey) {
          if let fallbackSuggestion = self._getSuggestion(key: fallbackKey, timestamp: timestamp) {
            suggestions = fallbackSuggestion
            activeKey = fallbackKey
            break
          }
        }
      }
      guard let suggestions else { return OverrideSuggestion() }
      let forceFlag = self._forceHighScoreOverrideFlag(for: activeKey)
      return OverrideSuggestion(
        candidates: suggestions,
        forceHighScoreOverride: forceFlag,
        scenario: nil,
        overrideCursor: keyCursorRaw
      )
    }
  }

  public func getSuggestion(
    key: String,
    timestamp: Double
  )
    -> [(keyArray: [String], value: String, probability: Double, previous: String?)]? {
    withLock {
      _getSuggestion(key: key, timestamp: timestamp)
    }
  }

  public func memorizePerception(
    _ perception: (contextualizedGramKey: String, candidate: String),
    timestamp: Double
  ) {
    let key = perception.contextualizedGramKey
    let candidate = perception.candidate
    guard !key.isEmpty else { return }
    guard !shouldIgnoreKey(key) else { return }
    withLock {
      if let thePair = mutLRUMap[key] {
        thePair.perception.update(candidate: candidate, timestamp: timestamp)
        if let index = mutLRUKeySeqList.firstIndex(of: key) {
          mutLRUKeySeqList.remove(at: index)
        }
        mutLRUMap[key] = thePair
        mutLRUKeySeqList.insert(key, at: 0)
        print("Perceptor: 已更新現有洞察: \(key)")
      } else {
        let perception = Perception()
        perception.update(candidate: candidate, timestamp: timestamp)
        let koPair = KeyPerceptionPair(key: key, perception: perception)
        mutLRUMap[key] = koPair
        mutLRUKeySeqList.insert(key, at: 0)
        print("Perceptor: 已完成新洞察: \(key)")
      }
      trimLRUIfNeededLocked()
    }
  }

  public func memorizePerception(
    _ intel: Homa.PerceptionIntel,
    timestamp: Double
  ) {
    memorizePerception(
      (contextualizedGramKey: intel.contextualizedGramKey, candidate: intel.candidate),
      timestamp: timestamp
    )
  }

  public func bleachSpecifiedSuggestions(targets: [String]) {
    guard !targets.isEmpty else { return }
    withLock {
      let keysToRemove = mutLRUMap.keys.filter { key in
        mutLRUMap[key]?.perception.overrides.keys.contains(where: { targets.contains($0) }) ?? false
      }
      if !keysToRemove.isEmpty {
        keysToRemove.forEach { mutLRUMap.removeValue(forKey: $0) }
        resetLRUListLocked()
      }
    }
  }

  /// 清除指定的建議（基於 context + candidate 對）
  public func bleachSpecifiedSuggestions(
    targets: [(contextualizedGramKey: String, candidate: String)]
  ) {
    guard !targets.isEmpty else { return }
    withLock {
      var hasChanges = false
      var keysToRemoveCompletely: [String] = []

      for target in targets {
        guard let pair = mutLRUMap[target.contextualizedGramKey] else { continue }
        let perception = pair.perception

        if perception.overrides.removeValue(forKey: target.candidate) != nil {
          hasChanges = true

          if perception.overrides.isEmpty {
            keysToRemoveCompletely.append(target.contextualizedGramKey)
          }
        }
      }

      if !keysToRemoveCompletely.isEmpty {
        keysToRemoveCompletely.forEach { mutLRUMap.removeValue(forKey: $0) }
      }

      if hasChanges {
        resetLRUListLocked()
      }
    }
  }

  /// 清除指定讀音（head reading）底下的所有建議
  public func bleachSpecifiedSuggestionsForHeadReadings(_ headReadingTargets: [String]) {
    let targets = Set(headReadingTargets.filter { !$0.isEmpty })
    guard !targets.isEmpty else { return }
    withLock {
      var hasChanges = false
      var keysToRemove: [String] = []

      for key in mutLRUMap.keys {
        guard let parts = parsePerceptionKey(key) else { continue }
        if targets.contains(parts.headReading) {
          hasChanges = true
          keysToRemove.append(key)
        }
      }

      if !keysToRemove.isEmpty {
        keysToRemove.forEach { mutLRUMap.removeValue(forKey: $0) }
      }

      if hasChanges {
        resetLRUListLocked()
      }
    }
  }

  public func bleachUnigrams() {
    withLock {
      var keysToRemove: [String] = []
      for key in mutLRUMap.keys {
        guard let parts = parsePerceptionKey(key) else { continue }
        if parts.prev1 == nil, parts.prev2 == nil {
          keysToRemove.append(key)
        }
      }
      if !keysToRemove.isEmpty {
        keysToRemove.forEach { mutLRUMap.removeValue(forKey: $0) }
        resetLRUListLocked()
      }
    }
  }

  public func resetLRUList() {
    withLock {
      resetLRUListLocked()
    }
  }

  public func clearData() {
    withLock {
      mutLRUMap.removeAll()
      mutLRUKeySeqList.removeAll()
    }
  }

  public func getSavableData() -> [KeyPerceptionPair] {
    withLock {
      mutLRUMap.values.sorted {
        $0.latestTimeStamp > $1.latestTimeStamp
      }
    }
  }

  public func loadData(from data: [KeyPerceptionPair]) {
    withLock {
      var newMap = [String: KeyPerceptionPair]()
      data.forEach { currentPair in
        guard !shouldIgnoreKey(currentPair.key) else { return }
        newMap[currentPair.key] = currentPair
      }
      mutLRUMap = newMap
      resetLRUListLocked()
      trimLRUIfNeededLocked()
    }
  }
}

// MARK: - Suggestion Helpers

extension Perceptor {
  fileprivate typealias CandidateTuple = (
    keyArray: [String],
    value: String,
    probability: Double,
    previous: String?
  )

  fileprivate struct PerceptionKeyParts {
    let headReading: String
    let headValue: String
    let prev1: (reading: String, value: String)?
    let prev2: (reading: String, value: String)?
  }

  fileprivate func _getSuggestion(
    key: String,
    timestamp: Double
  )
    -> [CandidateTuple]? {
    guard let parts = parsePerceptionKey(key) else { return nil }
    guard !shouldIgnorePerception(parts) else { return nil }
    let frontEdgeReading = parts.headReading
    guard !frontEdgeReading.isEmpty else { return nil }
    guard !key.isEmpty, let kvPair = mutLRUMap[key] else { return nil }
    let perception = kvPair.perception
    var candidates: [CandidateTuple] = []
    var currentHighScore: Double = threshold

    let keyArrayForCandidate = splitReadingSegments(frontEdgeReading)
    let isUnigramKey = parts.prev1 == nil && parts.prev2 == nil
    let isSingleCharUnigram = isUnigramKey && keyArrayForCandidate.count == 1

    for (candidate, override) in perception.overrides {
      let overrideScore = calculateWeight(
        eventCount: override.count,
        totalCount: perception.count,
        eventTimestamp: override.timestamp,
        timestamp: timestamp,
        isUnigram: isUnigramKey,
        isSingleCharUnigram: isSingleCharUnigram
      )

      if overrideScore <= threshold { continue }

      let previousStr = parts.prev1?.value
      let keyArray =
        keyArrayForCandidate.isEmpty ? [frontEdgeReading] : keyArrayForCandidate

      if overrideScore > currentHighScore {
        candidates = [
          (keyArray: keyArray, value: candidate, probability: overrideScore, previous: previousStr),
        ]
        currentHighScore = overrideScore
      } else if overrideScore == currentHighScore {
        candidates.append(
          (keyArray: keyArray, value: candidate, probability: overrideScore, previous: previousStr)
        )
      }
    }

    return candidates.isEmpty ? nil : candidates
  }

  fileprivate func _alternateKeys(for originalKey: String) -> [String] {
    guard let originalParts = parsePerceptionKey(originalKey) else { return [] }
    guard !shouldIgnorePerception(originalParts) else { return [] }
    let headSegments = splitReadingSegments(originalParts.headReading)
    let primaryHeadCandidates: Set<String> = {
      guard let firstSegment = headSegments.first else { return [] }
      guard let lastSegment = headSegments.last else { return [firstSegment] }
      if firstSegment == lastSegment { return [firstSegment] }
      return [firstSegment, lastSegment]
    }()
    guard !primaryHeadCandidates.isEmpty else { return [] }

    var results: [String] = []
    for keyCandidate in mutLRUKeySeqList {
      guard let candidateParts = parsePerceptionKey(keyCandidate) else { continue }
      guard !shouldIgnorePerception(candidateParts) else { continue }
      guard compareContextPart(candidateParts.prev1, originalParts.prev1) else { continue }
      guard compareContextPart(candidateParts.prev2, originalParts.prev2) else { continue }
      let candidateHeadSegments = splitReadingSegments(candidateParts.headReading)
      let matchesPrimaryHead = candidateHeadSegments.contains(where: primaryHeadCandidates.contains)
      let matchesFullHead = candidateParts.headReading == originalParts.headReading
      let matchesOriginalHead = candidateHeadSegments.contains(originalParts.headReading)
      guard matchesPrimaryHead || matchesFullHead || matchesOriginalHead else { continue }
      if keyCandidate != originalKey {
        results.append(keyCandidate)
      }
    }
    return results
  }

  fileprivate func _forceHighScoreOverrideFlag(for key: String) -> Bool {
    guard let parts = parsePerceptionKey(key) else { return false }
    guard !shouldIgnorePerception(parts) else { return false }
    let headLen = splitReadingSegments(parts.headReading).count
    let prev1Len = parts.prev1.map { splitReadingSegments($0.reading).count }
    let prev2Len = parts.prev2.map { splitReadingSegments($0.reading).count }

    if headLen > 1 {
      if let p1Len = prev1Len, p1Len == 1 {
        if let p2Len = prev2Len {
          return p2Len == 1
        } else {
          return true
        }
      }
    }
    return false
  }

  private func splitReadingSegments(_ reading: String) -> [String] {
    reading
      .split(separator: Self.readingSeparator)
      .map(String.init)
      .filter { !$0.isEmpty }
  }

  fileprivate func parsePerceptionKey(_ key: String) -> PerceptionKeyParts? {
    if let parsed = parseDashDelimitedPerceptionKey(key) {
      return parsed
    }
    return parseLegacyPerceptionKey(key)
  }

  fileprivate func parseDashDelimitedPerceptionKey(_ key: String) -> PerceptionKeyParts? {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.contains("&") else { return nil }

    var components: [String] = []
    var buffer = ""
    var depth = 0
    for ch in trimmed {
      if ch == "&", depth == 0 {
        let token = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty { components.append(token) }
        buffer.removeAll(keepingCapacity: true)
        continue
      }
      if ch == "(" { depth += 1 }
      if ch == ")" { depth -= 1 }
      buffer.append(ch)
      if depth < 0 { return nil }
    }

    let lastToken = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    if !lastToken.isEmpty { components.append(lastToken) }
    guard let headComponent = components.last else { return nil }

    func parseComponent(_ component: String) -> (reading: String, value: String)? {
      let trimmedComponent = component.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedComponent == "()" { return nil }
      guard trimmedComponent.first == "(", trimmedComponent.last == ")" else { return nil }
      let inner = trimmedComponent.dropFirst().dropLast()
      let segments = inner.split(separator: ",", maxSplits: 1).map(String.init)
      guard segments.count == 2 else { return nil }
      let reading = segments[0].trimmingCharacters(in: .whitespacesAndNewlines)
      let value = segments[1].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !reading.isEmpty, !value.isEmpty else { return nil }
      return (reading, value)
    }

    guard let headPair = parseComponent(headComponent) else { return nil }
    let prev1 = components.count >= 2 ? parseComponent(components[components.count - 2]) : nil
    let prev2 = components.count >= 3 ? parseComponent(components[components.count - 3]) : nil

    return .init(
      headReading: headPair.reading,
      headValue: headPair.value,
      prev1: prev1,
      prev2: prev2
    )
  }

  fileprivate func parseLegacyPerceptionKey(_ key: String) -> PerceptionKeyParts? {
    guard key.first == "(", key.last == ")", key.count >= 2 else { return nil }
    let inner = key.dropFirst().dropLast()
    var parts: [String] = []
    var depth = 0
    var token = ""
    for ch in inner {
      if ch == ",", depth == 0 {
        parts.append(token)
        token.removeAll()
        continue
      }
      if ch == "(" { depth += 1 }
      if ch == ")" { depth -= 1 }
      token.append(ch)
    }
    if !token.isEmpty { parts.append(token) }
    guard !parts.isEmpty else { return nil }
    let headReading = parts.last!.trimmingCharacters(in: .whitespaces)
    if headReading.contains("(") || headReading.contains(")") { return nil }

    func parsePrev(_ s: String) -> (String, String)? {
      if s == "()" { return nil }
      guard s.first == "(", s.last == ")" else { return nil }
      let inner = s.dropFirst().dropLast()
      if let colonIdx = inner.firstIndex(of: ":") {
        let reading = inner[..<colonIdx]
        let value = inner[inner.index(after: colonIdx)...]
        return (String(reading), String(value))
      }
      return nil
    }

    let count = parts.count
    let prev1 = count >= 2 ? parsePrev(parts[count - 2]) : nil
    let prev2 = count >= 3 ? parsePrev(parts[count - 3]) : nil
    return .init(headReading: headReading, headValue: headReading, prev1: prev1, prev2: prev2)
  }

  fileprivate func compareContextPart(
    _ lhs: (reading: String, value: String)?,
    _ rhs: (reading: String, value: String)?
  )
    -> Bool {
    switch (lhs, rhs) {
    case (nil, nil):
      true
    case let (.some(lValue), .some(rValue)):
      lValue.reading == rValue.reading && lValue.value == rValue.value
    default:
      false
    }
  }

  /// 判斷一個 perception key 是否應該被忽略（基於包含底線前綴的讀音）
  fileprivate func shouldIgnorePerception(_ parts: PerceptionKeyParts) -> Bool {
    let readings = [parts.headReading, parts.prev1?.reading, parts.prev2?.reading]
      .compactMap { $0 }
    return readings.contains { containsUnderscorePrefixedReading($0) }
  }

  /// 判斷一個 key 是否應該被忽略
  fileprivate func shouldIgnoreKey(_ key: String) -> Bool {
    guard let parts = parsePerceptionKey(key) else { return false }
    return shouldIgnorePerception(parts)
  }

  /// 檢查讀音是否包含底線前綴的片段
  fileprivate func containsUnderscorePrefixedReading(_ reading: String) -> Bool {
    splitReadingSegments(reading).contains { $0.hasPrefix("_") }
  }

  /// 清除所有包含底線前綴的 keys
  fileprivate func purgeUnderscorePrefixedKeysLocked() {
    let invalidKeys = mutLRUMap.keys.filter { shouldIgnoreKey($0) }
    guard !invalidKeys.isEmpty else { return }
    invalidKeys.forEach { mutLRUMap.removeValue(forKey: $0) }
  }
}

// MARK: - Weight Calculation

extension Perceptor {
  internal func calculateWeight(
    eventCount: Int,
    totalCount: Int,
    eventTimestamp: Double,
    timestamp: Double,
    isUnigram: Bool = false,
    isSingleCharUnigram: Bool = false
  )
    -> Double {
    let prob = Double(eventCount) / Double(max(totalCount, 1))

    if timestamp <= eventTimestamp {
      return min(-1.0, prob * -1.0)
    }

    let daysDiff = (timestamp - eventTimestamp) / (24 * 3_600)

    var T = 8.0
    if isUnigram { T *= 0.85 }
    if isSingleCharUnigram { T *= 0.8 }

    if daysDiff >= T { return threshold - 0.001 }

    let pAge = 2.0
    let ageNorm = max(0.0, 1.0 - (daysDiff / T))
    let ageFactor = pow(ageNorm, pAge)

    let freqByProb = sqrt(max(0.0, prob))
    let freqByCount = log1p(Double(eventCount)) / log(10.0)
    let freqFactor = min(1.0, 0.5 * freqByProb + 0.5 * max(0.0, freqByCount))

    let base = max(1e-9, freqFactor * ageFactor)
    let score = -base * Self.kWeightMultiplier

    return max(score, threshold + 0.001)
  }
}

// MARK: - Private Types

extension Perceptor {
  public struct Override: Hashable, Encodable, Decodable {
    // MARK: Lifecycle

    fileprivate init(count: Int, timestamp: Double) {
      self.count = count
      self.timestamp = timestamp
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      self.count = try container.decode(Int.self, forKey: .count)
      self.timestamp = try container.decode(Double.self, forKey: .timestamp)
    }

    // MARK: Public

    public fileprivate(set) var count: Int = 0
    public fileprivate(set) var timestamp: Double = 0.0

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.count == rhs.count && lhs.timestamp == rhs.timestamp
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(count, forKey: .count)
      try container.encode(timestamp, forKey: .timestamp)
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(count)
      hasher.combine(timestamp)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
      case count = "c"
      case timestamp = "ts"
    }
  }

  public final class Perception: Hashable, Encodable, Decodable {
    // MARK: Lifecycle

    fileprivate init() {}

    public required init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      self.overrides = try container.decode(
        [String: Perceptor.Override].self,
        forKey: .overrides
      )
    }

    // MARK: Public

    public fileprivate(set) var overrides: [String: Override] = [:]

    public static func == (lhs: Perception, rhs: Perception) -> Bool {
      lhs.count == rhs.count && lhs.overrides == rhs.overrides
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(overrides, forKey: .overrides)
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(overrides)
    }

    // MARK: Internal

    var count: Int {
      overrides.values.map(\.count).reduce(0, +)
    }

    // MARK: Fileprivate

    fileprivate func update(
      candidate: String,
      timestamp: Double
    ) {
      overrides[candidate, default: .init(count: 0, timestamp: timestamp)].count += 1
      overrides[candidate, default: .init(count: 0, timestamp: timestamp)].timestamp = timestamp
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
      case overrides = "o"
    }
  }

  public final class KeyPerceptionPair: Hashable, Encodable, Decodable {
    // MARK: Lifecycle

    fileprivate init(key: String, perception: Perception) {
      self.key = key
      self.perception = perception
    }

    public required init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      self.key = try container.decode(String.self, forKey: .key)
      self.perception = try container.decode(Perception.self, forKey: .perception)
    }

    // MARK: Public

    public fileprivate(set) var key: String
    public fileprivate(set) var perception: Perception

    public var latestTimeStamp: Double {
      perception.overrides.values.map(\.timestamp).max() ?? 0
    }

    public static func == (lhs: KeyPerceptionPair, rhs: KeyPerceptionPair) -> Bool {
      lhs.key == rhs.key && lhs.perception == rhs.perception
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(key, forKey: .key)
      try container.encode(perception, forKey: .perception)
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(key)
      hasher.combine(perception)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
      case key = "k"
      case perception = "p"
    }
  }
}
