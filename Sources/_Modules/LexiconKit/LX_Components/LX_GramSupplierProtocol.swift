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

  func queryAssociatedPhrasesAsGrams(
    _ previous: (keyArray: [String], value: String),
    anterior anteriorValue: String?,
    filterType: VanguardTrie.Trie.EntryType
  )
    -> [Lexicon.HomaGramTuple]?
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

  public func queryAssociatedPhrasesAsGrams(
    _ previous: (keyArray: [String], value: String),
    anterior anteriorValue: String? = nil,
    filterType: VanguardTrie.Trie.EntryType
  )
    -> [Lexicon.HomaGramTuple]? {
    queryAssociatedPhrasesAsGrams(previous, anterior: anteriorValue, filterType: filterType)
  }

  /// Exactly copied from VanguardTrieProtocol.
  public func queryAssociatedPhrasesPlain(
    _ previous: (keyArray: [String], value: String),
    anterior anteriorValue: String? = nil,
    filterType: VanguardTrie.Trie.EntryType
  )
    -> [(keyArray: [String], value: String)]? {
    let rawResults = queryAssociatedPhrasesAsGrams(
      previous,
      anterior: anteriorValue,
      filterType: filterType
    )
    guard let rawResults else { return nil }
    let prevSegLength = previous.keyArray.count
    var results = [(keyArray: [String], value: String)]()
    var inserted = Set<Int>()
    rawResults.forEach { entry in
      let newResult = (
        keyArray: Array(entry.keyArray[prevSegLength...]),
        value: entry.value.map(\.description)[prevSegLength...].joined()
      )
      let theHash = "\(newResult)".hashValue
      guard !inserted.contains(theHash) else { return }
      inserted.insert("\(newResult)".hashValue)
      results.append(newResult)
    }
    guard !results.isEmpty else { return nil }
    return results
  }
}
