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
    public static let decryptReadingKeys = Self(rawValue: 1 << 3)
    public static let decryptValues = Self(rawValue: 1 << 4)
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
    let decryptReadingKeys = flags.contains(.decryptReadingKeys)
    let decryptValues = flags.contains(.decryptValues)
    if decryptReadingKeys || decryptValues {
      concatenated = concatenated.map { currentTupleRAW in
        let newKeyArray = decryptReadingKeys
          ? currentTupleRAW.keyArray.map(decryptReadingKey)
          : currentTupleRAW.keyArray
        let newValue = decryptValues
          ? decryptReadingKey(currentTupleRAW.value)
          : currentTupleRAW.value
        return HomaGramTuple(
          newKeyArray, newValue, currentTupleRAW.probability, currentTupleRAW.previous
        )
      }
    }
    if flags.contains(.sort) { concatenated.sort(by: Self.sortGrams) }
    var insertedThings: Set<Int> = []
    concatenated = concatenated.compactMap { theTuple in
      let kvHash: Int = makeHash([theTuple.keyArray, theTuple.value, theTuple.previous])
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

extension Lexicon {
  public static func encryptReadingKey(_ target: String) -> String {
    guard target.first != "_" else { return target }
    var result = String()
    result.unicodeScalars.reserveCapacity(target.unicodeScalars.count)
    for scalar in target.unicodeScalars {
      result.unicodeScalars.append(Self.bpmfReplacements4Encryption[scalar] ?? scalar)
    }
    return result
  }

  public static func decryptReadingKey(_ target: String) -> String {
    guard target.first != "_" else { return target }
    var result = String()
    result.unicodeScalars.reserveCapacity(target.unicodeScalars.count)
    for scalar in target.unicodeScalars {
      result.unicodeScalars.append(Self.bpmfReplacements4Decryption[scalar] ?? scalar)
    }
    return result
  }

  private static let bpmfReplacements4Encryption: [Unicode.Scalar: Unicode.Scalar] = [
    "ㄅ": "b", "ㄆ": "p", "ㄇ": "m", "ㄈ": "f", "ㄉ": "d",
    "ㄊ": "t", "ㄋ": "n", "ㄌ": "l", "ㄍ": "g", "ㄎ": "k",
    "ㄏ": "h", "ㄐ": "j", "ㄑ": "q", "ㄒ": "x", "ㄓ": "Z",
    "ㄔ": "C", "ㄕ": "S", "ㄖ": "r", "ㄗ": "z", "ㄘ": "c",
    "ㄙ": "s", "ㄧ": "i", "ㄨ": "u", "ㄩ": "v", "ㄚ": "a",
    "ㄛ": "o", "ㄜ": "e", "ㄝ": "E", "ㄞ": "B", "ㄟ": "P",
    "ㄠ": "M", "ㄡ": "F", "ㄢ": "D", "ㄣ": "T", "ㄤ": "N",
    "ㄥ": "L", "ㄦ": "R", "ˊ": "2", "ˇ": "3", "ˋ": "4",
    "˙": "5",
  ]

  private static let bpmfReplacements4Decryption: [Unicode.Scalar: Unicode.Scalar] = [
    "b": "ㄅ", "p": "ㄆ", "m": "ㄇ", "f": "ㄈ", "d": "ㄉ",
    "t": "ㄊ", "n": "ㄋ", "l": "ㄌ", "g": "ㄍ", "k": "ㄎ",
    "h": "ㄏ", "j": "ㄐ", "q": "ㄑ", "x": "ㄒ", "Z": "ㄓ",
    "C": "ㄔ", "S": "ㄕ", "r": "ㄖ", "z": "ㄗ", "c": "ㄘ",
    "s": "ㄙ", "i": "ㄧ", "u": "ㄨ", "v": "ㄩ", "a": "ㄚ",
    "o": "ㄛ", "e": "ㄜ", "E": "ㄝ", "B": "ㄞ", "P": "ㄟ",
    "M": "ㄠ", "F": "ㄡ", "D": "ㄢ", "T": "ㄣ", "N": "ㄤ",
    "L": "ㄥ", "R": "ㄦ", "2": "ˊ", "3": "ˇ", "4": "ˋ",
    "5": "˙",
  ]
}
