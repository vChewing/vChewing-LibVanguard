// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - VanguardTrieProtocol

public protocol VanguardTrieProtocol {
  typealias TNode = VanguardTrie.Trie.TNode
  typealias Entry = VanguardTrie.Trie.Entry
  typealias EntryType = VanguardTrie.Trie.EntryType

  var readingSeparator: String { get }
  func getNodeIDs(keys: [String], filterType: EntryType, partiallyMatch: Bool) -> Set<Int>
  func getNode(nodeID: Int) -> TNode?
  func getEntries(node: TNode) -> [Entry]
}

extension VanguardTrieProtocol {
  func partiallyMatchedKeys(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType
  )
    -> [[String]] {
    guard !keys.isEmpty else { return [] }

    // 1. 用 getNodeIDs() 以給定的讀音串找出被牽涉到的 NodeID 陣列
    let nodeIDs = getNodeIDs(keys: keys, filterType: filterType, partiallyMatch: true)

    // 2. 準備收集結果與追蹤已處理節點，避免重複處理
    var result: [[String]] = []
    var processedNodes = Set<Int>()

    // 3. 對每個 NodeID 獲取對應節點、詞條和讀音
    for nodeID in nodeIDs {
      // 跳過已處理的節點
      guard !processedNodes.contains(nodeID),
            let node = getNode(nodeID: nodeID) else { continue }

      processedNodes.insert(nodeID)

      // 5. 提前獲取一次 entries 並重用
      let entries = getEntries(node: node)

      // 6. 過濾出符合條件的詞條
      let matchedEntries = entries.filter { entry in
        // 確保讀音數量匹配
        guard entry.readings.count == keys.count else { return false }

        // 確保類型匹配
        if !filterType.isEmpty, !entry.typeID.contains(filterType) {
          return false
        }

        // 確保每個讀音都以對應的前綴開頭
        return zip(keys, entry.readings).allSatisfy { $1.hasPrefix($0) }
      }

      // 7. 收集讀音
      result.append(contentsOf: matchedEntries.map(\.readings))
    }

    return result
  }

  public func hasGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool = false,
    partiallyMatchedKeysHandler: (([[String]]) -> ())? = nil
  )
    -> Bool {
    guard !keys.isEmpty else { return false }

    if partiallyMatch {
      // 增加快速路徑：如果不需要處理匹配結果，只需檢查是否有匹配節點
      if partiallyMatchedKeysHandler == nil {
        return !getNodeIDs(keys: keys, filterType: filterType, partiallyMatch: true).isEmpty
      } else {
        let partiallyMatchedResult = partiallyMatchedKeys(keys, filterType: filterType)
        partiallyMatchedKeysHandler?(partiallyMatchedResult)
        return !partiallyMatchedResult.isEmpty
      }
    } else {
      // 對於精確匹配，直接用 getNodeIDs
      let nodeIDs = getNodeIDs(keys: keys, filterType: filterType, partiallyMatch: false)
      return !nodeIDs.isEmpty
    }
  }

  public func queryGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool = false,
    partiallyMatchedKeysPostHandler: (([[String]]) -> ())? = nil
  )
    -> [(keyArray: [String], value: String, probability: Double, previous: String?)] {
    guard !keys.isEmpty else { return [] }

    if partiallyMatch {
      // 1. 獲取匹配的讀音和節點
      let partiallyMatchedResult = partiallyMatchedKeys(keys, filterType: filterType)
      defer { partiallyMatchedKeysPostHandler?(partiallyMatchedResult) }

      guard !partiallyMatchedResult.isEmpty else { return [] }

      // 2. 獲取所有節點IDs
      let nodeIDs = getNodeIDs(keys: keys, filterType: filterType, partiallyMatch: true)

      // 使用緩存避免重複查詢
      var processedNodeEntries = [Int: [Entry]]()
      var results = [(keyArray: [String], value: String, probability: Double, previous: String?)]()

      // 3. 獲取每個節點的詞條
      for nodeID in nodeIDs {
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

        // 4. 過濾符合條件的詞條
        let filteredEntries = entries.filter { entry in
          guard entry.readings.count == keys.count else { return false }

          if !filterType.isEmpty, !entry.typeID.contains(filterType) {
            return false
          }

          return zip(keys, entry.readings).allSatisfy { $1.hasPrefix($0) }
        }

        // 5. 將符合條件的詞條添加到結果中
        results.append(contentsOf: filteredEntries.map(\.asTuple))
      }

      return results
    } else {
      // 精確匹配 - 現在也使用緩存提高效能
      let nodeIDs = getNodeIDs(keys: keys, filterType: filterType, partiallyMatch: false)
      var processedNodeEntries = [Int: [Entry]]()
      var results = [(keyArray: [String], value: String, probability: Double, previous: String?)]()

      for nodeID in nodeIDs {
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
        let filteredEntries = entries.filter { entry in
          filterType.isEmpty || entry.typeID.contains(filterType)
        }

        results.append(contentsOf: filteredEntries.map(\.asTuple))
      }

      return results
    }
  }
}
