// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Testing

@testable import Homa

// MARK: - HomaPerformanceTests

@Suite(.serialized)
public struct HomaPerformanceTests: HomaTestSuite {
  // MARK: Internal

  @Test("[Homa] Bench_LargeScaleSentenceAssembly")
  func testLargeScaleSentenceAssembly() async throws {
    print("// Starting large scale sentence assembly performance test")

    // 構築一份更複雜的測試資料。這次使用繁體中文。

    let testSentences = [
      "ㄙㄨㄛˇ-ㄨㄟˋ-ㄎㄞ-ㄊㄨㄛˋ", // 所謂開拓
      "ㄐㄧㄡˋ-ㄕˋ-ㄧㄢˊ-ㄓㄜ˙-ㄑㄧㄢˊ-ㄖㄣˊ-ㄨㄟˋ-ㄐㄧㄣˋ-ㄉㄜ˙-ㄉㄠˋ-ㄌㄨˋ", // 就是沿著前人未盡的道路
      "ㄗㄡˇ-ㄔㄨ-ㄍㄥ-ㄧㄠˊ-ㄩㄢˇ-ㄉㄜ˙-ㄐㄩˋ-ㄌㄧˊ", // 走出更遙遠的距離
      "ㄧㄣ-ㄨㄟˊ-ㄎㄞ-ㄊㄨㄛˋ-ㄉㄜ˙-ㄉㄠˋ-ㄌㄨˋ", // 因為開拓的道路
      "ㄘㄨㄥˊ-ㄌㄞˊ-ㄅㄨˋ-ㄧㄡˊ-ㄊㄚ-ㄖㄣˊ-ㄆㄨ-ㄐㄧㄡˋ", // 從來不由他人鋪就
    ]

    let mockLM = TestLM(rawData: createExtensiveMockData())
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) },
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )

    var totalTime: Double = 0
    let iterations = 100

    for iteration in 0 ..< iterations {
      let sentence = testSentences[iteration % testSentences.count]
      let keys = sentence.split(separator: "-").map(String.init)

      // 每次迭代都清空一次組字器。
      assembler.clear()

      let iterationTime = Self.measureTime {
        do {
          for key in keys {
            try assembler.insertKey(key)
          }
          _ = assembler.assemble()
        } catch {
          // Handle error
        }
      }

      totalTime += iterationTime

      if iteration % 20 == 0 {
        print("// Completed iteration \(iteration), time: \(iterationTime)s")
      }
    }

    let averageTime = totalTime / Double(iterations)
    print("// Average time per sentence: \(averageTime)s")
    print("// Total time for \(iterations) iterations: \(totalTime)s")

    // 效能斷言 - 平均每句話的組字不該超過 5ms。
    #expect(
      averageTime < 0.005,
      "Sentence assembly should be under 5ms on average, was \(averageTime)s"
    )
  }

  @Test("[Homa] Bench_TrieOpsStressTest")
  func testTrieOperationsStress() async throws {
    print("// Starting Trie operations stress test")

    let mockLM = TestLM(rawData: createExtensiveMockData())

    // 測試查詢效能。
    let keys = ["ㄙㄨㄛˇ", "ㄨㄟˋ", "ㄎㄞ", "ㄊㄨㄛˋ", "ㄐㄧㄡˋ", "ㄕˋ"]
    let iterations = 1_000

    let queryTime = Self.measureTime {
      for _ in 0 ..< iterations {
        for key in keys {
          _ = mockLM.queryGrams([key])
          _ = mockLM.hasGrams([key])
        }
      }
    }

    let avgQueryTime = queryTime / Double(iterations * keys.count)
    print("// Average query time: \(avgQueryTime)s")
    print("// Total query time for \(iterations * keys.count) operations: \(queryTime)s")

    // 效能斷言 - 平均每句話的組字不該超過 0.1ms。
    #expect(
      avgQueryTime < 0.0001,
      "Trie queries should be under 0.1ms on average, was \(avgQueryTime)s"
    )
  }

  @Test("[Homa] Bench_MemoryUsageAndARCPressure")
  func testMemoryUsage() async throws {
    print("// Starting memory usage test")

    let mockLM = TestLM(rawData: createExtensiveMockData())
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) },
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )

    // 模擬重度使用情形模式
    let testTime = Self.measureTime {
      for batch in 0 ..< 50 {
        // 創建暨摧毀組字器副本，測試 ARC 效能
        for _ in 0 ..< 20 {
          let tempAssembler = Homa.Assembler(
            gramQuerier: { mockLM.queryGrams($0) },
            gramAvailabilityChecker: { mockLM.hasGrams($0) }
          )

          try? tempAssembler.insertKey("test\(batch)")
          _ = tempAssembler.assemble()
        }

        // 以累積資料測試主要組字器
        try? assembler.insertKey("batch\(batch)")
        _ = assembler.assemble()

        if batch % 10 == 0 {
          assembler.clear()
        }
      }
    }

    print("// Memory usage test completed in: \(testTime)s")
    #expect(
      testTime < 1.0,
      "Memory usage test should complete in under 1 second, took \(testTime)s"
    )
  }

  @Test("[Homa] Bench_AdvancedOptimizations")
  func testAdvancedOptimizations() async throws {
    print("// Starting advanced optimizations benchmark")

    // 用更大的真實資料集來做測試
    let testData = generateRealisticChineseInput()
    let mockLM = TestLM(rawData: testData.mockData)

    var totalTime: Double = 0
    let iterations = 200 // 增加迭代次數以追求測試可信度

    // 預熱快取
    for _ in 0 ..< 10 {
      let assembler = Homa.Assembler(
        gramQuerier: { mockLM.queryGrams($0) },
        gramAvailabilityChecker: { mockLM.hasGrams($0) }
      )

      for key in testData.keys.prefix(5) {
        try? assembler.insertKey(key)
      }
      _ = assembler.assemble()
    }

    // 執行實際基準測試
    for iteration in 0 ..< iterations {
      let keys = testData.keys

      let iterationTime = try Self.measureTime {
        let assembler = Homa.Assembler(
          gramQuerier: { mockLM.queryGrams($0) },
          gramAvailabilityChecker: { mockLM.hasGrams($0) }
        )

        for key in keys {
          try assembler.insertKey(key)
        }
        _ = assembler.assemble()
      }

      totalTime += iterationTime

      if iteration % 50 == 0 {
        print("// Iteration \(iteration), time: \(iterationTime)s")
      }
    }

    let averageTime = totalTime / Double(iterations)
    print("// Advanced benchmark - Average time: \(averageTime)s")
    print("// Advanced benchmark - Total time: \(totalTime)s for \(iterations) iterations")

    // 效能斷言 - 這裡使用更寬鬆的閾值要求
    #expect(
      averageTime < 0.02,
      "Advanced benchmark should be under 20ms on average, was \(averageTime)s"
    )
  }

  // MARK: Private

  private func generateRealisticChineseInput() -> (keys: [String], mockData: String) {
    // 生成複雜的擬真語言模型資料。
    var mockData = createExtensiveMockData()

    // 建立真實的中文注音輸入模式 - 使用與 Mock 資料對應的注音符號
    let knownBopomofo = [
      "ㄙㄨㄛˇ", "ㄨㄟˋ", "ㄎㄞ", "ㄊㄨㄛˋ", "ㄐㄧㄡˋ", "ㄕˋ",
      "ㄧㄢˊ", "ㄓㄜ˙", "ㄑㄧㄢˊ", "ㄖㄣˊ", "ㄐㄧㄣˋ", "ㄉㄜ˙", 
      "ㄉㄠˋ", "ㄌㄨˋ", "ㄗㄡˇ", "ㄔㄨ", "ㄍㄥ", "ㄧㄠˊ", 
      "ㄩㄢˇ", "ㄐㄩˋ", "ㄌㄧˊ", "ㄧㄣ", "ㄨㄟˊ", "ㄘㄨㄥˊ", 
      "ㄌㄞˊ", "ㄅㄨˋ", "ㄧㄡˊ", "ㄊㄚ", "ㄆㄨ"
    ]

    // 建立一些雙元圖組合
    for i in 0 ..< min(knownBopomofo.count, 10) {
      for j in 0 ..< min(knownBopomofo.count, 10) {
        let bigram = "\(knownBopomofo[i])-\(knownBopomofo[j])"
        let weight = -7.0 - Double.random(in: 0 ... 2)
        mockData += "\n\(bigram) 測試\(i)\(j) \(weight)"
      }
    }

    // 生成測試用讀音鍵值，以模擬長句輸入。只使用已知存在的讀音。
    var keys: [String] = []
    for _ in 0 ..< 15 { // Longer input sequence
      keys.append(knownBopomofo.randomElement()!)
    }

    return (keys: keys, mockData: mockData)
  }

  private func createExtensiveMockData() -> String {
    """
    ㄙㄨㄛˇ 所 -3.2
    ㄙㄨㄛˇ 索 -6.1
    ㄨㄟˋ 謂 -3.8
    ㄨㄟˋ 為 -4.2
    ㄨㄟˋ 位 -5.3
    ㄎㄞ 開 -3.5
    ㄎㄞ 凱 -5.9
    ㄊㄨㄛˋ 拓 -4.1
    ㄊㄨㄛˋ 托 -5.2
    ㄐㄧㄡˋ 就 -3.7
    ㄐㄧㄡˋ 舊 -5.4
    ㄕˋ 是 -3.1
    ㄕˋ 事 -4.8
    ㄕˋ 世 -5.2
    ㄧㄢˊ 沿 -4.3
    ㄧㄢˊ 言 -5.1
    ㄓㄜ˙ 著 -3.9
    ㄓㄜ˙ 者 -4.7
    ㄑㄧㄢˊ 前 -3.6
    ㄑㄧㄢˊ 錢 -5.8
    ㄖㄣˊ 人 -3.4
    ㄖㄣˊ 仁 -6.2
    ㄨㄟˋ 未 -4.1
    ㄐㄧㄣˋ 盡 -4.5
    ㄐㄧㄣˋ 進 -4.9
    ㄉㄜ˙ 的 -2.8
    ㄉㄠˋ 道 -3.7
    ㄉㄠˋ 到 -4.3
    ㄌㄨˋ 路 -4.2
    ㄌㄨˋ 露 -6.1
    ㄗㄡˇ 走 -3.9
    ㄗㄡˇ 揍 -6.7
    ㄔㄨ 出 -3.8
    ㄔㄨ 初 -5.4
    ㄍㄥ 更 -4.1
    ㄍㄥ 耕 -6.3
    ㄧㄠˊ 遙 -4.8
    ㄧㄠˊ 搖 -5.9
    ㄩㄢˇ 遠 -4.2
    ㄩㄢˇ 院 -5.6
    ㄐㄩˋ 距 -4.7
    ㄐㄩˋ 巨 -5.3
    ㄌㄧˊ 離 -4.1
    ㄌㄧˊ 李 -5.8
    ㄧㄣ 因 -3.8
    ㄧㄣ 音 -5.2
    ㄨㄟˊ 為 -3.5
    ㄨㄟˊ 維 -5.7
    ㄘㄨㄥˊ 從 -4.1
    ㄘㄨㄥˊ 叢 -6.4
    ㄌㄞˊ 來 -3.7
    ㄌㄞˊ 萊 -5.9
    ㄅㄨˋ 不 -3.2
    ㄅㄨˋ 布 -5.1
    ㄧㄡˊ 由 -4.3
    ㄧㄡˊ 油 -5.4
    ㄊㄚ 他 -3.6
    ㄊㄚ 她 -4.1
    ㄆㄨ 鋪 -4.9
    ㄆㄨ 撲 -6.2
    """
  }
}
