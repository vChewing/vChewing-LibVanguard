// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.
// Refactored from the Cpp version of this class by Lukhnos Liu (MIT License).

import Homa

// MARK: - Perceptor

public struct Perceptor {
  // MARK: Lifecycle

  public init(
    capacity: Int = 500,
    decayConstant: Double? = nil,
    thresholdProvider: (() -> Double)? = nil
  ) {
    self.capacity = max(capacity, 1) // Ensures that this integer value is always > 0.
    let decayConstant = decayConstant ?? Self.kPerceptedOverrideHalfLife
    let logZeroDotFive: Double = -0.6931471805599453 // ln(0.5)
    self.decayExp = logZeroDotFive / decayConstant
    self.thresholdProvider = thresholdProvider
  }

  // MARK: Public

  public private(set) var capacity: Int

  public var thresholdProvider: (() -> Double)?

  public var threshold: Double {
    let fallbackValue = Double(Int8.min)
    guard let thresholdCalculated = thresholdProvider?() else { return fallbackValue }
    guard thresholdCalculated < 0 else { return fallbackValue }
    return thresholdCalculated
  }

  // MARK: Internal

  static let kPerceptedOverrideHalfLife: Double = 3_600.0 * 6 // 6 小時半衰一次，能持續不到六天的記憶。
  static let kDecayThreshold: Double = 1.0 / 1_919_810

  private(set) var decayExp: Double
  private(set) var mapLRUKeySeqList: [String] = []
  private(set) var mapLRU: [String: KeyPerceptionPair] = [:]
}

// MARK: Perceptor.PerceptionError

extension Perceptor {
  public enum PerceptionError: Error {
    case wrapped(String)

    // MARK: Lifecycle

    public init(_ msg: String) {
      self = .wrapped(msg)
    }
  }
}

// MARK: - Private Structures

extension Perceptor {
  enum OverrideUnit: String, CodingKey {
    case count = "c"
    case timestamp = "ts"
  }

  enum PerceptionUnit: String, CodingKey {
    case count = "c"
    case overrides = "o"
  }

  enum KeyPerceptionPairUnit: String, CodingKey {
    case key = "k"
    case perception = "p"
  }

  public struct Override: Hashable, Encodable, Decodable {
    // MARK: Public

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.count == rhs.count && lhs.timestamp == rhs.timestamp
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: OverrideUnit.self)
      try container.encode(count, forKey: .count)
      try container.encode(timestamp, forKey: .timestamp)
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(count)
      hasher.combine(timestamp)
    }

    // MARK: Internal

    var count: Int = 0
    var timestamp: Double = 0.0
  }

  public struct Perception: Hashable, Encodable, Decodable {
    // MARK: Public

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.count == rhs.count && lhs.overrides == rhs.overrides
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: PerceptionUnit.self)
      try container.encode(count, forKey: .count)
      try container.encode(overrides, forKey: .overrides)
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(count)
      hasher.combine(overrides)
    }

    // MARK: Internal

    var count: Int = 0
    var overrides: [String: Override] = [:]

    mutating func update(
      candidate: String,
      timestamp: Double
    ) {
      count += 1
      if overrides.keys.contains(candidate) {
        overrides[candidate]?.timestamp = timestamp
        overrides[candidate]?.count += 1
      } else {
        overrides[candidate] = .init(count: 1, timestamp: timestamp)
      }
    }
  }

  public struct KeyPerceptionPair: Hashable, Encodable, Decodable {
    // MARK: Public

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.key == rhs.key && lhs.perception == rhs.perception
    }

    public func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: KeyPerceptionPairUnit.self)
      try container.encode(key, forKey: .key)
      try container.encode(perception, forKey: .perception)
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(key)
      hasher.combine(perception)
    }

    // MARK: Internal

    var key: String
    var perception: Perception
  }
}

// MARK: - Public Methods in Homa.

extension Perceptor {
  public mutating func performPerception(
    assembledBefore: [Homa.GramInPath], assembledAfter: [Homa.GramInPath],
    cursor: Int, timestamp: Double
  ) {
    // 參數合規性檢查。
    let countBefore = assembledBefore.totalKeyCount
    let countAfter = assembledAfter.totalKeyCount
    guard countBefore == countAfter, countBefore * countAfter > 0 else { return }
    // 先判斷用哪種覆寫方法。
    var actualCursor = 0
    let currentGramInPath = assembledAfter.findGram(at: cursor, target: &actualCursor)
    guard let currentGramInPath, currentGramInPath.score >= threshold else { return }
    // 當前節點超過三個字的話，就不記憶了。在這種情形下，使用者可以考慮新增自訂語彙。
    guard currentGramInPath.spanLength <= 3 else { return }
    // 前一個節點得從前一次爬軌結果當中來找。
    guard actualCursor > 0 else { return } // 該情況應該不會出現。
    let currentGramInPathIndex = actualCursor
    actualCursor -= 1
    var prevGramInPathIndex = 0
    let prevGramInPath = assembledBefore.findGram(at: actualCursor, target: &prevGramInPathIndex)
    guard let prevGramInPath else { return }
    // 不需要跟蹤其他情況，因為一定會是 Specified Score Override。
    let breakingUp = currentGramInPath.spanLength == 1 && prevGramInPath.spanLength > 1

    let targetGramIndex = breakingUp ? currentGramInPathIndex : prevGramInPathIndex
    let key: String? = Perceptor.buildKeyForPerception(
      sentence: assembledAfter, headIndex: targetGramIndex
    )
    guard let key else { return }
    doPerception(
      key: key, candidate: currentGramInPath.value, timestamp: timestamp
    )
  }

  public func fetchSuggestion(
    currentSentence: [Homa.GramInPath], cursor: Int, timestamp: Double
  )
    -> [Homa.Gram]? {
    var headIndex = 0
    let gramIterated = currentSentence.findGram(at: cursor, target: &headIndex)
    guard let gramIterated else { return nil }
    let key = Perceptor.buildKeyForPerception(
      sentence: currentSentence,
      headIndex: headIndex
    )
    guard let key else { return nil }
    return getSuggestion(
      key: key,
      timestamp: timestamp,
      frontEdgeReading: gramIterated.joinedCurrentKey(by: "-")
    )
  }

  public mutating func bleachSpecifiedSuggestions(targets: [String]) {
    if targets.isEmpty { return }
    var hasChanges = false

    // 使用過濾方式更新 mapLRU，避免重複代碼
    let keysToRemove = mapLRU.keys.filter { key in
      let perception = mapLRU[key]?.perception
      return perception?.overrides.keys.contains(where: { targets.contains($0) }) ?? false
    }

    if !keysToRemove.isEmpty {
      hasChanges = true
      keysToRemove.forEach { mapLRU.removeValue(forKey: $0) }
    }

    if hasChanges {
      resetLRUList()
    }
  }

  /// 自 LRU 辭典內移除所有的單元圖。
  public mutating func bleachUnigrams() {
    let keysToRemove = mapLRU.keys.filter { $0.has(string: "(),()") }
    if !keysToRemove.isEmpty {
      keysToRemove.forEach { mapLRU.removeValue(forKey: $0) }
      resetLRUList()
    }
  }

  public mutating func resetLRUList() {
    mapLRUKeySeqList.removeAll()
    for neta in mapLRU.reversed() {
      mapLRUKeySeqList.append(neta.key)
    }
  }

  public mutating func clearData() {
    mapLRU = .init()
    mapLRUKeySeqList = .init()
  }

  public func getSavableData() -> [KeyPerceptionPair] {
    mapLRU.values.map(\.self)
  }

  public mutating func loadData(from data: [KeyPerceptionPair]) {
    var newMap = [String: KeyPerceptionPair]()
    data.forEach { currentPair in
      newMap[currentPair.key] = currentPair
    }
    mapLRU = newMap
    resetLRUList()
  }
}

// MARK: - Other Non-Public Internal Methods

extension Perceptor {
  internal mutating func doPerception(key: String, candidate: String, timestamp: Double) {
    // 檢查 key 是否有效
    guard !key.isEmpty else { return }

    if mapLRU[key] == nil {
      // 建立新的 perception
      var perception: Perception = .init()
      perception.update(
        candidate: candidate,
        timestamp: timestamp
      )

      let koPair = KeyPerceptionPair(key: key, perception: perception)

      // 先將 key 添加到 map 和 list 的開頭
      mapLRU[key] = koPair
      mapLRUKeySeqList.insert(key, at: 0)

      // 如果超過容量，則移除最後一個
      if mapLRUKeySeqList.count > capacity {
        if let lastKey = mapLRUKeySeqList.last {
          mapLRU.removeValue(forKey: lastKey)
        }
        mapLRUKeySeqList.removeLast()
      }

      print("Perceptor: 已完成新洞察: \(key)")
    } else {
      // 更新現有的洞察
      if var theNeta = mapLRU[key] {
        theNeta.perception.update(candidate: candidate, timestamp: timestamp)

        // 移除舊的項目引用
        if let index = mapLRUKeySeqList.firstIndex(where: { $0 == key }) {
          mapLRUKeySeqList.remove(at: index)
        }

        // 更新 Map 和 List
        mapLRU[key] = theNeta
        mapLRUKeySeqList.insert(key, at: 0)

        print("Perceptor: 已更新現有洞察: \(key)")
      }
    }
  }

  internal func getSuggestion(
    key: String,
    timestamp: Double,
    frontEdgeReading: String
  )
    -> [Homa.Gram]? {
    guard !key.isEmpty, let kvPair = mapLRU[key] else { return nil }

    let perception: Perception = kvPair.perception
    var candidates: [Homa.Gram] = .init()
    var currentHighScore: Double = 0

    for (candidate, override) in perception.overrides {
      // 對 Unigram 只給大約六小時的半衰期。
      let keyCells = key.dropLast(1).dropFirst(1).split(separator: ",")
      let isUnigramKey = key.has(string: "(),(),") || keyCells.count == 1
      var decayExp = decayExp * (isUnigramKey ? 24 : 1)
      // 對於單漢字 Unigram，讓半衰期繼續除以 12。
      guard let frontEdgeKey = keyCells.last else { continue }
      if isUnigramKey, !frontEdgeKey.contains("-") { decayExp *= 12 }

      let overrideScore = getScore(
        eventCount: override.count,
        totalCount: perception.count,
        eventTimestamp: override.timestamp,
        timestamp: timestamp,
        lambda: decayExp
      )

      // 如果分數為零則跳過
      if overrideScore <= 0 { continue }

      let previousStr: String? = {
        switch keyCells.count {
        case 2...:
          let keyCellPrev = keyCells.reversed()[1].dropFirst().dropLast().description
          let prevCells = keyCellPrev.split(separator: ":")
          if prevCells.count == 2 {
            return prevCells.last?.description
          }
          return nil
        default: return nil
        }
      }()

      if overrideScore > currentHighScore {
        candidates = [
          Homa.Gram(
            keyArray: [frontEdgeReading],
            current: candidate,
            previous: previousStr,
            probability: overrideScore
          ),
        ]
        currentHighScore = overrideScore
      } else if overrideScore == currentHighScore {
        candidates.append(
          Homa.Gram(
            keyArray: [frontEdgeReading],
            current: candidate,
            previous: previousStr,
            probability: overrideScore
          )
        )
      }
    }

    return candidates
  }

  internal func getScore(
    eventCount: Int,
    totalCount: Int,
    eventTimestamp: Double,
    timestamp: Double,
    lambda: Double
  )
    -> Double {
    let decay = _exp((timestamp - eventTimestamp) * lambda)
    if decay < Self.kDecayThreshold { return 0.0 }
    let prob = Double(eventCount) / Double(totalCount)
    return prob * decay
  }

  internal static func buildKeyForPerception(
    sentence: [Homa.GramInPath], headIndex cursorIndex: Int, readingOnly: Bool = false
  )
    -> String? {
    // let whiteList = "你他妳她祢衪它牠再在"
    var arrGrams: [Homa.GramInPath] = []
    var intLength = 0
    for gramInPath in sentence {
      arrGrams.append(gramInPath)
      intLength += gramInPath.spanLength
      if intLength >= cursorIndex {
        break
      }
    }

    if arrGrams.isEmpty { return nil }

    arrGrams = Array(arrGrams.reversed())

    let kvCurrent = Homa.CandidatePair(keyArray: arrGrams[0].keyArray, value: arrGrams[0].value)
    guard !kvCurrent.isReadingMismatched else { return nil }
    let strCurrent = kvCurrent.keyArray.joined(separator: "-")
    guard !strCurrent.contains("_") else { return nil }

    func makeNGramKey(_ target: Homa.CandidatePair?) -> String? {
      guard let target, !target.isReadingMismatched else { return nil }
      guard !target.keyArray.joined().isEmpty, !target.value.isEmpty else { return nil }
      return "(\(target.keyArray.joined(separator: "-")):\(target.value))"
    }

    // 字音數與字數不一致的內容會被拋棄。
    if kvCurrent.keyArray.count != kvCurrent.value.count { return nil }

    // 前置單元只記錄讀音，在其後的單元則同時記錄讀音與字詞
    var kvPrevious = Homa.CandidatePair?.none
    var kvAnterior = Homa.CandidatePair?.none
    var readingStack = ""
    var ngramKey: String {
      var realKeys: [String] = [kvAnterior, kvPrevious].compactMap {
        guard let thisKV = $0 else { return nil }
        return makeNGramKey(thisKV)
      }
      realKeys.append(strCurrent)
      return "(\(realKeys.joined(separator: ":")))"
    }

    var result: String? {
      if readingStack.contains("_") {
        return nil
      } else {
        let realResult = readingOnly ? strCurrent : ngramKey
        return realResult.isEmpty ? nil : realResult
      }
    }

    func checkKeyValueValidityInThisContext(_ target: Homa.CandidatePair) -> Bool {
      !target.keyArray.joined(separator: "-").contains("_") && !target.isReadingMismatched
    }

    if arrGrams.count >= 2 {
      let maybeKvPrevious = arrGrams[1].asCandidatePair
      if checkKeyValueValidityInThisContext(maybeKvPrevious) {
        kvPrevious = maybeKvPrevious
        readingStack = maybeKvPrevious.keyArray.joined(separator: "-") + readingStack
      }
    }

    if arrGrams.count >= 3 {
      let maybeKvAnterior = arrGrams[2].asCandidatePair
      if checkKeyValueValidityInThisContext(maybeKvAnterior) {
        kvAnterior = maybeKvAnterior
        readingStack = maybeKvAnterior.keyArray.joined(separator: "-") + readingStack
      }
    }

    return result
  }
}
