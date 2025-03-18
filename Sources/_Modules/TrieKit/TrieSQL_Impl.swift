// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import CSQLite3

// MARK: - VanguardTrie.SQLTrie + VanguardTrieProtocol

// 讓 SQLTrie 遵循 VanguardTrieProtocol
extension VanguardTrie.SQLTrie: VanguardTrieProtocol {
  public func getNodeIDs(
    keyArray: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool
  )
    -> Set<Int> {
    guard !keyArray.isEmpty else { return [] }

    if partiallyMatch {
      var nodeIDs = Set<Int>()

      // 構建查詢前綴條件
      let firstKeyEscaped = keyArray[0].replacingOccurrences(of: "'", with: "''")

      // 查詢與前綴比對的 keychain
      let query = """
        SELECT k.node_id
        FROM keychain_id_map k
        WHERE k.keychain LIKE '\(firstKeyEscaped)%'
      """

      var statement: OpaquePointer?

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
          let nodeID = Int(sqlite3_column_int(statement, 0))

          if filterType.isEmpty {
            nodeIDs.insert(nodeID)
          } else {
            // 需要檢查節點中的詞條是否符合類型
            if let entriesBlob = getNodeEntriesBlob(nodeID: nodeID),
               let entries = decodeEntriesFromBase64(entriesBlob),
               entries.contains(where: { $0.typeID.contains(filterType) }) {
              nodeIDs.insert(nodeID)
            }
          }
        }
      }

      sqlite3_finalize(statement)
      return nodeIDs
    } else {
      // 精確比對
      let keychain = keyArray.joined(separator: readingSeparator.description)
      return getNodeIDsForKeychain(keychain, filterType: filterType)
    }
  }

  public func getNode(nodeID: Int) -> VanguardTrie.Trie.TNode? {
    // 查詢節點資訊
    let query = """
      SELECT n.id, n.parent_id, n.character, n.reading_key, n.entries_blob
      FROM nodes n
      WHERE n.id = ?
    """

    var statement: OpaquePointer?
    var node: VanguardTrie.Trie.TNode?

    if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
      sqlite3_bind_int(statement, 1, Int32(nodeID))

      if sqlite3_step(statement) == SQLITE_ROW {
        // 獲取節點基本資訊
        let id = Int(sqlite3_column_int(statement, 0))
        let parentID: Int?
        if sqlite3_column_type(statement, 1) != SQLITE_NULL {
          parentID = Int(sqlite3_column_int(statement, 1))
        } else {
          parentID = nil
        }

        let character: String
        if let charPtr = sqlite3_column_text(statement, 2) {
          character = String(cString: charPtr)
        } else {
          character = ""
        }

        let readingKey: String
        if let readingKeyPtr = sqlite3_column_text(statement, 3) {
          readingKey = String(cString: readingKeyPtr)
        } else {
          readingKey = ""
        }

        // 創建節點
        node = VanguardTrie.Trie.TNode(
          id: id,
          entries: [],
          parentID: parentID,
          character: character,
          readingKey: readingKey
        )

        // 解碼詞條
        if let blobPtr = sqlite3_column_text(statement, 4) {
          let blobString = String(cString: blobPtr)
          if !blobString.isEmpty, let entries = decodeEntriesFromBase64(blobString) {
            node?.entries = entries
          }
        }

        // 獲取子節點資訊並更新 children 辭典
        let childrenQuery = "SELECT id, character FROM nodes WHERE parent_id = ?"
        var childStmt: OpaquePointer?

        if sqlite3_prepare_v2(database, childrenQuery, -1, &childStmt, nil) == SQLITE_OK {
          sqlite3_bind_int(childStmt, 1, Int32(nodeID))

          while sqlite3_step(childStmt) == SQLITE_ROW {
            let childID = Int(sqlite3_column_int(childStmt, 0))
            if let charPtr = sqlite3_column_text(childStmt, 1) {
              let char = String(cString: charPtr)
              node?.children[char] = childID
            }
          }
        }

        sqlite3_finalize(childStmt)
      }
    }

    sqlite3_finalize(statement)
    return node
  }

  public func getEntries(node: VanguardTrie.Trie.TNode) -> [Entry] {
    node.entries
  }
}
