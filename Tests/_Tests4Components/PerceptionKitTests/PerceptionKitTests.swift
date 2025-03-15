// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

@testable import PerceptionKit
import Testing

private let nowTimeStamp: Double = 114_514 * 10_000
private let capacity = 5
private let halfLife: Double = 5_400

// MARK: - PerceptorTests

@Suite(.serialized)
public struct PerceptorTests {
  // MARK: Internal

  @Test("[Homa] Perceptor_BasicOps")
  func testBasicOps() throws {
    var perceptor = Perceptor(
      capacity: capacity,
      decayConstant: Double(halfLife)
    )
    let key = "((ㄕㄣˊ-ㄌㄧˇ-ㄌㄧㄥˊ-ㄏㄨㄚˊ:神里綾華),(ㄉㄜ˙:的),ㄍㄡˇ)"
    let frontEdgeReading = "ㄍㄡˇ"
    let expectedSuggestion = "狗"
    percept(who: &perceptor, key: key, candidate: expectedSuggestion, timestamp: nowTimeStamp)
    var suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp,
      frontEdgeReading: frontEdgeReading
    )
    #expect(suggested?.map(\.current).first ?? "" == expectedSuggestion)
    #expect(suggested?.map(\.previous).first ?? "" == "的")
    var i = 0
    while !(suggested?.isEmpty ?? true) {
      suggested = perceptor.getSuggestion(
        key: key,
        timestamp: nowTimeStamp + (halfLife * Double(i)),
        frontEdgeReading: frontEdgeReading
      )
      let suggestedCandidates = suggested
      if suggestedCandidates?.isEmpty ?? true { print(i) }
      if i >= 21 {
        #expect(
          (suggested?.map(\.current).first ?? "") != expectedSuggestion,
          "Failed at iteration \(i)"
        )
        #expect(suggested?.isEmpty ?? false)
      } else {
        #expect(
          (suggested?.map(\.current).first ?? "") == expectedSuggestion,
          "Failed at iteration \(i)"
        )
      }
      i += 1
    }
  }

  @Test("[Homa] Perceptor_NewestAgainstRepeatedlyUsed")
  func testNewestAgainstRepeatedlyUsed() throws {
    var perceptor = Perceptor(
      capacity: capacity,
      decayConstant: Double(halfLife)
    )
    let key = "((ㄕㄣˊ-ㄌㄧˇ-ㄌㄧㄥˊ-ㄏㄨㄚˊ:神里綾華),(ㄉㄜ˙:的),ㄍㄡˇ)"
    let frontEdgeReading = "ㄍㄡˇ"
    let valRepeatedlyUsed = "狗" // 更常用
    let valNewest = "苟" // 最近偶爾用了一次
    let stamps: [Double] = [0, 0.5, 2, 2.5, 4, 4.5, 5.3].map { nowTimeStamp + halfLife * $0 }
    stamps.forEach { stamp in
      percept(who: &perceptor, key: key, candidate: valRepeatedlyUsed, timestamp: stamp)
    }
    var suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp,
      frontEdgeReading: frontEdgeReading
    )
    #expect(suggested?.map(\.current).first ?? "" == valRepeatedlyUsed)
    [6.0, 18.0, 23.0].forEach { i in
      suggested = perceptor.getSuggestion(
        key: key,
        timestamp: nowTimeStamp + halfLife * Double(i),
        frontEdgeReading: frontEdgeReading
      )
      #expect(
        (suggested?.map(\.current).first ?? "") == valRepeatedlyUsed,
        "Failed at iteration \(i)"
      )
    }
    // 試試看偶爾選了不常用的詞的話、是否會影響上文所生成的有一定強效的記憶。
    percept(
      who: &perceptor,
      key: key,
      candidate: valNewest,
      timestamp: nowTimeStamp + halfLife * 23.4
    )
    suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp + halfLife * 26,
      frontEdgeReading: frontEdgeReading
    )
    #expect(suggested?.map(\.current).first ?? "" == valNewest)
    suggested = perceptor.getSuggestion(
      key: key,
      timestamp: nowTimeStamp + halfLife * 50,
      frontEdgeReading: frontEdgeReading
    )
    #expect((suggested?.map(\.current).first ?? "") != valNewest)
    #expect(suggested?.isEmpty ?? false)
  }

  @Test("[Homa] Perceptor_LRUTable")
  func testLRUTable() throws {
    let a = (key: "((ㄕㄣˊ-ㄌㄧˇ-ㄌㄧㄥˊ-ㄏㄨㄚˊ:神里綾華),(ㄉㄜ˙:的),ㄍㄡˇ)", value: "狗", head: "ㄍㄡˇ")
    let b = (key: "((ㄆㄞˋ-ㄇㄥˊ:派蒙),(ㄉㄜ˙:的),ㄐㄧㄤˇ-ㄐㄧㄣ)", value: "伙食費", head: "ㄏㄨㄛˇ-ㄕˊ-ㄈㄟˋ")
    let c = (key: "((ㄍㄨㄛˊ-ㄅㄥ:國崩),(ㄉㄜ˙:的),ㄇㄠˋ-ㄗ˙)", value: "帽子", head: "ㄇㄠˋ-ㄗ˙")
    let d = (key: "((ㄌㄟˊ-ㄉㄧㄢˋ-ㄐㄧㄤ-ㄐㄩㄣ:雷電將軍),(ㄉㄜ˙:的),ㄐㄧㄠˇ-ㄔㄡˋ)", value: "腳臭", head: "ㄐㄧㄠˇ-ㄔㄡˋ")
    var perceptor = Perceptor(
      capacity: 2,
      decayConstant: Double(halfLife)
    )
    percept(who: &perceptor, key: a.key, candidate: a.value, timestamp: nowTimeStamp)
    percept(who: &perceptor, key: b.key, candidate: b.value, timestamp: nowTimeStamp + halfLife * 1)
    percept(who: &perceptor, key: c.key, candidate: c.value, timestamp: nowTimeStamp + halfLife * 2)
    // C is in the list.
    var suggested = perceptor.getSuggestion(
      key: c.key,
      timestamp: nowTimeStamp + halfLife * 3,
      frontEdgeReading: c.head
    )
    #expect(suggested?.map(\.current).first ?? "" == c.value)
    #expect(suggested?.map(\.previous).first ?? "" == "的")
    // B is in the list.
    suggested = perceptor.getSuggestion(
      key: b.key,
      timestamp: nowTimeStamp + halfLife * 3.5,
      frontEdgeReading: b.head
    )
    #expect(suggested?.map(\.current).first ?? "" == b.value)
    #expect(suggested?.map(\.previous).first ?? "" == "的")
    // A is purged.
    suggested = perceptor.getSuggestion(
      key: a.key,
      timestamp: nowTimeStamp + halfLife * 4,
      frontEdgeReading: a.head
    )
    #expect(suggested == nil)
    // Observe a new pair (D).
    percept(
      who: &perceptor,
      key: d.key,
      candidate: d.value,
      timestamp: nowTimeStamp + halfLife * 4.5
    )
    // D is in the list.
    suggested = perceptor.getSuggestion(
      key: d.key,
      timestamp: nowTimeStamp + halfLife * 5,
      frontEdgeReading: d.head
    )
    #expect(suggested?.map(\.current).first ?? "" == d.value)
    #expect(suggested?.map(\.previous).first ?? "" == "的")
    // C is in the list.
    suggested = perceptor.getSuggestion(
      key: c.key,
      timestamp: nowTimeStamp + halfLife * 5.5,
      frontEdgeReading: c.head
    )
    #expect(suggested?.map(\.current).first ?? "" == c.value)
    #expect(suggested?.map(\.previous).first ?? "" == "的")
    // B is purged.
    suggested = perceptor.getSuggestion(
      key: b.key,
      timestamp: nowTimeStamp + halfLife * 6,
      frontEdgeReading: b.head
    )
    #expect(suggested == nil)
  }

  // MARK: Private

  private func percept(
    who perceptor: inout Perceptor,
    key: String,
    candidate: String,
    timestamp stamp: Double
  ) {
    perceptor.doPerception(
      key: key,
      candidate: candidate,
      timestamp: stamp
    )
  }
}
