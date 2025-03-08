// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - VanguardTrie

public enum VanguardTrie {
  public final class Trie: Codable {
    // MARK: Lifecycle

    public init(separator: String) {
      self.readingSeparator = separator
      self.root = .init(id: 0)
      self.nodes = [:]

      // 初始化時，將根節點加入到節點字典中
      root.id = 0
      root.parentID = nil
      root.character = ""
      nodes[0] = root
      self.keyChainIDMap = [:]
    }

    public required init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)

      self.readingSeparator = try container.decode(String.self, forKey: .readingSeparator)
      let nodesExtracted = try container.decode(Set<TNode>.self, forKey: .nodes)
      var nodesMap = [Int: TNode]()
      nodesExtracted.forEach {
        nodesMap[$0.id] = $0
      }
      self.nodes = nodesMap

      // 從節點字典中獲取根節點
      guard let rootNode = nodes[0] else {
        throw DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Root node with ID 0 not found in nodes dictionary"
          )
        )
      }
      self.root = rootNode
      self.keyChainIDMap = [:]
      updateKeyChainIDMap()
    }

    // MARK: Public

    public final class TNode: Codable, Hashable, Identifiable {
      // MARK: Lifecycle

      public init(
        id: Int,
        entries: [Entry] = [],
        parentID: Int? = nil,
        character: String = ""
      ) {
        self.id = id
        self.entries = entries
        self.parentID = parentID
        self.character = character
        self.children = [:]
      }

      public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(Int.self, forKey: .id)
        self.parentID = try container.decodeIfPresent(Int.self, forKey: .parentID)
        self.character = try container.decode(String.self, forKey: .character)
        self.children = (
          try container.decodeIfPresent([String: Int].self, forKey: .children)
        ) ?? [:]
        self.entries = (
          try container.decodeIfPresent([Entry].self, forKey: .entries)
        ) ?? []
      }

      // MARK: Public

      public fileprivate(set) var id: Int = 0
      public var entries: [Entry] = []
      public fileprivate(set) var parentID: Int?
      public fileprivate(set) var character: String = ""
      public var children: [String: Int] = [:] // 新的結構：字符 -> 子節點ID映射

      public static func == (
        lhs: TNode,
        rhs: TNode
      )
        -> Bool {
        lhs.hashValue == rhs.hashValue
      }

      public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(entries)
        hasher.combine(parentID)
        hasher.combine(character)
        hasher.combine(children)
      }

      public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        if !entries.isEmpty {
          try container.encode(entries, forKey: .entries)
        }
        try container.encodeIfPresent(parentID, forKey: .parentID)
        try container.encode(character, forKey: .character)
        if !children.isEmpty {
          try container.encode(children, forKey: .children)
        }
      }

      // MARK: Private

      private enum CodingKeys: String, CodingKey {
        case id
        case entries
        case parentID
        case character
        case children
      }
    }

    public struct Entry: Codable, Hashable, Sendable {
      // MARK: Lifecycle

      public init(
        readings: [String],
        value: String,
        typeID: EntryType,
        probability: Double,
        previous: String?
      ) {
        self.readings = readings
        self.value = value
        self.typeID = typeID
        self.probability = probability
        self.previous = previous
      }

      public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stackRawStr = try container.decode(String.self)
        let stack = stackRawStr.split(separator: "\t")
        let theException = DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Can't parse the following contents into an Entry: \(stackRawStr)"
          )
        )
        guard [4, 5].contains(stack.count) else { throw theException }
        self.readings = stack[0].components(separatedBy: " ")
        self.value = stack[1].description
        guard let typeIDRaw = Int32(stack[2]) else { throw theException }
        guard let probability = Double(stack[3]) else { throw theException }
        self.typeID = .init(rawValue: typeIDRaw)
        self.probability = probability
        if stack.count == 5 {
          self.previous = stack[4].description
        } else {
          self.previous = nil
        }
      }

      // MARK: Public

      public let readings: [String]
      public let value: String
      public let typeID: EntryType
      public let probability: Double
      public let previous: String?

      public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        /// 第一行是读音串，第二行是资料值，第三行是 typeID，第四行是 probability，第五行是 previous。
        var stack = [String]()
        stack.append(readings.joined(separator: " "))
        stack.append(value)
        stack.append(typeID.rawValue.description)
        stack.append(probability.description)
        if let previous {
          stack.append(previous)
        }
        try container.encode(stack.joined(separator: "\t"))
      }

      // MARK: Private

      private enum CodingKeysAlt: String, CodingKey {
        case readings
        case value
        case typeID
        case probability
        case previous
      }
    }

    public struct EntryType: OptionSet, Sendable, Codable, Hashable {
      // MARK: Lifecycle

      public init(rawValue: Int32) {
        self.rawValue = rawValue
      }

      // MARK: Public

      public static let langNeutral = Self(rawValue: 1 << 0)

      public let rawValue: Int32 // 必須得是 Int32，否則 SQLite 編碼可能會有問題。
    }

    public let readingSeparator: String
    public let root: TNode
    public fileprivate(set) var nodes: [Int: TNode] // 新增：節點字典，以id為索引
    public fileprivate(set) var keyChainIDMap: [String: Set<Int>]

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)

      try container.encode(readingSeparator, forKey: .readingSeparator)
      try container.encode(Set(nodes.values), forKey: .nodes)
    }

    // MARK: Private

    private enum CodingKeys: CodingKey {
      case readingSeparator
      case nodes
    }
  }
}

// MARK: - Extending Methods (Entry).

extension VanguardTrie.Trie.Entry {
  public var asTuple: (
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

  public var isReadingValueLengthMatched: Bool {
    readings.count == value.count
  }
}

// MARK: - Extending Methods (Trie: Insert and Search API).

extension VanguardTrie.Trie {
  public func insert(_ givenKey: String? = nil, entry: Entry) {
    var currentNode = root
    var currentNodeID = 0

    let key = givenKey ?? entry.readings.joined(separator: readingSeparator)

    // 遍歷關鍵字的每個字符
    key.forEach { char in
      let charStr = char.description
      if let childNodeID = currentNode.children[charStr],
         let matchedNode = nodes[childNodeID] {
        // 有效的子節點已存在，繼續遍歷
        currentNodeID = childNodeID
        currentNode = matchedNode
        return
      }
      // 創建新的子節點
      let newNodeID = nodes.count
      let newNode = TNode(id: newNodeID, parentID: currentNodeID, character: charStr)

      // 更新關係
      currentNode.children[charStr] = newNodeID
      nodes[newNodeID] = newNode

      // 更新當前節點
      currentNode = newNode
      currentNodeID = newNodeID
    }

    // 在最終節點添加詞條
    currentNode.entries.append(entry)

    // 直接更新 keyChainIDMap - 這裡是需要新增的部分
    let keyChainStr = entry.readings.joined(separator: readingSeparator)
    keyChainIDMap[keyChainStr, default: []].insert(currentNodeID)
  }

  public func search(_ key: String, partiallyMatch: Bool = false) -> [Entry] {
    // 使用 keyChainIDMap 優化查詢效能，尤其對於精確匹配的情況
    if !partiallyMatch {
      let nodeIDs = keyChainIDMap[key, default: []]
      if !nodeIDs.isEmpty {
        var results: [Entry] = []
        for nodeID in nodeIDs {
          if let node = nodes[nodeID] {
            results.append(contentsOf: node.entries)
          }
        }
        return results
      }
    }

    var currentNode = root
    // 遍歷關鍵字的每個字符
    for char in key {
      let charStr = char.description
      // 查找對應字符的子節點
      guard let childNodeID = currentNode.children[charStr] else { return [] }
      guard let childNode = nodes[childNodeID] else { return [] }
      // 更新當前節點
      currentNode = childNode
    }

    return partiallyMatch ? collectAllDescendantEntries(from: currentNode) : currentNode.entries
  }

  public func clearAllContents() {
    root.children.removeAll()
    root.entries.removeAll()
    root.id = 0
    nodes.removeAll()
    nodes[0] = root
    updateKeyChainIDMap()
  }

  private func collectAllDescendantEntries(from node: TNode) -> [Entry] {
    var result = node.entries
    // 遍歷所有子節點
    node.children.values.forEach { childNodeID in
      guard let childNode = nodes[childNodeID] else { return }
      result.append(contentsOf: collectAllDescendantEntries(from: childNode))
    }
    return result
  }

  private func updateKeyChainIDMap() {
    // 清空現有映射以確保資料一致性
    keyChainIDMap.removeAll()

    // 遍歷所有節點和條目來重建映射
    nodes.forEach { nodeID, node in
      node.entries.forEach { entry in
        let keyChainStr = entry.readings.joined(separator: readingSeparator)
        keyChainIDMap[keyChainStr, default: []].insert(nodeID)
      }
    }
  }
}

// MARK: - VanguardTrie.Trie + VanguardTrieProtocol

extension VanguardTrie.Trie: VanguardTrieProtocol {
  public func getNodeIDs(keys: [String], filterType: EntryType, partiallyMatch: Bool) -> Set<Int> {
    switch partiallyMatch {
    case false:
      return keyChainIDMap[keys.joined(separator: readingSeparator)] ?? []
    case true:
      guard !keys.isEmpty else { return [] }

      // 使用 keyChainIDMap 來優化查詢
      var matchedNodeIDs = Set<Int>()

      // 從 keyChainIDMap 中查找所有鍵
      keyChainIDMap.forEach { keyChain, nodeIDs in
        // 只處理那些至少和首個查詢鍵匹配的鍵鏈
        let keyComponents = keyChain.components(separatedBy: readingSeparator)

        // 檢查長度是否匹配
        guard keyComponents.count == keys.count else { return }

        // 檢查每個元素是否以對應的前綴開頭
        guard zip(keys, keyComponents).allSatisfy({ $1.hasPrefix($0) }) else { return }

        // 檢查類型過濾條件
        if !filterType.isEmpty {
          for nodeID in nodeIDs {
            guard let node = nodes[nodeID] else { continue }
            if node.entries.contains(where: { $0.typeID.contains(filterType) }) {
              matchedNodeIDs.insert(nodeID)
            }
          }
        } else {
          matchedNodeIDs.formUnion(nodeIDs)
        }
      }
      return matchedNodeIDs
    }
  }

  public func getNode(nodeID: Int) -> TNode? {
    nodes[nodeID]
  }

  public func getEntries(node: TNode) -> [Entry] {
    node.entries
  }
}
