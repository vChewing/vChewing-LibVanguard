// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Homa.AssemblerConfig

extension Homa {
  /// 用於組字器的組態設定。
  public struct Config: Codable, Hashable {
    // MARK: Lifecycle

    public init(
      assembledSentence: [GramInPath] = [],
      keys: [String] = [],
      spans: [NodeSpan] = [],
      cursor: Int = 0,
      maxSpanLength: Int = 10,
      marker: Int = 0
    ) {
      self.assembledSentence = assembledSentence
      self.keys = keys
      self.spans = spans
      self.cursor = cursor
      self.maxSpanLength = max(6, maxSpanLength)
      self.marker = marker
    }

    // MARK: Public

    /// 最近一次爬軌結果。
    public var assembledSentence: [GramInPath] = []
    /// 該組字器已經插入的的索引鍵，以陣列的形式存放。
    public var keys = [String]()
    /// 該組字器的幅位單元陣列。
    public var spans = [NodeSpan]()

    /// 該組字器的敲字游標位置。
    public var cursor: Int = 0 {
      didSet {
        cursor = max(0, min(cursor, length))
        marker = cursor
      }
    }

    /// 該軌格內可以允許的最大幅位長度。
    public var maxSpanLength: Int = 10 {
      didSet {
        _ = (maxSpanLength < 6) ? maxSpanLength = 6 : dropNodesBeyondMaxSpanLength()
      }
    }

    /// 該組字器的標記器（副游標）位置。
    public var marker: Int = 0 { didSet { marker = max(0, min(marker, length)) } }

    /// 該組字器的長度，組字器內已經插入的單筆索引鍵的數量，也就是內建漢字讀音的數量（唯讀）。
    /// - Remark: 理論上而言，spans.count 也是這個數。
    /// 但是，為了防止萬一，就用了目前的方法來計算。
    public var length: Int { keys.count }

    /// 該組字器的硬拷貝。
    /// - Remark: 因為 Node 不是 Struct，所以會在 Assembler 被拷貝的時候無法被真實複製。
    /// 這樣一來，Assembler 複製品當中的 Node 的變化會被反應到原先的 Assembler 身上。
    /// 這在某些情況下會造成意料之外的混亂情況，所以需要引入一個拷貝用的建構子。
    public var hardCopy: Self {
      var newCopy = self
      newCopy.assembledSentence = assembledSentence
      newCopy.spans = spans.map(\.hardCopy)
      return newCopy
    }

    /// 重置包括游標在內的各項參數，且清空各種由組字器生成的內部資料。
    ///
    /// 將已經被插入的索引鍵陣列與幅位單元陣列（包括其內的節點）全部清空。
    /// 最近一次的爬軌結果陣列也會被清空。游標跳轉換算表也會被清空。
    public mutating func clear() {
      assembledSentence.removeAll()
      keys.removeAll()
      spans.removeAll()
      cursor = 0
      marker = 0
    }

    /// 清除所有幅長超過 MaxSpanLength 的節點。
    public mutating func dropNodesBeyondMaxSpanLength() {
      spans.indices.forEach { currentPos in
        spans[currentPos].keys.forEach { currentSpanLength in
          if currentSpanLength > maxSpanLength {
            spans[currentPos].removeValue(forKey: currentSpanLength)
          }
        }
      }
    }
  }
}
