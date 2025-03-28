// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import TrieKit

// MARK: - VanguardTrie.TrieHub

extension VanguardTrie {
  internal class TrieHub {
    // MARK: Lifecycle

    init() {}

    // MARK: Internal

    internal var sqlTrieMap: [FactoryTrieDBType: VanguardTrie.SQLTrie] = [:]
    internal var plistTrieMap: [FactoryTrieDBType: VanguardTrie.Trie] = [:]
    internal var userTrie: LexiconGramSupplierProtocol?
    internal var cinTrie: LexiconGramSupplierProtocol?
  }
}

extension VanguardTrie.TrieHub {
  /// - Warning: 如果新指派的 Trie 有創建失敗的話，其對應的類型的原始 Trie 會變成 nil。
  public func updateTrieFromSQLFile(
    _ trieMapProvider: @escaping ()
      -> [FactoryTrieDBType: String]
  ) {
    let map = trieMapProvider()
    map.forEach { trieDataType, urlStr in
      let newTrie = VanguardTrie.SQLTrie(dbPath: urlStr, useDFD: isAppleSilicon()) // 必須得是唯讀。
      sqlTrieMap[trieDataType]?.closeAndNullifyConnection()
      sqlTrieMap[trieDataType] = newTrie
    }
  }

  /// - Warning: 如果新指派的 Trie 有創建失敗的話，其對應的類型的原始 Trie 會變成 nil。
  public func updateTrieFromSQLScript(
    _ trieMapProvider: @escaping () -> [FactoryTrieDBType: String]
  ) {
    let map = trieMapProvider()
    map.forEach { trieDataType, sqlScript in
      let newTrie = VanguardTrie.SQLTrie(sqlContent: sqlScript) // 必須得是唯讀。
      sqlTrieMap[trieDataType]?.closeAndNullifyConnection()
      sqlTrieMap[trieDataType] = newTrie
    }
  }

  /// - Warning: 如果新指派的 Trie 有創建失敗的話，其對應的類型的原始 Trie 會變成 nil。
  public func updateTrieFromPlistFile(_ trieMapProvider: @escaping () -> [FactoryTrieDBType: URL]) {
    let map = trieMapProvider()
    map.forEach { trieDataType, url in
      let newTriePlist = try? VanguardTrie.TrieIO.load(from: url)
      plistTrieMap[trieDataType] = newTriePlist
    }
  }
}

// MARK: - VanguardTrie.TrieHub + LexiconGramSupplierProtocol

extension VanguardTrie.TrieHub: LexiconGramSupplierProtocol {
  public func hasGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool,
    partiallyMatchedKeysHandler: ((Set<[String]>) -> ())?
  )
    -> Bool {
    guard !keys.isEmpty else { return false }
    let keysVanilla = keys
    let isRevLookup = filterType == .revLookup
    let keysEncrypted = isRevLookup ? keys : keys.map(Lexicon.encryptReadingKey)
    let partiallyMatch = isRevLookup ? false : partiallyMatch
    var partiallyMatchedKeys: Set<[String]> = []
    defer { if !isRevLookup { partiallyMatchedKeysHandler?(partiallyMatchedKeys) } }
    for dataType in FactoryTrieDBType.allCases {
      dataTypeCheck: switch dataType {
      case .revLookup where !isRevLookup: continue
      default: break dataTypeCheck
      }
      return Lexicon.concatGramAvailabilityCheckResults {
        userTrie?.hasGrams(
          keysVanilla, filterType: filterType, partiallyMatch: partiallyMatch
        ) { retrievedKeys in
          partiallyMatchedKeys.formUnion(retrievedKeys)
        }
        plistTrieMap[dataType]?.hasGrams(
          keysEncrypted, filterType: filterType, partiallyMatch: partiallyMatch
        ) { retrievedKeys in
          partiallyMatchedKeys.formUnion(retrievedKeys)
        }
        sqlTrieMap[dataType]?.hasGrams(
          keysEncrypted, filterType: filterType, partiallyMatch: partiallyMatch
        ) { retrievedKeys in
          partiallyMatchedKeys.formUnion(retrievedKeys)
        }
        if filterType.contains(.cinCassette) {
          cinTrie?.hasGrams(
            keysVanilla, filterType: filterType, partiallyMatch: partiallyMatch
          ) { retrievedKeys in
            partiallyMatchedKeys.formUnion(retrievedKeys)
          }
        }
      }
    }
    return false
  }

  public func queryGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool,
    partiallyMatchedKeysPostHandler: ((Set<[String]>) -> ())?
  )
    -> [Lexicon.HomaGramTuple] {
    guard !keys.isEmpty else { return [] }
    let isRevLookup = filterType == .revLookup
    let keysVanilla = keys
    let keysEncrypted = isRevLookup ? keys : keys.map(Lexicon.encryptReadingKey)
    let partiallyMatch = isRevLookup ? false : partiallyMatch
    var result = [Lexicon.HomaGramTuple]()
    var partiallyMatchedKeys: Set<[String]> = []
    defer { if !isRevLookup { partiallyMatchedKeysPostHandler?(partiallyMatchedKeys) } }
    for dataType in FactoryTrieDBType.allCases {
      dataTypeCheck: switch dataType {
      case .revLookup where !isRevLookup: continue
      default: break dataTypeCheck
      }
      let fetched: [Lexicon.HomaGramTuple]? = Lexicon.concatGramQueryResults {
        userTrie?.queryGrams(
          keysVanilla, filterType: filterType, partiallyMatch: partiallyMatch
        ) { retrievedKeys in
          partiallyMatchedKeys.formUnion(retrievedKeys)
        }
        Lexicon.concatGramQueryResults(
          flags: isRevLookup ? .decryptValues : .decryptReadingKeys
        ) {
          plistTrieMap[dataType]?.queryGrams(
            keysEncrypted, filterType: filterType, partiallyMatch: partiallyMatch
          ) { retrievedKeys in
            partiallyMatchedKeys.formUnion(retrievedKeys)
          }
          sqlTrieMap[dataType]?.queryGrams(
            keysEncrypted, filterType: filterType, partiallyMatch: partiallyMatch
          ) { retrievedKeys in
            partiallyMatchedKeys.formUnion(retrievedKeys)
          }
        }
        if filterType.contains(.cinCassette) {
          cinTrie?.queryGrams(
            keysVanilla, filterType: filterType, partiallyMatch: partiallyMatch
          ) { retrievedKeys in
            partiallyMatchedKeys.formUnion(retrievedKeys)
          }
        }
      }
      guard let fetched, !fetched.isEmpty else { continue }
      result.append(contentsOf: fetched)
    }
    return result
  }

  public func queryAssociatedPhrasesAsGrams(
    _ previous: (keyArray: [String], value: String),
    anterior anteriorValue: String?,
    filterType: VanguardTrie.Trie.EntryType
  )
    -> [Lexicon.HomaGramTuple]? {
    guard !filterType.contains(.revLookup) else { return nil }
    var keys = previous.keyArray
    guard !keys.isEmpty, keys.allSatisfy({ !$0.isEmpty }) else { return [] }
    guard !previous.value.isEmpty else { return [] }
    let isRevLookup = filterType == .revLookup
    keys = isRevLookup ? keys : keys.map(Lexicon.encryptReadingKey)
    var result = [Lexicon.HomaGramTuple]()
    for dataType in FactoryTrieDBType.allCases {
      dataTypeCheck: switch dataType {
      case .revLookup where !isRevLookup: continue
      default: break dataTypeCheck
      }
      let fetched: [Lexicon.HomaGramTuple]? = Lexicon.concatGramQueryResults {
        userTrie?.queryAssociatedPhrasesAsGrams(
          previous, anterior: anteriorValue, filterType: filterType
        )
        Lexicon.concatGramQueryResults(flags: .decryptReadingKeys) {
          plistTrieMap[dataType]?.queryAssociatedPhrasesAsGrams(
            previous, anterior: anteriorValue, filterType: filterType
          )
          sqlTrieMap[dataType]?.queryAssociatedPhrasesAsGrams(
            previous, anterior: anteriorValue, filterType: filterType
          )
        }
        if filterType.contains(.cinCassette) {
          cinTrie?.queryAssociatedPhrasesAsGrams(
            previous, anterior: anteriorValue, filterType: filterType
          )
        }
      }
      guard let fetched, !fetched.isEmpty else { continue }
      result.append(contentsOf: fetched)
    }
    return result.isEmpty ? nil : result
  }
}
