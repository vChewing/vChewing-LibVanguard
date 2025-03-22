// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

@testable import LexiconKit
import Testing

@Suite(.serialized)
public struct LXTests4LMPlainBPMF {
  @Test("[LXKit] LMPlainBPMF_QueryTest")
  func testQueryingFromLMPlainBPMF() throws {
    let theLM = Lexicon.LMPlainBPMF()
    // 倚天中文 DOS 系統沒有「㨃」字（也沒有「ㄉㄨㄟˇ」讀音）。
    #expect(theLM?.hasGrams("ㄉㄨㄟˇ", partiallyMatch: false) != true)
    var foundKeys: Set<[String]> = []
    let hasGramsDUI = theLM?.hasGrams("ㄉㄨㄟ", partiallyMatch: true) { foundKeys = $0 }
    #expect(hasGramsDUI ?? false)
    #expect(foundKeys == [["ㄉㄨㄟ"], ["ㄉㄨㄟˋ"]])
    let queriedDUI1 = theLM?.queryGrams("ㄉㄨㄟ", isCHS: false, partiallyMatch: false)
    #expect(queriedDUI1?.map(\.value) == ["堆", "頧", "痽"])
    let queriedDUIAll = theLM?.queryGrams("ㄉㄨㄟ", isCHS: false, partiallyMatch: true)
    #expect(queriedDUIAll?.map(\.value).joined() == "堆頧痽對隊兌碓懟譈濧薱轛濻瀩憝")
  }
}
