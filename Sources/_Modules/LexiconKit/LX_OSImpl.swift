// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

internal func isAppleSilicon() -> Bool {
  #if canImport(Darwin)
    #if os(macOS) || targetEnvironment(macCatalyst) || targetEnvironment(simulator)
      // 檢查系統架構
      var sysInfo = utsname()
      uname(&sysInfo)

      let machine = withUnsafePointer(to: &sysInfo.machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: 1) {
          String(cString: $0)
        }
      }

      // Apple Silicon 通常以 "arm64" 開頭
      return machine.contains("arm64")
    #else
      // 非 macOS 系統（如 iOS）默認使用 ARM
      #if arch(arm64)
        return true
      #else
        return false
      #endif
    #endif
  #else
    return false
  #endif
}

// MARK: - ArrayBuilder

@resultBuilder
enum ArrayBuilder<Element> {
  static func buildEither(first elements: [Element]) -> [Element] {
    elements
  }

  static func buildEither(second elements: [Element]) -> [Element] {
    elements
  }

  static func buildOptional(_ elements: [Element]?) -> [Element] {
    elements ?? []
  }

  static func buildExpression(_ expression: Element) -> [Element] {
    [expression]
  }

  static func buildExpression(_: ()) -> [Element] {
    []
  }

  static func buildBlock(_ elements: [Element]...) -> [Element] {
    elements.flatMap { $0 }
  }

  static func buildArray(_ elements: [[Element]]) -> [Element] {
    Array(elements.joined())
  }
}
