// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import TrieKit

// MARK: - LexiconGramSupplierProtocol

public protocol LexiconGramSupplierProtocol: AnyObject {
  func hasGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool,
    partiallyMatchedKeysHandler: ((Set<[String]>) -> ())?
  )
    -> Bool

  func queryGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool,
    partiallyMatchedKeysPostHandler: ((Set<[String]>) -> ())?
  )
    -> [Lexicon.HomaGramTuple]
}

extension LexiconGramSupplierProtocol {
  public func queryGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool = false,
    partiallyMatchedKeysPostHandler: ((Set<[String]>) -> ())? = nil
  )
    -> [Lexicon.HomaGramTuple] {
    queryGrams(
      keys,
      filterType: filterType,
      partiallyMatch: partiallyMatch,
      partiallyMatchedKeysPostHandler: partiallyMatchedKeysPostHandler
    )
  }

  public func hasGrams(
    _ keys: [String],
    filterType: VanguardTrie.Trie.EntryType,
    partiallyMatch: Bool = false,
    partiallyMatchedKeysHandler: ((Set<[String]>) -> ())? = nil
  )
    -> Bool {
    hasGrams(
      keys,
      filterType: filterType,
      partiallyMatch: partiallyMatch,
      partiallyMatchedKeysHandler: partiallyMatchedKeysHandler
    )
  }
}
