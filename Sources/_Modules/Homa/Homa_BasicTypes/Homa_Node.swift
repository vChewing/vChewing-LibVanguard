// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Homa.Node.OverrideType

extension Homa.Node {
  /// 三種不同的針對一個節點的覆寫行為。
  /// - none: 無覆寫行為。
  /// - withTopGramScore: 使用指定的元圖資料值來覆寫該節點，
  /// 但卻使用當前狀態下權重最高的元圖的權重數值。
  /// 例：如果該節點內的元圖陣列是 `[("a", -114), ("b", -514), ("c", -1919)]`
  /// 的話，指定該覆寫行為則會導致該節點返回的結果為 `("c", -114)`。
  /// 該覆寫行為多用於諸如使用者半衰記憶模組的建議行為。
  /// 被覆寫的這個節點的狀態可能不會再被爬軌行為擅自改回。
  /// 該覆寫行為無法防止其它節點被爬軌函式所支配。
  /// 這種情況下就需要用到 overridingScore。
  /// - withSpecified: 將該節點權重覆寫為 overridingScore，
  /// 使其被爬軌函式所青睞、不受其他節點的影響。
  public enum OverrideType: Int, Codable {
    case none = 0
    case withTopGramScore = 1
    case withSpecified = 2
  }
}

// MARK: - Homa.Node

extension Homa {
  public final class Node: Codable {
    // MARK: Lifecycle

    /// 生成一個字詞節點。
    ///
    /// 一個節點由這些內容組成：幅位長度、索引鍵、以及一組元圖。幅位長度就是指這個
    /// 節點在組字器內橫跨了多少個字長。組字器負責構築自身的節點。對於由多個漢字組成
    /// 的詞，組字器會將多個讀音索引鍵合併為一個讀音索引鍵、據此向語言模組請求對應的
    /// 元圖結果陣列。舉例說，如果一個詞有兩個漢字組成的話，那麼讀音也是有兩個、其
    /// 索引鍵也是由兩個讀音組成的，那麼這個節點的幅位長度就是 2。
    /// - Parameters:
    ///   - keyArray: 給定索引鍵陣列，不得為空。
    ///   - spanLength: 給定幅位長度，一般情況下與給定索引鍵陣列內的索引鍵數量一致。
    ///   - grams: 給定元圖陣列，不得為空。
    public init(keyArray: [String] = [], grams: [Homa.Gram] = []) {
      self.keyArray = keyArray
      self.grams = grams
      self.bigramMap = grams.allBigramsMap
      self.currentOverrideType = .none
    }

    /// 以指定字詞節點生成拷貝。
    /// - Remark: 因為 Node 不是 Struct，所以會在 Assembler 被拷貝的時候無法被真實複製。
    /// 這樣一來，Assembler 複製品當中的 Node 的變化會被反應到原先的 Assembler 身上。
    /// 這在某些情況下會造成意料之外的混亂情況，所以需要引入一個拷貝用的建構子。
    public init(node: Node) {
      self.overridingScore = node.overridingScore
      self.keyArray = node.keyArray
      self.grams = node.grams
      self.bigramMap = node.bigramMap
      self.currentOverrideType = node.currentOverrideType
      self.currentGramIndex = node.currentGramIndex
    }

    // MARK: Public

    /// 一個用以覆寫權重的數值。該數值之高足以改變爬軌函式對該節點的讀取結果。這裡用
    /// 「0」可能看似足夠了，但仍會使得該節點的覆寫狀態有被爬軌函式忽視的可能。比方說
    /// 要針對索引鍵「a b c」複寫的資料值為「A B C」，使用大寫資料值來覆寫節點。這時，
    /// 如果這個獨立的 c 有一個可以拮抗權重的詞「bc」的話，可能就會導致爬軌函式的算法
    /// 找出「A->bc」的爬軌途徑（尤其是當 A 和 B 使用「0」作為複寫數值的情況下）。這樣
    /// 一來，「A-B」就不一定始終會是爬軌函式的青睞結果了。所以，這裡一定要用大於 0 的
    /// 數（比如野獸常數），以讓「c」更容易單獨被選中。
    public var overridingScore: Double = 114_514

    /// 索引鍵陣列。
    public private(set) var keyArray: [String]
    /// 雙元圖快取。
    public private(set) var bigramMap: [String: Homa.Gram]
    /// 該節點目前的覆寫狀態種類。
    public private(set) var currentOverrideType: OverrideType

    /// 元圖陣列。
    public private(set) var grams: [Homa.Gram] {
      didSet {
        bigramMap = grams.allBigramsMap
      }
    }

    /// 當前該節點所指向的（元圖陣列內的）元圖索引位置。
    public private(set) var currentGramIndex: Int = 0 {
      didSet { currentGramIndex = max(min(grams.count - 1, currentGramIndex), 0) }
    }
  }
}

// MARK: - Homa.Node + Hashable

extension Homa.Node: Hashable {
  /// 預設雜湊函式。
  /// - Parameter hasher: 目前物件的雜湊碼。
  public func hash(into hasher: inout Hasher) {
    hasher.combine(overridingScore)
    hasher.combine(keyArray)
    hasher.combine(grams)
    hasher.combine(bigramMap)
    hasher.combine(currentOverrideType)
    hasher.combine(currentGramIndex)
  }
}

// MARK: - Homa.Node + Equatable

extension Homa.Node: Equatable {
  public static func == (lhs: Homa.Node, rhs: Homa.Node) -> Bool {
    lhs.hashValue == rhs.hashValue
  }
}

extension Homa.Node {
  /// 幅位長度。
  public var spanLength: Int { keyArray.count }

  /// 該節點當前狀態所展示的鍵值配對。
  public var currentPair: Homa.CandidatePair? {
    guard let value else { return nil }
    return (keyArray: keyArray, value: value)
  }

  /// 生成自身的拷貝。
  /// - Remark: 因為 Node 不是 Struct，所以會在 Assembler 被拷貝的時候無法被真實複製。
  /// 這樣一來，Assembler 複製品當中的 Node 的變化會被反應到原先的 Assembler 身上。
  /// 這在某些情況下會造成意料之外的混亂情況，所以需要引入一個拷貝用的建構子。
  public var copy: Homa.Node { .init(node: self) }

  /// 檢查當前節點是否「讀音字長與候選字字長不一致」。
  public var isReadingMismatched: Bool {
    guard let value else { return false }
    return keyArray.count != value.count
  }

  /// 該節點是否處於被覆寫的狀態。
  public var isOverridden: Bool { currentOverrideType != .none }

  /// 給出該節點內部元圖陣列內目前被索引位置所指向的元圖。
  public var currentGram: Homa.Gram? {
    grams.isEmpty ? nil : grams[currentGramIndex]
  }

  /// 給出該節點內部元圖陣列內目前被索引位置所指向的元圖的資料值。
  public var value: String? { currentGram?.current }

  /// 給出目前的最高權重單元圖當中的權重值。該結果可能會受節點覆寫狀態所影響。
  private var unigramScore: Double {
    let unigrams = grams.filter { ($0.previous ?? "").isEmpty }
    guard let firstUnigram = unigrams.first else { return 0 }
    switch currentOverrideType {
    case .withSpecified: return overridingScore
    case .withTopGramScore: return firstUnigram.probability
    default: return currentGram?.probability ?? firstUnigram.probability
    }
  }

  /// 給出目前的最高權元圖當中的權重值（包括雙元圖）。該結果可能會受節點覆寫狀態所影響。
  /// - Remarks: 這個函式會根據匹配到的前述節點內容，來查詢可能的雙元圖資料。
  /// 一旦有匹配到的雙元圖資料，就會比較雙元圖資料的權重與當前節點的權重，並選擇
  /// 權重較高的那個、然後**據此視情況自動修改這個節點的覆寫狀態種類**。
  /// - Parameter previous: 前述節點內容，用以查詢可能的雙元圖資料。
  /// - Returns: 權重。
  public func getScore(previous: String?) -> Double {
    guard !grams.isEmpty else { return 0 }
    guard let previous, !previous.isEmpty else { return unigramScore }
    let bigram = bigramMap[previous]
    let bigramScore = bigram?.probability
    let currentScore = unigramScore
    guard let bigram, let bigramScore else { return currentScore }
    guard bigramScore > currentScore else { return currentScore }
    let overrideSucceeded = selectOverrideGram(
      value: bigram.current,
      previous: bigram.previous,
      type: .withTopGramScore
    )
    return overrideSucceeded ? bigramScore : currentScore
  }

  /// 重設該節點的覆寫狀態、及其內部的元圖索引位置指向。
  public func reset() {
    currentGramIndex = 0
    currentOverrideType = .none
  }

  /// 將索引鍵按照給定的分隔符銜接成一個字串。
  /// - Parameter separator: 給定的分隔符，預設值為 Assembler.theSeparator。
  /// - Returns: 已經銜接完畢的字串。
  public func joinedKey(by separator: String) -> String {
    keyArray.joined(separator: separator)
  }

  /// 置換掉該節點內的元圖陣列資料。
  /// 如果此時影響到了 currentUnigramIndex 所指的內容的話，則將其重設為 0。
  /// - Parameter source: 新的元圖陣列資料，必須不能為空（否則必定崩潰）。
  public func syncingGrams(from source: [Homa.Gram]) {
    let oldCurrentValue = grams[currentGramIndex].current
    grams = source
    // 保險，請按需啟用。
    // if unigrams.isEmpty { unigrams.append(.init(value: key, score: -114.514)) }
    currentGramIndex = max(min(grams.count - 1, currentGramIndex), 0)
    let newCurrentValue = grams[currentGramIndex].current
    if oldCurrentValue != newCurrentValue { reset() }
  }

  /// 指定要覆寫的元圖資料值、以及覆寫行為種類。
  /// - Parameters:
  ///   - value: 給定的元圖資料值。
  ///   - previous: 前述資料。
  ///   - type: 覆寫行為種類。
  /// - Returns: 操作是否順利完成。
  public func selectOverrideGram(
    value: String,
    previous: String? = nil,
    type: Homa.Node.OverrideType
  )
    -> Bool {
    guard type != .none else { return false }
    for (i, gram) in grams.enumerated() {
      if value != gram.current { continue }
      if let previous, !previous.isEmpty, previous != gram.previous { continue }
      currentGramIndex = i
      currentOverrideType = type
      return true
    }
    return false
  }
}

// MARK: - Array Extensions.

extension Array where Element == Homa.Node {
  /// 從一個節點陣列當中取出目前的選字字串陣列。
  public var values: [String] { compactMap(\.value) }

  /// 從一個節點陣列當中取出目前的索引鍵陣列。
  public func joinedKeys(by separator: String) -> [String] {
    map { $0.keyArray.lazy.joined(separator: separator) }
  }

  /// 從一個節點陣列當中取出目前的索引鍵陣列。
  public var keyArrays: [[String]] { map(\.keyArray) }

  /// 返回一連串的節點起點。結果為 (Result A, Result B) 辭典陣列。
  /// Result A 以索引查座標，Result B 以座標查索引。
  private var nodeBorderPointDictPair: (regionCursorMap: [Int: Int], cursorRegionMap: [Int: Int]) {
    // Result A 以索引查座標，Result B 以座標查索引。
    var resultA = [Int: Int]()
    var resultB: [Int: Int] = [-1: 0] // 防呆
    var cursorCounter = 0
    enumerated().forEach { nodeCounter, neta in
      resultA[nodeCounter] = cursorCounter
      neta.keyArray.forEach { _ in
        resultB[cursorCounter] = nodeCounter
        cursorCounter += 1
      }
    }
    resultA[count] = cursorCounter
    resultB[cursorCounter] = count
    return (resultA, resultB)
  }

  /// 返回一個辭典，以座標查索引。允許以游標位置查詢其屬於第幾個幅位座標（從 0 開始算）。
  public var cursorRegionMap: [Int: Int] { nodeBorderPointDictPair.cursorRegionMap }

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
    let mapPair = nodeBorderPointDictPair
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
  ///   - outCursorPastNode: 找出的節點的前端位置。
  /// - Returns: 查找結果。
  public func findNode(at cursor: Int, target outCursorPastNode: inout Int) -> Homa.Node? {
    guard !isEmpty else { return nil }
    let cursor = Swift.max(0, Swift.min(cursor, totalKeyCount - 1)) // 防呆
    let range = contextRange(ofGivenCursor: cursor)
    outCursorPastNode = range.upperBound
    guard let rearNodeID = nodeBorderPointDictPair.1[cursor] else { return nil }
    return count - 1 >= rearNodeID ? self[rearNodeID] : nil
  }

  /// 在陣列內以給定游標位置找出對應的節點。
  /// - Parameter cursor: 給定游標位置。
  /// - Returns: 查找結果。
  public func findNode(at cursor: Int) -> Homa.Node? {
    var useless = 0
    return findNode(at: cursor, target: &useless)
  }

  /// 提供一組逐字的字音配對陣列（不使用 Homa 的 KeyValuePaired 類型），但字音不匹配的節點除外。
  public var smashedPairs: [(key: String, value: String)] {
    var arrData = [(key: String, value: String)]()
    forEach { node in
      guard let nodeValue = node.value else { return }
      if node.isReadingMismatched, !node.keyArray.joined().isEmpty {
        arrData.append(
          (key: node.keyArray.joined(separator: "\t"), value: nodeValue)
        )
        return
      }
      let arrValueChars = nodeValue.map(\.description)
      node.keyArray.enumerated().forEach { i, key in
        arrData.append((key: key, value: arrValueChars[i]))
      }
    }
    return arrData
  }
}
