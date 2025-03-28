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

// MARK: - CandidateProxyProtocol

public protocol CandidateProxyProtocol {
  var selectionKeys: String { get }
  var isVerticalTyping: Bool { get }
  var isCandidateState: Bool { get }
  var showCodePointForCurrentCandidate: Bool { get }
  var shouldAutoExpandCandidates: Bool { get }
  var isCandidateContextMenuEnabled: Bool { get }
  var showReverseLookupResult: Bool { get }
  var clientAccentColorObj: AnyObject? { get }

  func candidatePairs(conv: Bool) -> [(keyArray: [String], value: String)]
  func candidatePairSelectionConfirmed(at index: Int)
  func candidatePairHighlightChanged(at index: Int)
  func candidatePairRightClicked(at index: Int, action: CandidateContextMenuAction)
  func candidateTooltip(shortened: Bool) -> String
  func resetCandidateWindowOrigin()
  func buzzOnFlipActionBorderEvent()

  @discardableResult
  func reverseLookup(for value: String) -> [String]
}

// MARK: - CtlCandidateProtocol

public protocol CtlCandidateProtocol {
  var tooltip: String { get set }
  var reverseLookupResult: [String] { get set }
  var locale: String { get set }
  var currentLayout: CandidateWindowOrientation { get set }
  var proxy: CandidateProxyProtocol? { get set }
  var highlightedIndex: Int { get set }
  var visible: Bool { get set }
  var windowTopLeftPoint: CGPoint { get set }
  var candidateFontObj: AnyObject? { get set }
  var useLangIdentifier: Bool { get set }

  init(_ layout: CandidateWindowOrientation)
  func reloadData()
  func updateDisplay()
  func flipPage(_ direction: CandidateFlipActionDirection)
  func flipLine(_ direction: CandidateFlipActionDirection)
  func flipHighlightedCandidate(_ direction: CandidateFlipActionDirection)
  func candidateIndexAtKeyLabelIndex(_: Int) -> Int?
  func set(
    windowTopLeftOrigin: CGPoint,
    screenBottomSafeZoneHeight height: Double,
    useGCD: Bool
  )
}
