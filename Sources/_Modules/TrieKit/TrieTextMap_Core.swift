// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - VanguardTrie.TextMapTrie

extension VanguardTrie {
  /// Phase 04: 惰性解析的 TextMap Trie。
  ///
  /// 與 `Trie`（全物化常駐 RAM）不同，`TextMapTrie` 將原始 UTF-8 資料以
  /// `Data` 形式常駐記憶體，僅在查詢時按需解析對應 VALUES 行的詞條。
  ///
  /// 穩態記憶體佔用約為原始檔案大小（~15 MB）加上輕量索引（~2 MB），
  /// 顯著低於全物化 Trie 的開銷。QueryBuffer 快取已解析的節點以攤平重複查詢成本。
  public final class TextMapTrie {
    // MARK: Lifecycle

    /// 從 TextMap 格式的 Data 建構惰性 Trie。
    ///
    /// 初期化時只解析 HEADER 與 KEY_LINE_MAP，建立行偏移量索引，
    /// 不解析 VALUES 區段的詞條內容。
    /// - Parameter data: 完整的 `.txtMap` 檔案內容（UTF-8）。
    /// - Throws: 解析所需 PRAGMA 區段缺失或格式有誤時拋出例外。
    public init(data: Data) throws {
      self.rawData = data

      // Phase 04: Step 1 — 定位三個 PRAGMA 區段的位元組範圍。
      let bounds = try Self.locatePragmaBounds(in: data)

      // Phase 04: Step 2 — 解析 HEADER（段落小，可安全轉為 String）。
      let headerStr = Self.extractString(
        from: data,
        start: bounds.headerContentStart,
        end: bounds.valuesLineStart
      )
      let hdr = Self.parseHeaderContent(headerStr)
      self.readingSeparator = hdr.separator
      self.isTyping = hdr.isTyping
      self.defaultProbs = hdr.defaultProbs

      // Phase 04: Step 3 — 掃描 VALUES 區段的行偏移量（位元組層級）。
      self.valuesLineOffsets = Self.scanValueLineOffsets(
        in: data,
        from: bounds.valuesContentStart,
        to: bounds.keyMapLineStart
      )
      self.valuesEndOffset = bounds.keyMapLineStart

      // Phase 04: Step 4 — 解析 KEY_LINE_MAP，建立讀音鍵 → 行範圍索引。
      let (entries, initialsMap) = Self.parseKeyLineMapContent(
        in: data,
        from: bounds.keyMapContentStart,
        to: data.count,
        separator: hdr.separator
      )
      self.keyEntries = entries
      self.keyInitialsIDMap = initialsMap
      self.valueLineToKeyEntryIndex = Self.buildLineOwnerIndex(
        keyEntries: entries,
        valueLineCount: valuesLineOffsets.count
      )
      self.reverseLookupTable = Self.buildReverseLookupTable(
        in: data,
        keyEntries: entries,
        valueLineOffsets: valuesLineOffsets,
        valuesEndOffset: valuesEndOffset,
        isTyping: hdr.isTyping,
        defaultProbs: hdr.defaultProbs,
        separator: hdr.separator
      )
    }

    // MARK: Public

    public let readingSeparator: Character

    // MARK: Internal

    /// 虛擬節點索引。索引值即為 node ID。
    struct KeyEntry {
      let readingKeyStart: Int
      let readingKeyEnd: Int
      let startLine: Int
      let count: Int
    }

    struct RevLookupEntry {
      let key: ContiguousArray<UInt8>
      let lineIndices: [Int]
    }

    internal let keyInitialsIDMap: [String: [Int]]

    // MARK: Private

    /// 原始 TextMap 檔案的完整 UTF-8 位元組。
    private let rawData: Data
    private let isTyping: Bool
    private let defaultProbs: [Int32: Double]

    /// VALUES 區段中每行的起始位元組偏移量（絕對偏移量，指向 `rawData` 內）。
    private let valuesLineOffsets: [Int]
    /// VALUES 區段結束的位元組偏移量（即 KEY_LINE_MAP PRAGMA 行的起始位置）。
    private let valuesEndOffset: Int

    private let keyEntries: [KeyEntry]
    private let valueLineToKeyEntryIndex: [Int32]
    private let reverseLookupTable: [RevLookupEntry]

    // Phase 04: QueryBuffer 快取已解析的節點，避免重複解析。
    private let queryBuffer4Node: QueryBuffer<VanguardTrie.Trie.TNode?> = .init()
    private let queryBuffer4Nodes: QueryBuffer<[VanguardTrie.Trie.TNode]> = .init()
    private let queryBuffer4NodeIDs: QueryBuffer<[Int]> = .init()
  }
}

// MARK: - Init Helpers

extension VanguardTrie.TextMapTrie {
  private static let revLookupEntryType = VanguardTrie.Trie.EntryType(rawValue: 3)
  private static let cnsEntryType = VanguardTrie.Trie.EntryType(rawValue: 7)

  /// 三個 PRAGMA 區段的位元組邊界。
  private struct PragmaBounds {
    /// HEADER 內容起始（HEADER PRAGMA 行之後）。
    let headerContentStart: Int
    /// VALUES PRAGMA 行起始位置。
    let valuesLineStart: Int
    /// VALUES 內容起始（VALUES PRAGMA 行之後）。
    let valuesContentStart: Int
    /// KEY_LINE_MAP PRAGMA 行起始位置。
    let keyMapLineStart: Int
    /// KEY_LINE_MAP 內容起始（KEY_LINE_MAP PRAGMA 行之後）。
    let keyMapContentStart: Int
  }

  /// 以位元組掃描定位三個 PRAGMA 行的位置。
  private static func locatePragmaBounds(in data: Data) throws -> PragmaBounds {
    let pragmaH = Array("#PRAGMA:VANGUARD_HOMA_LEXICON_HEADER".utf8)
    let pragmaV = Array("#PRAGMA:VANGUARD_HOMA_LEXICON_VALUES".utf8)
    let pragmaK = Array("#PRAGMA:VANGUARD_HOMA_LEXICON_KEY_LINE_MAP".utf8)
    let newline: UInt8 = 0x0A

    var headerContentStart: Int?
    var valuesLineStart: Int?
    var valuesContentStart: Int?
    var keyMapLineStart: Int?
    var keyMapContentStart: Int?

    data.withUnsafeBytes { buf in
      let ptr = buf.bindMemory(to: UInt8.self)
      let total = ptr.count
      var i = 0
      while i < total {
        let lineStart = i
        // 跳到行尾。
        while i < total, ptr[i] != newline { i += 1 }
        let nextLineStart = Swift.min(i + 1, total)
        // 只檢查以 '#' 起始的行。
        if lineStart < total, ptr[lineStart] == 0x23 {
          if matchPrefix(ptr, at: lineStart, count: total, prefix: pragmaH) {
            headerContentStart = nextLineStart
          } else if matchPrefix(ptr, at: lineStart, count: total, prefix: pragmaV) {
            valuesLineStart = lineStart
            valuesContentStart = nextLineStart
          } else if matchPrefix(ptr, at: lineStart, count: total, prefix: pragmaK) {
            keyMapLineStart = lineStart
            keyMapContentStart = nextLineStart
          }
        }
        i = nextLineStart
      }
    }

    guard let hCS = headerContentStart,
          let vLS = valuesLineStart,
          let vCS = valuesContentStart,
          let kLS = keyMapLineStart,
          let kCS = keyMapContentStart
    else {
      throw VanguardTrie.TrieIO.Exception.deserializationFailed(
        NSError(domain: "VanguardTrie.TextMapTrie", code: -1, userInfo: [
          NSLocalizedDescriptionKey: "TextMap missing required PRAGMA sections.",
        ])
      )
    }

    return PragmaBounds(
      headerContentStart: hCS,
      valuesLineStart: vLS,
      valuesContentStart: vCS,
      keyMapLineStart: kLS,
      keyMapContentStart: kCS
    )
  }

  /// 位元組前綴比對。
  private static func matchPrefix(
    _ ptr: UnsafeBufferPointer<UInt8>,
    at offset: Int,
    count: Int,
    prefix: [UInt8]
  )
    -> Bool {
    guard offset + prefix.count <= count else { return false }
    for j in 0 ..< prefix.count {
      if ptr[offset + j] != prefix[j] { return false }
    }
    return true
  }

  /// HEADER 段落解析結果。
  private struct HeaderInfo {
    let separator: Character
    let isTyping: Bool
    let defaultProbs: [Int32: Double]
  }

  /// 解析 HEADER 段落內容。
  private static func parseHeaderContent(_ content: String) -> HeaderInfo {
    var separator: Character = "-"
    var isTyping = false
    var defaultProbs: [Int32: Double] = [:]

    content.enumerateLines { line, _ in
      let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
      guard parts.count >= 2 else { return }
      switch parts[0] {
      case "READING_SEPARATOR":
        if let c = parts[1].first { separator = c }
      case "TYPE":
        isTyping = parts[1] == "TYPING"
      default:
        if parts[0].hasPrefix("DEFAULT_PROB_") {
          let typeIDStr = String(parts[0].dropFirst("DEFAULT_PROB_".count))
          if let typeIDRaw = Int32(typeIDStr), let prob = Double(parts[1]) {
            defaultProbs[typeIDRaw] = prob
          }
        }
      }
    }

    return HeaderInfo(separator: separator, isTyping: isTyping, defaultProbs: defaultProbs)
  }

  /// 掃描 VALUES 區段中每行的起始位元組偏移量。
  private static func scanValueLineOffsets(
    in data: Data,
    from start: Int,
    to end: Int
  )
    -> [Int] {
    guard end > start else { return [] }
    var offsets: [Int] = [start]
    data.withUnsafeBytes { buf in
      let ptr = buf.bindMemory(to: UInt8.self)
      for i in start ..< end where ptr[i] == 0x0A {
        let nextLine = i + 1
        if nextLine < end {
          offsets.append(nextLine)
        }
      }
    }
    return offsets
  }

  /// 解析 KEY_LINE_MAP 段落，產出虛擬節點陣列與 keyInitials 索引。
  private static func parseKeyLineMapContent(
    in data: Data,
    from start: Int,
    to end: Int,
    separator: Character
  )
    -> ([KeyEntry], [String: [Int]]) {
    var keyEntries = [KeyEntry]()
    var keyInitialsIDMap: [String: [Int]] = [:]
    let tab: UInt8 = 0x09
    let newline: UInt8 = 0x0A

    data.withUnsafeBytes { buf in
      let ptr = buf.bindMemory(to: UInt8.self)
      var lineStart = start
      var cursor = start

      func processLine(_ lowerBound: Int, _ upperBound: Int) {
        guard upperBound > lowerBound else { return }
        var firstTab: Int?
        var secondTab: Int?
        var current = lowerBound
        while current < upperBound {
          if ptr[current] == tab {
            if firstTab == nil {
              firstTab = current
            } else {
              secondTab = current
              break
            }
          }
          current += 1
        }
        guard let firstTab, let secondTab, firstTab > lowerBound else { return }

        let startLineRaw = Self.extractString(from: data, start: firstTab + 1, end: secondTab)
        let countRaw = Self.extractString(from: data, start: secondTab + 1, end: upperBound)
        guard let startLine = Int(startLineRaw), let count = Int(countRaw) else { return }

        let nodeID = keyEntries.count
        keyEntries.append(
          KeyEntry(
            readingKeyStart: lowerBound,
            readingKeyEnd: firstTab,
            startLine: startLine,
            count: count
          )
        )

        let readingKey = Self.extractString(from: data, start: lowerBound, end: firstTab)
        let keyInitialsStr = readingKey.split(separator: separator).compactMap {
          $0.first?.description
        }.joined()
        keyInitialsIDMap[keyInitialsStr, default: []].append(nodeID)
      }

      while cursor <= end {
        if cursor == end || ptr[cursor] == newline {
          processLine(lineStart, cursor)
          lineStart = cursor + 1
        }
        cursor += 1
      }
    }

    return (keyEntries, keyInitialsIDMap)
  }

  private static func buildLineOwnerIndex(
    keyEntries: [KeyEntry],
    valueLineCount: Int
  )
    -> [Int32] {
    guard valueLineCount > 0 else { return [] }
    var lineOwners = Array(repeating: Int32(-1), count: valueLineCount)
    for (keyEntryIndex, keyEntry) in keyEntries.enumerated() {
      let end = min(keyEntry.startLine + keyEntry.count, valueLineCount)
      for lineIndex in keyEntry.startLine ..< end {
        lineOwners[lineIndex] = Int32(keyEntryIndex)
      }
    }
    return lineOwners
  }

  private static func buildReverseLookupTable(
    in data: Data,
    keyEntries: [KeyEntry],
    valueLineOffsets: [Int],
    valuesEndOffset: Int,
    isTyping: Bool,
    defaultProbs: [Int32: Double],
    separator: Character
  )
    -> [RevLookupEntry] {
    var charToLineIndices: [String: [Int]] = [:]

    for keyEntry in keyEntries {
      let readingKey = extractString(
        from: data,
        start: keyEntry.readingKeyStart,
        end: keyEntry.readingKeyEnd
      )
      let segmentCount = readingKey.split(separator: separator).count
      let endLine = min(keyEntry.startLine + keyEntry.count, valueLineOffsets.count)

      for lineIndex in keyEntry.startLine ..< endLine {
        let start = valueLineOffsets[lineIndex]
        let rawEnd = lineIndex + 1 < valueLineOffsets.count
          ? valueLineOffsets[lineIndex + 1]
          : valuesEndOffset
        let end = (rawEnd > start && data[rawEnd - 1] == 0x0A) ? rawEnd - 1 : rawEnd
        guard end > start else { continue }

        let line = extractString(from: data, start: start, end: end)
        let includeGroupedTypingLine = line.first == "@" && segmentCount == 1
        let parsed = VanguardTrie.TrieIO.parseValueLine(
          line,
          isTyping: isTyping,
          defaultProbs: defaultProbs
        )

        for parsedEntry in parsed {
          let charactersToIndex: [String] = if parsedEntry.typeID == cnsEntryType {
            parsedEntry.value.map(String.init)
          } else if includeGroupedTypingLine {
            parsedEntry.value.filter { currentCharacter in
              currentCharacter.unicodeScalars.contains { $0.properties.isIdeographic }
            }.map(String.init)
          } else {
            []
          }

          for character in charactersToIndex {
            charToLineIndices[character, default: []].append(lineIndex)
          }
        }
      }
    }

    var result: [RevLookupEntry] = []
    result.reserveCapacity(charToLineIndices.count)
    for (character, lineIndices) in charToLineIndices {
      let sortedLineIndices = lineIndices.sorted()
      var deduplicatedLineIndices: [Int] = []
      deduplicatedLineIndices.reserveCapacity(sortedLineIndices.count)
      for currentLineIndex in sortedLineIndices
        where deduplicatedLineIndices.last != currentLineIndex {
        deduplicatedLineIndices.append(currentLineIndex)
      }
      result.append(
        RevLookupEntry(
          key: ContiguousArray(character.utf8),
          lineIndices: deduplicatedLineIndices
        )
      )
    }

    result.sort { lhs, rhs in
      lhs.key.withUnsafeBufferPointer { lBuf in
        rhs.key.withUnsafeBufferPointer { rBuf in
          compareUTF8Buffers(lBuf, rBuf) < 0
        }
      }
    }
    return result
  }

  /// 從 rawData 提取指定位元組範圍的 UTF-8 字串。
  private static func extractString(from data: Data, start: Int, end: Int) -> String {
    guard end > start else { return "" }
    return String(decoding: data[start ..< end], as: UTF8.self)
  }
}

// MARK: - Lazy Node Parsing

extension VanguardTrie.TextMapTrie {
  private var reverseLookupNodeIDOffset: Int { keyEntries.count + 1 }

  /// 將 VALUES 區段的某一行提取為 String。
  private func extractValueLine(_ lineIndex: Int) -> String {
    guard lineIndex >= 0, lineIndex < valuesLineOffsets.count else { return "" }
    let start = valuesLineOffsets[lineIndex]
    let rawEnd = lineIndex + 1 < valuesLineOffsets.count
      ? valuesLineOffsets[lineIndex + 1]
      : valuesEndOffset
    // 去掉尾端的 \n。
    let end = (rawEnd > start && rawData[rawEnd - 1] == 0x0A) ? rawEnd - 1 : rawEnd
    guard end > start else { return "" }
    return Self.extractString(from: rawData, start: start, end: end)
  }

  /// 解析指定虛擬節點的 VALUES 行，產出 TNode。
  private func parseNodeEntries(_ nodeID: Int) -> VanguardTrie.Trie.TNode? {
    guard nodeID >= 0, nodeID < keyEntries.count else { return nil }
    let keyEntry = keyEntries[nodeID]
    let readingKey = Self.extractString(
      from: rawData,
      start: keyEntry.readingKeyStart,
      end: keyEntry.readingKeyEnd
    )
    let node = VanguardTrie.Trie.TNode(
      id: nodeID,
      readingKey: TrieStringPool.shared.internKey(readingKey)
    )
    let endLine = keyEntry.startLine + keyEntry.count
    for i in keyEntry.startLine ..< endLine {
      let line = extractValueLine(i)
      let parsed = VanguardTrie.TrieIO.parseValueLine(
        line, isTyping: isTyping, defaultProbs: defaultProbs
      )
      for p in parsed {
        node.entries.append(VanguardTrie.Trie.Entry(
          value: p.value,
          typeID: p.typeID,
          probability: p.probability,
          previous: p.previous
        ))
      }
    }
    return node.entries.isEmpty ? nil : node
  }

  private func reverseLookupIndex(for key: String) -> Int? {
    let keyUTF8 = Array(key.utf8)
    var lo = 0
    var hi = reverseLookupTable.count - 1
    while lo <= hi {
      let mid = lo + (hi - lo) / 2
      let currentEntry = reverseLookupTable[mid]
      let cmp = currentEntry.key.withUnsafeBufferPointer { currentBuffer in
        compareUTF8(currentBuffer, keyUTF8)
      }
      if cmp < 0 {
        lo = mid + 1
      } else if cmp > 0 {
        hi = mid - 1
      } else {
        return mid
      }
    }
    return nil
  }

  private func parsedReadings(from lineIndices: [Int]) -> [String] {
    var readings: [String] = []
    var seen: Set<String> = []
    for lineIndex in lineIndices {
      guard lineIndex >= 0, lineIndex < valueLineToKeyEntryIndex.count else { continue }
      let keyEntryIndex = Int(valueLineToKeyEntryIndex[lineIndex])
      guard keyEntryIndex >= 0, keyEntryIndex < keyEntries.count else { continue }
      let keyEntry = keyEntries[keyEntryIndex]
      let readingKey = Self.extractString(
        from: rawData,
        start: keyEntry.readingKeyStart,
        end: keyEntry.readingKeyEnd
      )
      if seen.insert(readingKey).inserted {
        readings.append(readingKey)
      }
    }
    return readings
  }

  private func parseReverseLookupNode(_ reverseLookupIndex: Int) -> VanguardTrie.Trie.TNode? {
    guard reverseLookupIndex >= 0, reverseLookupIndex < reverseLookupTable.count else { return nil }
    let reverseLookupEntry = reverseLookupTable[reverseLookupIndex]
    let readingValues = parsedReadings(from: reverseLookupEntry.lineIndices)
    guard !readingValues.isEmpty else { return nil }
    let node = VanguardTrie.Trie.TNode(
      id: reverseLookupNodeIDOffset + reverseLookupIndex,
      readingKey: TrieStringPool.shared.internKey(
        String(decoding: reverseLookupEntry.key, as: UTF8.self)
      )
    )
    node.entries.append(
      VanguardTrie.Trie.Entry(
        value: readingValues.joined(separator: "\t"),
        typeID: Self.revLookupEntryType,
        probability: 0,
        previous: nil
      )
    )
    return node
  }
}

// MARK: - VanguardTrie.TextMapTrie + VanguardTrieProtocol

extension VanguardTrie.TextMapTrie: VanguardTrieProtocol {
  public func getNodeIDsForKeyArray(
    _ keyArray: [String],
    longerSegment: Bool
  )
    -> [Int] {
    guard !keyArray.isEmpty, keyArray.allSatisfy({ !$0.isEmpty }) else { return [] }
    let keyInitialsStr = keyArray.compactMap {
      TrieStringPool.shared.internKey(TrieStringOperationCache.shared.getCachedFirstChar($0))
    }.joined()

    let cacheKey: Int = {
      var hasher = Hasher()
      hasher.combine(keyInitialsStr)
      hasher.combine(longerSegment)
      return hasher.finalize()
    }()

    if let cached = queryBuffer4NodeIDs.get(hashKey: cacheKey) { return cached }

    var matchedNodeIDs = [Int]()
    if longerSegment {
      for (initials, nodeIDs) in keyInitialsIDMap where initials.hasPrefix(keyInitialsStr) {
        matchedNodeIDs.append(contentsOf: nodeIDs)
      }
      matchedNodeIDs.sort()
    } else {
      matchedNodeIDs = keyInitialsIDMap[keyInitialsStr] ?? []
    }

    queryBuffer4NodeIDs.set(hashKey: cacheKey, value: matchedNodeIDs)
    return matchedNodeIDs
  }

  public func getNode(_ nodeID: Int) -> TNode? {
    if let cached = queryBuffer4Node.get(hashKey: nodeID) { return cached }
    let result = if nodeID >= reverseLookupNodeIDOffset {
      parseReverseLookupNode(nodeID - reverseLookupNodeIDOffset)
    } else {
      parseNodeEntries(nodeID)
    }
    queryBuffer4Node.set(hashKey: nodeID, value: result)
    return result
  }

  public func getNodes(
    keyArray: [String],
    filterType: EntryType,
    partiallyMatch: Bool,
    longerSegment: Bool
  )
    -> [TNode] {
    if filterType == Self.revLookupEntryType {
      guard !partiallyMatch, !longerSegment, keyArray.count == 1,
            let matchedIndex = reverseLookupIndex(for: keyArray[0])
      else {
        return []
      }
      return getNode(reverseLookupNodeIDOffset + matchedIndex).map { [$0] } ?? []
    }

    let cacheKey: Int = {
      var hasher = Hasher()
      hasher.combine(keyArray)
      hasher.combine(filterType)
      hasher.combine(partiallyMatch)
      hasher.combine(longerSegment)
      return hasher.finalize()
    }()

    if let cached = queryBuffer4Nodes.get(hashKey: cacheKey) { return cached }

    let matchedNodeIDs = getNodeIDsForKeyArray(keyArray, longerSegment: longerSegment)
    guard !matchedNodeIDs.isEmpty else {
      queryBuffer4Nodes.set(hashKey: cacheKey, value: [])
      return []
    }

    var handledNodeIDs: Set<Int> = []
    let matchedNodes: [TNode] = matchedNodeIDs.compactMap {
      guard let theNode = getNode($0) else { return nil }
      let nodeID = theNode.id
      guard !handledNodeIDs.contains(nodeID) else { return nil }
      handledNodeIDs.insert(nodeID)
      let nodeKeyArray = TrieStringOperationCache.shared.getCachedSplit(
        theNode.readingKey,
        separator: readingSeparator
      )
      guard nodeMeetsFilter(theNode, filter: filterType) else { return nil }
      var matched: Bool = longerSegment
        ? nodeKeyArray.count > keyArray.count
        : nodeKeyArray.count == keyArray.count
      switch partiallyMatch {
      case true:
        matched = matched && zip(nodeKeyArray, keyArray).allSatisfy { $0.hasPrefix($1) }
      case false:
        matched = matched && zip(nodeKeyArray, keyArray).allSatisfy(==)
      }
      return matched ? theNode : nil
    }

    queryBuffer4Nodes.set(hashKey: cacheKey, value: matchedNodes)
    return matchedNodes
  }
}

private func compareUTF8(_ lhs: UnsafeBufferPointer<UInt8>, _ rhs: [UInt8]) -> Int {
  let count = Swift.min(lhs.count, rhs.count)
  for i in 0 ..< count {
    if lhs[i] < rhs[i] { return -1 }
    if lhs[i] > rhs[i] { return 1 }
  }
  if lhs.count < rhs.count { return -1 }
  if lhs.count > rhs.count { return 1 }
  return 0
}

private func compareUTF8Buffers(
  _ lhs: UnsafeBufferPointer<UInt8>,
  _ rhs: UnsafeBufferPointer<UInt8>
)
  -> Int {
  let count = Swift.min(lhs.count, rhs.count)
  for i in 0 ..< count {
    if lhs[i] < rhs[i] { return -1 }
    if lhs[i] > rhs[i] { return 1 }
  }
  if lhs.count < rhs.count { return -1 }
  if lhs.count > rhs.count { return 1 }
  return 0
}
