// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Homa
import Testing
@testable import TrieKit

// MARK: - TrieKitTestsSQL

@Suite(.serialized)
public struct TrieKitTests: TrieKitTestSuite {
  // MARK: Internal

  // 這裡重複對護摩引擎的胡桃測試（Full Match）。
  @Test("[TrieKit] Trie SQL Structure Test (Full Match)", arguments: [false, true])
  func testTrieSQLStructureWithFullMatch(useSQL: Bool) async throws {
    let mockLM = try await prepareTrieLM(useSQL: useSQL)
    let readings: [Substring] = "you1 die2 neng2 liu2 yi4 lv3 fang1".split(separator: " ")
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

  // 這裡重複對護摩引擎的胡桃測試（Partial Match）。
  @Test("[TrieKit] Trie SQL Structure Test (Partial Match)", arguments: [false, true])
  func testTrieSQLStructureWithPartialMatch(useSQL: Bool) async throws {
    let mockLM = try await prepareTrieLM(useSQL: useSQL)
    #expect(mockLM.hasGrams(["y"], partiallyMatch: true))
    #expect(!mockLM.queryGrams(["y"], partiallyMatch: true).isEmpty)
    let readings: [String] = "ydnlylf".map(\.description)
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
  }

  // MARK: Private

  private func prepareTrieLM(useSQL: Bool) async throws -> TestLM4Trie {
    // 先測試物件創建。
    let trie = VanguardTrie.Trie(separator: "-")
    strLMSampleDataHutao.enumerateLines { line, _ in
      let components = line.split(whereSeparator: \.isWhitespace)
      guard components.count >= 3 else { return }
      let value = String(components[1])
      guard let probability = Double(components[2].description) else { return }
      let previous = components.count > 3 ? String(components[3]) : nil
      let readings: [String] = components[0].split(
        separator: trie.readingSeparator
      ).map(\.description)
      let entry = VanguardTrie.Trie.Entry(
        readings: readings,
        value: value,
        typeID: .langNeutral,
        probability: probability,
        previous: previous
      )
      let key = readings.joined(separator: trie.readingSeparator)
      trie.insert(key, entry: entry)
    }
    let trieFinal: VanguardTrieProtocol
    switch useSQL {
    case false:
      let encoded = try VanguardTrie.TrieIO.serialize(trie)
      trieFinal = try VanguardTrie.TrieIO.deserialize(encoded)
    case true:
      let sqlScript = VanguardTrie.TrieSQLScriptGenerator.generateSQLScript(trie)
      let sqlTrie = VanguardTrie.SQLTrie(sqlContent: sqlScript)
      guard let sqlTrie else {
        assertionFailure("SQLTrie initialization failed.")
        exit(1)
      }
      trieFinal = sqlTrie
      #expect(sqlTrie.getTableRowCount("entries") ?? 0 > 0)
      #expect(sqlTrie.getTableRowCount("config") ?? 0 > 0)
      #expect(sqlTrie.getTableRowCount("nodes") ?? 0 > 0)
      #expect(sqlTrie.getTableRowCount("reading_mappings") ?? 0 > 0)
      #expect(sqlTrie.getTableRowCount("keychain_id_map") ?? 0 > 0)
    }
    let mockLM = TestLM4Trie(trie: trieFinal)
    #expect(trieFinal.hasGrams(["yi4", "lv3"], filterType: .langNeutral))
    #expect(!mockLM.queryGrams(["yi4", "lv3"]).isEmpty)
    return mockLM
  }
}
