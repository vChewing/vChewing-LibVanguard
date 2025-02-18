// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
@testable import Homa
import Testing

// MARK: - HomaTestSuite

protocol HomaTestSuite {}

extension HomaTestSuite {
  static func makeAssemblerUsingMockLM() -> Homa.Assembler {
    .init(
      gramQuerier: { keyArray in
        [
          Homa.Gram(
            keyArray: keyArray,
            current: keyArray.joined(separator: "-"),
            previous: nil,
            probability: -1
          ).asTuple,
        ]
      },
      gramAvailabilityChecker: {
        $0.reduce(0) { $1.isEmpty ? $0 : $0 + $1.count } != 0
      }
    )
  }

  static func mustDone(_ task: @escaping () throws -> ()) -> Bool {
    do {
      try task()
      return true
    } catch {
      return false
    }
  }

  static func mustFail(_ task: @escaping () throws -> ()) -> Bool {
    do {
      try task()
      return false
    } catch {
      return true
    }
  }

  static func measureTime(_ task: @escaping () -> ()) -> Double {
    let startTime = Date.now.timeIntervalSince1970
    task()
    return Date.now.timeIntervalSince1970 - startTime
  }
}

// MARK: - Assembler Extensions for Test Purposes Only.

extension Homa.Assembler {
  /// 該函式已被淘汰，因為有「仍有極端場合無法徹底清除 node-crossing 內容」的故障。
  /// 現僅用於單元測試、以確認其繼任者是否有給出所有該給出的正常結果。
  /// - Parameter location: 游標位置。
  /// - Returns: 候選字音配對陣列。
  public func fetchCandidatesDeprecated(
    at location: Int,
    filter: CandidateFetchFilter = .all
  )
    -> [Homa.CandidatePairWeighted] {
    var result = [Homa.CandidatePairWeighted]()
    guard !keys.isEmpty else { return result }
    let location = max(min(location, keys.count - 1), 0) // 防呆
    let anchors: [(location: Int, node: Homa.Node)] = fetchOverlappingNodes(at: location)
    let keyAtCursor = keys[location]
    anchors.map(\.node).forEach { theNode in
      theNode.grams.forEach { gram in
        switch filter {
        case .all:
          // 得加上這道篩選，不然會出現很多無效結果。
          if !theNode.keyArray.contains(keyAtCursor) { return }
        case .beginAt:
          if theNode.keyArray[0] != keyAtCursor { return }
        case .endAt:
          if theNode.keyArray.reversed()[0] != keyAtCursor { return }
        }
        result.append((
          pair: (keyArray: theNode.keyArray, value: gram.current),
          weight: gram.probability
        ))
      }
    }
    return result
  }
}

// MARK: - Dumping Unigrams from the Assembler.

extension Homa.Assembler {
  func dumpUnigrams() -> String {
    spans.map { currentSpan in
      currentSpan.values.map { currentNode in
        currentNode.grams.map { currentGram in
          let readingChain = currentGram.keyArray.joined(separator: "-")
          let value = currentGram.current
          let score = currentGram.probability
          return "\(readingChain) \(value) \(score)"
        }
        .joined(separator: "\n")
      }
      .joined(separator: "\n")
    }
    .joined(separator: "\n")
  }
}

// MARK: - HomaTests4MockLM

public struct HomaTests4MockLM {
  @Test("[Homa] MockedLanguageModel_(For Unit Tests)")
  func testMockLM() async throws {
    let mockLM = TestLM(rawData: strLMSampleDataHutao)
    let fangQueried = mockLM.queryGrams(["fang1"])
    #expect(fangQueried.count == 7)
    let firstBigramPreviousValue = fangQueried.compactMap(\.previous).first
    #expect(firstBigramPreviousValue == "一縷")
  }
}

// MARK: - Entry

private struct Entry: Codable, Hashable, Sendable {
  let readings: [String]
  let value: String
  let probability: Double
  let previous: String?

  var asTuple: (
    keyArray: [String],
    value: String,
    probability: Double,
    previous: String?
  ) {
    (
      keyArray: readings,
      value: value,
      probability: probability,
      previous: previous
    )
  }

  var isReadingAndValueMatched: Bool {
    readings.count == value.count
  }
}

// MARK: - TestLM

final class TestLM {
  // MARK: Lifecycle

  init(rawData: String, readingSeparator: String = "-", valueSegmentationOnly: Bool = false) {
    self.trie = Trie(separator: readingSeparator)
    rawData.split(whereSeparator: \.isNewline).forEach { line in
      let components = line.split(whereSeparator: \.isWhitespace)
      guard components.count >= 3 else { return }
      let value = String(components[1])
      guard let probability = Double(components[2].description) else { return }
      let previous = components.count > 3 ? String(components[3]) : nil
      let readings: [String] = valueSegmentationOnly
        ? value.map(\.description)
        : components[0].split(separator: readingSeparator).map(\.description)
      let entry = Entry(
        readings: readings,
        value: value,
        probability: probability,
        previous: previous
      )
      let key = readings.joined(separator: readingSeparator)
      trie.insert(key, entry: entry)
    }
  }

  // MARK: Internal

  var readingSeparator: String { trie.readingSeparator }

  func partiallyMatchKeys(_ keys: [String]) -> [[String]] {
    guard !keys.isEmpty else { return [] }
    let searchKey = keys.joined(separator: ".*?")
    let entries = trie.search(keys[0], partiallyMatch: true)

    return entries.compactMap { entry in
      let keyChain = entry.readings.joined(separator: readingSeparator)
      guard let regex = try? Regex("\(searchKey).*?"),
            keyChain.contains(regex),
            entry.readings.count == keys.count else { return nil }

      for (currentKey, currentReading) in zip(keys, entry.readings) {
        guard currentReading.hasPrefix(currentKey) else { return nil }
      }
      return entry.readings
    }
  }

  func hasGrams(
    _ keys: [String],
    partiallyMatch: Bool = false,
    partiallyMatchedKeysHandler: (([[String]]) -> ())? = nil
  )
    -> Bool {
    guard !keys.isEmpty else { return false }
    if partiallyMatch {
      let partiallyMatchedResult = partiallyMatchKeys(keys)
      partiallyMatchedKeysHandler?(partiallyMatchedResult)
      return !partiallyMatchedResult.isEmpty
    }
    return !trie.search(keys.joined(separator: readingSeparator)).isEmpty
  }

  func queryGrams(
    _ keys: [String],
    partiallyMatch: Bool = false,
    partiallyMatchedKeysPostHandler: (([[String]]) -> ())? = nil
  )
    -> [(keyArray: [String], value: String, probability: Double, previous: String?)] {
    guard !keys.isEmpty else { return [] }

    if partiallyMatch {
      let partiallyMatchedResult = partiallyMatchKeys(keys)
      defer { partiallyMatchedKeysPostHandler?(partiallyMatchedResult) }
      guard !partiallyMatchedResult.isEmpty else { return [] }

      return trie.search(keys[0], partiallyMatch: true)
        .filter { entry in
          entry.readings.count == keys.count &&
            zip(keys, entry.readings).allSatisfy { $1.hasPrefix($0) }
        }
        .map(\.asTuple)
    }

    return trie.search(keys.joined(separator: readingSeparator))
      .map(\.asTuple)
  }

  // MARK: Private

  private let trie: Trie
}

// MARK: - Trie

private class Trie {
  // MARK: Lifecycle

  init(separator: String) {
    self.readingSeparator = separator
  }

  // MARK: Internal

  class TNode {
    var children: [Character: TNode] = [:]
    var entries: [Entry] = []
  }

  let readingSeparator: String

  func insert(_ key: String, entry: Entry) {
    var node = root
    for char in key {
      if node.children[char] == nil {
        node.children[char] = TNode()
      }
      node = node.children[char]!
    }
    node.entries.append(entry)
  }

  func search(_ key: String, partiallyMatch: Bool = false) -> [Entry] {
    var node = root
    for char in key {
      guard let nextNode = node.children[char] else {
        return []
      }
      node = nextNode
    }
    return partiallyMatch ? collectAllEntries(from: node) : node.entries
  }

  // MARK: Private

  private let root = TNode()

  private func collectAllEntries(from node: TNode) -> [Entry] {
    var result = node.entries
    for child in node.children.values {
      result.append(contentsOf: collectAllEntries(from: child))
    }
    return result
  }
}
