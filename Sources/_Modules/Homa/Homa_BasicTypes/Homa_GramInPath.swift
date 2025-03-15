// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Homa.GramInPath

extension Homa {
  /// 假節點，便於將節點當中的任何對 assembler 外圍的有效資訊單獨拿出來以 Sendable 的形式傳遞。
  ///
  /// 該結構體的所有成員都不可變。
  @frozen
  public struct GramInPath: Codable, Hashable, Sendable {
    // MARK: Lifecycle

    public init(gram: Gram, isOverridden: Bool) {
      self.gram = gram
      self.isOverridden = isOverridden
    }

    // MARK: Public

    public let gram: Gram
    public let isOverridden: Bool

    public var value: String { gram.current }
    public var score: Double { gram.probability }
    public var spanLength: Int { gram.spanLength }
    public var keyArray: [String] { gram.keyArray }
    public var isReadingMismatched: Bool { gram.isReadingMismatched }

    /// 該節點當前狀態所展示的鍵值配對。
    public var asCandidatePair: Homa.CandidatePair {
      .init(keyArray: keyArray, value: value)
    }

    /// 將當前單元圖的讀音陣列按照給定的分隔符銜接成一個字串。
    /// - Parameter separator: 給定的分隔符，預設值為 Assembler.theSeparator。
    /// - Returns: 已經銜接完畢的字串。
    public func joinedCurrentKey(by separator: String) -> String {
      keyArray.joined(separator: separator)
    }
  }
}

extension Array where Element == Homa.GramInPath {
  /// 從一個節點陣列當中取出目前的選字字串陣列。
  public var values: [String] { compactMap(\.value) }

  /// 從一個節點陣列當中取出目前的索引鍵陣列。
  public func joinedKeys(by separator: String) -> [String] {
    map { $0.keyArray.joined(separator: separator) }
  }

  /// 從一個節點陣列當中取出目前的索引鍵陣列。
  public var keyArrays: [[String]] { map(\.keyArray) }

  /// 返回一連串的節點起點。結果為 (Result A, Result B) 辭典陣列。
  /// Result A 以索引查座標，Result B 以座標查索引。
  private var gramBorderPointDictPair: (regionCursorMap: [Int: Int], cursorRegionMap: [Int: Int]) {
    // Result A 以索引查座標，Result B 以座標查索引。
    var resultA = [Int: Int]()
    var resultB: [Int: Int] = [-1: 0] // 防呆
    var cursorCounter = 0
    enumerated().forEach { gramCounter, neta in
      resultA[gramCounter] = cursorCounter
      neta.keyArray.forEach { _ in
        resultB[cursorCounter] = gramCounter
        cursorCounter += 1
      }
    }
    resultA[count] = cursorCounter
    resultB[cursorCounter] = count
    return (resultA, resultB)
  }

  /// 返回一個辭典，以座標查索引。允許以游標位置查詢其屬於第幾個幅位座標（從 0 開始算）。
  public var cursorRegionMap: [Int: Int] { gramBorderPointDictPair.cursorRegionMap }

  /// 總讀音單元數量。在絕大多數情況下，可視為總幅位長度。
  public var totalKeyCount: Int { map(\.keyArray.count).reduce(0, +) }

  /// 根據給定的游標，返回其前後最近的節點邊界。
  /// - Parameter cursor: 給定的游標。
  public func contextRange(ofGivenCursor cursor: Int) -> Range<Int> {
    guard !isEmpty else { return 0 ..< 0 }
    let lastSpanningLength = reversed()[0].keyArray.count
    var nilReturn = (totalKeyCount - lastSpanningLength) ..< totalKeyCount
    if cursor >= totalKeyCount { return nilReturn } // 防呆
    let cursor = Swift.max(0, cursor) // 防呆
    nilReturn = cursor ..< cursor
    // 下文按道理來講不應該會出現 nilReturn。
    let mapPair = gramBorderPointDictPair
    guard let rearNodeID = mapPair.cursorRegionMap[cursor] else { return nilReturn }
    guard let rearIndex = mapPair.regionCursorMap[rearNodeID]
    else { return nilReturn }
    guard let frontIndex = mapPair.regionCursorMap[rearNodeID + 1]
    else { return nilReturn }
    return rearIndex ..< frontIndex
  }

  /// 在陣列內以給定游標位置找出對應的節點。
  /// - Parameters:
  ///   - cursor: 給定游標位置。
  ///   - outCursorAheadOfNode: 找出的節點的前端位置。
  /// - Returns: 查找結果。
  public func findGram(at cursor: Int, target outCursorAheadOfNode: inout Int) -> Element? {
    guard !isEmpty else { return nil }
    let cursor = Swift.max(0, Swift.min(cursor, totalKeyCount - 1)) // 防呆
    let range = contextRange(ofGivenCursor: cursor)
    outCursorAheadOfNode = range.upperBound
    guard let rearNodeID = gramBorderPointDictPair.1[cursor] else { return nil }
    return count - 1 >= rearNodeID ? self[rearNodeID] : nil
  }

  /// 在陣列內以給定游標位置找出對應的節點。
  /// - Parameter cursor: 給定游標位置。
  /// - Returns: 查找結果。
  public func findGram(at cursor: Int) -> Element? {
    var useless = 0
    return findGram(at: cursor, target: &useless)
  }

  /// 提供一組逐字的字音配對陣列（不使用 Homa 的 KeyValuePaired 類型），但字音不相符的節點除外。
  public var smashedPairs: [(key: String, value: String)] {
    var arrData = [(key: String, value: String)]()
    forEach { gram in
      if gram.isReadingMismatched, !gram.keyArray.joined().isEmpty {
        arrData.append(
          (key: gram.keyArray.joined(separator: "\t"), value: gram.value)
        )
        return
      }
      let arrValueChars = gram.value.map(\.description)
      gram.keyArray.enumerated().forEach { i, key in
        arrData.append((key: key, value: arrValueChars[i]))
      }
    }
    return arrData
  }
}
