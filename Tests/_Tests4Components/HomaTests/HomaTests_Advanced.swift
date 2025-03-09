// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

@testable import Homa
import Testing

// MARK: - HomaTestsAdvanced

@Suite(.serialized)
public struct HomaTestsAdvanced: HomaTestSuite {
  /// 組字器的分詞功能測試，同時測試組字器的硬拷貝功能。
  @Test("[Homa] Assember_HardCopyAndWordSegmentation")
  func testHardCopyAndWordSegmentation() async throws {
    let regexToFilter = try Regex(".* 能留 .*\n")
    let mockLM = TestLM(
      rawData: strLMSampleDataHutao.replacing(regexToFilter, with: ""),
      readingSeparator: "",
      valueSegmentationOnly: true
    )
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) },
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )
    try "幽蝶能留一縷芳".forEach { i in
      try assembler.insertKey(i.description)
    }
    let result = assembler.assemble()
    #expect(result.joinedKeys(by: "") == ["幽蝶", "能", "留", "一縷", "芳"])
    let hardCopy = assembler.copy
    #expect(hardCopy.config == assembler.config)
  }

  /// 組字器的組字壓力測試。
  @Test("[Homa] Assember_StressBench")
  func testStressBenchOnAssemblingSentences() async throws {
    print("// Stress test preparation begins.")
    let mockLM = TestLM(rawData: strLMStressData)
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) },
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )
    try (0 ..< 512).forEach { _ in
      try assembler.insertKey("sheng1")
    }
    print("// Stress test started.")
    let timeElapsed = Self.measureTime {
      assembler.assemble()
    }
    print("// Stress test elapsed: \(timeElapsed)s.")
  }

  @Test("[Homa] Assembler_UpdateUnigramDataForAllNodes")
  func testUpdateUnigramDataForAllNodes() async throws {
    let readings: [Substring] = "shu4 xin1 feng1".split(separator: " ")
    let newRawStringLM = strLMSampleDataEmoji + "\nshu4-xin1-feng1 樹新風 -9"
    let regexToFilter = try Regex(".*(樹|新|風) .*")
    let mockLMWithFilter = TestLM(
      rawData: newRawStringLM.replacing(regexToFilter, with: "")
    )
    let mockLM = TestLM(
      rawData: newRawStringLM
    )
    let assembler = Homa.Assembler(
      gramQuerier: { mockLMWithFilter.queryGrams($0) }, // 會回傳包含 Bigram 的結果。
      gramAvailabilityChecker: { mockLMWithFilter.hasGrams($0) }
    )
    try readings.forEach {
      try assembler.insertKey($0.description)
    }
    var assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["樹心", "封"])
    // 先置換語言模型 API 再更新所有節點的 Unigram 資料。
    assembler.gramQuerier = { mockLM.queryGrams($0) }
    assembler.gramAvailabilityChecker = { mockLM.hasGrams($0) }
    try assembler.assignNodes(updateExisting: true)
    assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["樹新風"])
  }

  /// `fetchCandidatesDeprecated` 這個方法在極端情況下（比如兩個連續讀音，等）會有故障，現已棄用。
  /// 目前這筆測試並不能曝露這個函式的問題，但卻能用來輔助測試其**繼任者**是否能完成一致的正確工作。
  @Test("[Homa] Assembler_VerifyCandidateFetchResultsWithNewAPI")
  func testVerifyCandidateFetchResultsWithNewAPI() async throws {
    let readings = "da4 qian2 tian1 zai5 ke1 ji4 gong1 yuan2 chao1 shang1"
    let mockLM = TestLM(
      rawData: strLMSampleDataTechGuarden + "\n" + strLMSampleDataLitch
    )
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) },
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )
    try readings.split(separator: " ").forEach {
      try assembler.insertKey($0.description)
    }
    // 初始爬軌結果。
    let assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["大前天", "在", "科技", "公園", "超商"])
    var stack1A = [String]()
    var stack1B = [String]()
    var stack2A = [String]()
    var stack2B = [String]()
    for i in 0 ... assembler.keys.count {
      stack1A
        .append(
          assembler.fetchCandidates(at: i, filter: .beginAt).map(\.pair.value)
            .joined(separator: "-")
        )
      stack1B
        .append(
          assembler.fetchCandidates(at: i, filter: .endAt).map(\.pair.value)
            .joined(separator: "-")
        )
      stack2A
        .append(
          assembler.fetchCandidatesDeprecated(at: i, filter: .beginAt).map(\.pair.value)
            .joined(separator: "-")
        )
      stack2B
        .append(
          assembler.fetchCandidatesDeprecated(at: i, filter: .endAt).map(\.pair.value)
            .joined(separator: "-")
        )
    }
    stack1B.removeFirst()
    stack2B.removeLast()
    #expect(stack1A == stack2A)
    #expect(stack1B == stack2B)
  }

  /// 測試是否有效隔絕橫跨游標位置的候選字詞。
  ///
  /// 「選字窗內出現橫跨游標的候選字」的故障會破壞使用體驗，得防止發生。
  /// （微軟新注音沒有這個故障，macOS 內建的注音也沒有。）
  @Test("[Homa] Assember_FilteringOutCandidatesAcrossingTheCursor")
  func testFilteringOutCandidatesAcrossingTheCursor() async throws {
    // 一號測試。
    do {
      let readings: [Substring] = "ke1 ji4 gong1 yuan2".split(separator: " ")
      let mockLM = TestLM(rawData: strLMSampleDataTechGuarden)
      let assembler = Homa.Assembler(
        gramQuerier: { mockLM.queryGrams($0) },
        gramAvailabilityChecker: { mockLM.hasGrams($0) }
      )
      try readings.forEach {
        try assembler.insertKey($0.description)
      }
      // 初始爬軌結果。
      let assembledSentence = assembler.assemble().compactMap(\.value)
      #expect(assembledSentence == ["科技", "公園"])
      // 測試候選字詞過濾。
      let gotBeginAt = assembler.fetchCandidates(at: 2, filter: .beginAt).map(\.pair.value)
      let gotEndAt = assembler.fetchCandidates(at: 2, filter: .endAt).map(\.pair.value)
      #expect(!gotBeginAt.contains("濟公"))
      #expect(gotBeginAt.contains("公園"))
      #expect(!gotEndAt.contains("公園"))
      #expect(gotEndAt.contains("科技"))
    }
    // 二號測試。
    do {
      let readings: [Substring] = "sheng1 sheng1".split(separator: " ")
      let mockLM = TestLM(rawData: strLMStressData + "\n" + strLMSampleDataHutao)
      let assembler = Homa.Assembler(
        gramQuerier: { mockLM.queryGrams($0) },
        gramAvailabilityChecker: { mockLM.hasGrams($0) }
      )
      try readings.forEach {
        try assembler.insertKey($0.description)
      }
      var a = assembler.fetchCandidates(at: 1, filter: .beginAt)
        .map(\.pair.keyArray.count).max() ?? 0
      var b = assembler.fetchCandidates(at: 1, filter: .endAt)
        .map(\.pair.keyArray.count).max() ?? 0
      var c = assembler.fetchCandidates(at: 0, filter: .beginAt)
        .map(\.pair.keyArray.count).max() ?? 0
      var d = assembler.fetchCandidates(at: 2, filter: .endAt)
        .map(\.pair.keyArray.count).max() ?? 0
      #expect("\(a) \(b) \(c) \(d)" == "1 1 2 2")
      assembler.cursor = assembler.length
      try assembler.insertKey("fang1")
      a = assembler.fetchCandidates(at: 1, filter: .beginAt)
        .map(\.pair.keyArray.count).max() ?? 0
      b = assembler.fetchCandidates(at: 1, filter: .endAt)
        .map(\.pair.keyArray.count).max() ?? 0
      c = assembler.fetchCandidates(at: 0, filter: .beginAt)
        .map(\.pair.keyArray.count).max() ?? 0
      d = assembler.fetchCandidates(at: 2, filter: .endAt)
        .map(\.pair.keyArray.count).max() ?? 0
      #expect("\(a) \(b) \(c) \(d)" == "1 1 2 2")
    }
  }

  /// 組字器的組字功能測試（單元圖，完整輸入讀音與聲調，完全匹配）。
  @Test("[Homa] Assember_AssembleAndOverride_WithUnigramAndCursorJump")
  func testAssembleAndOverrideWithUnigramAndCursorJump() async throws {
    let readings = "chao1 shang1 da4 qian2 tian1 wei2 zhi3 hai2 zai5 mai4 nai3 ji1"
    let mockLM = TestLM(rawData: strLMSampleDataLitch)
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) },
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )
    try readings.split(separator: " ").forEach {
      try assembler.insertKey($0.description)
    }
    #expect(assembler.length == 12)
    #expect(assembler.length == assembler.cursor)
    // 初始爬軌結果。
    var assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["超商", "大前天", "為止", "還", "在", "賣", "荔枝"])
    // 測試 DumpDOT。
    let expectedDumpDOT = """
    digraph {\ngraph [ rankdir=TB ];\nBOS;\nBOS -> 超;\n超;\n超 -> 傷;\n\
    BOS -> 超商;\n超商;\n超商 -> 大;\n超商 -> 大錢;\n超商 -> 大前天;\n傷;\n\
    傷 -> 大;\n傷 -> 大錢;\n傷 -> 大前天;\n大;\n大 -> 前;\n大 -> 前天;\n大錢;\n\
    大錢 -> 添;\n大前天;\n大前天 -> 為;\n大前天 -> 為止;\n前;\n前 -> 添;\n前天;\n\
    前天 -> 為;\n前天 -> 為止;\n添;\n添 -> 為;\n添 -> 為止;\n為;\n為 -> 指;\n\
    為止;\n為止 -> 還;\n指;\n指 -> 還;\n還;\n還 -> 在;\n在;\n在 -> 賣;\n賣;\n\
    賣 -> 乃;\n賣 -> 荔枝;\n乃;\n乃 -> 雞;\n荔枝;\n荔枝 -> EOS;\n雞;\n雞 -> EOS;\nEOS;\n}\n
    """
    let actualDumpDOT = assembler.dumpDOT(verticalGraph: true)
    #expect(actualDumpDOT == expectedDumpDOT)
    // 單獨測試對最前方的讀音的覆寫。
    do {
      let assemberCopy1 = assembler.copy
      try assemberCopy1.overrideCandidate((keyArray: ["ji1"], value: "雞"), at: 11)
      assembledSentence = assemberCopy1.assemble().compactMap(\.value)
      #expect(assembledSentence == ["超商", "大前天", "為止", "還", "在", "賣", "乃", "雞"])
    }
    // 回到先前的測試，測試對整個詞的覆寫。
    try assembler.overrideCandidate((keyArray: ["nai3", "ji1"], value: "奶雞"), at: 10)
    assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["超商", "大前天", "為止", "還", "在", "賣", "奶雞"])
    // 測試游標跳轉。
    assembler.cursor = 10 // 向後
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .rear) })
    #expect(assembler.cursor == 9)
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .rear) })
    #expect(assembler.cursor == 8)
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .rear) })
    #expect(assembler.cursor == 7)
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .rear) })
    #expect(assembler.cursor == 5)
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .rear) })
    #expect(assembler.cursor == 2)
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .rear) })
    #expect(assembler.cursor == 0)
    #expect(Self.mustFail { try assembler.jumpCursorBySpan(to: .rear) })
    #expect(assembler.cursor == 0) // 接下來準備向前
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .front) })
    #expect(assembler.cursor == 2)
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .front) })
    #expect(assembler.cursor == 5)
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .front) })
    #expect(assembler.cursor == 7)
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .front) })
    #expect(assembler.cursor == 8)
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .front) })
    #expect(assembler.cursor == 9)
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .front) })
    #expect(assembler.cursor == 10)
    #expect(Self.mustDone { try assembler.jumpCursorBySpan(to: .front) })
    #expect(assembler.cursor == 12)
    #expect(Self.mustFail { try assembler.jumpCursorBySpan(to: .front) })
    #expect(assembler.cursor == 12)
  }

  /// 組字器的組字功能測試（雙元圖，完整輸入讀音與聲調，完全匹配）。
  ///
  /// 這個測試包含了：
  /// - 讀音輸入處理。
  /// - 組字器的基本組句功能。
  /// - 候選字詞覆寫功能。
  /// - 在有雙元圖（Bigram）與僅有單元圖（Unigram）的情況下的爬軌結果對比測試。
  @Test("[Homa] Assember_AssembleAndOverride_FullMatch_WithBigram")
  func testAssembleWithBigramAndOverrideWithFullMatch() async throws {
    let readings: [Substring] = "you1 die2 neng2 liu2 yi4 lv3 fang1".split(separator: " ")
    let mockLM = TestLM(rawData: strLMSampleDataHutao)
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) }, // 會回傳包含 Bigram 的結果。
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )
    try readings.forEach {
      try assembler.insertKey($0.description)
    }
    // 初始爬軌結果。
    var assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["幽蝶", "能", "留意", "呂方"])
    // 測試覆寫「留」以試圖打斷「留意」。
    try assembler.overrideCandidate(
      (["liu2"], "留"), at: 3, type: .withSpecified
    )
    // 測試覆寫「一縷」以打斷「留意」與「呂方」。這也便於最後一個位置的 Bigram 測試。
    // （因為是有了「一縷」這個前提才會去找對應的 Bigram。）
    try assembler.overrideCandidate(
      (["yi4", "lv3"], "一縷"), at: 4, type: .withSpecified
    )
    let dotWithBigram = assembler.dumpDOT(verticalGraph: true)
    assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["幽蝶", "能", "留", "一縷", "芳"])
    // 剛才測試 Bigram 生效了。現在禁用 Bigram 試試看。先攔截掉 Bigram 結果。
    assembler.gramQuerier = { mockLM.queryGrams($0).filter { $0.previous == nil } }
    try assembler.assignNodes(updateExisting: true) // 置換掉所有節點裡面的資料。
    assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["幽蝶", "能", "留", "一縷", "方"])
    // 對位置 7 這個最前方的座標位置使用節點覆寫。會在此過程中自動糾正成對位置 6 的覆寫。
    try assembler.overrideCandidate(
      (["fang1"], "芳"), at: 7, type: .withSpecified
    )
    assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["幽蝶", "能", "留", "一縷", "芳"])
    let dotSansBigram = assembler.dumpDOT(verticalGraph: true)
    // 驗證兩次 dumpDOT 結果是否雷同。
    #expect(dotWithBigram == dotSansBigram)
    let expectedDOT = """
    digraph {\ngraph [ rankdir=TB ];\nBOS;\nBOS -> 優;\n優;\n優 -> 跌;\nBOS -> 幽蝶;\n\
    幽蝶;\n幽蝶 -> 能;\n幽蝶 -> 能留;\n跌;\n跌 -> 能;\n跌 -> 能留;\n能;\n能 -> 留;\n\
    能 -> 留意;\n能留;\n能留 -> 亦;\n能留 -> 一縷;\n留;\n留 -> 亦;\n留 -> 一縷;\n留意;\n\
    留意 -> 旅;\n留意 -> 呂方;\n亦;\n亦 -> 旅;\n亦 -> 呂方;\n一縷;\n一縷 -> 芳;\n旅;\n\
    旅 -> 芳;\n呂方;\n呂方 -> EOS;\n芳;\n芳 -> EOS;\nEOS;\n}\n
    """
    #expect(dotWithBigram == expectedDOT)
  }

  /// 組字器的組字功能測試（雙元圖，不完整輸入讀音與聲調，類似華碩輸入法、智能狂拼、RIME、搜狗的輸入風格）。
  ///
  /// 這個測試包含了：
  /// - 讀音輸入處理。
  /// - 組字器的基本組句功能。
  /// - 候選字詞覆寫功能。
  @Test("[Homa] Assember_AssembleAndOverride_PartialMatch_WithBigram")
  func testAssembleWithBigramAndOverrideWithPartialMatch() async throws {
    let readings: [String] = "ydnlylf".map(\.description)
    let mockLM = TestLM(rawData: strLMSampleDataHutao)
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0, partiallyMatch: true) }, // 會回傳包含 Bigram 的結果。
      gramAvailabilityChecker: { mockLM.hasGrams($0, partiallyMatch: true) }
    )
    try readings.forEach {
      try assembler.insertKey($0.description)
    }
    var assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["幽蝶", "能", "留意", "呂方"])
    // 測試覆寫「留」以試圖打斷「留意」。
    try assembler.overrideCandidate(
      (["liu2"], "留"), at: 3, type: .withSpecified
    )
    // 測試覆寫「一縷」以打斷「留意」與「呂方」。這也便於最後一個位置的 Bigram 測試。
    // （因為是有了「一縷」這個前提才會去找對應的 Bigram。）
    try assembler.overrideCandidate(
      (["yi4", "lv3"], "一縷"), at: 4, type: .withSpecified
    )
    assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["幽蝶", "能", "留", "一縷", "芳"])
    let actualkeysJoined = assembler.actualKeys.joined(separator: " ")
    #expect(actualkeysJoined == "you1 die2 neng2 liu2 yi4 lv3 fang1")
  }

  /// 針對完全覆蓋的節點的專項覆寫測試。
  @Test("[Homa] Assember_ResetFullyOverlappedNodesOnOverride")
  func testResettingFullyOverlappedNodesOnOverride() async throws {
    let readings: [Substring] = "shui3 guo3 zhi1".split(separator: " ")
    let mockLM = TestLM(rawData: strLMSampleDataFruitJuice)
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) }, // 會回傳包含 Bigram 的結果。
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )
    try readings.forEach {
      try assembler.insertKey($0.description)
    }
    var assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["水果汁"])

    // 測試針對第一個漢字的位置的操作。
    do {
      do {
        #expect(Self.mustDone {
          try assembler.overrideCandidate((keyArray: ["shui3"], value: "💦"), at: 0)
        })
        assembledSentence = assembler.assemble().compactMap(\.value)
        #expect(assembledSentence == ["💦", "果汁"])
      }
      do {
        #expect(Self.mustDone {
          try assembler.overrideCandidate(
            (keyArray: ["shui3", "guo3", "zhi1"], value: "水果汁"), at: 1
          )
        })
        assembledSentence = assembler.assemble().compactMap(\.value)
        #expect(assembledSentence == ["水果汁"])
      }
      do {
        #expect(Self.mustDone {
          // 再覆寫回來。
          try assembler.overrideCandidate((keyArray: ["shui3"], value: "💦"), at: 0)
        })
        assembledSentence = assembler.assemble().compactMap(\.value)
        #expect(assembledSentence == ["💦", "果汁"])
      }
    }

    // 測試針對其他位置的操作。
    do {
      do {
        #expect(Self.mustDone {
          try assembler.overrideCandidate((keyArray: ["guo3"], value: "裹"), at: 1)
        })
        assembledSentence = assembler.assemble().compactMap(\.value)
        #expect(assembledSentence == ["💦", "裹", "之"])
      }
      do {
        #expect(Self.mustDone {
          try assembler.overrideCandidate((keyArray: ["zhi1"], value: "知"), at: 2)
        })
        assembledSentence = assembler.assemble().compactMap(\.value)
        #expect(assembledSentence == ["💦", "裹", "知"])
      }
      do {
        #expect(Self.mustDone {
          // 再覆寫回來。
          try assembler.overrideCandidate(
            (keyArray: ["shui3", "guo3", "zhi1"], value: "水果汁"), at: 3
          )
        })
        assembledSentence = assembler.assemble().compactMap(\.value)
        #expect(assembledSentence == ["水果汁"])
      }
    }
  }

  /// 針對不完全覆蓋的節點的專項覆寫測試。
  @Test("[Homa] Assember_ResetPartiallyOverlappedNodesOnOverride")
  func testResettingPartiallyOverlappedNodesOnOverride() async throws {
    let readings: [Substring] = "ke1 ji4 gong1 yuan2".split(separator: " ")
    let mockLM = TestLM(rawData: strLMSampleDataTechGuarden + "\ngong1-yuan2 公猿 -9")
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) }, // 會回傳包含 Bigram 的結果。
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )
    try readings.forEach {
      try assembler.insertKey($0.description)
    }
    var assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["科技", "公園"])
    do {
      #expect(Self.mustDone {
        try assembler.overrideCandidate(
          (keyArray: ["ji4", "gong1"], value: "濟公"), at: 1
        )
      })
      assembledSentence = assembler.assemble().compactMap(\.value)
      #expect(assembledSentence == ["顆", "濟公", "元"])
    }
    do {
      #expect(Self.mustDone {
        try assembler.overrideCandidate(
          (keyArray: ["gong1", "yuan2"], value: "公猿"), at: 2
        )
      })
      assembledSentence = assembler.assemble().compactMap(\.value)
      #expect(assembledSentence == ["科技", "公猿"]) // 「技工」被重設。
    }
    do {
      #expect(Self.mustDone {
        try assembler.overrideCandidate(
          (keyArray: ["ke1", "ji4"], value: "科際"), at: 0
        )
      })
      assembledSentence = assembler.assemble().compactMap(\.value)
      #expect(assembledSentence == ["科際", "公猿"]) // 「公猿」沒有受到影響。
    }
  }

  @Test("[Homa] Assembler_CandidateDisambiguation")
  func testCandidateDisambiguation() async throws {
    let readings: [Substring] = "da4 shu4 xin1 de5 mi4 feng1".split(separator: " ")
    let regexToFilter = try Regex("\nshu4-xin1 .*")
    let mockLM = TestLM(
      rawData: strLMSampleDataEmoji.replacing(regexToFilter, with: "")
    )
    let assembler = Homa.Assembler(
      gramQuerier: { mockLM.queryGrams($0) }, // 會回傳包含 Bigram 的結果。
      gramAvailabilityChecker: { mockLM.hasGrams($0) }
    )
    try readings.forEach {
      try assembler.insertKey($0.description)
    }
    var assembledSentence = assembler.assemble().compactMap(\.value)
    #expect(assembledSentence == ["大樹", "新的", "蜜蜂"])
    let pos = 2
    do {
      #expect(Self.mustDone {
        try assembler.overrideCandidate((keyArray: ["xin1"], value: "🆕"), at: pos)
      })
      assembledSentence = assembler.assemble().compactMap(\.value)
      #expect(assembledSentence == ["大樹", "🆕", "的", "蜜蜂"])
    }
    do {
      #expect(Self.mustDone {
        try assembler.overrideCandidate((keyArray: ["xin1", "de5"], value: "🆕"), at: pos)
      })
      assembledSentence = assembler.assemble().compactMap(\.value)
      #expect(assembledSentence == ["大樹", "🆕", "蜜蜂"])
    }
  }
}
