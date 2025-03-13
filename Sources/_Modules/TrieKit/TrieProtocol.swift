// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - VanguardTrieProtocol

public protocol VanguardTrieProtocol {
  typealias TNode = VanguardTrie.Trie.TNode
  typealias Entry = VanguardTrie.Trie.Entry
  typealias EntryType = VanguardTrie.Trie.EntryType

  var readingSeparator: Character { get }
  func getNodeIDs(keys: [String], filterType: EntryType, partiallyMatch: Bool) -> Set<Int>
  func getNode(nodeID: Int) -> TNode?
  func getEntries(node: TNode) -> [Entry]
}

extension VanguardTrieProtocol {
  var chopCaseSeparator: Character { "&" }

  /// 特殊函式，專門用來處理那種單個讀音位置有兩個讀音的情況。
  ///
  /// 這只可能是前端打拼音串之後被 TekkonNext.PinyinTrie 分析出了多個結果。
  /// 比如說敲了漢語拼音 s 的話會被分析成兩個結果「ㄕ」和「ㄙ」。
  /// 這會以「ㄕ\(chopCaseSeparator)ㄙ」的形式插入注拼引擎、然後再被傳到這個 Trie 內來查詢。
  func getNodeIDs(
    keysChopped: [String],
    filterType: EntryType,
    partiallyMatch: Bool
  )
    -> Set<Int> {
    // 單個讀音位置的多個可能性以 chopCaseSeparator 區隔。
    guard keysChopped.joined().contains(chopCaseSeparator) else {
      return getNodeIDs(
        keys: keysChopped,
        filterType: filterType,
        partiallyMatch: partiallyMatch
      )
    }

    var possibleReadings = [[String]]()

    // 遞歸函數生成所有組合可能性
    func generateCombinations(index: Int, current: [String]) {
      // 如果已經處理完所有切片，將當前組合加入結果
      if index >= keysChopped.count {
        possibleReadings.append(current)
        return
      }

      // 取得當前位置的所有候選項
      let candidates = keysChopped[index].split(separator: chopCaseSeparator)

      // 對每個候選項進行遞歸
      for candidate in candidates {
        var newCombination = current
        newCombination.append(candidate.description)
        generateCombinations(index: index + 1, current: newCombination)
      }
    }

    // 從索引0開始，使用空數組作為初始組合
    generateCombinations(index: 0, current: [])

    var result = Set<Int>()
    possibleReadings.forEach { keys in
      getNodeIDs(
        keys: keys,
        filterType: filterType,
        partiallyMatch: partiallyMatch
      ).forEach { nodeID in
        result.insert(nodeID)
      }
    }
    return result
  }

  func partiallyMatchedKeys(
    _ keys: [String],
    nodeIDs: Set<Int>,
    filterType: VanguardTrie.Trie.EntryType
  )
    -> Set<[String]> {
    guard !keys.isEmpty else { return [] }

    // 2. 準備收集結果與追蹤已處理節點，避免重複處理
    var result: Set<[String]> = []
    var processedNodes = Set<Int>()

    // 3. 對每個 NodeID 獲取對應節點、詞條和讀音
    for nodeID in nodeIDs {
      // 跳過已處理的節點
      guard !processedNodes.contains(nodeID),
            let node = getNode(nodeID: nodeID) else { continue }

      processedNodes.insert(nodeID)

      // 5. 提前獲取一次 entries 並重用
      let entries = getEntries(node: node)

      // 確保讀音數量相符
      let nodeReadings = node.readingKey.split(separator: readingSeparator).map(\.description)
      guard nodeReadings.count == keys.count else { continue }
      // 確保每個讀音都以對應的前綴開頭
      let allPrefixMatched = zip(keys, nodeReadings).allSatisfy { $1.hasPrefix($0) }
      guard allPrefixMatched else { continue }

      // 6. 過濾出符合條件的詞條
      let firstMatchedEntry = entries.first { entry in

        // 確保類型相符
        if !filterType.isEmpty, !entry.typeID.contains(filterType) {
          return false
        }
        return true
      }

      guard firstMatchedEntry != nil else { continue }

      // 7. 收集讀音
      result.insert(nodeReadings)
    }

    return result
  }

  public func hasGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool = false,
    partiallyMatchedKeysHandler: ((Set<[String]>) -> ())? = nil
  )
    -> Bool {
    guard !keys.isEmpty else { return false }

    if partiallyMatch {
      // 增加快速路徑：如果不需要處理比對結果，只需檢查是否有相符的節點
      if partiallyMatchedKeysHandler == nil {
        return !getNodeIDs(keysChopped: keys, filterType: filterType, partiallyMatch: true).isEmpty
      } else {
        let nodeIDs = getNodeIDs(keysChopped: keys, filterType: filterType, partiallyMatch: true)
        let partiallyMatchedResult = partiallyMatchedKeys(
          keys,
          nodeIDs: nodeIDs,
          filterType: filterType
        )
        partiallyMatchedKeysHandler?(partiallyMatchedResult)
        return !partiallyMatchedResult.isEmpty
      }
    } else {
      // 對於精確比對，直接用 getNodeIDs
      let nodeIDs = getNodeIDs(keysChopped: keys, filterType: filterType, partiallyMatch: false)
      return !nodeIDs.isEmpty
    }
  }

  public func queryGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool = false,
    partiallyMatchedKeysPostHandler: ((Set<[String]>) -> ())? = nil
  )
    -> [(keyArray: [String], value: String, probability: Double, previous: String?)] {
    guard !keys.isEmpty else { return [] }

    if partiallyMatch {
      // 1. 獲取所有節點IDs
      let nodeIDs = getNodeIDs(keysChopped: keys, filterType: filterType, partiallyMatch: true)
      guard !nodeIDs.isEmpty else { return [] }
      // 2. 獲取比對的讀音和節點，除非 handler 是 nil。
      defer {
        let partiallyMatchedResult = partiallyMatchedKeys(
          keys,
          nodeIDs: nodeIDs,
          filterType: filterType
        )
        if !partiallyMatchedResult.isEmpty {
          partiallyMatchedKeysPostHandler?(partiallyMatchedResult)
        }
      }

      // 使用緩存避免重複查詢
      var processedNodeEntries = [Int: [Entry]]()
      var results = [(keyArray: [String], value: String, probability: Double, previous: String?)]()

      // 3. 獲取每個節點的詞條
      for nodeID in nodeIDs {
        guard let node = getNode(nodeID: nodeID) else { continue }
        let nodeReadings = node.readingKey.split(separator: readingSeparator).map(\.description)
        // 使用緩存避免重複查詢
        let entries: [Entry]
        if let cachedEntries = processedNodeEntries[nodeID] {
          entries = cachedEntries
        } else if let node = getNode(nodeID: nodeID) {
          entries = getEntries(node: node)
          processedNodeEntries[nodeID] = entries // 緩存結果
        } else {
          continue
        }
        guard nodeReadings.count == keys.count else { continue }
        guard zip(keys, nodeReadings).allSatisfy({
          let keyCases = $0.split(separator: chopCaseSeparator)
          for currentKeyCase in keyCases {
            if $1.hasPrefix(currentKeyCase) { return true }
          }
          return false
        }) else { continue }

        // 4. 過濾符合條件的詞條
        var inserted = Set<Entry>()
        let filteredEntries = entries.filter { entry in
          guard filterType.isEmpty || entry.typeID.contains(filterType) else { return false }
          return inserted.insert(entry).inserted
        }

        // 5. 將符合條件的詞條添加到結果中
        results.append(contentsOf: filteredEntries.map { entry in
          entry.asTuple(
            with: node.readingKey.split(separator: readingSeparator).map(\.description)
          )
        })
      }

      return results
    } else {
      // 精確比對 - 現在也使用緩存提高效能
      let nodeIDs = getNodeIDs(keysChopped: keys, filterType: filterType, partiallyMatch: false)
      var processedNodeEntries = [Int: [Entry]]()
      var results = [(keyArray: [String], value: String, probability: Double, previous: String?)]()

      for nodeID in nodeIDs {
        guard let node = getNode(nodeID: nodeID) else { continue }

        // 使用緩存避免重複查詢
        let entries: [Entry]
        if let cachedEntries = processedNodeEntries[nodeID] {
          entries = cachedEntries
        } else if let node = getNode(nodeID: nodeID) {
          entries = getEntries(node: node)
          processedNodeEntries[nodeID] = entries
        } else {
          continue
        }

        // 過濾符合類型的詞條
        var inserted = Set<Entry>()
        let filteredEntries = entries.filter { entry in
          guard filterType.isEmpty || entry.typeID.contains(filterType) else { return false }
          return inserted.insert(entry).inserted
        }

        results.append(contentsOf: filteredEntries.map { entry in
          entry.asTuple(
            with: node.readingKey.split(separator: readingSeparator).map(\.description)
          )
        })
      }

      return results
    }
  }
}
