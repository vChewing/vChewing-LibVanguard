// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Homa.Gram

extension Homa {
  /// 護摩組字引擎專用的元圖類型，可以是單元圖、也可以是雙元圖。
  /// - Remark: 護摩組字引擎所利用的雙元圖資料不包含讀音。此處故意使用 class 而非 struct 是因為其記憶體位址有特殊之用途。
  public final class Gram: Codable, CustomStringConvertible, Equatable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(_ rawTuple: GramRAW, backoff: Double = 0) {
      self.keyArray = rawTuple.keyArray
      self.current = rawTuple.value
      if let previous = rawTuple.previous, !previous.isEmpty {
        self.previous = previous
      } else {
        self.previous = nil
      }
      self.probability = rawTuple.probability
      self.backoff = backoff
    }

    public init(
      keyArray: [String],
      current: String,
      previous: String? = nil,
      probability: Double = 0,
      backoff: Double = 0
    ) {
      self.keyArray = keyArray
      self.current = current
      if let previous, !previous.isEmpty {
        self.previous = previous
      } else {
        self.previous = nil
      }
      self.probability = probability
      self.backoff = backoff
    }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      self.keyArray = try container.decode([String].self, forKey: .keyArray)
      self.current = try container.decode(String.self, forKey: .current)
      self.previous = try container.decodeIfPresent(String.self, forKey: .previous)
      self.probability = try container.decode(Double.self, forKey: .probability)
      self.backoff = try container.decode(Double.self, forKey: .backoff)
    }

    // MARK: Public

    public let keyArray: [String]
    public let current: String
    public let previous: String?
    public let probability: Double
    public let backoff: Double // 最大單元圖機率

    public var isUnigram: Bool { previous == nil }

    public var description: String {
      describe(keySeparator: "-")
    }

    public var descriptionSansReading: String {
      guard let previous else {
        return "P(\(current))=\(probability), BOW('\(current)')=\(backoff)" // 單元圖
      }
      return "P(\(current)|\(previous))=\(probability)" // 雙元圖
    }

    public var asTuple: GramRAW {
      (
        keyArray: keyArray,
        value: current,
        probability: probability,
        previous: previous
      )
    }

    /// 檢查是否「讀音字長與候選字字長不一致」。
    public var isReadingMismatched: Bool {
      keyArray.count != current.count
    }

    /// 幅長。
    public var spanLength: Int {
      keyArray.count
    }

    public static func == (lhs: Homa.Gram, rhs: Homa.Gram) -> Bool {
      lhs.hashValue == rhs.hashValue
    }

    public func describe(keySeparator: String) -> String {
      let header = "[\(isUnigram ? "Unigram" : "Bigram")]"
      let body = "'\(keyArray.joined(separator: keySeparator))', \(descriptionSansReading)"
      return "\(header) \(body)"
    }

    /// 預設雜湊函式。
    /// - Parameter hasher: 目前物件的雜湊碼。
    public func hash(into hasher: inout Hasher) {
      hasher.combine(keyArray)
      hasher.combine(current)
      hasher.combine(previous)
      hasher.combine(probability)
      hasher.combine(backoff)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(keyArray, forKey: .keyArray)
      try container.encode(current, forKey: .current)
      try container.encodeIfPresent(previous, forKey: .previous)
      try container.encode(probability, forKey: .probability)
      try container.encode(backoff, forKey: .backoff)
    }

    // MARK: Internal

    enum CodingKeys: String, CodingKey {
      case keyArray = "keys"
      case current = "curr"
      case previous = "prev"
      case probability = "prob"
      case backoff = "bkof"
    }
  }
}

extension Array where Element == Homa.Gram {
  var asGramTypes: (unigrams: [Element], bigrams: [Element]) {
    reduce(into: ([Element](), [Element]())) { result, element in
      if element.isUnigram {
        result.0.append(element)
      } else {
        result.1.append(element)
      }
    }
  }

  var allBigramsMap: [String: [Element]] {
    var theMap = [String: [Element]]()
    filter { $0.previous != nil }
      .forEach { theMap[$0.previous!, default: []].append($0) }
    return theMap
  }
}
