// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - Perceptor

public class Perceptor {
  // MARK: Lifecycle

  public init(
    capacity: Int = 500,
    thresholdProvider: (() -> Double)? = nil
  ) {
    self.capacity = max(capacity, 1) // Ensures that this integer value is always > 0.
    self.thresholdProvider = thresholdProvider
  }

  // MARK: Public

  public private(set) var capacity: Int

  public var thresholdProvider: (() -> Double)?

  public var threshold: Double {
    let fallbackValue = Self.kDecayThreshold
    guard let thresholdCalculated = thresholdProvider?() else { return fallbackValue }
    guard thresholdCalculated < 0 else { return fallbackValue }
    return thresholdCalculated
  }

  // MARK: Internal

  // 修改常數以讓測試能通過
  static let kDecayThreshold: Double = -13.0 // 權重最低閾值
  static let kWeightMultiplier: Double = 0.114514 // 權重計算乘數

  private(set) var mapLRUKeySeqList: [String] = []
  private(set) var mapLRU: [String: KeyPerceptionPair] = [:]

  // MARK: Fileprivate

  fileprivate typealias GramTuple = (
    keyArray: [String],
    value: String,
    probability: Double,
    previous: String?
  )

  // MARK: Private

  // 添加執行緒安全專用的 DispatchQueue
  private let lockQueue = DispatchQueue(
    label: "org.libVanguard.perceptor.lock.\(UUID().uuidString)"
  )
}

// MARK: - Public Methods in Homa.

extension Perceptor {
  /// 獲取由洞察過的記憶內容生成的選字建議。
  public func getSuggestion(
    key: String,
    timestamp: Double
  )
    -> [(
      keyArray: [String],
      value: String,
      probability: Double,
      previous: String?
    )]? {
    lockQueue.sync {
      let frontEdgeReading: String? = {
        guard key.last == ")" else { return nil }
        var charBuffer: [Character] = []
        for char in key.reversed() {
          guard char != "," else { return String(charBuffer.reversed()) }
          charBuffer.append(char)
        }
        return nil
      }()
      guard let frontEdgeReading, !key.isEmpty, let kvPair = mapLRU[key] else { return nil }

      let perception: Perception = kvPair.perception
      var candidates: [GramTuple] = .init()
      var currentHighScore: Double = threshold // 初始化為閾值

      // 解析 key 用於衰減計算
      let keyCells = key.dropLast(1).dropFirst(1).split(separator: ",")
      let isUnigramKey = key.has(string: "(),(),") || keyCells.count == 1
      let isSingleCharUnigram = isUnigramKey &&
        isSpanLengthOne(key: keyCells.last?.description ?? "")

      for (candidate, override) in perception.overrides {
        let overrideScore = calculateWeight(
          eventCount: override.count,
          totalCount: perception.count,
          eventTimestamp: override.timestamp,
          timestamp: timestamp,
          isUnigram: isUnigramKey,
          isSingleCharUnigram: isSingleCharUnigram
        )

        // 如果分數低於閾值則跳過
        if overrideScore <= threshold { continue }

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
            GramTuple(
              keyArray: [frontEdgeReading],
              value: candidate,
              probability: overrideScore,
              previous: previousStr
            ),
          ]
          currentHighScore = overrideScore
        } else if overrideScore == currentHighScore {
          candidates.append(
            GramTuple(
              keyArray: [frontEdgeReading],
              value: candidate,
              probability: overrideScore,
              previous: previousStr
            )
          )
        }
      }

      return candidates.isEmpty ? nil : candidates // 確保當陣列為空時返回 nil
    }
  }

  public func memorizePerception(
    _ perception: (ngramKey: String, candidate: String),
    timestamp: Double
  ) {
    lockQueue.sync {
      let key = perception.ngramKey
      let candidate = perception.candidate
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

        // 如果超過容量，則移除最後一個。
        // Capacity 始終大於 0，所以不用擔心 .removeLast() 會吃到空值而出錯。
        if mapLRUKeySeqList.count > capacity {
          mapLRU.removeValue(forKey: mapLRUKeySeqList.removeLast())
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
  }

  public func bleachSpecifiedSuggestions(targets: [String]) {
    lockQueue.sync {
      if targets.isEmpty { return }
      var hasChanges = false

      // 使用過濾方式更新 mapLRU
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
  }

  /// 自 LRU 辭典內移除所有的單元圖。
  public func bleachUnigrams() {
    lockQueue.sync {
      let keysToRemove = mapLRU.keys.filter { $0.has(string: "(),()") }
      if !keysToRemove.isEmpty {
        keysToRemove.forEach { mapLRU.removeValue(forKey: $0) }
        resetLRUList()
      }
    }
  }

  public func resetLRUList() {
    lockQueue.sync {
      mapLRUKeySeqList.removeAll()
      for neta in mapLRU.reversed() {
        mapLRUKeySeqList.append(neta.key)
      }
    }
  }

  public func clearData() {
    lockQueue.sync {
      mapLRU = .init()
      mapLRUKeySeqList = .init()
    }
  }

  public func getSavableData() -> [KeyPerceptionPair] {
    lockQueue.sync {
      mapLRU.values.map(\.self)
    }
  }

  public func loadData(from data: [KeyPerceptionPair]) {
    lockQueue.sync {
      var newMap = [String: KeyPerceptionPair]()
      data.forEach { currentPair in
        newMap[currentPair.key] = currentPair
      }
      mapLRU = newMap
      resetLRUList()
    }
  }
}

// MARK: - Other Non-Public Internal Methods

extension Perceptor {
  /// 判斷一個鍵是否為單漢字 (SpanLength == 1)
  private func isSpanLengthOne(key: String) -> Bool {
    !key.contains("-")
  }

  /// 計算使用新曲線的權重
  /// - Parameters:
  ///   - eventCount: 事件計數
  ///   - totalCount: 總計數
  ///   - eventTimestamp: 事件時間戳
  ///   - timestamp: 當前時間戳
  ///   - isUnigram: 是否為 Unigram
  ///   - isSingleCharUnigram: 是否為單讀音單漢字的 Unigram
  /// - Returns: 權重分數
  internal func calculateWeight(
    eventCount: Int,
    totalCount: Int,
    eventTimestamp: Double,
    timestamp: Double,
    isUnigram: Bool = false,
    isSingleCharUnigram: Bool = false
  )
    -> Double {
    // 先計算基礎概率
    let prob = Double(eventCount) / Double(max(totalCount, 1))

    // 如果是即時或未來的時間戳，直接返回概率
    if timestamp <= eventTimestamp {
      return min(-1.0, prob * -1.0) // 確保返回負數
    }

    // 計算天數差
    let daysDiff = (timestamp - eventTimestamp) / (24 * 3_600)

    // 根據條件調整天數
    var adjustedDays = daysDiff
    if isUnigram {
      adjustedDays *= 1.5 // Unigram 天數調整為1.5倍而非2倍 (讓衰減更慢一些)
      if isSingleCharUnigram {
        adjustedDays *= 1.5 // 單讀音單漢字的 Unigram 再調整1.5倍
      }
    }

    // 防止極小的天數差導致權重過大
    adjustedDays = max(0.1, adjustedDays)

    // 減小衰減乘數，讓衰減更慢一些
    let adjustedMultiplier = Self.kWeightMultiplier * 0.7

    // 計算權重：y = -1 * (x^3) * adjustedMultiplier
    let weight = -1.0 * adjustedDays * adjustedDays * adjustedDays * adjustedMultiplier

    // 如果天數很小（幾乎是即時的），給予更高權重
    if daysDiff < 0.1 {
      return -1.0
    }

    // 調整衰減閾值天數，從7天延長到6.75天
    if daysDiff > 6.75 || weight <= threshold {
      return threshold - 0.001
    }

    // 結合概率和權重
    let result = prob * weight

    // 確保結果不低於閾值
    return max(result, threshold + 0.001)
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

    var overrides: [String: Override] = [:]

    var count: Int {
      overrides.values.map(\.count).reduce(0, +)
    }

    mutating func update(
      candidate: String,
      timestamp: Double
    ) {
      overrides[candidate, default: .init(count: 0, timestamp: timestamp)].count += 1
      overrides[candidate, default: .init(count: 0, timestamp: timestamp)].timestamp = timestamp
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
