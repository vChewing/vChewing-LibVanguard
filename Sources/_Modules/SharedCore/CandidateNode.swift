// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

open class CandidateNode {
  // MARK: Lifecycle

  public init(name: String, members: [CandidateNode] = [], previous: CandidateNode? = nil) {
    self.name = name
    self.members = members
    members.forEach { $0.previous = self }
    self.previous = previous
  }

  public init(name: String, symbols: [String]) {
    self.name = name
    self.members = symbols.map { CandidateNode(name: $0, symbols: []) }
    members.forEach { $0.previous = self }
  }

  // MARK: Public

  public static let root: Mutex<CandidateNode> = .init(.init(name: "/"))

  public var name: String
  public var members: [CandidateNode]
  public var previous: CandidateNode?
}
