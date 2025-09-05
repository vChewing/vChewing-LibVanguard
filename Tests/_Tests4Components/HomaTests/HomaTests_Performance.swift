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
      "ㄋㄧˇ-ㄏㄠˇ-ㄕˋ-ㄐㄧㄝˋ", // 你好世界
      "ㄙㄨㄛˇ-ㄨㄟˋ-ㄎㄞ-ㄊㄨㄛˋ-ㄐㄧㄡˋ-ㄕˋ-ㄧㄢˊ-ㄓㄨㄛˊ-ㄑㄧㄢˊ-ㄖㄣˊ-ㄨㄟˋ-ㄐㄧㄣˋ-ㄉㄜ˙-ㄉㄠˋ-ㄌㄨˋ", // 所謂開拓，就是沿著前人未盡的道路
      "ㄨㄛˇ-ㄞˋ-ㄋㄧˇ-ㄇㄣ˙", // 我愛你們
      "ㄓㄜˋ-ㄕˋ-ㄧ-ㄍㄜˋ-ㄘㄜˋ-ㄕˋ", // 這是一個測試
      "ㄍㄨㄥ-ㄔㄥˊ-ㄕ-ㄉㄜ˙-ㄍㄨㄥ-ㄗㄨㄛˋ", // 工程師的工作
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
    let keys = ["ㄋㄧˇ", "ㄏㄠˇ", "ㄕˋ", "ㄐㄧㄝˋ", "ㄓㄨㄥ", "ㄨㄣˊ"]
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
      "ㄋㄧˇ", "ㄏㄠˇ", "ㄕˋ", "ㄐㄧㄝˋ", "ㄓㄨㄥ", "ㄨㄣˊ", "ㄕˇ", "ㄩㄥˋ",
      "ㄓㄜˇ", "ㄨㄛˇ", "ㄞˋ", "ㄇㄣ˙", "ㄓㄜˋ", "ㄧ", "ㄍㄜˋ", "ㄘㄜˋ", 
      "ㄍㄨㄥ", "ㄔㄥˊ", "ㄕ", "ㄉㄜ˙", "ㄗㄨㄛˋ", "ㄙㄨㄛˇ", "ㄨㄟˋ", 
      "ㄎㄞ", "ㄊㄨㄛˋ", "ㄐㄧㄡˋ", "ㄧㄢˊ", "ㄓㄨㄛˊ", "ㄑㄧㄢˊ", 
      "ㄖㄣˊ", "ㄐㄧㄣˋ", "ㄉㄠˋ", "ㄌㄨˋ"
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
    ㄋㄧˇ 你 -4.5
    ㄋㄧˇ 尼 -6.2
    ㄏㄠˇ 好 -4.1
    ㄏㄠˇ 號 -5.8
    ㄕˋ 是 -3.9
    ㄕˋ 事 -5.2
    ㄕˋ 世 -5.4
    ㄐㄧㄝˋ 界 -4.8
    ㄐㄧㄝˋ 接 -5.1
    ㄓㄨㄥ 中 -4.0
    ㄓㄨㄥ 鐘 -6.1
    ㄨㄣˊ 文 -4.2
    ㄨㄣˊ 聞 -5.5
    ㄕˇ 使 -4.0
    ㄕˇ 史 -6.8
    ㄩㄥˋ 用 -4.3
    ㄩㄥˋ 永 -6.7
    ㄓㄜˇ 者 -4.5
    ㄓㄜˇ 這 -3.8
    ㄨㄛˇ 我 -3.8
    ㄞˋ 愛 -4.5
    ㄇㄣ˙ 們 -4.1
    ㄓㄜˋ 這 -3.7
    ㄧ 一 -3.5
    ㄍㄜˋ 個 -3.8
    ㄘㄜˋ 測 -5.9
    ㄍㄨㄥ 工 -4.7
    ㄔㄥˊ 程 -5.0
    ㄕ 師 -4.9
    ㄉㄜ˙ 的 -3.2
    ㄗㄨㄛˋ 作 -4.4
    ㄙㄨㄛˇ 所 -4.6
    ㄨㄟˋ 謂 -5.3
    ㄨㄟˋ 未 -5.8
    ㄎㄞ 開 -4.2
    ㄊㄨㄛˋ 拓 -5.7
    ㄐㄧㄡˋ 就 -4.1
    ㄧㄢˊ 沿 -5.4
    ㄓㄨㄛˊ 著 -4.3
    ㄑㄧㄢˊ 前 -4.8
    ㄖㄣˊ 人 -4.0
    ㄐㄧㄣˋ 盡 -5.6
    ㄉㄠˋ 道 -4.7
    ㄌㄨˋ 路 -4.5
    ㄋㄧˇ-ㄏㄠˇ 你好 -7.5
    ㄕˋ-ㄐㄧㄝˋ 世界 -8.1
    ㄓㄨㄥ-ㄨㄣˊ 中文 -7.8
    ㄕˇ-ㄩㄥˋ 使用 -8.4
    ㄩㄥˋ-ㄓㄜˇ 用者 -8.9
    ㄨㄛˇ-ㄞˋ 我愛 -8.9
    ㄋㄧˇ-ㄇㄣ˙ 你們 -8.7
    ㄓㄜˋ-ㄕˋ 這是 -8.0
    ㄧ-ㄍㄜˋ 一個 -7.9
    ㄘㄜˋ-ㄕˋ 測試 -9.1
    ㄍㄨㄥ-ㄔㄥˊ 工程 -8.8
    ㄔㄥˊ-ㄕ 程師 -9.2
    ㄕ-ㄉㄜ˙ 師的 -9.5
    ㄍㄨㄥ-ㄗㄨㄛˋ 工作 -8.6
    ㄙㄨㄛˇ-ㄨㄟˋ 所謂 -8.3
    ㄎㄞ-ㄊㄨㄛˋ 開拓 -8.7
    ㄧㄢˊ-ㄓㄨㄛˊ 沿著 -9.0
    ㄑㄧㄢˊ-ㄖㄣˊ 前人 -8.5
    ㄨㄟˋ-ㄐㄧㄣˋ 未盡 -9.2
    ㄉㄠˋ-ㄌㄨˋ 道路 -8.4
    """
  }
}
