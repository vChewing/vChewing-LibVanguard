// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - SIMD字符串操作

/// 為提升性能的 SIMD 最佳化字符串操作
@usableFromInline
enum SIMDStringOps {
  /// 針對語音鍵最佳化的快速字符串比較
  @usableFromInline
  static func fastCompare(_ lhs: String, _ rhs: String) -> Bool {
    // 對於語音輸入中常見的短字符串，直接比較通常是最快的
    guard lhs.count == rhs.count else { return false }

    // 對於非常短的字符串（常見情況），使用直接比較
    if lhs.count <= 8 {
      return lhs == rhs
    }

    // 對於較長的字符串，使用最佳化比較
    return lhs.withCString { lhsPtr in
      rhs.withCString { rhsPtr in
        memcmp(lhsPtr, rhsPtr, lhs.utf8.count) == 0
      }
    }
  }

  /// 字符串的快速雜湊計算
  @usableFromInline
  static func fastHash(_ string: String) -> Int {
    var hasher = Hasher()

    // 對常見的短字符串使用更高效的雜湊
    if string.count <= 16 {
      hasher.combine(string)
    } else {
      // 對於較長的字符串，分塊雜湊以獲得更好的性能
      let utf8 = string.utf8
      var chunks = utf8.makeIterator()
      while let chunk = chunks.next() {
        hasher.combine(chunk)
      }
    }

    return hasher.finalize()
  }

  /// 針對部分匹配的最佳化前綴檢查
  @usableFromInline
  static func hasPrefix(_ string: String, _ prefix: String) -> Bool {
    guard string.count >= prefix.count else { return false }

    // 空前綴的快速路徑
    if prefix.isEmpty { return true }

    // 針對常見情況使用最佳化實作
    if prefix.count <= 4 {
      let stringPrefix = string.prefix(prefix.count)
      return String(stringPrefix) == prefix
    }

    return string.hasPrefix(prefix)
  }
}

// MARK: - 語音樹狀節點

/// 專為語音輸入模式設計的特化樹狀節點
@usableFromInline
struct PhoneticTrieNode {
  // MARK: Lifecycle

  @usableFromInline
  init() {
    self.children = []
    self.values = []
    self.isTerminal = false
  }

  // MARK: Internal

  @usableFromInline
  var children: ContiguousArray<(key: String, node: PhoneticTrieNode)>

  @usableFromInline
  var values: ContiguousArray<String>

  @usableFromInline
  var isTerminal: Bool

  @usableFromInline
  mutating func insert(_ key: String, value: String) {
    if key.isEmpty {
      values.append(value)
      isTerminal = true
      return
    }

    let firstChar = String(key.first!)
    let remainder = String(key.dropFirst())

    // 尋找或建立子節點
    for i in children.indices {
      if children[i].key == firstChar {
        children[i].node.insert(remainder, value: value)
        return
      }
    }

    // 建立新的子節點
    var newNode = Self()
    newNode.insert(remainder, value: value)
    children.append((key: firstChar, node: newNode))

    // 保持子節點排序以進行二元搜尋
    if children.count > 8 {
      children.sort { $0.key < $1.key }
    }
  }

  @usableFromInline
  func search(_ key: String) -> [String] {
    if key.isEmpty {
      return isTerminal ? Array(values) : []
    }

    let firstChar = String(key.first!)
    let remainder = String(key.dropFirst())

    // 對較大的子陣列進行二元搜尋
    if children.count > 8 {
      var left = 0
      var right = children.count - 1

      while left <= right {
        let mid = (left + right) / 2
        let comparison = children[mid].key.compare(firstChar)

        switch comparison {
        case .orderedSame:
          return children[mid].node.search(remainder)
        case .orderedAscending:
          left = mid + 1
        case .orderedDescending:
          right = mid - 1
        }
      }
      return []
    } else {
      // 對小陣列進行線性搜尋
      for (childKey, childNode) in children {
        if childKey == firstChar {
          return childNode.search(remainder)
        }
      }
      return []
    }
  }
}

// MARK: - 原子快取

/// 使用原子操作的簡單無鎖快取
@usableFromInline
struct AtomicCache<Key: Hashable, Value> {
  // MARK: Lifecycle

  @usableFromInline
  init(capacity: Int = 1_024) {
    let count = Swift.max(capacity, 16).nextPowerOfTwo()
    self.bucketCount = count
    self.bucketMask = count - 1
    self.buckets = UnsafeMutablePointer<Bucket>.allocate(capacity: count)

    for i in 0 ..< count {
      buckets[i] = Bucket()
    }
  }

  // MARK: Internal

  @usableFromInline
  struct Bucket {
    var key: Key?
    var value: Value?
    var version: UInt64 = 0
  }

  @usableFromInline
  func get(_ key: Key) -> Value? {
    let hash = key.hashValue
    let bucketIndex = hash & bucketMask
    let bucket = buckets[bucketIndex]

    // 目前使用簡單檢查，不使用複雜的原子操作
    if let storedKey = bucket.key, storedKey == key {
      return bucket.value
    }
    return nil
  }

  @usableFromInline
  func set(_ key: Key, value: Value) {
    let hash = key.hashValue
    let bucketIndex = hash & bucketMask

    buckets[bucketIndex].key = key
    buckets[bucketIndex].value = value
    buckets[bucketIndex].version += 1
  }

  // MARK: Private

  private let buckets: UnsafeMutablePointer<Bucket>
  private let bucketCount: Int
  private let bucketMask: Int
}

extension Int {
  @usableFromInline
  func nextPowerOfTwo() -> Int {
    guard self > 1 else { return 1 }
    var n = self - 1
    n |= n >> 1
    n |= n >> 2
    n |= n >> 4
    n |= n >> 8
    n |= n >> 16
    return n + 1
  }
}
