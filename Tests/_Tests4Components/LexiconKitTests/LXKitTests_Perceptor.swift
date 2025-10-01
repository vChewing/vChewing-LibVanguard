// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import Testing

@testable import LexiconKit

// 更新時間常數，使用天為單位
private let nowTimeStamp: Double = 114_514 * 10_000
private let capacity = 5
private let dayInSeconds: Double = 24 * 3_600 // 一天的秒數

// MARK: - LXTests4Perceptor

@Suite(.serialized)
public struct LXTests4Perceptor {
  // MARK: Internal

  @Test("[LXKit] Perceptor_BasicPerceptionOps")
  func testBasicPerceptionOps() throws {
    let perceptor = Perceptor(capacity: capacity)
    let key = "((ㄕㄣˊ-ㄌㄧˇ-ㄌㄧㄥˊ-ㄏㄨㄚˊ:神里綾華),(ㄉㄜ˙:的),ㄍㄡˇ)"
    let expectedSuggestion = "狗"
    percept(who: perceptor, key: key, candidate: expectedSuggestion, timestamp: nowTimeStamp)

    // 即時查詢應該能找到結果
    var suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp
    )
    #expect(suggested?.map(\.value).first ?? "" == expectedSuggestion)
    #expect(suggested?.map(\.previous).first ?? "" == "的")

    // 測試 2 天和 8 天的記憶衰退
    // 2 天內應該保留，8 天應該消失
    suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp + (dayInSeconds * 2)
    )
    #expect(suggested?.map(\.value).first ?? "" == expectedSuggestion)

    suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp + (dayInSeconds * 8)
    )
    #expect(suggested == nil) // 修正：不應該檢查空陣列，而是檢查 nil
  }

  @Test("[LXKit] Perceptor_NewestAgainstRepeatedlyUsed")
  func testNewestAgainstRepeatedlyUsed() throws {
    let perceptor = Perceptor(capacity: capacity)
    let key = "((ㄕㄣˊ-ㄌㄧˇ-ㄌㄧㄥˊ-ㄏㄨㄚˊ:神里綾華),(ㄉㄜ˙:的),ㄍㄡˇ)"
    let valRepeatedlyUsed = "狗" // 更常用
    let valNewest = "苟" // 最近偶爾用了一次

    // 使用天數作為單位
    let stamps: [Double] = [0, 0.1, 0.2].map { nowTimeStamp + dayInSeconds * $0 }
    stamps.forEach { stamp in
      percept(who: perceptor, key: key, candidate: valRepeatedlyUsed, timestamp: stamp)
    }

    // 即時查詢應該能找到結果
    var suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp
    )
    #expect(suggested?.map(\.value).first ?? "" == valRepeatedlyUsed)

    // 在 1 天後選擇了另一個候選字
    percept(
      who: perceptor,
      key: key,
      candidate: valNewest,
      timestamp: nowTimeStamp + dayInSeconds * 1
    )

    // 在 1.1 天檢查最新使用的候選字是否被建議
    suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp + dayInSeconds * 1.1
    )
    #expect(suggested?.map(\.value).first ?? "" == valNewest)

    // 在 8 天時，記憶仍應位於有效視窗內
    suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp + dayInSeconds * 8
    )
    #expect(suggested != nil, "約 7 天的有效視窗內記憶應該仍可取得")

    // 超過 8 天視窗後，記憶應該衰減
    suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp + dayInSeconds * 9
    )
    #expect(suggested == nil, "超過 8 天後記憶應該衰減")
  }

  // 添加一個專門測試長期記憶衰減的測試
  @Test("[LXKit] Perceptor_LongTermMemoryDecay")
  func testLongTermMemoryDecay() throws {
    let perceptor = Perceptor(capacity: capacity)
    let key = "((ㄔㄥˊ-ㄒㄧㄣˋ:誠信),(ㄓㄜˋ:這),ㄉㄧㄢˇ)"
    let expectedSuggestion = "點"

    // 記錄一個記憶
    percept(who: perceptor, key: key, candidate: expectedSuggestion, timestamp: nowTimeStamp)

    // 確認剛剛記錄的能被找到
    var suggested = perceptor.getSuggestion(key: key, timestamp: nowTimeStamp)
    #expect(suggested?.map(\.value).first ?? "" == expectedSuggestion)

    // 測試不同天數的衰減，預期約 8 天後記憶衰減
    let testCases: [(day: Double, expectAvailable: Bool)] = [
      (0, true),
      (1, true),
      (3, true),
      (5, true),
      (7.5, true),
      (8.0, false),
      (9.0, false),
      (20, false),
      (80, false),
    ]

    for testCase in testCases {
      let currentTimestamp = nowTimeStamp + (dayInSeconds * testCase.day)
      suggested = perceptor.getSuggestion(key: key, timestamp: currentTimestamp)

      if testCase.expectAvailable {
        #expect(suggested != nil, "第\(testCase.day)天的記憶應維持可用")
        if let suggestion = suggested?.first {
          let score = suggestion.probability
          #expect(
            score > perceptor.threshold,
            "第\(testCase.day)天的權重\(score)不應低於閾值\(Perceptor.kDecayThreshold)"
          )
        }
      } else {
        #expect(suggested == nil, "第\(testCase.day)天後記憶應衰減")
      }
    }
  }

  @Test("[LXKit] Perceptor_LRUTable")
  func testLRUTable() throws {
    let a = (key: "((ㄕㄣˊ-ㄌㄧˇ-ㄌㄧㄥˊ-ㄏㄨㄚˊ:神里綾華),(ㄉㄜ˙:的),ㄍㄡˇ)", value: "狗", head: "ㄍㄡˇ")
    let b = (key: "((ㄆㄞˋ-ㄇㄥˊ:派蒙),(ㄉㄜ˙:的),ㄐㄧㄤˇ-ㄐㄧㄣ)", value: "伙食費", head: "ㄏㄨㄛˇ-ㄕˊ-ㄈㄟˋ")
    let c = (key: "((ㄍㄨㄛˊ-ㄅㄥ:國崩),(ㄉㄜ˙:的),ㄇㄠˋ-ㄗ˙)", value: "帽子", head: "ㄇㄠˋ-ㄗ˙")
    let d = (key: "((ㄌㄟˊ-ㄉㄧㄢˋ-ㄐㄧㄤ-ㄐㄩㄣ:雷電將軍),(ㄉㄜ˙:的),ㄐㄧㄠˇ-ㄔㄡˋ)", value: "腳臭", head: "ㄐㄧㄠˇ-ㄔㄡˋ")

    // 容量為2的LRU測試
    let perceptor = Perceptor(capacity: 2)

    // 緊接著記錄三個項目，只保留最後兩個
    percept(who: perceptor, key: a.key, candidate: a.value, timestamp: nowTimeStamp)
    percept(who: perceptor, key: b.key, candidate: b.value, timestamp: nowTimeStamp + 1)
    percept(who: perceptor, key: c.key, candidate: c.value, timestamp: nowTimeStamp + 2)

    // C是最新的，應該在清單中
    var suggested = perceptor.getSuggestion(
      key: c.key,
      timestamp: nowTimeStamp + 3
    )
    #expect(suggested?.map(\.value).first ?? "" == c.value)

    // B是第二新的，應該在清單中
    suggested = perceptor.getSuggestion(
      key: b.key,
      timestamp: nowTimeStamp + 4
    )
    #expect(suggested?.map(\.value).first ?? "" == b.value)

    // A最舊，應該被移除
    suggested = perceptor.getSuggestion(
      key: a.key,
      timestamp: nowTimeStamp + 5
    )
    #expect(suggested == nil)

    // 添加D, B應該被移除
    percept(who: perceptor, key: d.key, candidate: d.value, timestamp: nowTimeStamp + 6)

    suggested = perceptor.getSuggestion(
      key: d.key,
      timestamp: nowTimeStamp + 7
    )
    #expect(suggested?.map(\.value).first ?? "" == d.value)

    suggested = perceptor.getSuggestion(
      key: c.key,
      timestamp: nowTimeStamp + 8
    )
    #expect(suggested?.map(\.value).first ?? "" == c.value)

    suggested = perceptor.getSuggestion(
      key: b.key,
      timestamp: nowTimeStamp + 9
    )
    #expect(suggested == nil)
  }

  @Test("[LXKit] Perceptor_Homa_Integration_test")
  func testIntegrationAgainstHoma() throws {
    let perceptor = Perceptor()
    let hub = LXTests4TrieHub.makeSharedTrie4Tests(useSQL: true)
    let readings: [Substring] = "ㄧㄡ ㄉㄧㄝˊ ㄋㄥˊ ㄌㄧㄡˊ ㄧˋ ㄌㄩˇ ㄈㄤ".split(separator: " ")
    let assembler = Homa.Assembler(
      gramQuerier: { hub.queryGrams($0, filterType: .cht, partiallyMatch: false) },
      gramAvailabilityChecker: { hub.hasGrams($0, filterType: .cht, partiallyMatch: false) },
      perceptor: { intel in
        perceptor.memorizePerception(
          intel,
          timestamp: Date().timeIntervalSince1970
        )
      }
    )
    try readings.forEach { try assembler.insertKey($0.description) }
    var assembledSentence = assembler.assemble().values
    #expect(assembledSentence == ["優", "跌", "能", "留意", "旅", "方"])
    try assembler.overrideCandidate(
      Homa.CandidatePair(keyArray: ["ㄧㄡ"], value: "幽"),
      at: 0
    )
    try assembler.overrideCandidate(
      Homa.CandidatePair(keyArray: ["ㄉㄧㄝˊ"], value: "蝶"),
      at: 1
    )
    try assembler.overrideCandidate(
      Homa.CandidatePair(keyArray: ["ㄌㄧㄡˊ"], value: "留"),
      at: 3
    )
    try assembler.overrideCandidate(
      Homa.CandidatePair(keyArray: ["ㄧˋ", "ㄌㄩˇ"], value: "一縷"),
      at: 4
    )
    try assembler.overrideCandidate(
      Homa.CandidatePair(keyArray: ["ㄈㄤ"], value: "芳"),
      at: 6
    )
    assembledSentence = assembler.assemble().values
    #expect(assembledSentence == ["幽", "蝶", "能", "留", "一縷", "芳"])
    let actualkeysJoined = assembler.actualKeys.joined(separator: " ")
    #expect(actualkeysJoined == "ㄧㄡ ㄉㄧㄝˊ ㄋㄥˊ ㄌㄧㄡˊ ㄧˋ ㄌㄩˇ ㄈㄤ")
    let expectedPerceptionKeys: [String] = [
      "((ㄌㄧㄡˊ:留),(ㄧˋ-ㄌㄩˇ:一縷),ㄈㄤ)",
      "((ㄋㄥˊ:能),(ㄌㄧㄡˊ:留),ㄧˋ-ㄌㄩˇ)",
      "((ㄉㄧㄝˊ:蝶),(ㄋㄥˊ:能),ㄌㄧㄡˊ)",
      "((ㄧㄡ:幽),ㄉㄧㄝˊ)",
      "(ㄧㄡ)",
    ]
    print(perceptor.getSavableData().map(\.key) == expectedPerceptionKeys)
  }

  // MARK: Private

  private func percept(
    who perceptor: Perceptor,
    key: String,
    candidate: String,
    timestamp stamp: Double
  ) {
    perceptor.memorizePerception(
      (ngramKey: key, candidate: candidate),
      timestamp: stamp
    )
  }
}
