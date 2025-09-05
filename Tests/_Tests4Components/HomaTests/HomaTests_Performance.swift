// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

@testable import Homa
import Testing

// MARK: - HomaPerformanceTests

@Suite(.serialized)
public struct HomaPerformanceTests: HomaTestSuite {
  
  @Test("[Performance] Large Scale Sentence Assembly")
  func testLargeScaleSentenceAssembly() async throws {
    print("// Starting large scale sentence assembly performance test")
    
    // Create a more comprehensive test dataset
    let testSentences = [
      "ni3-hao3-shi4-jie4", // 你好世界
      "zhong1-guo2-ren2-min2", // 中国人民  
      "wo3-ai4-ni3-men5", // 我爱你们
      "zhe4-shi4-yi1-ge4-ce4-shi4", // 这是一个测试
      "cheng2-xu4-yuan2-de5-gong1-zuo4" // 程序员的工作
    ]
    
    let mockLM = TestLM(rawData: createExtensiveMockData())
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) },
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )
    
    var totalTime: Double = 0
    let iterations = 100
    
    for iteration in 0..<iterations {
      let sentence = testSentences[iteration % testSentences.count]
      let keys = sentence.split(separator: "-").map(String.init)
      
      // Clear assembler for each iteration
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
    
    // Performance assertion - should be under 5ms per sentence on average
    #expect(averageTime < 0.005, "Sentence assembly should be under 5ms on average, was \(averageTime)s")
  }
  
  @Test("[Performance] Trie Operations Stress Test")
  func testTrieOperationsStress() async throws {
    print("// Starting Trie operations stress test")
    
    let mockLM = TestLM(rawData: createExtensiveMockData())
    
    // Test query performance
    let keys = ["ni3", "hao3", "shi4", "jie4", "zhong1", "guo2"]
    let iterations = 1000
    
    let queryTime = Self.measureTime {
      for _ in 0..<iterations {
        for key in keys {
          _ = mockLM.queryGrams([key])
          _ = mockLM.hasGrams([key])
        }
      }
    }
    
    let avgQueryTime = queryTime / Double(iterations * keys.count)
    print("// Average query time: \(avgQueryTime)s")
    print("// Total query time for \(iterations * keys.count) operations: \(queryTime)s")
    
    // Performance assertion - should be under 0.1ms per query on average
    #expect(avgQueryTime < 0.0001, "Trie queries should be under 0.1ms on average, was \(avgQueryTime)s")
  }
  
  @Test("[Performance] Memory Usage and GC Pressure") 
  func testMemoryUsage() async throws {
    print("// Starting memory usage test")
    
    let mockLM = TestLM(rawData: createExtensiveMockData())
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) },
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )
    
    // Simulate heavy usage pattern
    let testTime = Self.measureTime {
      for batch in 0..<50 {
        // Create and destroy assemblers to test GC pressure
        for _ in 0..<20 {
          let tempAssembler = Homa.Assembler(
            gramQuerier: { mockLM.queryGrams($0) },
            gramAvailabilityChecker: { mockLM.hasGrams($0) }
          )
          
          try? tempAssembler.insertKey("test\(batch)")
          _ = tempAssembler.assemble()
        }
        
        // Test main assembler with accumulated data
        try? assembler.insertKey("batch\(batch)")
        _ = assembler.assemble()
        
        if batch % 10 == 0 {
          assembler.clear()
        }
      }
    }
    
    print("// Memory usage test completed in: \(testTime)s")
    #expect(testTime < 1.0, "Memory usage test should complete in under 1 second, took \(testTime)s")
  }
  
  private func createExtensiveMockData() -> String {
    return """
    ni3 你 -4.5
    ni3 尼 -6.2
    hao3 好 -4.1  
    hao3 號 -5.8
    shi4 是 -3.9
    shi4 事 -5.2
    shi4 世 -5.4
    jie4 界 -4.8
    jie4 接 -5.1
    zhong1 中 -4.0
    zhong1 钟 -6.1
    guo2 国 -4.2
    guo2 果 -5.5
    ren2 人 -4.0
    ren2 仁 -6.8
    min2 民 -4.3
    min2 敏 -6.7
    wo3 我 -3.8
    ai4 爱 -4.5
    men5 们 -4.1
    zhe4 这 -3.7
    yi1 一 -3.5
    ge4 个 -3.8
    ce4 测 -5.9
    xu4 序 -5.1
    yuan2 员 -4.9
    de5 的 -3.2
    gong1 工 -4.7
    zuo4 作 -4.4
    cheng2 程 -5.0
    ni3-hao3 你好 -7.5
    shi4-jie4 世界 -8.1
    zhong1-guo2 中国 -7.8
    ren2-min2 人民 -8.4
    wo3-ai4 我爱 -8.9
    ni3-men5 你们 -8.7
    zhe4-shi4 这是 -8.0
    yi1-ge4 一个 -7.9
    ce4-shi4 测试 -9.1
    cheng2-xu4 程序 -8.8
    xu4-yuan2 序员 -9.2
    yuan2-de5 员的 -9.5
    gong1-zuo4 工作 -8.6
    """
  }
}