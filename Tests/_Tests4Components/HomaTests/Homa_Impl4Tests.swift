// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
@testable import Homa
import Testing

// MARK: - HomaTestSuite

protocol HomaTestSuite {}

extension HomaTestSuite {
  static func makeAssemblerUsingMockLM() -> Homa.Assembler {
    .init(
      gramQuerier: { keyArray in
        [
          Homa.Gram(
            keyArray: keyArray,
            current: keyArray.joined(separator: "-"),
            previous: nil,
            probability: -1
          ).asTuple,
        ]
      },
      gramAvailabilityChecker: {
        $0.reduce(0) { $1.isEmpty ? $0 : $0 + $1.count } != 0
      }
    )
  }

  static func mustDone(_ task: @escaping () throws -> ()) -> Bool {
    do {
      try task()
      return true
    } catch {
      return false
    }
  }

  static func mustFail(_ task: @escaping () throws -> ()) -> Bool {
    do {
      try task()
      return false
    } catch {
      return true
    }
  }

  static func measureTime(_ task: @escaping () -> ()) -> Double {
    let startTime = Date.now.timeIntervalSince1970
    task()
    return Date.now.timeIntervalSince1970 - startTime
  }
}

// MARK: - Assembler Extensions for Test Purposes Only.

extension Homa.Assembler {
  /// 該函式已被淘汰，因為有「仍有極端場合無法徹底清除 node-crossing 內容」的故障。
  /// 現僅用於單元測試、以確認其繼任者是否有給出所有該給出的正常結果。
  /// - Parameter location: 游標位置。
  /// - Returns: 候選字音配對陣列。
  func fetchCandidatesDeprecated(
    at location: Int,
    filter: CandidateFetchFilter = .all
  )
    -> [Homa.CandidatePairWeighted] {
    var result = [Homa.CandidatePairWeighted]()
    guard !keys.isEmpty else { return result }
    let location = max(min(location, keys.count - 1), 0) // 防呆
    let anchors: [(location: Int, node: Homa.Node)] = fetchOverlappingNodes(at: location)
    let keyAtCursor = keys[location]
    anchors.map(\.node).forEach { theNode in
      theNode.grams.forEach { gram in
        switch filter {
        case .all:
          // 得加上這道篩選，不然會出現很多無效結果。
          if !theNode.keyArray.contains(keyAtCursor) { return }
        case .beginAt:
          if theNode.keyArray[0] != keyAtCursor { return }
        case .endAt:
          if theNode.keyArray.reversed()[0] != keyAtCursor { return }
        }
        result.append((
          pair: (keyArray: theNode.keyArray, value: gram.current),
          weight: gram.probability
        ))
      }
    }
    return result
  }
}

// MARK: - Dumping Unigrams from the Assembler.

extension Homa.Assembler {
  func dumpUnigrams() -> String {
    spans.map { currentSpan in
      currentSpan.values.map { currentNode in
        currentNode.grams.map { currentGram in
          let readingChain = currentGram.keyArray.joined(separator: "-")
          let value = currentGram.current
          let score = currentGram.probability
          return "\(readingChain) \(value) \(score)"
        }
        .joined(separator: "\n")
      }
      .joined(separator: "\n")
    }
    .joined(separator: "\n")
  }
}

// MARK: - HomaTests4MockLM

public struct HomaTests4MockLM {
  @Test("[Homa] MockedLanguageModel_(For Unit Tests)")
  func testMockLM() async throws {
    let mockLM = TestLM(rawData: strLMSampleDataHutao)
    let fangQueried = mockLM.queryGrams(["fang1"])
    #expect(fangQueried.count == 7)
    let firstBigramPreviousValue = fangQueried.compactMap(\.previous).first
    #expect(firstBigramPreviousValue == "一縷")
  }
}

// MARK: - TestLM

final class TestLM {
  // MARK: Lifecycle

  init(rawData: String, readingSeparator: String = "-", valueSegmentationOnly: Bool = false) {
    self.trie = SimpleTrie(separator: readingSeparator)
    rawData.split(whereSeparator: \.isNewline).forEach { line in
      let components = line.split(whereSeparator: \.isWhitespace)
      guard components.count >= 3 else { return }
      let value = String(components[1])
      guard let probability = Double(components[2].description) else { return }
      let previous = components.count > 3 ? String(components[3]) : nil
      let readings: [String] = valueSegmentationOnly
        ? value.map(\.description)
        : components[0].split(separator: readingSeparator).map(\.description)
      let entry = SimpleTrie.Entry(
        readings: readings,
        value: value,
        probability: probability,
        previous: previous
      )
      let key = readings.joined(separator: readingSeparator)
      trie.insert(key, entry: entry)
    }
  }

  // MARK: Internal

  var readingSeparator: String { trie.readingSeparator }

  func hasGrams(
    _ keys: [String],
    partiallyMatch: Bool = false
  )
    -> Bool {
    guard !keys.isEmpty else { return false }
    return trie.hasGrams(
      keys,
      partiallyMatch: partiallyMatch
    )
  }

  func queryGrams(
    _ keys: [String],
    partiallyMatch: Bool = false
  )
    -> [(keyArray: [String], value: String, probability: Double, previous: String?)] {
    guard !keys.isEmpty else { return [] }
    return trie.queryGrams(
      keys,
      partiallyMatch: partiallyMatch
    )
  }

  // MARK: Private

  private let trie: SimpleTrie
}

// MARK: - SimpleTrie

/// Literarily the Vanguard Trie sans EntryType and Codable support.
public class SimpleTrie {
  // MARK: Lifecycle

  public init(separator: String) {
    self.readingSeparator = separator
    self.root = .init()
    self.nodes = [:]

    // 初始化時，將根節點加入到節點字典中
    root.id = 0
    root.parentID = nil
    root.character = ""
    nodes[0] = root
  }

  // MARK: Public

  public class TNode: Hashable, Identifiable {
    // MARK: Lifecycle

    public init(
      id: Int? = nil,
      entries: [Entry] = [],
      parentID: Int? = nil,
      character: String = ""
    ) {
      self.id = id
      self.entries = entries
      self.parentID = parentID
      self.character = character
      self.children = [:]
    }

    // MARK: Public

    public var id: Int?
    public var entries: [Entry] = []
    public var parentID: Int?
    public var character: String = ""
    public var children: [String: Int] = [:] // 新的結構：字符 -> 子節點ID映射

    public static func == (
      lhs: TNode,
      rhs: TNode
    )
      -> Bool {
      lhs.hashValue == rhs.hashValue
    }

    public func hash(into hasher: inout Hasher) {
      hasher.combine(id)
      hasher.combine(entries)
      hasher.combine(parentID)
      hasher.combine(character)
      hasher.combine(children)
    }

    // MARK: Private

    private enum CodingKeys: String, CodingKey {
      case id
      case entries
      case parentID
      case character
      case children
    }
  }

  public struct Entry: Codable, Hashable, Sendable {
    public let readings: [String]
    public let value: String
    public let probability: Double
    public let previous: String?

    public var asTuple: (
      keyArray: [String],
      value: String,
      probability: Double,
      previous: String?
    ) {
      (
        keyArray: readings,
        value: value,
        probability: probability,
        previous: previous
      )
    }
  }

  public let readingSeparator: String
  public let root: TNode
  public var nodes: [Int: TNode] // 新增：節點字典，以id為索引

  // MARK: Private

  private enum CodingKeys: CodingKey {
    case readingSeparator
    case nodes
  }
}

// MARK: - Extending Methods (Trie: Insert and Search API).

extension SimpleTrie {
  func insert(_ key: String, entry: Entry) {
    var currentNode = root
    var currentNodeID = 1

    // 遍歷關鍵字的每個字符
    key.forEach { char in
      let charStr = char.description
      if let childNodeID = currentNode.children[charStr],
         let matchedNode = nodes[childNodeID] {
        // 有效的子節點已存在，繼續遍歷
        currentNodeID = childNodeID
        currentNode = matchedNode
        return
      }
      // 創建新的子節點
      let newNodeID = Int(nodes.count + 1)
      let newNode = TNode(id: newNodeID, parentID: currentNodeID, character: charStr)

      // 更新關係
      currentNode.children[charStr] = newNodeID
      nodes[newNodeID] = newNode

      // 更新當前節點
      currentNode = newNode
      currentNodeID = newNodeID
    }

    // 在最終節點添加詞條
    currentNode.entries.append(entry)
  }

  func search(_ key: String, partiallyMatch: Bool = false) -> [Entry] {
    var currentNode = root
    // 遍歷關鍵字的每個字符
    for char in key {
      let charStr = char.description
      // 查找對應字符的子節點
      guard let childNodeID = currentNode.children[charStr] else { return [] }
      guard let childNode = nodes[childNodeID] else { return [] }
      // 更新當前節點
      currentNode = childNode
    }

    return partiallyMatch ? collectAllDescendantEntries(from: currentNode) : currentNode.entries
  }

  private func collectAllDescendantEntries(from node: TNode) -> [Entry] {
    var result = node.entries
    // 遍歷所有子節點
    node.children.values.forEach { childNodeID in
      guard let childNode = nodes[childNodeID] else { return }
      result.append(contentsOf: collectAllDescendantEntries(from: childNode))
    }
    return result
  }
}

// MARK: - Extending Methods (Trie: Public Data Inventory Confirmation API).

extension SimpleTrie {
  func hasGrams(
    _ keys: [String],
    partiallyMatch: Bool = false
  )
    -> Bool {
    guard !keys.isEmpty else { return false }
    return switch partiallyMatch {
    case false: !search(keys.joined(separator: readingSeparator)).isEmpty
    case true: hasPartiallyMatchedKeys(keys)
    }
  }

  private func hasPartiallyMatchedKeys(
    _ keys: [String]
  )
    -> Bool {
    guard !keys.isEmpty else { return false }
    let searchKey = keys.joined(separator: ".*?")
    let regex = try? NSRegularExpression(pattern: "\(searchKey).*?", options: [])
    guard let regex else { return false }
    let entries = search(keys[0], partiallyMatch: true)

    for entry in entries {
      // 此處僅檢查是否會有有效內容，所以在發現第一筆有效資料之後就返回 true 即可。
      let keyChain = entry.readings.joined(separator: readingSeparator)

      // 使用 NSRegularExpression 替代 Swift Regex 以提高相容性
      let firstMatchedResult = regex.firstMatch(
        in: keyChain, options: [],
        range: NSRange(location: 0, length: keyChain.utf16.count)
      )
      guard firstMatchedResult != nil else { continue }
      guard entry.readings.count == keys.count else { continue }

      for (currentKey, currentReading) in zip(keys, entry.readings) {
        guard currentReading.hasPrefix(currentKey) else { continue }
      }
      guard !entry.readings.isEmpty else { continue }
      return true
    }
    return false
  }
}

// MARK: - Extending Methods (Trie: Public Data Query API).

extension SimpleTrie {
  func queryGrams(
    _ keys: [String],
    partiallyMatch: Bool = false
  )
    -> [(keyArray: [String], value: String, probability: Double, previous: String?)] {
    guard !keys.isEmpty else { return [] }
    switch partiallyMatch {
    case false:
      return search(keys.joined(separator: readingSeparator)).map(\.asTuple)
    case true:
      let partiallyMatchedResult = partiallyMatchedKeys(keys)
      guard !partiallyMatchedResult.isEmpty else { return [] }
      return search(keys[0], partiallyMatch: true)
        .filter { entry in
          entry.readings.count == keys.count &&
            zip(keys, entry.readings).allSatisfy { $1.hasPrefix($0) }
        }
        .map(\.asTuple)
    }
  }

  private func partiallyMatchedKeys(
    _ keys: [String]
  )
    -> [[String]] {
    guard !keys.isEmpty else { return [] }
    let searchKey = keys.joined(separator: ".*?")
    let entries = search(keys[0], partiallyMatch: true)

    return entries.compactMap { entry in
      let keyChain = entry.readings.joined(separator: readingSeparator)

      // 使用 NSRegularExpression 替代 Swift Regex 以提高相容性
      let regex = try? NSRegularExpression(pattern: "\(searchKey).*?", options: [])
      guard let regex else { return nil }
      let firstMatchedResult = regex.firstMatch(
        in: keyChain, options: [],
        range: NSRange(location: 0, length: keyChain.utf16.count)
      )
      guard firstMatchedResult != nil else { return nil }
      guard entry.readings.count == keys.count else { return nil }

      for (currentKey, currentReading) in zip(keys, entry.readings) {
        guard currentReading.hasPrefix(currentKey) else { return nil }
      }

      guard !entry.readings.isEmpty else { return nil }
      return entry.readings
    }
  }
}
