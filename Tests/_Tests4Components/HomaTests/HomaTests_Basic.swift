// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

@testable import Homa
import Testing

// MARK: - HomaTestsBasic

@Suite(.serialized)
public struct HomaTestsBasic: HomaTestSuite {
  @Test("[Homa] NodeSpanAPIs")
  func testNodeSpanAPIs() async throws {
    let langModel = TestLM(rawData: strLMSampleDataLitch)
    var span = Homa.NodeSpan()
    let queriedRawGramsDa = langModel.queryGrams(["da4"])
    let queriedRawGramsDaqiantian = langModel.queryGrams(["da4-qian2-tian1"])
    let n1 = Homa.Node(
      keyArray: ["da4"],
      grams: queriedRawGramsDa.map { Homa.Gram($0) }
    )
    let n3 = Homa.Node(
      keyArray: ["da4", "qian2", "tian1"],
      grams: queriedRawGramsDaqiantian.map { Homa.Gram($0) }
    )
    #expect(span.maxLength == 0)
    span.addNode(node: n1)
    #expect(span.maxLength == 1)
    span.addNode(node: n3)
    #expect(span.maxLength == 3)
    #expect(span[1] == n1)
    #expect(span[2] == nil)
    #expect(span[3] == n3)
    span.removeAll()
    #expect(span.maxLength == 0)
    #expect(span[1] == nil)
    #expect(span[2] == nil)
    #expect(span[3] == nil)
  }

  @Test("[Homa] Assembler_BasicSpanNodeGramInsertion")
  func testBasicSpanNodeGramInsertion() async throws {
    let assembler = Self.makeAssemblerUsingMockLM()
    #expect((assembler.cursor, assembler.length) == (0, 0))
    try assembler.insertKey("s")
    #expect((assembler.cursor, assembler.length) == (1, 1))
    #expect(assembler.spans.count == 1)
    #expect(assembler.spans[0].maxLength == 1)
    #expect(assembler.spans[0][1]?.keyArray == ["s"])
    try assembler.dropKey(direction: .rear)
    #expect((assembler.cursor, assembler.length) == (0, 0))
    #expect(assembler.spans.isEmpty)
  }

  @Test("[Homa] Assembler_DefendingInvalidOps")
  func testDefendingInvalidOps() async throws {
    let mockLM = TestLM(rawData: "ping2 ping2 -1")
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) },
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )
    #expect(Self.mustFail { try assembler.insertKey("guo3") })
    #expect(Self.mustFail { try assembler.insertKey("") })
    #expect(Self.mustFail { try assembler.insertKey("") })
    let configAlpha = assembler.config
    #expect(Self.mustFail { try assembler.dropKey(direction: .rear) })
    #expect(Self.mustFail { try assembler.dropKey(direction: .front) })
    let configBravo = assembler.config
    #expect(configAlpha == configBravo)
    #expect(Self.mustDone { try assembler.insertKey("ping2") })
    #expect(Self.mustDone { try assembler.dropKey(direction: .rear) })
    #expect(assembler.length == 0)
    #expect(Self.mustDone { try assembler.insertKey("ping2") })
    assembler.cursor = 0
    #expect(Self.mustDone { try assembler.dropKey(direction: .front) })
    #expect(assembler.length == 0)
  }

  /// 測試任何長度大於 1 的幅位。
  @Test("[Homa] Assembler_SpansAcrossPositions")
  func testSpansAcrossPositions() async throws {
    let assembler = Self.makeAssemblerUsingMockLM()
    try assembler.insertKey("h")
    try assembler.insertKey("o")
    try assembler.insertKey("g")
    #expect((assembler.cursor, assembler.length) == (3, 3))
    #expect((assembler.spans.count) == 3)
    #expect(assembler.spans[0].maxLength == 3)
    #expect(assembler.spans[0][1]?.keyArray == ["h"])
    #expect(assembler.spans[0][2]?.keyArray == ["h", "o"])
    #expect(assembler.spans[0][3]?.keyArray == ["h", "o", "g"])
    #expect(assembler.spans[1].maxLength == 2)
    #expect(assembler.spans[1][1]?.keyArray == ["o"])
    #expect(assembler.spans[1][2]?.keyArray == ["o", "g"])
    #expect(assembler.spans[2].maxLength == 1)
    #expect(assembler.spans[2][1]?.keyArray == ["g"])
  }

  /// 測試對讀音鍵與幅位的刪除行為。
  ///
  /// 敝專案不使用石磬軟體及其成員們所使用的「前 (Before) / 後 (After)」術語體系，
  /// 而是採用「前方 (Front) / 後方 (Rear)」這種中英文表述都不產生歧義的講法。
  @Test("[Homa] Assembler_KeyAndSpanDeletionInAllDirections")
  func testKeyAndSpanDeletionInAllDirections() async throws {
    let assembler = Self.makeAssemblerUsingMockLM()
    // 測試對讀音鍵的刪除行為（對兩個方向都測試）。
    try assembler.insertKey("a")
    assembler.cursor = 0
    #expect((assembler.cursor, assembler.length) == (0, 1))
    #expect(assembler.spans.count == 1)
    #expect(Self.mustFail { try assembler.dropKey(direction: .rear) })
    #expect((assembler.cursor, assembler.length) == (0, 1))
    #expect(assembler.spans.count == 1)
    #expect(Self.mustDone { try assembler.dropKey(direction: .front) })
    #expect((assembler.cursor, assembler.length) == (0, 0))
    #expect(assembler.spans.isEmpty)

    func resetAssemblerForTests() throws {
      assembler.clear()
      try assembler.insertKey("h")
      try assembler.insertKey("o")
      try assembler.insertKey("g")
    }

    // 測試對幅位的刪除行為所產生的影響（從最前端開始往後方刪除）。
    do {
      try resetAssemblerForTests()
      assembler.cursor = assembler.length // 這句跑不跑其實都一樣。
      #expect(Self.mustFail { try assembler.dropKey(direction: .front) }) // 必敗
      #expect(Self.mustDone { try assembler.dropKey(direction: .rear) }) // 成功
      #expect((assembler.cursor, assembler.length) == (2, 2))
      #expect((assembler.spans.count) == 2)
      #expect(assembler.spans[0].maxLength == 2)
      #expect(assembler.spans[0][1]?.keyArray == ["h"])
      #expect(assembler.spans[0][2]?.keyArray == ["h", "o"])
      #expect(assembler.spans[1].maxLength == 1)
      #expect(assembler.spans[1][1]?.keyArray == ["o"])
    }

    // 測試對幅位的刪除行為所產生的影響（從最後端開始往前方刪除）。
    do {
      try resetAssemblerForTests()
      assembler.cursor = 0
      #expect(Self.mustFail { try assembler.dropKey(direction: .rear) }) // 必敗
      #expect(Self.mustDone { try assembler.dropKey(direction: .front) }) // 成功
      #expect((assembler.cursor, assembler.length) == (0, 2))
      #expect((assembler.spans.count) == 2)
      #expect(assembler.spans[0].maxLength == 2)
      #expect(assembler.spans[0][1]?.keyArray == ["o"])
      #expect(assembler.spans[0][2]?.keyArray == ["o", "g"])
      #expect(assembler.spans[1].maxLength == 1)
      #expect(assembler.spans[1][1]?.keyArray == ["g"])
    }

    // 測試對幅位的刪除行為所產生的影響（從中間開始往後方刪除）。
    do {
      try resetAssemblerForTests()
      assembler.cursor = 2
      #expect(Self.mustDone { try assembler.dropKey(direction: .rear) })
      #expect((assembler.cursor, assembler.length) == (1, 2))
      #expect((assembler.spans.count) == 2)
      #expect(assembler.spans[0].maxLength == 2)
      #expect(assembler.spans[0][1]?.keyArray == ["h"])
      #expect(assembler.spans[0][2]?.keyArray == ["h", "g"])
      #expect(assembler.spans[1].maxLength == 1)
      #expect(assembler.spans[1][1]?.keyArray == ["g"])
    }

    // 測試對幅位的刪除行為所產生的影響（從中間開始往前方刪除）。
    do {
      let snapshot = assembler.config
      try resetAssemblerForTests()
      assembler.cursor = 1
      #expect(Self.mustDone { try assembler.dropKey(direction: .front) })
      #expect((assembler.cursor, assembler.length) == (1, 2))
      #expect((assembler.spans.count) == 2)
      #expect(assembler.spans[0].maxLength == 2)
      #expect(assembler.spans[0][1]?.keyArray == ["h"])
      #expect(assembler.spans[0][2]?.keyArray == ["h", "g"])
      #expect(assembler.spans[1].maxLength == 1)
      #expect(assembler.spans[1][1]?.keyArray == ["g"])
      #expect(snapshot == assembler.config)
    }
  }

  /// 測試在插入某個幅位之後、對其他幅位的影響。
  @Test("[Homa] Assembler_SpanInsertion")
  func testSpanInsertion() async throws {
    let assembler = Self.makeAssemblerUsingMockLM()
    try assembler.insertKey("是")
    try assembler.insertKey("學")
    try assembler.insertKey("生")
    assembler.cursor = 1
    try assembler.insertKey("大")
    #expect((assembler.cursor, assembler.length) == (2, 4))
    #expect(assembler.spans.count == 4)
    #expect(assembler.spans[0].maxLength == 4)
    #expect(assembler.spans[0][1]?.keyArray == ["是"])
    #expect(assembler.spans[0][2]?.keyArray == ["是", "大"])
    #expect(assembler.spans[0][3]?.keyArray == ["是", "大", "學"])
    #expect(assembler.spans[0][4]?.keyArray == ["是", "大", "學", "生"])
    #expect(assembler.spans[1].maxLength == 3)
    #expect(assembler.spans[1][1]?.keyArray == ["大"])
    #expect(assembler.spans[1][2]?.keyArray == ["大", "學"])
    #expect(assembler.spans[1][3]?.keyArray == ["大", "學", "生"])
    #expect(assembler.spans[2].maxLength == 2)
    #expect(assembler.spans[2][1]?.keyArray == ["學"])
    #expect(assembler.spans[2][2]?.keyArray == ["學", "生"])
    #expect(assembler.spans[3].maxLength == 1)
    #expect(assembler.spans[3][1]?.keyArray == ["生"])
  }

  /// 測試在一個很長的組字區內在中间刪除掉或者添入某個讀音鍵之後的影響。
  @Test("[Homa] Assembler_LongGridDeletionAndInsertion")
  func testLongGridDeletionAndInsertion() async throws {
    let assembler = Self.makeAssemblerUsingMockLM()
    try "無可奈何花作香幽蝶能留一縷芳".forEach {
      try assembler.insertKey($0.description)
    }
    do {
      assembler.cursor = 8
      #expect(Self.mustDone { try assembler.dropKey(direction: .rear) })
      #expect((assembler.cursor, assembler.length) == (7, 13))
      #expect(assembler.spans.count == 13)
      #expect(assembler.spans[0][5]?.keyArray.joined() == "無可奈何花")
      #expect(assembler.spans[1][5]?.keyArray.joined() == "可奈何花作")
      #expect(assembler.spans[2][5]?.keyArray.joined() == "奈何花作香")
      #expect(assembler.spans[3][5]?.keyArray.joined() == "何花作香蝶")
      #expect(assembler.spans[4][5]?.keyArray.joined() == "花作香蝶能")
      #expect(assembler.spans[5][5]?.keyArray.joined() == "作香蝶能留")
      #expect(assembler.spans[6][5]?.keyArray.joined() == "香蝶能留一")
      #expect(assembler.spans[7][5]?.keyArray.joined() == "蝶能留一縷")
      #expect(assembler.spans[8][5]?.keyArray.joined() == "能留一縷芳")
    }
    do {
      #expect(Self.mustDone { try assembler.insertKey("幽") })
      #expect((assembler.cursor, assembler.length) == (8, 14))
      #expect(assembler.spans.count == 14)
      #expect(assembler.spans[0][6]?.keyArray.joined() == "無可奈何花作")
      #expect(assembler.spans[1][6]?.keyArray.joined() == "可奈何花作香")
      #expect(assembler.spans[2][6]?.keyArray.joined() == "奈何花作香幽")
      #expect(assembler.spans[3][6]?.keyArray.joined() == "何花作香幽蝶")
      #expect(assembler.spans[4][6]?.keyArray.joined() == "花作香幽蝶能")
      #expect(assembler.spans[5][6]?.keyArray.joined() == "作香幽蝶能留")
      #expect(assembler.spans[6][6]?.keyArray.joined() == "香幽蝶能留一")
      #expect(assembler.spans[7][6]?.keyArray.joined() == "幽蝶能留一縷")
      #expect(assembler.spans[8][6]?.keyArray.joined() == "蝶能留一縷芳")
    }
  }
}
