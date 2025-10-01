// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// 下述測試內容有通過，但效能問題堪憂，已經停用且封存在此。該效能問題出在 SQLTrie 的 Constructor 上。
//
// extension FactoryTrieDBType {
//   func getFactorySQLDemoFileContent4Tests() -> String {
//     let url = Bundle.module.url(forResource: sqlFileNameStem, withExtension: "sql")
//     guard let url else { return "" }
//     return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
//   }
//
//   internal static let headerFileNameStem = "FactoryDemoDictSharedHeader"
//   internal static let footerFileNameStem = "FactoryDemoDictSharedFooter"
// }
//
// public struct LexiconTestsDeprecated {
//   @Test("[LexiconKit] Access_Bundled_Data_For_Tests", arguments: FactoryTrieDBType.allCases)
//   func testBundleDataAccessForUnitTests(type currentCase: FactoryTrieDBType) throws {
//     let sqlFileContent = currentCase.getFactorySQLDemoFileContent4Tests()
//     #expect(!sqlFileContent.isEmpty)
//     let trie = VanguardTrie.SQLTrie(sqlContent: sqlFileContent)
//     #expect(trie != nil)
//   }
//
//   @Test("[LexiconKit] TrieHub_Construction_FromSQLContentString")
//   func testTrieHubConstructionFromSQLContentString() throws {
//     let hub = VanguardTrie.TrieHub()
//     hub.updateTrieFromSQLScript {
//       var resultMap4FilePaths: [FactoryTrieDBType: String] = [:]
//       FactoryTrieDBType.allCases.forEach { currentCase in
//         let sqlFilePath = currentCase.getFactorySQLDemoFileContent4Tests()
//         resultMap4FilePaths[currentCase] = sqlFilePath
//       }
//       return resultMap4FilePaths
//     }
//     #expect(hub.sqlTrieMap.count == FactoryTrieDBType.allCases.count)
//     #expect(hub.hasGrams(["ㄧㄡ"], filterType: .chs))
//     let revLookupResultYou = hub.queryGrams(["ㄧㄡ"], filterType: .chs).first
//     #expect(revLookupResultYou?.keyArray.first == VanguardTrie.encryptReadingKey("ㄧㄡ"))
//     #expect(hub.hasGrams(["⾡"], filterType: .revLookup))
//     let revLookupResultChuo4 = hub.queryGrams(["⾡"], filterType: .revLookup).first
//     #expect(revLookupResultChuo4?.value == VanguardTrie.encryptReadingKey("ㄔㄨㄛˋ"))
//   }
// }
