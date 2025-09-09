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

    // 優化的快取鍵計算 - 使用更簡單的雜湊
    let formedKeyHash: Int = keyInitialsStr.hashValue ^ (longerSpan ? 1 : 0)

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
        if let nodeIDsText = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) {
          if !nodeIDsText.isEmpty {
            // 向後相容：支援舊的 JSON 格式和新的逗號分隔格式
            if nodeIDsText.starts(with: "[") && nodeIDsText.hasSuffix("]") {
              // 舊的 JSON 格式
              if let data = nodeIDsText.data(using: .utf8),
                 let setDecoded = try? JSONDecoder().decode(Set<Int>.self, from: data) {
                nodeIDs.formUnion(setDecoded)
              }
            } else {
              // 新的逗號分隔格式（更快）
              let nodeIDStrings = nodeIDsText.split(separator: ",")
              for nodeIDString in nodeIDStrings {
                if let nodeID = Int(nodeIDString) {
                  nodeIDs.insert(nodeID)
                }
              }
            }
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
    // 優化的快取鍵計算 - 使用更簡單的雜湊
    let formedKeyHash: Int = keyArray.hashValue ^ filterType.hashValue ^ (partiallyMatch ? 1 : 0) ^ (longerSpan ? 2 : 0)

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
          let nodeKeyArray = TrieStringOperationCache.shared.getCachedSplit(
            theNode.readingKey,
            separator: readingSeparator
          )
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
    
    // 使用預編譯的語句
    guard let statement = preparedNodeQuery else { return nil }
    
    // 重置語句狀態
    sqlite3_reset(statement)
    sqlite3_clear_bindings(statement)
    
    // 綁定參數
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
