// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Lexicon.GramConcatFlags

extension Lexicon {
  public struct GramConcatFlags: OptionSet, Codable, Hashable, Sendable {
    // MARK: Lifecycle

    public init(rawValue: UInt) {
      self.rawValue = rawValue
    }

    // MARK: Public

    public static let sort = Self(rawValue: 1 << 1)
    public static let deduplicate = Self(rawValue: 1 << 2)
    public static let all: Self = [.sort, .deduplicate]

    public let rawValue: UInt
  }
}

extension Lexicon {
  public static func concatGramAvailabilityCheckResults(
    @ArrayBuilder<Bool?> subResults: () -> [Bool?]
  )
    -> Bool {
    subResults().reduce(false) { $0 || $1 ?? false }
  }

  /// 用以統整元圖檢索結果的 API。
  /// - Parameters:
  ///   - flags: 整理時要做的事情的標記。
  ///   - forbiddenKeyValueHashes: 用以過濾結果的雜湊串。
  ///   - grams: 要整理的元圖檢索結果。
  /// - Remark: 雜湊的生成方法為：`Lexicon.makeHash([keyArray, value, previous])`。
  /// - Returns: 整理厚的結果。
  public static func concatGramQueryResults(
    flags: GramConcatFlags = [],
    forbiddenKeyValueHashes: Set<Int> = [],
    @ArrayBuilder<[HomaGramTuple]?> grams: () -> [[HomaGramTuple]?]
  )
    -> [HomaGramTuple]? {
    var concatenated: [HomaGramTuple] = grams().compactMap { $0 }.flatMap { $0 }
    guard !concatenated.isEmpty else { return nil }
    if flags.contains(.sort) { concatenated.sort(by: Self.sortGrams) }
    var insertedThings: Set<Int> = []
    concatenated = concatenated.compactMap { theTuple in
      let kvHash = makeGramIdentityHash(theTuple.keyArray, theTuple.value, theTuple.previous)
      if !forbiddenKeyValueHashes.isEmpty {
        guard !forbiddenKeyValueHashes.contains(kvHash) else { return nil }
        return theTuple
      }
      if flags.contains(.deduplicate) {
        return insertedThings.insert(kvHash).inserted ? theTuple : nil
      }
      return theTuple
    }
    return concatenated
  }

  private static func sortGrams(_ lhs: HomaGramTuple, _ rhs: HomaGramTuple) -> Bool {
    if lhs.keyArray.count != rhs.keyArray.count {
      return lhs.keyArray.count > rhs.keyArray.count
    }
    if lhs.keyArray != rhs.keyArray {
      return lhs.keyArray.lexicographicallyPrecedes(rhs.keyArray)
    }
    return lhs.probability > rhs.probability
  }

  private static func makeGramIdentityHash(
    _ keyArray: [String], _ value: String, _ previous: String?
  )
    -> Int {
    var hasher = Hasher()
    hasher.combine(keyArray)
    hasher.combine(value)
    hasher.combine(previous)
    return hasher.finalize()
  }
}
