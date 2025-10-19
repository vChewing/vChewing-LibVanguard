// (c) 2025 and onwards The vChewing Project (LGPL v3.0 License or later).
// ====================
// This code is released under the SPDX-License-Identifier: `LGPL-3.0-or-later`.

import Foundation

// MARK: - CandidateContextMenuAction

public enum CandidateContextMenuAction: Int, Sendable {
  case toBoost
  case toNerf
  case toFilter
}

// MARK: - CandidateWindowOrientation

public enum CandidateWindowOrientation: Int, Sendable {
  case horizontal
  case vertical
}

// MARK: - CandidateFlipActionDirection

public enum CandidateFlipActionDirection: Int, Sendable {
  case next = 1
  case previous = -1
}

// MARK: - CtlCandidateDelegateCore

public protocol CtlCandidateDelegateCore: AnyObject {
  func candidateController() -> CtlCandidateProtocolCore?
  func candidatePairs(conv: Bool) -> [(keyArray: [String], value: String)]
  func candidatePairSelectionConfirmed(at index: Int)
  func candidatePairHighlightChanged(at index: Int)
  func candidatePairContextMenuActionTriggered(
    at index: Int, action: CandidateContextMenuAction
  )
  func candidatePairManipulated(at index: Int, action: CandidateContextMenuAction)
  func candidateToolTip(shortened: Bool) -> String
  func resetCandidateWindowOrigin()
  func checkIsMacroTokenResult(_ index: Int) -> Bool
  @discardableResult
  func reverseLookup(for value: String) -> [String]
  var selectionKeys: String { get }
  var isVerticalTyping: Bool { get }
  var isCandidateState: Bool { get }
  var showCodePointForCurrentCandidate: Bool { get }
  var shouldAutoExpandCandidates: Bool { get }
  var isCandidateContextMenuEnabled: Bool { get }
  var showReverseLookupResult: Bool { get }
}

// MARK: - CtlCandidateProtocolCore

public protocol CtlCandidateProtocolCore {
  var tooltip: String { get set }
  var reverseLookupResult: [String] { get set }
  var locale: String { get set }
  var delegate: CtlCandidateDelegateCore? { get set }
  var highlightedIndex: Int { get set }
  var visible: Bool { get set }
  var windowTopLeftPoint: CGPoint { get set }
  var useLangIdentifier: Bool { get set }
  var currentLayout: UILayoutOrientation { get set }

  func reloadData()
  func updateDisplay()
  func showNextPage() -> Bool
  func showPreviousPage() -> Bool
  func showNextLine() -> Bool
  func showPreviousLine() -> Bool
  func highlightNextCandidate() -> Bool
  func highlightPreviousCandidate() -> Bool
  func candidateIndexAtKeyLabelIndex(_: Int) -> Int?
  func set(
    windowTopLeftPoint: CGPoint,
    bottomOutOfScreenAdjustmentHeight height: Double,
    useGCD: Bool
  )
}
