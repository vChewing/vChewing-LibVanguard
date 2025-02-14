// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Homa.NodeSpan

extension Homa {
  /// 幅位乃指一組共享起點的節點。其實是個辭典：[幅位長度: 節點]。
  public typealias NodeSpan = [Int: Node]
}

extension Homa.NodeSpan {
  /// 幅位乃指一組共享起點的節點。其實是個辭典：[幅位長度: 節點]。
  /// - Remark: 因為 Node 不是 Struct，所以會在 Assembler 被拷貝的時候無法被真實複製。
  /// 這樣一來，Assembler 複製品當中的 Node 的變化會被反應到原先的 Assembler 身上。
  /// 這在某些情況下會造成意料之外的混亂情況，所以需要引入一個拷貝用的建構子。
  public init(NodeSpan target: Homa.NodeSpan) {
    self.init()
    target.forEach { theKey, theValue in
      self[theKey] = theValue.copy
    }
  }

  /// 該幅位的硬拷貝。
  public var hardCopy: Homa.NodeSpan { .init(NodeSpan: self) }

  // MARK: - Dynamic Variables

  /// 該幅位單元內的所有節點當中持有最長幅位的節點長度。
  /// 該變數受該幅位的自身操作函式而被動更新。
  public var maxLength: Int { keys.max() ?? 0 }

  // MARK: - Functions

  /// 往該幅位塞入一個節點。
  /// - Remark: 這個函式用來防呆。一般情況下用不到。
  /// - Parameter node: 要塞入的節點。
  public mutating func addNode(node: Homa.Node) {
    self[node.spanLength] = node
  }
}
