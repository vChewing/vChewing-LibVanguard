// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import HomaSharedTestComponents
import Testing

@testable import LexiconKit

// 更新時間常數，使用天為單位
private let nowTimeStamp: Double = 114_514 * 10_000
private let capacity = 5
private let dayInSeconds: Double = 24 * 3_600 // 一天的秒數

private func makeAssembler(using rawData: String) -> Homa.Assembler {
  let lm = TestLM(rawData: rawData)
  return Homa.Assembler(
    gramQuerier: { lm.queryGrams($0, partiallyMatch: false) },
    gramAvailabilityChecker: { lm.hasGrams($0, partiallyMatch: false) }
  )
}

// MARK: - LXTests4Perceptor

@Suite(.serialized)
public struct LXTests4Perceptor {
  // MARK: Internal

  @Test("[LXKit] Perceptor_BasicPerceptionOps")
  func testBasicPerceptionOps() throws {
    let perceptor = Perceptor(capacity: capacity)
    let key = "(ㄕㄣˊ-ㄌㄧˇ-ㄌㄧㄥˊ-ㄏㄨㄚˊ,神里綾華)&(ㄉㄜ˙,的)&(ㄍㄡˇ,狗)"
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
      timestamp: nowTimeStamp + (dayInSeconds * 8.01)
    )
    #expect(suggested == nil) // 修正：不應該檢查空陣列，而是檢查 nil
  }

  @Test("[LXKit] Perceptor_NewestAgainstRepeatedlyUsed")
  func testNewestAgainstRepeatedlyUsed() throws {
    let perceptor = Perceptor(capacity: capacity)
    let key = "(ㄕㄣˊ-ㄌㄧˇ-ㄌㄧㄥˊ-ㄏㄨㄚˊ,神里綾華)&(ㄉㄜ˙,的)&(ㄍㄡˇ,狗)"
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

    // 約在 7.5 天時仍位於有效視窗內
    suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp + dayInSeconds * 7.5
    )
    #expect(suggested != nil, "約 7 天的有效視窗內記憶應該仍可取得")

    // 8 天多一點仍在有效視窗，因為最後一次選擇發生在第 1 天
    suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp + (dayInSeconds * 8.01)
    )
    #expect(suggested != nil, "距離最後一次選擇不足 8 天時記憶應保持")

    // 進一步驗證 9 天後（距離最後一次選擇逾 8 天）應衰減
    suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp + (dayInSeconds * 9.1)
    )
    #expect(suggested == nil, "超過 8 天後記憶應該衰減")
  }

  // 添加一個專門測試長期記憶衰減的測試
  @Test("[LXKit] Perceptor_LongTermMemoryDecay")
  func testLongTermMemoryDecay() throws {
    let perceptor = Perceptor(capacity: capacity)
    let key = "(ㄔㄥˊ-ㄒㄧㄣˋ,誠信)&(ㄓㄜˋ,這)&(ㄉㄧㄢˇ,點)"
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
      (8.1, false),
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
    let a = (key: "(ㄕㄣˊ-ㄌㄧˇ-ㄌㄧㄥˊ-ㄏㄨㄚˊ,神里綾華)&(ㄉㄜ˙,的)&(ㄍㄡˇ,狗)", value: "狗", head: "ㄍㄡˇ")
    let b = (key: "(ㄆㄞˋ-ㄇㄥˊ,派蒙)&(ㄉㄜ˙,的)&(ㄐㄧㄤˇ-ㄐㄧㄣ,獎金)", value: "伙食費", head: "ㄏㄨㄛˇ-ㄕˊ-ㄈㄟˋ")
    let c = (key: "(ㄍㄨㄛˊ-ㄅㄥ,國崩)&(ㄉㄜ˙,的)&(ㄇㄠˋ-ㄗ˙,帽子)", value: "帽子", head: "ㄇㄠˋ-ㄗ˙")
    let d = (key: "(ㄌㄟˊ-ㄉㄧㄢˋ-ㄐㄧㄤ-ㄐㄩㄣ,雷電將軍)&(ㄉㄜ˙,的)&(ㄐㄧㄠˇ-ㄔㄡˋ,腳臭)", value: "腳臭", head: "ㄐㄧㄠˇ-ㄔㄡˋ")

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

  @Test("[LXKit] Perceptor_BleachSpecifiedSuggestions_CandidateLevel")
  func testBleachSpecifiedSuggestionsAtCandidateLevel() throws {
    let perceptor = Perceptor(capacity: 10)
    let timestamp = nowTimeStamp
    let key1 = "(test1,測試1)&(key,鍵)&(target,目標1)"
    let candidate1 = "目標1"
    let key2 = "(test2,測試2)&(key,鍵)&(target,目標2)"
    let candidate2 = "目標2"
    let key3 = "(test3,測試3)&(key,鍵)&(target,目標3)"
    let candidate3 = "目標3"

    percept(who: perceptor, key: key1, candidate: candidate1, timestamp: timestamp)
    percept(who: perceptor, key: key2, candidate: candidate2, timestamp: timestamp)
    percept(who: perceptor, key: key3, candidate: candidate3, timestamp: timestamp)

    #expect(
      perceptor.getSuggestion(key: key1, timestamp: timestamp + 100)?.first?
        .value == candidate1
    )
    #expect(
      perceptor.getSuggestion(key: key2, timestamp: timestamp + 100)?.first?
        .value == candidate2
    )
    #expect(
      perceptor.getSuggestion(key: key3, timestamp: timestamp + 100)?.first?
        .value == candidate3
    )

    perceptor.bleachSpecifiedSuggestions(candidateTargets: [candidate2])

    #expect(
      perceptor.getSuggestion(key: key1, timestamp: timestamp + 100)?.first?
        .value == candidate1
    )
    #expect(perceptor.getSuggestion(key: key2, timestamp: timestamp + 100) == nil)
    #expect(
      perceptor.getSuggestion(key: key3, timestamp: timestamp + 100)?.first?
        .value == candidate3
    )
  }

  @Test("[LXKit] Perceptor_BleachSpecifiedSuggestions_MultipleOverrides")
  func testBleachSpecifiedSuggestionsMultipleOverrides() throws {
    let perceptor = Perceptor(capacity: 10)
    let timestamp = nowTimeStamp
    let key = "(test,測試)&(key,鍵)&(target,基底)"
    let candidate1 = "目標A"
    let candidate2 = "目標B"
    let candidate3 = "目標C"

    percept(who: perceptor, key: key, candidate: candidate1, timestamp: timestamp)
    percept(who: perceptor, key: key, candidate: candidate2, timestamp: timestamp + 10)
    percept(who: perceptor, key: key, candidate: candidate3, timestamp: timestamp + 20)

    #expect(perceptor.getSuggestion(key: key, timestamp: timestamp + 100) != nil)

    perceptor.bleachSpecifiedSuggestions(candidateTargets: [candidate2])

    let overrides = try #require(
      perceptor.getSavableData().first { $0.key == key }?.perception
        .overrides
    )
    #expect(!overrides.keys.contains(candidate2))
    #expect(overrides.keys.contains(candidate1))
    #expect(overrides.keys.contains(candidate3))
    #expect(overrides.count == 2)
  }

  @Test("[LXKit] Perceptor_BleachSpecifiedSuggestions_RemoveKeyWhenEmpty")
  func testBleachSpecifiedSuggestionsRemovesKeyWhenAllOverridesRemoved() throws {
    let perceptor = Perceptor(capacity: 10)
    let timestamp = nowTimeStamp
    let key = "(test,測試)&(key,鍵)&(target,基底)"
    let candidate = "唯一目標"

    percept(who: perceptor, key: key, candidate: candidate, timestamp: timestamp)
    #expect(perceptor.getSuggestion(key: key, timestamp: timestamp + 100) != nil)

    perceptor.bleachSpecifiedSuggestions(candidateTargets: [candidate])

    #expect(perceptor.getSuggestion(key: key, timestamp: timestamp + 100) == nil)
    #expect(perceptor.getSavableData().contains { $0.key == key } == false)
  }

  @Test("[LXKit] Perceptor_BleachSpecifiedSuggestions_Contextual")
  func testBleachSpecifiedSuggestionsWithContextPairs() throws {
    let perceptor = Perceptor(capacity: 10)
    let timestamp = nowTimeStamp
    let key1 = "(context1,上下文1)&(test,測試)&(target,共用目標)"
    let key2 = "(context2,上下文2)&(test,測試)&(target,共用目標)"
    let candidate = "共用目標"

    percept(who: perceptor, key: key1, candidate: candidate, timestamp: timestamp)
    percept(who: perceptor, key: key2, candidate: candidate, timestamp: timestamp)

    #expect(
      perceptor.getSuggestion(key: key1, timestamp: timestamp + 100)?.first?
        .value == candidate
    )
    #expect(
      perceptor.getSuggestion(key: key2, timestamp: timestamp + 100)?.first?
        .value == candidate
    )

    perceptor.bleachSpecifiedSuggestions(targets: [(ngramKey: key1, candidate: candidate)])

    #expect(perceptor.getSuggestion(key: key1, timestamp: timestamp + 100) == nil)
    #expect(
      perceptor.getSuggestion(key: key2, timestamp: timestamp + 100)?.first?
        .value == candidate
    )
  }

  @Test("[LXKit] Perceptor_BleachSpecifiedSuggestions_HeadReading")
  func testBleachSpecifiedSuggestionsHeadReadingTargets() throws {
    let perceptor = Perceptor(capacity: 10)
    let timestamp = nowTimeStamp
    let headReading = "ㄍㄡˇ"
    let key = "(context,上下文)&(head,頭)&(\(headReading),狗)"
    let otherKey = "(context,上下文)&(head,頭)&(ㄇㄠ,貓)"

    percept(who: perceptor, key: key, candidate: "狗", timestamp: timestamp)
    percept(who: perceptor, key: otherKey, candidate: "貓", timestamp: timestamp)

    perceptor.bleachSpecifiedSuggestions(headReadingTargets: [headReading])

    #expect(perceptor.getSuggestion(key: key, timestamp: timestamp + 100) == nil)
    #expect(perceptor.getSuggestion(key: otherKey, timestamp: timestamp + 100)?.first?.value == "貓")
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
      "(ㄌㄧㄡˊ,留)&(ㄧˋ-ㄌㄩˇ,一縷)&(ㄈㄤ,芳)",
      "(ㄋㄥˊ,能)&(ㄌㄧㄡˊ,留)&(ㄧˋ-ㄌㄩˇ,一縷)",
      "(ㄉㄧㄝˊ,蝶)&(ㄋㄥˊ,能)&(ㄌㄧㄡˊ,留)",
      "()&(ㄧㄡ,幽)&(ㄉㄧㄝˊ,蝶)",
      "()&()&(ㄧㄡ,幽)",
    ]
    #expect(perceptor.getSavableData().map(\.key) == expectedPerceptionKeys)
  }

  @Test("[LXKit] Perceptor_ActualCase_SaisoukiNoGaika")
  func testPOM_6_ActualCaseScenario_SaisoukiNoGaika() throws {
    let perceptor = Perceptor(capacity: capacity)
    let compositor = makeAssembler(using: HomaTests.strLMSampleData_SaisoukiNoGaika)
    // 測試用句「再創世的凱歌」。
    let readingKeys = ["zai4", "chuang4", "shi4", "de5", "kai3", "ge1"]
    try readingKeys.forEach { try compositor.insertKey($0) }
    compositor.assemble()
    let assembledBefore = compositor.assembledSentence.map { $0.value }.joined(separator: " ")
    #expect("再 創 是的 凱歌" == assembledBefore)
    // 測試此時生成的 keyForQueryingData 是否正確
    let cursorShi = 2
    let cursorShiDe = 3
    let keyForQueryingDataAt2 = compositor.assembledSentence
      .generateKeyForPerception(cursor: cursorShi)
    #expect(keyForQueryingDataAt2?.ngramKey == "(zai4,再)&(chuang4,創)&(shi4-de5,是的)")
    #expect(keyForQueryingDataAt2?.headReading == "shi4")
    let keyForQueryingDataAt3 = compositor.assembledSentence
      .generateKeyForPerception(cursor: cursorShiDe)
    #expect(keyForQueryingDataAt3?.ngramKey == "(zai4,再)&(chuang4,創)&(shi4-de5,是的)")
    #expect(keyForQueryingDataAt3?.headReading == "de5")
    // 應能提供『是的』『似的』『凱歌』等候選
    let pairsAtShiDeEnd = compositor.fetchCandidates(
      at: 4,
      filter: Homa.Assembler.CandidateFetchFilter.endAt
    )
    #expect(pairsAtShiDeEnd.map { $0.pair.value }.contains("是的"))
    #expect(pairsAtShiDeEnd.map { $0.pair.value }.contains("似的"))
    // 模擬使用者把『是』改為『世』，再合成：觀測應為 shortToLong
    var obsCapturedMaybe: Homa.PerceptionIntel?
    try compositor.overrideCandidate(
      Homa.CandidatePair(keyArray: ["shi4"], value: "世"),
      at: cursorShi,
      enforceRetokenization: true
    ) {
      obsCapturedMaybe = $0
    }
    let obsCaptured = try #require(obsCapturedMaybe, "Should have a capture.")
    #expect(obsCaptured.contextualizedGramKey == "(zai4,再)&(chuang4,創)&(shi4,世)")
    // compositor.assemble() <- 已經組句了。
    let assembledAfter = compositor.assembledSentence.map { $0.value }.joined(separator: " ")
    #expect("再 創 世 的 凱歌" == assembledAfter)
    perceptor.memorizePerception(obsCaptured, timestamp: nowTimeStamp)
    // 記憶完畢。先看看是否有記憶。
    let currentmemory = perceptor.getSavableData()
    let firstObservationKey = try #require(
      currentmemory.first?.key,
      "Perceptor memorized nothing, or something wrong happened."
    )
    #expect(firstObservationKey == obsCaptured.contextualizedGramKey)
    // 然後是記憶效力測試：
    let validationCompositor = makeAssembler(using: HomaTests.strLMSampleData_SaisoukiNoGaika)
    try readingKeys.prefix(4).forEach { try validationCompositor.insertKey($0) }
    validationCompositor.assemble()
    let cursorToTest = validationCompositor.cursor
    let assembledNow = validationCompositor.assembledSentence
      .map { $0.value }
      .joined(separator: " ")
    #expect(
      ["再 創 是的", "再 創 世 的"].contains(assembledNow),
      "Unexpected baseline assembly: \(assembledNow)"
    )
    let suggestion = perceptor.fetchSuggestion(
      assembledResult: validationCompositor.assembledSentence,
      cursor: cursorToTest,
      timestamp: nowTimeStamp
    )
    #expect(!suggestion.isEmpty)
    let firstSuggestionRAW = try #require(
      suggestion.candidates.first,
      "Perceptor suggested nothing, or something wrong happened."
    )
    let candidateSuggested = Homa.CandidatePair(
      keyArray: firstSuggestionRAW.keyArray,
      value: firstSuggestionRAW.value,
      score: firstSuggestionRAW.probability
    )
    let cursorForOverride = suggestion.overrideCursor ?? cursorShi
    if (try? validationCompositor.overrideCandidate(
      candidateSuggested,
      at: cursorForOverride,
      type: suggestion.forceHighScoreOverride
        ? Homa.Node.OverrideType.withSpecified
        : Homa.Node.OverrideType.withTopGramScore,
      enforceRetokenization: true
    )) == nil {
      try validationCompositor.overrideCandidateLiteral(
        candidateSuggested.value,
        at: cursorForOverride,
        overrideType: suggestion.forceHighScoreOverride
          ? Homa.Node.OverrideType.withSpecified
          : Homa.Node.OverrideType.withTopGramScore
      )
    }
    validationCompositor.assemble()
    let assembledByPOM = validationCompositor.assembledSentence
      .map { $0.value }
      .joined(separator: " ")
    #expect("再 創 世 的" == assembledByPOM)
  }

  @Test("[LXKit] Perceptor_ActualCase_SaisoukiOnly")
  func testPOM_7_ActualCaseScenario_SaisoukiOnly() throws {
    let perceptor = Perceptor(capacity: capacity)
    let compositor = makeAssembler(using: HomaTests.strLMSampleData_SaisoukiNoGaika)
    let readingKeys = ["zai4", "chuang4", "shi4"]
    try readingKeys.forEach { try compositor.insertKey($0) }
    compositor.assemble()
    let assembledBefore = compositor.assembledSentence.map { $0.value }.joined(separator: " ")
    #expect("再 創 是" == assembledBefore)

    let cursorShi = 2
    var obsCapturedMaybe: Homa.PerceptionIntel?
    try compositor.overrideCandidate(
      Homa.CandidatePair(keyArray: ["shi4"], value: "世"),
      at: cursorShi,
      enforceRetokenization: true
    ) {
      obsCapturedMaybe = $0
    }
    let obsCaptured = try #require(obsCapturedMaybe, "Should have a capture.")

    let assembledAfter = compositor.assembledSentence.map { $0.value }.joined(separator: " ")
    #expect("再 創 世" == assembledAfter)
    perceptor.memorizePerception(obsCaptured, timestamp: nowTimeStamp)

    let currentMemory = perceptor.getSavableData()
    #expect(currentMemory.first?.key == obsCaptured.contextualizedGramKey)

    compositor.clear()
    try readingKeys.forEach { try compositor.insertKey($0) }
    compositor.assemble()

    let assembledNow = compositor.assembledSentence.map { $0.value }.joined(separator: " ")
    #expect("再 創 是" == assembledNow)

    let cursorToTest = compositor.cursor
    let suggestion = perceptor.fetchSuggestion(
      assembledResult: compositor.assembledSentence,
      cursor: cursorToTest,
      timestamp: nowTimeStamp
    )
    #expect(!suggestion.isEmpty)
    let firstSuggestionRAW = try #require(
      suggestion.candidates.first,
      "Perceptor suggested nothing, or something wrong happened."
    )

    let candidateSuggested = Homa.CandidatePair(
      keyArray: firstSuggestionRAW.keyArray,
      value: firstSuggestionRAW.value,
      score: firstSuggestionRAW.probability
    )
    let cursorForOverride = suggestion.overrideCursor ?? cursorShi
    if (try? compositor.overrideCandidate(
      candidateSuggested,
      at: cursorForOverride,
      type: suggestion.forceHighScoreOverride
        ? Homa.Node.OverrideType.withSpecified
        : Homa.Node.OverrideType.withTopGramScore,
      enforceRetokenization: true
    )) == nil {
      try compositor.overrideCandidateLiteral(
        candidateSuggested.value,
        at: cursorForOverride,
        overrideType: suggestion.forceHighScoreOverride
          ? Homa.Node.OverrideType.withSpecified
          : Homa.Node.OverrideType.withTopGramScore
      )
    }
    compositor.assemble()
    let assembledByPOM = compositor.assembledSentence.map { $0.value }.joined(separator: " ")
    #expect("再 創 世" == assembledByPOM)
  }

  @Test("[LXKit] Perceptor_ActualCase_BusinessEnglishSession")
  func testPOM_8_ActualCaseScenario_BusinessEnglishSession() throws {
    let perceptor = Perceptor(capacity: capacity)
    let compositor = makeAssembler(using: HomaTests.strLMSampleData_BusinessEnglishSession)
    let readingKeys = ["shang1", "wu4", "ying1", "yu3", "hui4", "hua4"]
    try readingKeys.forEach { try compositor.insertKey($0) }
    compositor.assemble()
    let assembledBefore = compositor.assembledSentence.map { $0.value }.joined(separator: " ")
    #expect("商務 英語 繪畫" == assembledBefore)

    let cursorHua = 5
    let keyForQueryingDataAt5 = compositor.assembledSentence
      .generateKeyForPerception(cursor: cursorHua)
    #expect(keyForQueryingDataAt5?.ngramKey == "(shang1-wu4,商務)&(ying1-yu3,英語)&(hui4-hua4,繪畫)")
    #expect(keyForQueryingDataAt5?.headReading == "hua4")

    let pairsAtHuiHuaEnd = compositor.fetchCandidates(
      at: 6,
      filter: Homa.Assembler.CandidateFetchFilter.endAt
    )
    #expect(pairsAtHuiHuaEnd.map { $0.pair.value }.contains("繪畫"))
    #expect(pairsAtHuiHuaEnd.map { $0.pair.value }.contains("會話"))

    var obsCapturedMaybe: Homa.PerceptionIntel?
    try compositor.overrideCandidate(
      Homa.CandidatePair(keyArray: ["hui4", "hua4"], value: "會話"),
      at: cursorHua,
      enforceRetokenization: true
    ) {
      obsCapturedMaybe = $0
    }
    let obsCaptured = try #require(obsCapturedMaybe, "Should have a capture.")

    let assembledAfter = compositor.assembledSentence.map { $0.value }.joined(separator: " ")
    #expect("商務 英語 會話" == assembledAfter)
    perceptor.memorizePerception(obsCaptured, timestamp: nowTimeStamp)

    let currentMemory = perceptor.getSavableData()
    #expect(currentMemory.first?.key == obsCaptured.contextualizedGramKey)

    let validationCompositor = makeAssembler(
      using: HomaTests
        .strLMSampleData_BusinessEnglishSession
    )
    try readingKeys.forEach { try validationCompositor.insertKey($0) }
    validationCompositor.assemble()
    let cursorToTest = validationCompositor.cursor
    let assembledNow = validationCompositor.assembledSentence
      .map { $0.value }
      .joined(separator: " ")
    #expect(
      ["商務 英語 繪畫", "商務 英語 會話"].contains(assembledNow),
      "Unexpected baseline assembly: \(assembledNow)"
    )
    let suggestion = perceptor.fetchSuggestion(
      assembledResult: validationCompositor.assembledSentence,
      cursor: cursorToTest,
      timestamp: nowTimeStamp
    )
    #expect(!suggestion.isEmpty)
    let firstSuggestionRAW = try #require(
      suggestion.candidates.first,
      "Perceptor suggested nothing, or something wrong happened."
    )
    let candidateSuggested = Homa.CandidatePair(
      keyArray: firstSuggestionRAW.keyArray,
      value: firstSuggestionRAW.value,
      score: firstSuggestionRAW.probability
    )
    let cursorForOverride = suggestion.overrideCursor ?? cursorHua
    if (try? validationCompositor.overrideCandidate(
      candidateSuggested,
      at: cursorForOverride,
      type: suggestion.forceHighScoreOverride
        ? Homa.Node.OverrideType.withSpecified
        : Homa.Node.OverrideType.withTopGramScore,
      enforceRetokenization: true
    )) == nil {
      try validationCompositor.overrideCandidateLiteral(
        candidateSuggested.value,
        at: cursorForOverride,
        overrideType: suggestion.forceHighScoreOverride
          ? Homa.Node.OverrideType.withSpecified
          : Homa.Node.OverrideType.withTopGramScore
      )
    }
    validationCompositor.assemble()
    let assembledByPOM = validationCompositor.assembledSentence
      .map { $0.value }
      .joined(separator: " ")
    #expect("商務 英語 會話" == assembledByPOM)
  }

  @Test("[LXKit] Perceptor_ActualCase_DiJiaoSubmission")
  func testPOM_9_ActualCaseScenario_DiJiaoSubmission() throws {
    let perceptor = Perceptor(capacity: capacity)
    let compositor = makeAssembler(using: HomaTests.strLMSampleData_DiJiaoSubmission)
    let readingKeys = ["di4", "jiao1"]
    try readingKeys.forEach { try compositor.insertKey($0) }
    compositor.assemble()

    try compositor.overrideCandidate(
      Homa.CandidatePair(keyArray: ["di4"], value: "第"),
      at: 0,
      enforceRetokenization: true
    )
    compositor.assemble()

    let assembledAfterFirst = compositor.assembledSentence.map { $0.value }.joined(separator: " ")
    #expect(
      ["第 交", "第 教"].contains(assembledAfterFirst),
      "Unexpected assembly after forcing 第: \(assembledAfterFirst)"
    )

    let candidatesAtEnd = compositor.fetchCandidates(
      at: readingKeys.count,
      filter: Homa.Assembler.CandidateFetchFilter.endAt
    )
    let diJiaoCandidate = try #require(
      candidatesAtEnd.first(where: { $0.pair.value == "遞交" })?.pair,
      "遞交 should be available as a candidate ending at the current cursor."
    )

    var obsCapturedMaybe: Homa.PerceptionIntel?
    try compositor.overrideCandidate(
      diJiaoCandidate,
      at: readingKeys.count,
      enforceRetokenization: true
    ) {
      obsCapturedMaybe = $0
    }
    let obsCaptured = try #require(obsCapturedMaybe, "Should have a capture.")
    #expect(obsCaptured.candidate == "遞交")
    #expect(obsCaptured.contextualizedGramKey == "()&(di4,第)&(di4-jiao1,遞交)")

    let assembledAfterSecond = compositor.assembledSentence.map { $0.value }.joined(separator: " ")
    #expect("遞交" == assembledAfterSecond)

    perceptor.memorizePerception(obsCaptured, timestamp: nowTimeStamp)

    let savedKeys = perceptor.getSavableData().map { $0.key }
    #expect(savedKeys.contains(obsCaptured.contextualizedGramKey))

    let directSuggestion = perceptor.getSuggestion(
      key: obsCaptured.contextualizedGramKey,
      timestamp: nowTimeStamp
    )
    #expect(directSuggestion?.first?.value == "遞交")

    let validationCompositor = makeAssembler(using: HomaTests.strLMSampleData_DiJiaoSubmission)
    try readingKeys.forEach { try validationCompositor.insertKey($0) }
    validationCompositor.assemble()
    _ = try? validationCompositor.overrideCandidate(
      Homa.CandidatePair(keyArray: ["di4"], value: "第"),
      at: 0,
      enforceRetokenization: true
    )
    validationCompositor.assemble()

    let baselineKey = validationCompositor.assembledSentence
      .generateKeyForPerception(cursor: max(validationCompositor.cursor - 1, 0))
    #expect(baselineKey?.ngramKey == "()&(di4,第)&(jiao1,交)")

    let suggestion = perceptor.fetchSuggestion(
      assembledResult: validationCompositor.assembledSentence,
      cursor: validationCompositor.cursor,
      timestamp: nowTimeStamp
    )
    let savedDataDump = perceptor.getSavableData()
      .map { "\($0.key): \($0.perception.overrides.keys.sorted())" }
      .joined(separator: "; ")
    #expect(
      !suggestion.isEmpty,
      "Suggestion should not be empty. Saved data: [\(savedDataDump)]"
    )
    let firstSuggestionRAW = try #require(
      suggestion.candidates.first,
      "Perceptor suggested nothing, or something wrong happened."
    )
    #expect(firstSuggestionRAW.value == "遞交")
    #expect(firstSuggestionRAW.keyArray == ["di4", "jiao1"])

    let candidateSuggested = Homa.CandidatePair(
      keyArray: firstSuggestionRAW.keyArray,
      value: firstSuggestionRAW.value,
      score: firstSuggestionRAW.probability
    )
    let cursorForOverride = suggestion.overrideCursor ?? 0
    if (try? validationCompositor.overrideCandidate(
      candidateSuggested,
      at: cursorForOverride,
      type: suggestion.forceHighScoreOverride
        ? Homa.Node.OverrideType.withSpecified
        : Homa.Node.OverrideType.withTopGramScore,
      enforceRetokenization: true
    )) == nil {
      try validationCompositor.overrideCandidateLiteral(
        candidateSuggested.value,
        at: cursorForOverride,
        overrideType: suggestion.forceHighScoreOverride
          ? Homa.Node.OverrideType.withSpecified
          : Homa.Node.OverrideType.withTopGramScore,
        enforceRetokenization: true
      )
    }
    validationCompositor.assemble()
    let assembledByPOM = validationCompositor.assembledSentence.map { $0.value }
      .joined(separator: " ")
    #expect("遞交" == assembledByPOM)
  }

  // MARK: Private

  private func percept(
    who perceptor: Perceptor,
    key: String,
    candidate: String,
    timestamp stamp: Double
  ) {
    perceptor.memorizePerception(
      (contextualizedGramKey: key, candidate: candidate),
      timestamp: stamp
    )
  }
}
