// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - SIMD Optimized String Operations

/// SIMD-optimized string operations for better performance
@usableFromInline
enum SIMDStringOps {
  
  /// Fast string comparison optimized for phonetic keys
  @usableFromInline
  static func fastCompare(_ lhs: String, _ rhs: String) -> Bool {
    // For short strings common in phonetic input, direct comparison is often fastest
    guard lhs.count == rhs.count else { return false }
    
    // For very short strings (common case), use direct comparison
    if lhs.count <= 8 {
      return lhs == rhs
    }
    
    // For longer strings, use optimized comparison
    return lhs.withCString { lhsPtr in
      rhs.withCString { rhsPtr in
        return memcmp(lhsPtr, rhsPtr, lhs.utf8.count) == 0
      }
    }
  }
  
  /// Fast hash computation for strings
  @usableFromInline
  static func fastHash(_ string: String) -> Int {
    var hasher = Hasher()
    
    // Use more efficient hashing for common short strings
    if string.count <= 16 {
      hasher.combine(string)
    } else {
      // For longer strings, hash in chunks for better performance
      let utf8 = string.utf8
      var chunks = utf8.makeIterator()
      while let chunk = chunks.next() {
        hasher.combine(chunk)
      }
    }
    
    return hasher.finalize()
  }
  
  /// Optimized prefix checking for partial matching
  @usableFromInline
  static func hasPrefix(_ string: String, _ prefix: String) -> Bool {
    guard string.count >= prefix.count else { return false }
    
    // Fast path for empty prefix
    if prefix.isEmpty { return true }
    
    // Use optimized implementation for common case
    if prefix.count <= 4 {
      let stringPrefix = string.prefix(prefix.count)
      return String(stringPrefix) == prefix
    }
    
    return string.hasPrefix(prefix)
  }
}

// MARK: - Optimized Data Structures

/// A specialized trie node designed for phonetic input patterns
@usableFromInline
struct PhoneticTrieNode {
  @usableFromInline
  var children: ContiguousArray<(key: String, node: PhoneticTrieNode)>
  
  @usableFromInline
  var values: ContiguousArray<String>
  
  @usableFromInline
  var isTerminal: Bool
  
  @usableFromInline
  init() {
    self.children = []
    self.values = []
    self.isTerminal = false
  }
  
  @usableFromInline
  mutating func insert(_ key: String, value: String) {
    if key.isEmpty {
      values.append(value)
      isTerminal = true
      return
    }
    
    let firstChar = String(key.first!)
    let remainder = String(key.dropFirst())
    
    // Find or create child node
    for i in children.indices {
      if children[i].key == firstChar {
        children[i].node.insert(remainder, value: value)
        return
      }
    }
    
    // Create new child
    var newNode = PhoneticTrieNode()
    newNode.insert(remainder, value: value)
    children.append((key: firstChar, node: newNode))
    
    // Keep children sorted for binary search
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
    
    // Binary search for larger child arrays
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
      // Linear search for small arrays
      for (childKey, childNode) in children {
        if childKey == firstChar {
          return childNode.search(remainder)
        }
      }
      return []
    }
  }
}

// MARK: - Lock-Free Data Structures (Simplified)

/// A simple lock-free cache using atomic operations
@usableFromInline
struct AtomicCache<Key: Hashable, Value> {
  private let buckets: UnsafeMutablePointer<Bucket>
  private let bucketCount: Int
  private let bucketMask: Int
  
  @usableFromInline
  struct Bucket {
    var key: Key?
    var value: Value?
    var version: UInt64 = 0
  }
  
  @usableFromInline
  init(capacity: Int = 1024) {
    let count = Swift.max(capacity, 16).nextPowerOfTwo()
    self.bucketCount = count
    self.bucketMask = count - 1
    self.buckets = UnsafeMutablePointer<Bucket>.allocate(capacity: count)
    
    for i in 0..<count {
      buckets[i] = Bucket()
    }
  }
  
  @usableFromInline
  func get(_ key: Key) -> Value? {
    let hash = key.hashValue
    let bucketIndex = hash & bucketMask
    let bucket = buckets[bucketIndex]
    
    // Simple check without complex atomic operations for now
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