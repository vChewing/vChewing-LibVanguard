// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - VanguardTrie

public enum VanguardTrie {
  public final class Trie: Codable {
    // MARK: Lifecycle

    public init(separator: Character) {
      self.readingSeparator = separator
      self.root = .init(id: "")
      self.nodes = [:]

      // 初始化時，將根節點加入到節點辭典中
      root.id = ""
      root.parentID = nil
      root.character = ""
      nodes[""] = root
    }

    public required init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      let decodingErrorSep = DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription: "Separator is not a single character."
        )
      )
      let decodingErrorRoot0 = DecodingError.dataCorrupted(
        DecodingError.Context(
          codingPath: container.codingPath,
          debugDescription: "Root node with ID 0 not found in nodes dictionary"
        )
      )

      let separatorRaw = try container.decode(String.self, forKey: .readingSeparator)
      guard separatorRaw.count == 1 else { throw decodingErrorSep }
      guard let separatorChar = separatorRaw.first else { throw decodingErrorSep }

      self.readingSeparator = separatorChar
      let nodesExtracted = try container.decode(Set<TNode>.self, forKey: .nodes)
      var nodesMap = [String: TNode]()
      nodesExtracted.forEach {
        nodesMap[$0.id] = $0
      }
      self.nodes = nodesMap

      // 從節點辭典中獲取根節點
      guard let rootNode = nodes[""] else { throw decodingErrorRoot0 }
      self.root = rootNode
    }

    // MARK: Public

    public final class TNode: Codable, Hashable, Identifiable {
      // MARK: Lifecycle

      public init(
        id: String,
        entries: [Entry] = [],
        parentID: String? = nil,
        character: String = "",
        readingKey: String = ""
      ) {
        self.id = id
        self.entries = entries
        self.parentID = parentID
        self.character = character
        self.children = [:]
        self.readingKey = readingKey
      }

      public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        self.character = try container.decodeIfPresent(String.self, forKey: .character) ?? ""
        self.readingKey = try container.decodeIfPresent(String.self, forKey: .readingKey) ?? ""
        self.children = (
          try container.decodeIfPresent([String: String].self, forKey: .children)
        ) ?? [:]
        self.entries = (
          try container.decodeIfPresent([Entry].self, forKey: .entries)
        ) ?? []
      }

      // MARK: Public

      public internal(set) var id: String = ""
      public internal(set) var entries: [Entry] = []
      public internal(set) var parentID: String?
      public internal(set) var character: String = ""
      public internal(set) var readingKey: String = "" // 新增：存儲節點對應的讀音鍵
      public internal(set) var children: [String: String] = [:] // 新的結構：字符 -> 子節點ID映射

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
        hasher.combine(readingKey)
        hasher.combine(children)
      }

      public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        if !entries.isEmpty {
          try container.encode(entries, forKey: .entries)
        }
        try container.encodeIfPresent(parentID, forKey: .parentID)
        if !character.isEmpty {
          try container.encode(character, forKey: .character)
        }
        if !readingKey.isEmpty {
          try container.encode(readingKey, forKey: .readingKey)
        }
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
        case readingKey
        case children
      }
    }

    public struct Entry: Codable, Hashable, Sendable {
      // MARK: Lifecycle

      public init(
        value: String,
        typeID: EntryType,
        probability: Double,
        previous: String?
      ) {
        self.value = value
        self.typeID = typeID
        self.probability = probability
        self.previous = previous
      }

      public init(from decoder: any Decoder, readingKey: String) throws {
        let container = try decoder.singleValueContainer()
        let stackRawStr = try container.decode(String.self)
        let stack = stackRawStr.split(separator: "\t")
        let theException = DecodingError.dataCorrupted(
          DecodingError.Context(
            codingPath: container.codingPath,
            debugDescription: "Can't parse the following contents into an Entry: \(stackRawStr)"
          )
        )
        guard [3, 4].contains(stack.count) else { throw theException }
        self.value = stack[0].description
        guard let typeIDRaw = Int32(stack[1]) else { throw theException }
        guard let probability = Double(stack[2]) else { throw theException }
        self.typeID = .init(rawValue: typeIDRaw)
        self.probability = probability
        if stack.count == 4 {
          self.previous = stack[3].description
        } else {
          self.previous = nil
        }
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
        guard [3, 4].contains(stack.count) else { throw theException }
        self.value = stack[0].description
        guard let typeIDRaw = Int32(stack[1]) else { throw theException }
        guard let probability = Double(stack[2]) else { throw theException }
        self.typeID = .init(rawValue: typeIDRaw)
        self.probability = probability
        if stack.count == 4 {
          self.previous = stack[3].description
        } else {
          self.previous = nil
        }
      }

      // MARK: Public

      public let value: String
      public let typeID: EntryType
      public let probability: Double
      public let previous: String?

      public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        var stack = [String]()
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

    public let readingSeparator: Character
    public let root: TNode
    public internal(set) var nodes: [String: TNode] // 修改：由 Int 改為 String

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)

      try container.encode(String(readingSeparator), forKey: .readingSeparator)
      try container.encode(Set(nodes.values), forKey: .nodes)
    }

    // MARK: Private

    private enum CodingKeys: CodingKey {
      case readingSeparator
      case nodes
    }
  }
}

// MARK: - Extending Methods (Trie: Insert and Search API).

extension VanguardTrie.Trie {
  public func insert(entry: Entry, readings: [String]) {
    var currentNode = root
    var currentNodeID = ""

    let key = readings.joined(separator: readingSeparator.description)
    let keyCells = readings // 修改：直接使用 readings 作為 keyCells，不再拆分字符

    // 遍歷關鍵字的每個讀音單元
    keyCells.forEach { nodeUnitStr in
      let nextNodeKeyChain = currentNodeID.isEmpty ? nodeUnitStr :
        currentNodeID + readingSeparator.description + nodeUnitStr

      if let childNode = nodes[nextNodeKeyChain] {
        // 有效的子節點已存在，繼續遍歷
        currentNodeID = nextNodeKeyChain
        currentNode = childNode
        return
      }
      // 創建新的子節點
      let newNode = TNode(id: nextNodeKeyChain, parentID: currentNodeID, character: nodeUnitStr)

      // 更新關係
      currentNode.children[nodeUnitStr] = nextNodeKeyChain
      nodes[nextNodeKeyChain] = newNode

      // 更新當前節點
      currentNode = newNode
      currentNodeID = nextNodeKeyChain
    }

    // 在最終節點設定讀音鍵並添加詞條
    currentNode.readingKey = key
    currentNode.entries.append(entry)
  }

  public func clearAllContents() {
    root.children.removeAll()
    root.entries.removeAll()
    root.id = ""
    nodes.removeAll()
    nodes[""] = root
  }
}
