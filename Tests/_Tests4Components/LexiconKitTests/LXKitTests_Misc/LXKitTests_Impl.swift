// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation
@testable import LexiconKit
import SharedTrieTestDataBundle
import TrieKit

extension FactoryTrieDBType {
  func getFactorySQLiteDemoFilePath4Tests() -> String {
    Bundle.lexiconTestData.url(forResource: sqlFileNameStem, withExtension: "sqlite")?.path ?? ""
  }

  func getFactoryPlistDemoFileURL4Tests() -> URL? {
    Bundle.lexiconTestData.url(forResource: sqlFileNameStem, withExtension: "plist")
  }

  func getFactoryTextMapDemoFileURL4Tests() -> URL? {
    let ext = switch self {
    case .revLookup: "revlookup"
    case .typing: "txtMap"
    }
    return Bundle.lexiconTestData.url(forResource: sqlFileNameStem, withExtension: ext)
  }

  // MARK: Internal

  internal var sqlFileNameStem: String {
    switch self {
    case .revLookup: "FactoryDemoDict4RevLookup"
    case .typing: "FactoryDemoDict4Typing"
    }
  }
}
