// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
@testable import LexiconKit
import Tekkon
import Testing
import TrieKit

// MARK: - LexiconKitTests

@Suite(.serialized)
public struct LexiconKitTests {
  // MARK: Internal

  @Test("[LexiconKit] TrieHub_ConstructionAndQuery", arguments: [false, true])
  func testTrieHubConstructionAndQuery(useSQL: Bool) throws {
    let hub = Self.makeSharedTrie4Tests(useSQL: useSQL)
    let dataTypeCountRegistered = useSQL ? hub.sqlTrieMap.count : hub.plistTrieMap.count
    #expect(dataTypeCountRegistered == FactoryTrieDBType.allCases.count)
    #expect(hub.hasGrams(["_NORM"], filterType: .meta)) // META
    let queriedResultNORM = hub.queryGrams(["_NORM"], filterType: .meta)
    #expect((queriedResultNORM.map(\.probability).first ?? 0) > 0)
    #expect(hub.hasGrams(["_BUILD_TIMESTAMP"], filterType: .meta))
    let queriedResultTIME = hub.queryGrams(["_BUILD_TIMESTAMP"], filterType: .meta)
    #expect((queriedResultTIME.map(\.probability).first ?? 0) > 0)
    #expect(hub.hasGrams(["⾡"], filterType: .revLookup)) // RevLookup
    let queriedResultRevLookup = hub.queryGrams(["⾡"], filterType: .revLookup).first
    #expect(queriedResultRevLookup?.value == "ㄔㄨㄛˋ")
    #expect(hub.hasGrams(["ㄌㄩˇ"], filterType: .cns)) // CNS
    let queriedResultCNS = hub.queryGrams(["ㄌㄩˇ"], filterType: .cns).map(\.value)
    #expect(queriedResultCNS.contains("𡜅"))
    #expect(hub.hasGrams(["ㄊㄝ"], filterType: .nonKanji)) // nonKanji: Kana
    let queriedResultKana = hub.queryGrams(["ㄊㄝ"], filterType: .nonKanji).map(\.value)
    #expect(queriedResultKana.contains("テ"))
    #expect(hub.hasGrams(["ㄇㄧˋ"], filterType: .symbolPhrases)) // symbolPhrases
    let queriedResultSymbolPhrase = hub.queryGrams(["ㄇㄧˋ"], filterType: .symbolPhrases)
    #expect(queriedResultSymbolPhrase.map(\.value).contains("㊙️"))
    #expect(hub.hasGrams(["ㄋㄟ", "ㄋㄟ"], filterType: .zhuyinwen)) // zhuyinwen
    let queriedResultZhuyinwen = hub.queryGrams(["ㄋㄟ", "ㄋㄟ"], filterType: .zhuyinwen)
    #expect(queriedResultZhuyinwen.map(\.value).contains("ㄋㄟㄋㄟ"))
    #expect(hub.hasGrams(["_letter_L"], filterType: .letterPunctuations)) // letters
    let queriedResultLetter = hub.queryGrams(["_letter_L"], filterType: .letterPunctuations)
    #expect(queriedResultLetter.map(\.value).contains("L"))
    #expect(hub.hasGrams(["_punctuation_<"], filterType: .letterPunctuations)) // punctuations
    let queriedResultPunct = hub.queryGrams(["_punctuation_<"], filterType: .letterPunctuations)
    #expect(queriedResultPunct.map(\.value).contains("，"))
    // 漢字的話，基礎繁體表與基礎簡體表各自都有對方的結果。
    #expect(hub.hasGrams(["ㄌㄩˇ"], filterType: .chs)) // CHS Kanji
    let queriedResultCHS = hub.queryGrams(["ㄌㄩˇ"], filterType: .chs).map(\.value)
    #expect(queriedResultCHS.contains("缕"))
    #expect(queriedResultCHS.contains("縷"))
    #expect(!queriedResultCHS.contains("𡜅"))
    #expect(hub.hasGrams(["ㄌㄩˇ"], filterType: .cht)) // CHT Kanji
    let queriedResultCHT = hub.queryGrams(["ㄌㄩˇ"], filterType: .cht).map(\.value)
    #expect(queriedResultCHT.contains("縷"))
    #expect(queriedResultCHT.contains("缕"))
    #expect(!queriedResultCHT.contains("𡜅"))
    // 檢查基礎表的詞語結果：
    #expect(hub.hasGrams(["ㄌㄩˇ"], filterType: .chs)) // CHS Phrase
    let queriedResultCHS2 = hub.queryGrams(["ㄧˋ", "ㄌㄩˇ"], filterType: .chs).map(\.value)
    #expect(queriedResultCHS2.contains("一缕"))
    #expect(!queriedResultCHS2.contains("一縷"))
    #expect(hub.hasGrams(["ㄌㄩˇ"], filterType: .cht)) // CHT Phrase
    let queriedResultCHT2 = hub.queryGrams(["ㄧˋ", "ㄌㄩˇ"], filterType: .cht).map(\.value)
    #expect(queriedResultCHT2.contains("一縷"))
    #expect(!queriedResultCHT2.contains("一缕"))
  }

  @Test(
    "[LexiconKit] TrieHub_AssemblyingUsingFullMatch",
    arguments: [false, true]
  )
  func testTrieHubAssemblyingUsingFullMatch(useSQL: Bool) async throws {
    let hub = Self.makeSharedTrie4Tests(useSQL: useSQL)
    let readings: [Substring] = "ㄧㄡ ㄉㄧㄝˊ ㄋㄥˊ ㄌㄧㄡˊ ㄧˋ ㄌㄩˇ ㄈㄤ".split(separator: " ")
    let assembler = Homa.Assembler(
      gramQuerier: { hub.queryGrams($0, filterType: .cht, partiallyMatch: false) },
      gramAvailabilityChecker: { hub.hasGrams($0, filterType: .cht, partiallyMatch: false) }
    )
    try Self.measureTime("Key insertion time cost on full match", useSQL: useSQL) {
      try readings.forEach { try assembler.insertKey($0.description) }
    }
    var assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["優", "跌", "能", "留意", "旅", "方"])
    try assembler.overrideCandidate(.init((["ㄧㄡ"], "幽")), at: 0)
    try assembler.overrideCandidate(.init((["ㄉㄧㄝˊ"], "蝶")), at: 1)
    try assembler.overrideCandidate(.init((["ㄌㄧㄡˊ"], "留")), at: 3)
    try assembler.overrideCandidate(.init((["ㄧˋ", "ㄌㄩˇ"], "一縷")), at: 4)
    try assembler.overrideCandidate(.init((["ㄈㄤ"], "芳")), at: 6)
    assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["幽", "蝶", "能", "留", "一縷", "芳"])
    let actualkeysJoined = assembler.actualKeys.joined(separator: " ")
    #expect(actualkeysJoined == "ㄧㄡ ㄉㄧㄝˊ ㄋㄥˊ ㄌㄧㄡˊ ㄧˋ ㄌㄩˇ ㄈㄤ")
  }

  /// 該測試主要是為了測試效能。
  @Test(
    "[LexiconKit] TrieHub_AssemblyingUsingPartialMatchAndChops",
    arguments: [false, true]
  )
  func testTrieHubAssemblyingUsingPartialMatchAndChops(useSQL: Bool) async throws {
    let pinyinTrie = Tekkon.PinyinTrie(parser: .ofHanyuPinyin)
    let rawPinyin = "yodienliylvf"
    let rawPinyinChopped = pinyinTrie.chop(rawPinyin)
    #expect(rawPinyinChopped == ["yo", "die", "n", "li", "y", "lv", "f"])
    let keys2Add = pinyinTrie.deductChoppedPinyinToZhuyin(rawPinyinChopped)
    #expect(keys2Add == ["ㄧㄛ&ㄧㄡ&ㄩㄥ", "ㄉㄧㄝ", "ㄋ", "ㄌㄧ", "ㄧ&ㄩ", "ㄌㄩ&ㄌㄩㄝ&ㄌㄩㄢ", "ㄈ"])
    let hub = Self.makeSharedTrie4Tests(useSQL: useSQL)
    let assembler = Homa.Assembler(
      gramQuerier: { hub.queryGrams($0, filterType: .cht, partiallyMatch: true) },
      gramAvailabilityChecker: { hub.hasGrams($0, filterType: .cht, partiallyMatch: true) }
    )
    try Self.measureTime("Key insertion time cost on partial match", useSQL: useSQL) {
      try keys2Add.forEach { try assembler.insertKey($0.description) }
    }
    var assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["優", "跌", "能", "留意", "旅", "方"])
    try assembler.overrideCandidate(.init((["ㄧㄡ"], "幽")), at: 0)
    try assembler.overrideCandidate(.init((["ㄉㄧㄝˊ"], "蝶")), at: 1)
    try assembler.overrideCandidate(.init((["ㄌㄧㄡˊ"], "留")), at: 3)
    try assembler.overrideCandidate(.init((["ㄧˋ", "ㄌㄩˇ"], "一縷")), at: 4)
    try assembler.overrideCandidate(.init((["ㄈㄤ"], "芳")), at: 6)
    assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["幽", "蝶", "能", "留", "一縷", "芳"])
    let actualkeysJoined = assembler.actualKeys.joined(separator: " ")
    #expect(actualkeysJoined == "ㄧㄡ ㄉㄧㄝˊ ㄋㄥˊ ㄌㄧㄡˊ ㄧˋ ㄌㄩˇ ㄈㄤ")
  }

  // MARK: Private

  private static func measureTime(
    _ memo: String,
    useSQL: Bool,
    _ task: @escaping () throws -> ()
  ) throws {
    let timestamp1a = Date().timeIntervalSince1970
    try task()
    let timestamp1b = Date().timeIntervalSince1970
    let timeCost = ((timestamp1b - timestamp1a) * 100_000).rounded() / 100
    let tag = useSQL ? "(SQL)" : "(Plist)"
    print("[Sitrep \(tag)] \(memo): \(timeCost)ms.")
  }

  private static func makeSharedTrie4Tests(useSQL: Bool) -> VanguardTrie.TrieHub {
    let hub = VanguardTrie.TrieHub()
    let tag = useSQL ? "(SQL)" : "(Plist)"
    if useSQL {
      try? Self.measureTime("Hub booting time cost \(tag)", useSQL: true) {
        hub.updateTrieFromSQLFile {
          var resultMap4FilePaths: [FactoryTrieDBType: String] = [:]
          FactoryTrieDBType.allCases.forEach { currentCase in
            let sqlFilePath = currentCase.getFactorySQLiteDemoFilePath4Tests()
            resultMap4FilePaths[currentCase] = sqlFilePath
          }
          return resultMap4FilePaths
        }
      }
    } else {
      try? Self.measureTime("Hub booting time cost \(tag)", useSQL: false) {
        hub.updateTrieFromPlistFile {
          var resultMap4FileURLs: [FactoryTrieDBType: URL] = [:]
          FactoryTrieDBType.allCases.forEach { currentCase in
            if let plistURL = currentCase.getFactoryPlistDemoFileURL4Tests() {
              resultMap4FileURLs[currentCase] = plistURL
            }
          }
          return resultMap4FileURLs
        }
      }
    }
    return hub
  }
}
