// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import CSQLite3
import Foundation

// MARK: - VanguardTrie.SQLTrie

extension VanguardTrie {
  public final class SQLTrie {
    // MARK: Lifecycle

    /// 初始化 SQL 資料庫讀取器
    /// - Parameters:
    ///   - dbPath: SQLite 資料庫檔案路徑
    ///   - useDFD: 是否使用硬碟直讀。非 Apple Silicon Mac 的場合用了 DFD 可能會更慢。
    public convenience init?(dbPath: String, useDFD: Bool = false) {
      switch useDFD {
      case false: self.init(fromFileToMemory: dbPath)
      case true: self.init(dbPath4DFD: dbPath)
      }
    }

    /// 從 SQL 腳本內容初始化記憶體中的資料庫
    /// - Parameter sqlContent: SQL 腳本內容
    /// - Warning: 該 Constructor 可能會非常慢。
    /// 實際使用時建議還是直接用另一個 Constructor 直接讀取 SQLite 檔案。
    public init?(sqlContent: String) {
      // 創建記憶體資料庫
      if sqlite3_open_v2(":memory:", &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) !=
        SQLITE_OK {
        Self.printDebug("無法創建記憶體資料庫")
        return nil
      }

      // 禁用外鍵約束，以避免初始化期間的問題
      if sqlite3_exec(database, "PRAGMA foreign_keys=OFF;", nil, nil, nil) != SQLITE_OK {
        Self.printDebug("無法禁用外鍵約束: \(String(cString: sqlite3_errmsg(database)))")
        closeAndNullifyConnection()
        return nil
      }

      // 啟用延遲事務
      if sqlite3_exec(database, "PRAGMA synchronous=OFF;", nil, nil, nil) != SQLITE_OK ||
        sqlite3_exec(database, "PRAGMA journal_mode=MEMORY;", nil, nil, nil) != SQLITE_OK {
        Self.printDebug("無法優化資料庫效能: \(String(cString: sqlite3_errmsg(database)))")
      }

      var transactionBegun = false

      var errorHappened = false
      var statementBuffer = [String]()
      sqlContent.enumerateLines { currentLine, _ in
        guard !currentLine.hasPrefix("-- ") else { return }
        let isEndOfStatement = currentLine.last == ";"
        var statement: String = isEndOfStatement
          ? (statementBuffer + [currentLine]).joined(separator: "\n")
          : ""
        guard isEndOfStatement else {
          statementBuffer.append(currentLine)
          return
        }
        statementBuffer.removeAll()
        guard !errorHappened else { return }
        // 跳過空行和特定的事務控制語句
        statement = statement.trimmingCharacters(in: .newlines)
        if statement.isEmpty ||
          statement.uppercased().contains("PRAGMA SYNCHRONOUS") ||
          statement.uppercased().contains("PRAGMA JOURNAL_MODE") ||
          statement.uppercased().contains("COMMIT") ||
          statement.uppercased().contains("VACUUM") {
          return
        }

        if statement.uppercased().contains("BEGIN TRANSACTION") {
          guard !transactionBegun else { return }
          transactionBegun = true
        }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(self.database, "\(statement);", nil, nil, &errorMessage)

        if result != SQLITE_OK {
          if let errorMsg = errorMessage {
            let errorString = String(cString: errorMsg)
            Self.printDebug("執行 SQL 命令時發生錯誤: \(errorString)")
            Self.printDebug("問題命令: \(statement)")
            sqlite3_free(errorMessage)
          } else {
            Self.printDebug("執行 SQL 命令時發生錯誤，代碼: \(result)")
            Self.printDebug("問題命令: \(statement)")
          }
          sqlite3_exec(self.database, "ROLLBACK;", nil, nil, nil)
          self.closeAndNullifyConnection()
          errorHappened = true
        }
      }

      // 提交事務
      if sqlite3_exec(database, "COMMIT;", nil, nil, nil) != SQLITE_OK {
        Self.printDebug("無法提交事務: \(String(cString: sqlite3_errmsg(database)))")
        sqlite3_exec(database, "ROLLBACK;", nil, nil, nil)
        closeAndNullifyConnection()
        return nil
      }

      // 重新啟用外鍵約束
      if sqlite3_exec(database, "PRAGMA foreign_keys=ON;", nil, nil, nil) != SQLITE_OK {
        Self.printDebug("無法重新啟用外鍵約束: \(String(cString: sqlite3_errmsg(database)))")
      }

      // 初始化設定 - 直接調用相同的方法以確保一致性
      if !initializeSettings() {
        Self.printDebug("無法初始化分隔符設定")
        closeAndNullifyConnection()
        return nil
      }
    }

    /// 初始化 SQL 資料庫讀取器
    /// - Parameters:
    ///   - dbPath: SQLite 資料庫檔案路徑。
    private init?(dbPath4DFD dbPath: String) {
      // 檢查資料庫檔案是否存在
      guard FileManager.default.fileExists(atPath: dbPath) else {
        Self.printDebug("資料庫檔案不存在: \(dbPath)")
        return nil
      }

      // 選擇開啟模式
      let flags = SQLITE_OPEN_READONLY

      // 打開資料庫連接
      if sqlite3_open_v2(dbPath, &database, flags, nil) != SQLITE_OK {
        Self.printDebug("無法開啟資料庫: \(dbPath)")
        return nil
      }

      // 讀取分隔符設定
      if !initializeSettings() {
        return nil
      }
    }

    /// 從實體 SQLite 檔案讀取並在記憶體內以唯讀模式運作
    /// - Parameter dbPath: SQLite 資料庫檔案路徑
    private init?(fromFileToMemory dbPath: String) {
      // 檢查檔案是否存在
      guard FileManager.default.fileExists(atPath: dbPath) else {
        Self.printDebug("資料庫檔案不存在: \(dbPath)")
        return nil
      }

      // 先以唯讀模式開啟原始檔案
      var sourceDB: OpaquePointer?
      guard sqlite3_open_v2(dbPath, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        Self.printDebug("無法開啟來源資料庫: \(dbPath)")
        return nil
      }
      defer { sqlite3_close(sourceDB) }

      // 建立記憶體資料庫
      var memoryDB: OpaquePointer?
      guard sqlite3_open_v2(
        ":memory:",
        &memoryDB,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
        nil
      ) ==
        SQLITE_OK else {
        Self.printDebug("無法建立記憶體資料庫")
        return nil
      }

      // 準備備份物件
      let backup = sqlite3_backup_init(memoryDB, "main", sourceDB, "main")
      guard backup != nil else {
        Self.printDebug("無法初始化備份程序")
        sqlite3_close(memoryDB)
        return nil
      }

      // 執行備份
      let result = sqlite3_backup_step(backup, -1)
      sqlite3_backup_finish(backup)

      guard result == SQLITE_DONE else {
        Self.printDebug("複製到記憶體資料庫時發生錯誤")
        sqlite3_close(memoryDB)
        return nil
      }

      // 將記憶體資料庫設定為此實例的資料庫
      self.database = memoryDB

      // 讀取分隔符設定
      if !initializeSettings() {
        closeAndNullifyConnection()
        return nil
      }
    }

    deinit {
      if !closedAndNullified {
        closeAndNullifyConnection()
      }
    }

    // MARK: Public

    /// 資料庫是否為唯讀模式
    public let isReadOnly: Bool = true
    public private(set) var readingSeparator: Character = "-"
    public private(set) var closedAndNullified: Bool = false

    public let jsonDecoder: JSONDecoder = .init()

    /// - Warning: 跑過之後這個 Trie 就無法再使用了。
    public func closeAndNullifyConnection() {
      if let db = database {
        sqlite3_close_v2(db)
        database = nil
        closedAndNullified = true
      }
    }

    // MARK: Internal

    internal let queryBuffer4Node: QueryBuffer<TNode?> = .init()
    internal let queryBuffer4Nodes: QueryBuffer<[TNode]> = .init()
    internal let queryBuffer4NodeIDs: QueryBuffer<Set<Int>> = .init()
    internal var database: OpaquePointer?

    /// 獲取表的行數
    /// - Parameter tableName: 表名
    /// - Returns: 行數，如果出錯則返回nil
    func getTableRowCount(_ tableName: String) -> Int? {
      let query = "SELECT COUNT(*) FROM \(tableName)"
      var statement: OpaquePointer?
      var count: Int?

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        if sqlite3_step(statement) == SQLITE_ROW {
          count = Int(sqlite3_column_int(statement, 0))
        }
      }

      sqlite3_finalize(statement)
      return count
    }

    // MARK: - 輔助方法

    /// 從 base64 字串解碼 entries
    internal func decodeEntriesFromBase64(_ base64String: String) -> [Trie.Entry]? {
      guard !base64String.isEmpty,
            let data = Data(base64Encoded: base64String) else {
        return nil
      }

      do {
        return try plistDecoder.decode([Trie.Entry].self, from: data)
      } catch {
        Self.printDebug("Error decoding entries: \(error)")
        return nil
      }
    }

    // MARK: Private

    private let plistDecoder = PropertyListDecoder()

    private static func printDebug(
      _ items: Any...,
      separator: String = " ",
      terminator: String = "\n"
    ) {
      #if !DEBUG
        return
      #else
        print(items, separator: separator, terminator: terminator)
      #endif
    }

    /// 初始化資料庫設定
    /// - Returns: 是否成功初始化
    private func initializeSettings() -> Bool {
      // 檢查必要表是否存在
      let requiredTables = ["nodes", "keyinitials_id_map"]
      for table in requiredTables {
        if !checkTableExists(table) {
          Self.printDebug("資料庫中不存在 \(table) 表")
          return false
        }
      }

      // 檢查config表是否存在，如果存在則獲取分隔符，否則使用默認值
      if checkTableExists("config") {
        readingSeparator = fetchSeparator()
      } else {
        Self.printDebug("資料庫中不存在 config 表，使用預設分隔符 '-'")
        readingSeparator = "-"
      }

      return true
    }

    /// 獲取分隔符設定
    /// - Returns: 分隔符字串，如果獲取失敗則返回預設值 "-"
    private func fetchSeparator() -> Character {
      var separator: Character = "-"
      let query = "SELECT value FROM config WHERE key = 'separator' LIMIT 1" // 加上 LIMIT 1
      var statement: OpaquePointer?

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        let stepResult = sqlite3_step(statement)

        if stepResult == SQLITE_ROW {
          if let cString = sqlite3_column_text(statement, 0) {
            let string = String(cString: cString)
            if string.count == 1, let firstChar = string.first {
              separator = firstChar
            } else {
              Self.printDebug("警告：分隔符必須僅有一個 ASCII 字元。已讀取的資料值過長，故使用預設值 '-'")
            }
          }
        } else if stepResult == SQLITE_DONE {
          // 表存在但沒有找到分隔符配置，使用預設值
          Self.printDebug("警告：找不到分隔符設定，使用預設值 '-'")
        } else {
          Self.printDebug("查詢分隔符設定時發生錯誤: \(String(cString: sqlite3_errmsg(database)))")
        }
      } else {
        Self.printDebug("準備 SQL 語句時發生錯誤: \(String(cString: sqlite3_errmsg(database)))")
      }

      sqlite3_finalize(statement)
      return separator
    }

    /// 檢查資料表是否存在
    /// - Parameter tableName: 資料表名稱
    /// - Returns: 資料表是否存在
    private func checkTableExists(_ tableName: String) -> Bool {
      // 直接嘗試查詢表，如果不報錯就說明表存在
      let query = "SELECT 1 FROM \(tableName) LIMIT 1"
      var statement: OpaquePointer?
      let result = sqlite3_prepare_v2(database, query, -1, &statement, nil)

      // 無論查詢結果如何，都需要釋放statement
      defer {
        if statement != nil {
          sqlite3_finalize(statement)
        }
      }

      // SQLITE_OK 意味著查詢語句是正確的，表存在
      return result == SQLITE_OK
    }

    /// 顯示表的列資訊
    /// - Parameter tableName: 表名
    private func displayTableColumns(_ tableName: String) {
      // 這個查詢將返回表的所有列資訊
      let query = "PRAGMA table_info(\(tableName))"
      var statement: OpaquePointer?

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        Self.printDebug("  - 表結構:")

        while sqlite3_step(statement) == SQLITE_ROW {
          let name = String(cString: sqlite3_column_text(statement, 1))
          let type = String(cString: sqlite3_column_text(statement, 2))
          let notNull = sqlite3_column_int(statement, 3) != 0
          Self.printDebug("    * \(name) (\(type))\(notNull ? " NOT NULL" : "")")
        }
      }

      sqlite3_finalize(statement)
    }

    /// 顯示config表的內容
    private func displayConfigContent() {
      var statement: OpaquePointer?
      let query = "SELECT key, value FROM config"

      if sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK {
        Self.printDebug("\n配置項:")
        var hasRows = false

        while sqlite3_step(statement) == SQLITE_ROW {
          hasRows = true
          let key = String(cString: sqlite3_column_text(statement, 0))
          let value = String(cString: sqlite3_column_text(statement, 1))
          Self.printDebug("  * \(key): \(value)")
        }

        if !hasRows {
          Self.printDebug("  * 無配置項")
        }
      }

      sqlite3_finalize(statement)
    }

    // 直接查詢表中資料的偵錯方法
    private func directQueryDebug(keys: [String]) {
      // 1. 檢查 reading_mappings 表中是否有這些 readings
      for key in keys {
        var stmt: OpaquePointer?
        let query = "SELECT count(*) FROM reading_mappings WHERE reading = ?"
        if sqlite3_prepare_v2(database, query, -1, &stmt, nil) == SQLITE_OK {
          _ = key.withCString { cString in
            sqlite3_bind_text(stmt, 1, cString, -1, nil)
          }

          if sqlite3_step(stmt) == SQLITE_ROW {
            let count = sqlite3_column_int(stmt, 0)
            Self.printDebug("DEBUG: reading '\(key)' 在表中出現 \(count) 次")
          }
        }
        sqlite3_finalize(stmt)
      }

      // 2. 檢查有多少條目
      var stmt: OpaquePointer?
      if sqlite3_prepare_v2(database, "SELECT count(*) FROM entries", -1, &stmt, nil) == SQLITE_OK {
        if sqlite3_step(stmt) == SQLITE_ROW {
          let count = sqlite3_column_int(stmt, 0)
          Self.printDebug("DEBUG: entries 表中有 \(count) 條記錄")
        }
      }
      sqlite3_finalize(stmt)

      // 3. 檢查總共有多少 readings
      if sqlite3_prepare_v2(database, "SELECT count(*) FROM reading_mappings", -1, &stmt, nil) ==
        SQLITE_OK {
        if sqlite3_step(stmt) == SQLITE_ROW {
          let count = sqlite3_column_int(stmt, 0)
          Self.printDebug("DEBUG: reading_mappings 表中有 \(count) 條記錄")
        }
      }
      sqlite3_finalize(stmt)
    }
  }
}

extension Character {
  fileprivate init?(pointer: UnsafePointer<UInt8>) {
    let string = String(cString: pointer)
    guard string.count == 1, let result = string.first else {
      return nil
    }
    self = result
  }
}
