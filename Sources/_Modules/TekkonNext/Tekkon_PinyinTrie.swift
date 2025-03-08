// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

// MARK: - Tekkon.PinyinTrie

extension Tekkon {
  /// 用來處理拼音轉注音的字首樹實作。
  public struct PinyinTrie {
    // MARK: Lifecycle

    public init(parser: MandarinParser) {
      self.parser = parser
      // Key 是注音，Value 是拼音，所以要反過來建樹。
      if let table = parser.mapZhuyinPinyin {
        let reversedMap = Dictionary(grouping: table.map { ($0.value, $0.key) }, by: \.0)
          .mapValues { pairs in pairs.map(\.1) }
        for (pinyin, zhuyins) in reversedMap {
          for zhuyin in zhuyins {
            insert(pinyin: pinyin, zhuyin: zhuyin)
          }
        }
      }
    }

    // MARK: Public

    public let parser: MandarinParser

    /// 搜尋某個拼音的所有可能注音結果
    public func findZhuyin(for pinyin: String) -> Set<String> {
      guard !pinyin.isEmpty else { return [] }
      var current = root

      // 檢查完整拼音
      for char in pinyin {
        guard let next = current.children[char] else {
          // 如果找不到完整匹配，檢查是否為簡拼
          if pinyin.count == 1,
             let firstCharNode = root.children[pinyin.first!] {
            return firstCharNode.zhuyinValues
          }
          return []
        }
        current = next
      }

      return current.zhuyinValues
    }

    // MARK: Private

    /// 字首樹的節點定義
    private class PYNode {
      var children: [Character: PYNode] = [:]
      var zhuyinValues: Set<String> = []
      var isTerminating = false
    }

    private let root = PYNode()

    /// 插入一組拼音與注音的對應
    private mutating func insert(pinyin: String, zhuyin: String) {
      guard !pinyin.isEmpty else { return }
      var current = root

      // 插入完整拼音
      for char in pinyin {
        if current.children[char] == nil {
          current.children[char] = PYNode()
        }
        current = current.children[char]!
      }
      current.isTerminating = true
      current.zhuyinValues.insert(zhuyin)

      // 插入簡拼索引（第一個字母）
      if let firstChar = pinyin.first {
        let firstNode = root.children[firstChar] ?? PYNode()
        firstNode.zhuyinValues.insert(zhuyin)
        root.children[firstChar] = firstNode
      }
    }
  }
}

extension Tekkon.PinyinTrie {
  /// 拿已經 chop 段切過的拼音來算出可能的注音 chop 結果。可能會出現多個結果。
  ///
  /// 例：當前 parser 是漢語拼音的話，當給定參數如下時：
  /// ```swift
  /// `chopped: ["b", "yue", "z", "q", "s", "l", "l"]
  /// ```
  ///
  /// 期許結果是：
  ///
  /// ```swift
  /// [
  ///   ["ㄅ", "ㄩㄝ", "ㄗ", "ㄑ", "ㄙ", "ㄌ", "ㄌ"],
  ///   ["ㄅ", "ㄩㄝ", "ㄗ", "ㄑ", "ㄕ", "ㄌ", "ㄌ"],
  ///   ["ㄅ", "ㄩㄝ", "ㄓ", "ㄑ", "ㄙ", "ㄌ", "ㄌ"],
  ///   ["ㄅ", "ㄩㄝ", "ㄓ", "ㄑ", "ㄕ", "ㄌ", "ㄌ"],
  /// ]
  /// ```
  public func deductChoppedPinyinToZhuyin(chopped: [String]) -> [[String]] {
    guard parser.isPinyin else { return [chopped] }

    // 遞迴生成所有可能的組合
    func generateCombinations(index: Int, currentPath: [String], results: inout [[String]]) {
      if index >= chopped.count {
        results.append(currentPath)
        return
      }

      let segment = chopped[index]
      let zhuyins = findZhuyin(for: segment)

      if zhuyins.isEmpty {
        var newPath = currentPath
        newPath.append(segment)
        generateCombinations(index: index + 1, currentPath: newPath, results: &results)
      } else {
        for zhuyin in zhuyins.sorted() {  // 確保結果順序穩定
          var newPath = currentPath
          newPath.append(zhuyin)
          generateCombinations(index: index + 1, currentPath: newPath, results: &results)
        }
      }
    }

    var results = [[String]]()
    generateCombinations(index: 0, currentPath: [], results: &results)
    
    if results.isEmpty {
      return [chopped]
    }
    
    return results.sorted { $0.joined() < $1.joined() }
  }
}
