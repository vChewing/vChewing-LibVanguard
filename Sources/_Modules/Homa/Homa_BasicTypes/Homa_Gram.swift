// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Homa.Gram

extension Homa {
  /// 護摩組字引擎專用的元圖類型，可以是單元圖、也可以是雙元圖。
  /// - Remarks: 護摩組字引擎所利用的雙元圖資料不包含讀音。
  public final class Gram: Codable, CustomStringConvertible, Equatable, Sendable, Hashable {
    // MARK: Lifecycle

    public init(
      current: String,
      previous: String? = nil,
      probability: Double = 0,
      backoff: Double = 0
    ) {
      self.current = current
      if let previous, !previous.isEmpty {
        self.previous = previous
      } else {
        self.previous = nil
      }
      self.probability = probability
      self.backoff = backoff
    }

    // MARK: Public

    public let current: String
    public let previous: String?
    public let probability: Double
    public let backoff: Double // 最大單元圖機率

    public var isUnigram: Bool { previous == nil }

    public var description: String {
      guard let previous else {
        return "P(\(current))=\(probability), BOW('\(current)')=\(backoff)" // 單元圖
      }
      return "P(\(current)|\(previous))=\(probability)" // 雙元圖
    }

    public static func == (lhs: Homa.Gram, rhs: Homa.Gram) -> Bool {
      lhs.hashValue == rhs.hashValue
    }

    public func describe(queryString: String) -> String {
      "[\(isUnigram ? "Unigram" : "Bigram")] '\(queryString)', \(description)"
    }

    /// 預設雜湊函式。
    /// - Parameter hasher: 目前物件的雜湊碼。
    public func hash(into hasher: inout Hasher) {
      hasher.combine(current)
      hasher.combine(previous)
      hasher.combine(probability)
      hasher.combine(backoff)
    }

    // MARK: Internal

    enum CodingKeys: String, CodingKey {
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

  var allBigramsMap: [String: Element] {
    var theMap = [String: Element]()
    filter { $0.previous != nil }
      .forEach { theMap[$0.previous!] = $0 }
    return theMap
  }
}
