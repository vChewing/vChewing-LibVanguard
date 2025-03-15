// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

extension Homa {
  @frozen
  public struct CandidatePair: Codable, Hashable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(_ tuplet: CandidatePairRAW) {
      self.keyArray = tuplet.keyArray
      self.value = tuplet.value
    }

    public init(keyArray: [String], value: String) {
      self.keyArray = keyArray
      self.value = value
    }

    // MARK: Public

    public let keyArray: [String]
    public let value: String

    public var raw: CandidatePairRAW {
      (keyArray, value)
    }

    public var spanLength: Int {
      keyArray.count
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      lhs.raw == rhs.raw
    }
  }

  @frozen
  public struct CandidatePairWeighted: Codable, Hashable, Sendable, Equatable {
    // MARK: Lifecycle

    public init(_ tuplet: CandidatePairWeightedRAW) {
      self.pair = .init(tuplet.pair)
      self.weight = tuplet.weight
    }

    public init(pair: CandidatePair, weight: Double) {
      self.pair = pair
      self.weight = weight
    }

    // MARK: Public

    public let pair: CandidatePair
    public let weight: Double

    public var raw: CandidatePairWeightedRAW {
      (pair.raw, weight)
    }

    public var weightStr4Ref: String {
      weight.description.prefix(8).description
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
      guard lhs.pair == rhs.pair else { return false }
      return lhs.weight == rhs.weight
    }
  }
}
