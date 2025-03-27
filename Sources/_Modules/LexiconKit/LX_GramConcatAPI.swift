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
  ///   - forbiddenKeyValueHashes: 用以過濾結果的雜湊串，生成方法為：`Lexicon.makeHash([keyArray, value])`。
  ///   - grams: 要整理的元圖檢索結果。
  /// - Returns: 整理厚的結果。
  public static func concatGramQueryResults(
    flags: GramConcatFlags = [],
    forbiddenKeyValueHashes: Set<Int> = [],
    @ArrayBuilder<[HomaGramTuple]?> grams: () -> [[HomaGramTuple]?]
  )
    -> [HomaGramTuple]? {
    var concatenated = grams().compactMap { $0 }.flatMap { $0 }
    guard !concatenated.isEmpty else { return nil }
    if flags.contains(.sort) { concatenated.sort(by: Self.sortGrams) }
    var insertedThings: Set<Int> = []
    concatenated = concatenated.filter {
      if !forbiddenKeyValueHashes.isEmpty {
        let kvHash = Self.makeHash([$0.keyArray, $0.value])
        guard !forbiddenKeyValueHashes.contains(kvHash) else { return false }
        return true
      }
      if flags.contains(.deduplicate) {
        return insertedThings.insert("\($0)".hashValue).inserted
      }
      return true
    }
    return concatenated
  }

  private static func sortGrams(_ lhs: HomaGramTuple, _ rhs: HomaGramTuple) -> Bool {
    (
      rhs.keyArray.split(separator: "-").count, "\(lhs.keyArray)", rhs.probability
    ) < (
      lhs.keyArray.split(separator: "-").count, "\(rhs.keyArray)", lhs.probability
    )
  }

  private static func makeHash(_ targets: [any Hashable]) -> Int {
    var hasher = Hasher()
    targets.forEach { hasher.combine($0) }
    return hasher.finalize()
  }
}
