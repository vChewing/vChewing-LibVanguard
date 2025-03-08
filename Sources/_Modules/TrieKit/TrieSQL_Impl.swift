// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import CSQLite3
import Foundation

// MARK: - VanguardTrie.SQLTrie + VanguardTrieProtocol

// 讓 SQLTrie 遵循 VanguardTrieProtocol
extension VanguardTrie.SQLTrie: VanguardTrieProtocol {
  public func getNodeIDs(
    keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool
  )
    -> Set<Int> {
    guard !keys.isEmpty else { return [] }

    if partiallyMatch {
      var nodeIDs = Set<Int>()

      // 構建查詢前綴條件
      let firstKeyEscaped = keys[0].replacingOccurrences(of: "'", with: "''")
      let typeFilter = filterType.rawValue > 0 ?
        """
        AND EXISTS (
          SELECT 1 FROM entries e
          WHERE e.node_id = k.node_id
          AND (e.type_id & \(filterType.rawValue) != 0)
        )
        """ : ""

      // 查詢與前綴匹配的 keychain
      let query = """
        SELECT k.node_id
        FROM keychain_id_map k
        WHERE k.keychain LIKE '\(firstKeyEscaped)%'
        \(typeFilter)
      """

      var statement: OpaquePointer?

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        while sqlite3_step(statement) == SQLITE_ROW {
          let nodeID = Int(sqlite3_column_int(statement, 0))
          nodeIDs.insert(nodeID)
        }
      }

      sqlite3_finalize(statement)
      return nodeIDs
    } else {
      // 精確匹配
      let keychain = keys.joined(separator: readingSeparator)
      return getNodeIDsForKeychain(keychain, filterType: filterType)
    }
  }

  public func getNode(nodeID: Int) -> VanguardTrie.Trie.TNode? {
    // 查詢節點信息
    let query = """
      SELECT n.id, n.parent_id, n.character
      FROM nodes n
      WHERE n.id = ?
    """

    var statement: OpaquePointer?
    var node: VanguardTrie.Trie.TNode?

    if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
      sqlite3_bind_int(statement, 1, Int32(nodeID))

      if sqlite3_step(statement) == SQLITE_ROW {
        // 獲取節點基本信息
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

        // 創建節點
        node = VanguardTrie.Trie.TNode(
          id: id,
          entries: [],
          parentID: parentID,
          character: character
        )

        // 獲取子節點信息並更新 children 字典
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

    // 如果找到了節點，還需要獲取該節點的所有條目
    if let foundNode = node {
      foundNode.entries = getEntries(node: foundNode)
    }

    return node
  }

  public func getEntries(node: VanguardTrie.Trie.TNode) -> [VanguardTrie.Trie.Entry] {
    let nodeID = node.id
    guard nodeID <= Int32.max else { return [] }

    var entries: [VanguardTrie.Trie.Entry] = []
    let query = """
      SELECT e.id, e.value, e.probability, e.previous, e.type_id
      FROM entries e
      WHERE e.node_id = ?
    """

    var statement: OpaquePointer?

    if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
      sqlite3_bind_int(statement, 1, Int32(nodeID))

      while sqlite3_step(statement) == SQLITE_ROW {
        let entryId = sqlite3_column_int(statement, 0)

        guard let valuePtr = sqlite3_column_text(statement, 1) else { continue }
        let value = String(cString: valuePtr)

        let probability = sqlite3_column_double(statement, 2)

        // 處理可能為空的 previous 欄位
        let previous: String?
        if let prevPtr = sqlite3_column_text(statement, 3) {
          previous = String(cString: prevPtr)
        } else {
          previous = nil
        }

        // 處理 typeID
        let typeIDRaw = sqlite3_column_int(statement, 4)
        let typeID = VanguardTrie.Trie.EntryType(rawValue: typeIDRaw)

        // 獲取讀音
        let readings = getReadingsForEntry(entryId: entryId)

        // 創建並添加 Entry
        let entry = VanguardTrie.Trie.Entry(
          readings: readings,
          value: value,
          typeID: typeID,
          probability: probability,
          previous: previous
        )

        entries.append(entry)
      }
    }

    sqlite3_finalize(statement)
    return entries
  }
}
