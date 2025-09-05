// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - DynamicLayoutCache

/// 動態佈局效能快取，用於快取按鍵轉譯結果以提升動態佈局的輸入效能
internal final class DynamicLayoutCache: @unchecked Sendable {
  private let queue = DispatchQueue(label: "TekkonDynamicLayoutCache", qos: .userInteractive)
  
  /// 快取結果包裝器
  enum CacheResult: Sendable {
    case found(Unicode.Scalar?)
    case notFound
  }
  
  private var cache: [CacheKey: Unicode.Scalar?] = [:]
  
  /// 快取鍵值，包含佈局類型、按鍵、以及當前狀態
  struct CacheKey: Hashable, Sendable {
    let parser: Tekkon.MandarinParser
    let key: Unicode.Scalar
    let consonant: String
    let semivowel: String  
    let vowel: String
    let intonation: String
    let isPronounceable: Bool
    
    init(parser: Tekkon.MandarinParser, key: Unicode.Scalar, composer: Tekkon.Composer) {
      self.parser = parser
      self.key = key
      self.consonant = composer.consonant.value
      self.semivowel = composer.semivowel.value
      self.vowel = composer.vowel.value
      self.intonation = composer.intonation.value
      self.isPronounceable = composer.isPronounceable
    }
  }
  
  /// 從快取中獲取轉譯結果
  func get(parser: Tekkon.MandarinParser, key: Unicode.Scalar, composer: Tekkon.Composer) -> CacheResult {
    let cacheKey = CacheKey(parser: parser, key: key, composer: composer)
    return queue.sync {
      if let result = cache[cacheKey] {
        return .found(result)
      } else {
        return .notFound
      }
    }
  }
  
  /// 將轉譯結果存入快取
  func set(_ result: Unicode.Scalar?, parser: Tekkon.MandarinParser, key: Unicode.Scalar, composer: Tekkon.Composer) {
    let cacheKey = CacheKey(parser: parser, key: key, composer: composer)
    queue.sync {
      cache[cacheKey] = result
    }
  }
  
  /// 清空快取（用於記憶體管理）
  func clear() {
    queue.sync {
      cache.removeAll()
    }
  }
  
  /// 獲取快取統計資訊
  var statistics: (count: Int, memoryUsage: Int) {
    queue.sync {
      let count = cache.count
      // 粗略估計記憶體使用量（每個鍵值對約100字節）
      let memoryUsage = count * 100
      return (count: count, memoryUsage: memoryUsage)
    }
  }
}

// MARK: - CharacterSet Extensions for Performance

extension String {
  /// 高效能字符檢查，使用 CharacterSet 取代 contains
  func hasCharacterIn(_ characters: CharacterSet) -> Bool {
    return rangeOfCharacter(from: characters) != nil
  }
}

// MARK: - Performance Constants

extension Tekkon {
  /// 高效能字符集，用於快速字符檢查
  static let consonantJQXCharacterSet = CharacterSet(charactersIn: "ㄐㄑㄒ")
  static let consonantZCSCharacterSet = CharacterSet(charactersIn: "ㄓㄔㄕ")
  static let consonantBPMFCharacterSet = CharacterSet(charactersIn: "ㄅㄆㄇㄈ")
  static let consonantNLCharacterSet = CharacterSet(charactersIn: "ㄋㄌ")
  static let consonantZCSSZCSCharacterSet = CharacterSet(charactersIn: "ㄓㄔㄕㄗㄘㄙ")
  static let semivowelWCharacterSet = CharacterSet(charactersIn: "ㄨ")
  static let semivowelIUCharacterSet = CharacterSet(charactersIn: "ㄧㄩ")
  static let vowelECharacterSet = CharacterSet(charactersIn: "ㄜ")
  static let vowelOGCharacterSet = CharacterSet(charactersIn: "ㄛㄥ")
  static let vowelEICharacterSet = CharacterSet(charactersIn: "ㄟ")
  
  // 動態佈局按鍵字符集，用於快速檢查
  static let eten26KeysCharacterSet = CharacterSet(charactersIn: "dfhjklmnpqtw")
  static let hsuKeysCharacterSet = CharacterSet(charactersIn: "acdefghjklmns")
  static let starlightKeysCharacterSet = CharacterSet(charactersIn: "efgklmnt")
  static let alvinliuKeysCharacterSet = CharacterSet(charactersIn: "dfjlegnhkbmc")
  static let toneKeysCharacterSet = CharacterSet(charactersIn: "dfjk ")
  static let shortToneKeysCharacterSet = CharacterSet(charactersIn: "dfjs ")
  static let digitToneKeysCharacterSet = CharacterSet(charactersIn: "67890 ")
  
  /// 優化的字符檢查函數
  static func characterMatches(_ char: String, in characterSet: CharacterSet) -> Bool {
    guard !char.isEmpty, let firstScalar = char.unicodeScalars.first else { return false }
    return characterSet.contains(firstScalar)
  }
  
  /// 優化的按鍵檢查函數
  static func keyMatches(_ key: Unicode.Scalar, in characterSet: CharacterSet) -> Bool {
    return characterSet.contains(key)
  }
}