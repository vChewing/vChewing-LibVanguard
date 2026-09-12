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

    // TextMap 路徑改為單一 `.txtMap`，typing / revLookup 共用同一個惰性 TextMapTrie。
    internal var textMapTrieMap: [FactoryTrieDBType: any VanguardTrieProtocol] = [:]
    internal var userTrie: LexiconGramSupplierProtocol?
    internal var cinTrie: LexiconGramSupplierProtocol?
  }
}

extension VanguardTrie.TrieHub {
  /// - Warning: 如果新指派的 Trie 有創建失敗的話，其對應的類型的原始 Trie 會變成 nil。
  public func updateTrieFromTextMapFile(
    _ trieMapProvider: @escaping ()
      -> [FactoryTrieDBType: URL]
  ) {
    let map = trieMapProvider()
    let typingURL = map[.typing] ?? map.values.first {
      $0.pathExtension.caseInsensitiveCompare("txtMap") == .orderedSame
    }
    let newTrie = typingURL.flatMap { try? VanguardTrie.TrieIO.loadFromTextMapLazy(url: $0) }
    textMapTrieMap[.typing] = newTrie
    textMapTrieMap[.revLookup] = newTrie
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
        textMapTrieMap[dataType]?.hasGrams(
          keysVanilla, filterType: filterType, partiallyMatch: partiallyMatch
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
    -> [Lexicon.HomaGram] {
    guard !keys.isEmpty else { return [] }
    let isRevLookup = filterType == .revLookup
    let keysVanilla = keys
    let partiallyMatch = isRevLookup ? false : partiallyMatch
    var result = [Lexicon.HomaGram]()
    var partiallyMatchedKeys: Set<[String]> = []
    defer { if !isRevLookup { partiallyMatchedKeysPostHandler?(partiallyMatchedKeys) } }
    for dataType in FactoryTrieDBType.allCases {
      dataTypeCheck: switch dataType {
      case .revLookup where !isRevLookup: continue
      default: break dataTypeCheck
      }
      let fetched: [Lexicon.HomaGram]? = Lexicon.concatGramQueryResults {
        userTrie?.queryGrams(
          keysVanilla, filterType: filterType, partiallyMatch: partiallyMatch
        ) { retrievedKeys in
          partiallyMatchedKeys.formUnion(retrievedKeys)
        }
        textMapTrieMap[dataType]?.queryGrams(
          keysVanilla, filterType: filterType, partiallyMatch: partiallyMatch
        ) { retrievedKeys in
          partiallyMatchedKeys.formUnion(retrievedKeys)
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
    -> [Lexicon.HomaGram]? {
    guard !filterType.contains(.revLookup) else { return nil }
    let keys = previous.keyArray
    guard !keys.isEmpty, keys.allSatisfy({ !$0.isEmpty }) else { return [] }
    guard !previous.value.isEmpty else { return [] }
    var result = [Lexicon.HomaGram]()
    for dataType in FactoryTrieDBType.allCases {
      dataTypeCheck: switch dataType {
      case .revLookup: continue
      default: break dataTypeCheck
      }
      let fetched: [Lexicon.HomaGram]? = Lexicon.concatGramQueryResults {
        userTrie?.queryAssociatedPhrasesAsGrams(
          previous, anterior: anteriorValue, filterType: filterType
        )
        textMapTrieMap[dataType]?.queryAssociatedPhrasesAsGrams(
          previous, anterior: anteriorValue, filterType: filterType
        )
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
