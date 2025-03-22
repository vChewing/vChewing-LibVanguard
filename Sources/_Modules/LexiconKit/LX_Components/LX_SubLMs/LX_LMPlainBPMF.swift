// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import TrieKit

// MARK: - Lexicon.LMPlainBPMF

extension Lexicon {
  /// 總是有人要打ㄅ半的。
  ///
  /// ㄅ半輸入法有一種政確，就是候選字的排列順序一定得是倚天中文 DOS 環境的內建的注音輸入法的排序。
  /// 這些肌肉記憶已經深入他們的骨髓，導致他們完全用不來除此以外的任何輸入方案。
  /// 他們往往以為這些是香草的候選字詞順序，實際上這些跟香草一點關係都沒有。
  final class LMPlainBPMF {
    // MARK: Lifecycle

    init?() {
      do {
        let decoded = try JSONDecoder().decode(
          [String: [String: String]].self,
          from: lmPlainBPMFData
        )
        self.dataMap = decoded
      } catch {
        let prompt =
          "↑ Exception happened when parsing raw JSON sequence data from vChewing LMAssembly."
        print("\(error)\n\(prompt)")
        return nil
      }
    }

    // MARK: Internal

    @usableFromInline typealias DataMap = [String: [String: String]]

    var count: Int { dataMap.count }

    // MARK: Fileprivate

    fileprivate let dataMap: DataMap
  }
}

extension Lexicon.LMPlainBPMF {
  func hasGrams(
    _ key: String,
    partiallyMatch: Bool = false,
    partiallyMatchedKeysHandler: ((Set<[String]>) -> ())? = nil
  )
    -> Bool {
    guard !key.isEmpty else { return false }
    switch partiallyMatch {
    case false: return dataMap[key] != nil
    case true:
      if let partiallyMatchedKeysHandler {
        let filteredKeys: Set<String> = Set(dataMap.keys.filter { $0.hasPrefix(key) })
        defer { partiallyMatchedKeysHandler(Set(filteredKeys.map { [$0] })) }
        return !filteredKeys.isEmpty
      } else {
        return dataMap.keys.first(where: { $0.hasPrefix(key) }) != nil
      }
    }
  }

  func queryGrams(
    _ key: String,
    isCHS: Bool,
    partiallyMatch: Bool = false,
    partiallyMatchedKeysPostHandler: ((Set<[String]>) -> ())? = nil
  )
    -> [Lexicon.HomaGramTuple] {
    guard !key.isEmpty else { return [] }
    // 這裡不做去重複處理，因為倚天中文系統注音排序適應者們已經形成了肌肉記憶。
    var pairs: [Lexicon.HomaGramTuple] = []
    let subKey = isCHS ? "S" : "T"
    switch partiallyMatch {
    case false:
      if let currentRecordOfChars: String = dataMap[key]?[subKey] {
        pairs.append(contentsOf: currentRecordOfChars.map {
          ([key], $0.description, 0, nil)
        })
      }
    case true:
      let filteredKeys: Set<String> = Set(dataMap.keys.filter { $0.hasPrefix(key) })
      defer {
        partiallyMatchedKeysPostHandler?(Set(filteredKeys.map { [$0] }))
      }
      filteredKeys.sorted().forEach { matchedKey in
        guard let currentRecordOfChars = dataMap[matchedKey]?[subKey] else { return }
        pairs.append(contentsOf: currentRecordOfChars.map {
          ([key], $0.description, 0, nil)
        })
      }
    }
    return pairs
  }
}
