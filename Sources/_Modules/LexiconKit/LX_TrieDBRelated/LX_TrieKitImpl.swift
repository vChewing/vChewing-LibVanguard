// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import TrieKit

extension VanguardTrie.Trie.EntryType {
  public static let cinCassette = Self(rawValue: 100 << 0) // 這一條不用記錄到先鋒語料庫內。
  public static let meta = Self(rawValue: 2 << 0)
  public static let revLookup = Self(rawValue: 3 << 0)
  public static let letterPunctuations = Self(rawValue: 4 << 0)
  public static let chs = Self(rawValue: 5 << 0) // 0x0804
  public static let cht = Self(rawValue: 6 << 0) // 0x0404
  public static let cns = Self(rawValue: 7 << 0)
  public static let nonKanji = Self(rawValue: 8 << 0)
  public static let symbolPhrases = Self(rawValue: 9 << 0)
  public static let zhuyinwen = Self(rawValue: 10 << 0)
}

extension VanguardTrie {
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
