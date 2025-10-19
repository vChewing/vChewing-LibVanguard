// (c) 2022 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - IMEApp

public enum IMEApp {
  // MARK: - 輸入法的當前的簡繁體中文模式

  public static var currentInputMode: Shared.InputMode {
    .init(rawValue: PrefMgr().mostRecentInputMode) ?? .imeModeNULL
  }
}
