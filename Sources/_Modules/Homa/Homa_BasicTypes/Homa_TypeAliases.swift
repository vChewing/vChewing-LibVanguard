// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

extension Homa {
  public typealias CandidatePair = (keyArray: [String], value: String)
  public typealias CandidatePairWeighted = (pair: CandidatePair, weight: Double)
  public typealias GramQuerier = ([String]) -> [(
    keyArray: [String],
    value: String,
    probability: Double,
    previous: String?
  )]
  public typealias GramExistenceChecker = ([String]) -> Bool
}
