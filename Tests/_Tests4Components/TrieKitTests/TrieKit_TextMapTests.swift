// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
import Testing
@testable import TrieKit

@Suite(.serialized)
struct TrieKitTextMapTests {
  @Test("[TrieKit] TYPING TextMap 3-column numeric value disambiguation")
  func testTypingTextMapThreeColumnNumericValueDisambiguation() throws {
    let textMap = """
    #PRAGMA:VANGUARD_HOMA_LEXICON_HEADER
    VERSION\t1
    TYPE\tTYPING
    READING_SEPARATOR\t-
    ENTRY_COUNT\t1
    KEY_COUNT\t1
    #PRAGMA:VANGUARD_HOMA_LEXICON_VALUES
    1\t-13\t8
    #PRAGMA:VANGUARD_HOMA_LEXICON_KEY_LINE_MAP
    foo\t0\t1
    """

    let trie = try VanguardTrie.TrieIO.deserializeFromTextMap(textMap)
    let entries = trie.nodes.values.first(where: { $0.readingKey == "foo" })?.entries ?? []
    let entry = try #require(entries.first)

    #expect(entries.count == 1)
    #expect(entry.value == "1")
    #expect(entry.typeID.rawValue == 8)
    #expect(entry.probability == -13)
  }

  @Test("[TrieKit] TextMap round-trip preserves escaped grouped values")
  func testTextMapRoundTripPreservesEscapedGroupedValues() throws {
    let trie = VanguardTrie.Trie(separator: "-")
    trie.insert(
      entry: .init(value: "A B", typeID: .init(rawValue: 4), probability: 0, previous: nil),
      readings: ["foo"]
    )
    trie.insert(
      entry: .init(value: "C|D", typeID: .init(rawValue: 4), probability: 0, previous: nil),
      readings: ["foo"]
    )

    let textMap = VanguardTrie.TrieIO.serializeToTextMap(trie)
    let roundTripped = try VanguardTrie.TrieIO.deserializeFromTextMap(textMap)
    let values = roundTripped.nodes.values.first(where: { $0.readingKey == "foo" })?
      .entries.map(\.value).sorted() ?? []

    #expect(values == ["A B", "C|D"])
  }

  @Test("[TrieKit] TYPING TextMap grouped line with marker and escapes")
  func testTypingTextMapGroupedLineWithMarkerAndEscapes() throws {
    let encodedChsCell = #"A\sB|C\|D"#
    let emptyGroupedCellPlaceholder = String(UnicodeScalar(7)!)
    let textMap = """
    #PRAGMA:VANGUARD_HOMA_LEXICON_HEADER
    VERSION\t1
    TYPE\tTYPING
    READING_SEPARATOR\t-
    ENTRY_COUNT\t1
    KEY_COUNT\t1
    #PRAGMA:VANGUARD_HOMA_LEXICON_VALUES
    @-5.307\t\(encodedChsCell)\t\(emptyGroupedCellPlaceholder)
    #PRAGMA:VANGUARD_HOMA_LEXICON_KEY_LINE_MAP
    foo\t0\t1
    """

    let trie = try VanguardTrie.TrieIO.deserializeFromTextMap(textMap)
    let entries = trie.nodes.values.first(where: { $0.readingKey == "foo" })?.entries ?? []
    let values = entries.map(\.value).sorted()

    #expect(entries.count == 2)
    #expect(values == ["A B", "C|D"])
    #expect(entries.allSatisfy { $0.typeID.rawValue == 5 })
    #expect(entries.allSatisfy { $0.probability == -5.307 })
  }

  @Test("[TrieKit] Legacy TYPING grouped line remains readable")
  func testLegacyTypingGroupedLineStillParses() throws {
    let textMap = """
    #PRAGMA:VANGUARD_HOMA_LEXICON_HEADER
    VERSION\t1
    TYPE\tTYPING
    READING_SEPARATOR\t-
    ENTRY_COUNT\t1
    KEY_COUNT\t1
    #PRAGMA:VANGUARD_HOMA_LEXICON_VALUES
    -9.465\t数 樹\t數
    #PRAGMA:VANGUARD_HOMA_LEXICON_KEY_LINE_MAP
    foo\t0\t1
    """

    let trie = try VanguardTrie.TrieIO.deserializeFromTextMap(textMap)
    let entries = trie.nodes.values.first(where: { $0.readingKey == "foo" })?.entries ?? []
    let chsValues = entries.filter { $0.typeID.rawValue == 5 }.map(\.value).sorted()
    let chtValues = entries.filter { $0.typeID.rawValue == 6 }.map(\.value).sorted()

    #expect(chsValues == ["数", "樹"])
    #expect(chtValues == ["數"])
  }
}
