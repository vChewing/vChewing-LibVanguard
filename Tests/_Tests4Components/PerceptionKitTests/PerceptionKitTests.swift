// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
@testable import PerceptionKit
import Testing

// 更新時間常數，使用天為單位
private let nowTimeStamp: Double = 114_514 * 10_000
private let capacity = 5
private let dayInSeconds: Double = 24 * 3_600 // 一天的秒數

// MARK: - PerceptorTests

@Suite(.serialized)
public struct PerceptorTests {
  // MARK: Internal

  @Test("[PerceptionKit] Perceptor_BasicPerceptionOps")
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

  @Test("[PerceptionKit] Perceptor_NewestAgainstRepeatedlyUsed")
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

    // 在 8 天時，記憶應該已經衰減到閾值以下
    suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp + dayInSeconds * 8
    )

    // 移除原先的 TODO 和測試，直接檢查 nil
    #expect(suggested == nil, "經過8天後記憶仍未完全衰減")
  }

  // 添加一個專門測試長期記憶衰減的測試
  @Test("[PerceptionKit] Perceptor_LongTermMemoryDecay")
  func testLongTermMemoryDecay() throws {
    let perceptor = Perceptor(capacity: capacity)
    let key = "((ㄔㄥˊ-ㄒㄧㄣˋ:誠信),(ㄓㄜˋ:這),ㄉㄧㄢˇ)"
    let expectedSuggestion = "點"

    // 記錄一個記憶
    percept(who: perceptor, key: key, candidate: expectedSuggestion, timestamp: nowTimeStamp)

    // 確認剛剛記錄的能被找到
    var suggested = perceptor.getSuggestion(key: key, timestamp: nowTimeStamp)
    #expect(suggested?.map(\.value).first ?? "" == expectedSuggestion)

    // 測試不同天數的衰減
    // 調整期望：0-6天應該記憶存在，7天及以上應該消失
    let testDays = [0, 1, 3, 5, 6, 6.5, 7, 8, 20, 80]

    for days in testDays {
      let currentTimestamp = nowTimeStamp + (dayInSeconds * Double(days))
      suggested = perceptor.getSuggestion(key: key, timestamp: currentTimestamp)

      if days <= 5 {
        #expect(suggested != nil, "第\(days)天就不該衰減到閾值以下")
        if let suggestion = suggested?.first {
          let score = suggestion.probability
          #expect(
            score > perceptor.threshold,
            "第\(days)天的權重\(score)不應低於閾值\(Perceptor.kDecayThreshold)"
          )
        }
      } else {
        #expect(suggested == nil, "第\(days)天應該已經衰減到閾值以下")
      }
    }
  }

  @Test("[PerceptionKit] Perceptor_LRUTable")
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

    // C是最新的，應該在列表中
    var suggested = perceptor.getSuggestion(
      key: c.key,
      timestamp: nowTimeStamp + 3
    )
    #expect(suggested?.map(\.value).first ?? "" == c.value)

    // B是第二新的，應該在列表中
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
