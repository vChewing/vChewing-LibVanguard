// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import CSQLite3
import Foundation

// MARK: - VanguardTrie.SQLTrie + VanguardTrieProtocol

// 讓 SQLTrie 遵循 VanguardTrieProtocol
extension VanguardTrie.SQLTrie: VanguardTrieProtocol {
  /// 根據 keychain 字串查詢節點 ID
  public func getNodeIDsForKeyArray(_ keyArray: [String], longerSpan: Bool) -> [Int] {
    guard !keyArray.isEmpty, keyArray.allSatisfy({ !$0.isEmpty }) else { return [] }
    let keyInitialsStr = keyArray.compactMap {
      $0.first?.description
    }.joined()

    let formedKeyHash: Int = {
      var hasher = Hasher()
      hasher.combine(keyInitialsStr)
      hasher.combine(longerSpan)
      return hasher.finalize()
    }()

    if let cachedResult = queryBuffer4NodeIDs.get(hashKey: formedKeyHash) {
      return cachedResult.sorted()
    }

    var nodeIDs = Set<Int>()
    let escapedKeyInitials = keyInitialsStr.replacingOccurrences(of: "'", with: "''")

    let query = switch longerSpan {
    case false: """
      SELECT node_ids FROM keyinitials_id_map
      WHERE keyinitials = '\(escapedKeyInitials)'
      """
    case true: """
      SELECT node_ids FROM keyinitials_id_map
      WHERE keyinitials LIKE '\(escapedKeyInitials)%'
      """
    }

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
      while sqlite3_step(statement) == SQLITE_ROW {
        if let jsonData = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) {
          // 將 JSON 字串解析為 [Int]，然後轉換為 Set<Int>
          if let data = jsonData.data(using: .utf8),
             let setDecoded = try? jsonDecoder.decode(Set<Int>.self, from: data) {
            nodeIDs.formUnion(setDecoded)
          }
        }
      }
    }

    sqlite3_finalize(statement)
    queryBuffer4NodeIDs.set(hashKey: formedKeyHash, value: nodeIDs)
    return nodeIDs.sorted()
  }

  /// 此處不需要做 keyArray 長度配對檢查。
  public func getNodes(
    keyArray: [String],
    filterType: EntryType,
    partiallyMatch: Bool,
    longerSpan: Bool
  )
    -> [TNode] {
    let formedKeyHash: Int = {
      var hasher = Hasher()
      hasher.combine(keyArray)
      hasher.combine(filterType)
      hasher.combine(partiallyMatch)
      hasher.combine(longerSpan)
      return hasher.finalize()
    }()

    if let cachedResult = queryBuffer4Nodes.get(hashKey: formedKeyHash) { return cachedResult }

    // 接下來的步驟與 VanguardTrie.Trie 雷同。
    let matchedNodeIDs: [Int] = getNodeIDsForKeyArray(
      keyArray,
      longerSpan: longerSpan
    )
    guard !matchedNodeIDs.isEmpty else { return [] }
    var handledNodeHashes: Set<Int> = []
    let matchedNodes: [TNode] = matchedNodeIDs.compactMap {
      if let theNode = getNode($0) {
        let hash = theNode.hashValue
        if !handledNodeHashes.contains(hash) {
          handledNodeHashes.insert(theNode.hashValue)
          let nodeKeyArray = theNode.readingKey.split(separator: readingSeparator)
          if nodeMeetsFilter(theNode, filter: filterType) {
            var matched: Bool = longerSpan
              ? nodeKeyArray.count > keyArray.count
              : nodeKeyArray.count == keyArray.count
            switch partiallyMatch {
            case true:
              matched = matched && zip(nodeKeyArray, keyArray).allSatisfy { $0.hasPrefix($1) }
            case false:
              matched = matched && zip(nodeKeyArray, keyArray).allSatisfy(==)
            }
            return matched ? theNode : nil
          }
        }
      }
      return nil
    }
    let result = matchedNodes
    // 最後，將本次查詢的結果塞入快取。
    queryBuffer4Nodes.set(hashKey: formedKeyHash, value: result)
    return result
  }

  public func getNode(_ nodeID: Int) -> TNode? {
    if let cachedResult = queryBuffer4Node.get(hashKey: nodeID) { return cachedResult }
    // 基本查詢，只查必要資訊
    let query = """
    SELECT id, reading_key, entries_blob
    FROM nodes
    WHERE id = ?
    LIMIT 1
    """
    var statement: OpaquePointer?

    guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
      sqlite3_finalize(statement)
      return nil
    }
    defer { sqlite3_finalize(statement) }

    sqlite3_bind_int64(statement, 1, sqlite3_int64(nodeID))

    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

    // 直接從欄位讀取資料（注意：欄位索引從 0 開始）
    let id = Int(sqlite3_column_int64(statement, 0))
    let readingKey = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""

    // 創建節點
    let node = VanguardTrie.Trie.TNode(
      id: id,
      entries: [],
      readingKey: readingKey
    )

    // 解析詞條資料（如果有的話）
    if let blobPtr = sqlite3_column_text(statement, 2) {
      let blobString = String(cString: blobPtr)
      if !blobString.isEmpty, let entries = decodeEntriesFromBase64(blobString) {
        guard !entries.isEmpty else {
          queryBuffer4Node.set(hashKey: nodeID, value: nil)
          return nil
        }
        node.entries = entries
      }
    }

    queryBuffer4Node.set(hashKey: nodeID, value: node)
    return node
  }
}
