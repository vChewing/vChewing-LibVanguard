// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - Performance Utilities

/// String interning pool to reduce memory allocations for frequently used strings
@usableFromInline
final class StringInternPool: @unchecked Sendable {
  @usableFromInline
  static let shared = StringInternPool()
  
  private var pool: [String: String] = [:]
  private let lock = NSLock()
  
  @usableFromInline
  func intern(_ string: String) -> String {
    lock.lock()
    defer { lock.unlock() }
    
    if let interned = pool[string] {
      return interned
    }
    
    pool[string] = string
    return string
  }
  
  @usableFromInline
  func clear() {
    lock.lock()
    defer { lock.unlock() }
    pool.removeAll(keepingCapacity: true)
  }
}

/// Object pool for frequently allocated temporary objects
@usableFromInline
final class ObjectPool<T> {
  private var objects: ContiguousArray<T> = []
  private let createObject: () -> T
  private let resetObject: (T) -> Void
  private let lock = NSLock()
  
  @usableFromInline
  init(createObject: @escaping () -> T, resetObject: @escaping (T) -> Void = { _ in }) {
    self.createObject = createObject
    self.resetObject = resetObject
  }
  
  @usableFromInline
  func borrow() -> T {
    lock.lock()
    defer { lock.unlock() }
    
    if let object = objects.popLast() {
      return object
    }
    return createObject()
  }
  
  @usableFromInline
  func returnObject(_ object: T) {
    lock.lock()
    defer { lock.unlock() }
    
    resetObject(object)
    objects.append(object)
  }
}

/// Cache for frequently computed string operations
@usableFromInline
final class StringOperationCache: @unchecked Sendable {
  @usableFromInline
  static let shared = StringOperationCache()
  
  private var splitCache: [String: [String]] = [:]
  private var joinCache: [String: String] = [:]
  private let lock = NSLock()
  private let maxCacheSize = 1000
  
  @usableFromInline
  func getCachedSplit(_ string: String, separator: Character) -> [String] {
    let key = "\(string)|\(separator)"
    
    lock.lock()
    defer { lock.unlock() }
    
    if let cached = splitCache[key] {
      return cached
    }
    
    let result = string.split(separator: separator).map(String.init)
    
    // Prevent unbounded cache growth
    if splitCache.count < maxCacheSize {
      splitCache[key] = result
    }
    
    return result
  }
  
  @usableFromInline
  func getCachedJoin(_ strings: [String], separator: String) -> String {
    let key = strings.joined(separator: "|") + "|\(separator)"
    
    lock.lock()
    defer { lock.unlock() }
    
    if let cached = joinCache[key] {
      return cached
    }
    
    let result = strings.joined(separator: separator)
    
    // Prevent unbounded cache growth
    if joinCache.count < maxCacheSize {
      joinCache[key] = result
    }
    
    return result
  }
  
  @usableFromInline
  func clear() {
    lock.lock()
    defer { lock.unlock() }
    splitCache.removeAll(keepingCapacity: true)
    joinCache.removeAll(keepingCapacity: true)
  }
}