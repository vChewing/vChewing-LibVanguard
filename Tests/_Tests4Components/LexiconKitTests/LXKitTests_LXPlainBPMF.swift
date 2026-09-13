// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

@testable import LexiconKit
import Testing

@Suite(.serialized)
public struct LXTests4LXPlainBPMF {
  @Test("[LXKit] LXPlainBPMF_QueryTest")
  func testQueryingFromLXPlainBPMF() throws {
    let theLX = Lexicon.LXPlainBPMF()
    // 倚天中文 DOS 系統沒有「㨃」字（也沒有「ㄉㄨㄟˇ」讀音）。
    #expect(theLX?.hasGrams("ㄉㄨㄟˇ", partiallyMatch: false) != true)
    var foundKeys: Set<[String]> = []
    let hasGramsDUI = theLX?.hasGrams("ㄉㄨㄟ", partiallyMatch: true) { foundKeys = $0 }
    #expect(hasGramsDUI ?? false)
    #expect(foundKeys == [["ㄉㄨㄟ"], ["ㄉㄨㄟˋ"]])
    let queriedDUI1 = theLX?.queryGrams("ㄉㄨㄟ", isCHS: false, partiallyMatch: false)
    #expect(queriedDUI1?.map(\.value) == ["堆", "頧", "痽"])
    let queriedDUIAll = theLX?.queryGrams("ㄉㄨㄟ", isCHS: false, partiallyMatch: true)
    #expect(queriedDUIAll?.map(\.value).joined() == "堆頧痽對隊兌碓懟譈濧薱轛濻瀩憝")
  }
}
