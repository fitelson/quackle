import Foundation
import Observation
import SwiftUI

// QuackleBridge is thread-safe via bridgeQueue serialization
extension QuackleBridge: @unchecked Sendable {}

enum ActiveSheet: Identifiable {
    case blankPicker, topMoves, history, skillSlider
    var id: Self { self }
}

enum BonusType {
    case none, doubleLetter, tripleLetter, doubleWord, tripleWord
}

enum GameMode {
    case ai
    case multiplayer
}

struct TileModel: Identifiable, Equatable {
    let id = UUID()
    let letter: String
    let points: Int
    let isBlank: Bool

    static func == (lhs: TileModel, rhs: TileModel) -> Bool {
        lhs.id == rhs.id
    }

    static let tilePoints: [String: Int] = [
        "A": 1, "B": 3, "C": 3, "D": 2, "E": 1, "F": 4, "G": 2, "H": 4,
        "I": 1, "J": 8, "K": 5, "L": 1, "M": 3, "N": 1, "O": 1, "P": 3,
        "Q": 10, "R": 1, "S": 1, "T": 1, "U": 1, "V": 4, "W": 4, "X": 8,
        "Y": 4, "Z": 10, "?": 0
    ]
}

struct SquareModel {
    let letter: String?
    let isBlank: Bool
    let bonus: BonusType
}

struct MoveModel: Identifiable {
    let id = UUID()
    let description: String
    let score: Int
    let equity: Double
}

struct PlayerModel {
    let name: String
    let score: Int
}

enum DragSource: Equatable {
    case rack(tileId: UUID)
    case board(row: Int, col: Int)
}

@MainActor
@Observable
class QuackleEngine {
    var board: [[SquareModel]] = []
    var rack: [TileModel] = []
    var players: [PlayerModel] = []
    var currentPlayerName: String = ""
    var isHumanTurn: Bool = true
    var isGameOver: Bool = false
    var tilesInBag: Int = 100
    var opponentTileCount: Int = 7
    var turnNumber: Int = 0
    var errorMessage: String? = nil
    var isInitialized: Bool = false
    var loadingProgress: Double = 0.0
    var loadingStatus: String = ""

    // Tile placement state
    var tentativePlacements: [TilePlacement] = []
    var availableRack: [TileModel] = []  // rack minus placed tiles
    var isTentativeMoveValid: Bool = false  // real-time validation
    var tentativeMoveScore: Int = 0  // score preview for valid tentative move
    var tentativeMoveString: String? = nil  // the built move string
    var activeSheet: ActiveSheet? = nil  // single sheet presentation
    var pendingBlankRow: Int = -1
    var pendingBlankCol: Int = -1

    // Drag and drop state
    var activeDragSource: DragSource? = nil
    var activeDragLetter: String = ""
    var activeDragIsBlank: Bool = false
    var activeDragPoints: Int = 0
    var activeDragLocation: CGPoint = .zero
    var boardGridOrigin: CGPoint = .zero
    var boardSquareSizeForDrag: CGFloat = 0
    var boardGeoFrame: CGRect = .zero
    var boardZoomScale: CGFloat = 1.0
    var boardZoomAnchor: UnitPoint = .center
    var boardPanOffset: CGSize = .zero
    var rackFrame: CGRect = .zero
    var rackReorderIndex: Int? = nil  // live preview index during rack drag
    var isExchangeMode: Bool = false  // exchange tile selection mode
    var exchangeSelectedIds: Set<UUID> = []  // rack tiles selected for exchange
    var skillLevel: Double = 0.5  // 0=low, 0.5=medium, 1=high
    var moveHistory: [MoveHistoryEntry] = []
    var topMoves: [MoveModel] = []
    var humanFirst: Bool = true
    var showModeSelection: Bool = false

    // Multiplayer state
    var gameMode: GameMode = .ai
    var localPlayerIndex: Int = 0
    var multiplayerPlayer1ID: String = ""
    var multiplayerPlayer2ID: String = ""
    var multiplayerMatchID: String = ""
    var consecutiveScorelessTurns: Int = 0
    var onMultiplayerMoveCommitted: (() -> Void)?
    /// Win/loss/tie message shown when a multiplayer game ends (nil otherwise).
    var gameResultMessage: String?


    var isLocalPlayerTurn: Bool = true

    // AI move animation state
    var isAnimatingAIMove: Bool = false
    var aiAnimPhase: Int = 0  // 0=face-down at rack, 1=face-up at rack, 2=face-up flying to board
    var aiAnimTiles: [AIAnimTile] = []
    var opponentRackOrigin: CGPoint = .zero  // top-left of opponent rack in "game" space
    private var animationTask: Task<Void, Never>?
    /// Tracks the in-flight AI compute/trigger so a game (re)start can invalidate it.
    private var aiTriggerTask: Task<Void, Never>?
    /// True while an AI compute is logically in flight (gates saveGameState; cleared by
    /// cancelAIWork on supersession so a discarded compute doesn't block saves).
    private var aiComputeInFlight = false
    /// True only while `haveComputerPlay` is ACTUALLY executing on the bridge queue
    /// (set/cleared around the queue dispatch, NOT reset by cancelAIWork). withBridgeSync
    /// uses this to decide whether it must serialize.
    private var bridgeQueueBusy = false
    /// Bumped on every game (re)start/restore so a stale AI result is discarded.
    private var aiGeneration = 0

    private let bridge: QuackleBridge = QuackleBridge.shared()
    private let bridgeQueue = DispatchQueue(label: "com.bef.quackle.bridge")

    /// Run a destructive bridge mutation (new game / restore — which `delete _game`).
    /// If a `haveComputerPlay` is actually on the queue, serialize behind it via
    /// `bridgeQueue.sync` so we can't free `_game` mid-compute (use-after-free).
    /// Otherwise run directly — the queue is idle, so there's nothing to race, and we
    /// avoid `DispatchQueue.sync` from a Swift-concurrency context (unsafeForcedSync).
    /// Callers always `cancelAIWork()` first, which bumps the generation so a not-yet-
    /// dispatched compute bails instead of running against the new `_game`.
    private func withBridgeSync(_ body: @escaping () -> Void) {
        if bridgeQueueBusy {
            bridgeQueue.sync(execute: body)
        } else {
            body()
        }
    }

    /// Clear transient interaction state that must not survive a state reload (e.g. an
    /// opponent move arriving via poll while you were exchanging/dragging/picking a blank).
    /// Cancels an in-flight hypothetical drag cleanly rather than letting endDrag drop it
    /// against rebuilt (new-UUID) rack tiles.
    private func resetTransientInteractionState() {
        isExchangeMode = false
        exchangeSelectedIds = []
        activeDragSource = nil
        rackReorderIndex = nil
        if activeSheet == .blankPicker { activeSheet = nil }
        pendingBlankRow = -1
        pendingBlankCol = -1
    }

    /// Invalidate any in-flight/pending AI work; call at every game (re)start/restore.
    private func cancelAIWork() {
        aiGeneration &+= 1
        aiTriggerTask?.cancel()
        aiTriggerTask = nil
        animationTask?.cancel()
        animationTask = nil
        // Cancelling animationTask orphans its cleanup, so reset the animation DISPLAY
        // state here. Otherwise isAnimatingAIMove stays true with stale aiAnimTiles, and
        // BoardView keeps hiding those squares (isAnimatingTarget) — tiles "disappear"
        // when you switch games mid-AI-animation and come back.
        isAnimatingAIMove = false
        aiAnimTiles = []
        aiAnimPhase = 0
        // The discarded AI Task's continuation would normally reset this, but it can't
        // run until the current synchronous MainActor call returns — and callers run a
        // withBridgeSync (draining the queue, so _game is stable) right after. Reset now
        // so the new game's first saveGameState isn't skipped.
        aiComputeInFlight = false
    }

    private var canCommitCurrentTurn: Bool {
        guard !isGameOver else { return false }
        switch gameMode {
        case .ai: return isHumanTurn
        case .multiplayer: return isLocalPlayerTurn
        }
    }

    func initialize() {
        guard let dataPath = Bundle.main.path(forResource: "data", ofType: nil) else {
            errorMessage = "Could not find data directory in bundle"
            return
        }

        // Clear saved AI game if app version changed (avoids stale state)
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let savedBuild = UserDefaults.standard.string(forKey: "lastAppBuild") ?? ""
        if currentBuild != savedBuild {
            UserDefaults.standard.removeObject(forKey: "savedGameState")
            UserDefaults.standard.set(currentBuild, forKey: "lastAppBuild")
        }

        loadingStatus = "Setting up engine..."
        loadingProgress = 0.0

        let bridge = self.bridge
        let lexicon = "csw19"
        let queue = self.bridgeQueue

        Task {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                queue.async { bridge.initStage1Setup(withDataPath: dataPath); c.resume() }
            }
            self.loadingProgress = 0.25
            self.loadingStatus = "Loading dictionary..."

            let dawgOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                queue.async { c.resume(returning: bridge.initStage2LoadDawg(lexicon)) }
            }
            guard dawgOK else {
                self.errorMessage = "Failed to load dictionary"
                return
            }
            self.loadingProgress = 0.50
            self.loadingStatus = "Loading word graph..."

            let gaddagOK = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                queue.async { c.resume(returning: bridge.initStage3LoadGaddag(lexicon)) }
            }
            if !gaddagOK {
                print("[QuackleEngine] Warning: GADDAG not loaded — move generation will be slower")
            }
            self.loadingProgress = 0.75
            self.loadingStatus = "Loading strategy..."

            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                queue.async { bridge.initStage4LoadStrategy(lexicon); c.resume() }
            }
            self.loadingProgress = 0.90
            self.loadingStatus = "Starting game..."

            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                queue.async { bridge.initStageFinalize(); c.resume() }
            }
            self.loadingProgress = 1.0
            self.isInitialized = true
            // If a multiplayer game was already restored during init (e.g. an
            // inbound turn event that waited on isInitialized), don't clobber it
            // with a saved AI game / mode selection.
            if self.gameMode != .multiplayer {
                if !self.loadSavedGame() {
                    self.showModeSelection = true
                }
            }
        }
    }

    func startNewGame() {
        UserDefaults.standard.removeObject(forKey: "savedGameState")
        // Invalidate any in-flight AI work and serialize the destructive bridge
        // mutation behind it (it deletes _game) so it can't run while a previous
        // haveComputerPlay is still using the old _game on the bridge queue.
        cancelAIWork()
        resetTransientInteractionState()
        withBridgeSync { self.bridge.startNewGame(withHumanName: "You", aiMeanLoss: self.skillMeanLoss, aiStdDev: self.skillStdDev) }
        gameMode = .ai
        showModeSelection = false
        tentativePlacements = []
        moveHistory = []
        errorMessage = nil
        gameResultMessage = nil  // never show a stale multiplayer verdict on an AI game
        isAnimatingAIMove = false
        aiAnimTiles = []
        aiAnimPhase = 0
        consecutiveScorelessTurns = 0
        // NOTE: Do NOT clear onMultiplayerMoveCommitted here — it must survive
        // across game mode switches so multiplayer moves always get submitted.
        refreshState()
        if !isHumanTurn {
            let gen = aiGeneration
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard gen == self.aiGeneration else { return }  // a newer game started
                self.triggerAIIfNeeded()
            }
        }
    }

    // MARK: - Drag and Drop

    func startDragFromRack(tile: TileModel) {
        // Allow on your own turn, or in multiplayer off-turn for hypothetical moves —
        // but never on a finished board.
        let canDrag = !isGameOver && (gameMode == .multiplayer || isLocalPlayerTurn)
        guard !isAnimatingAIMove, canDrag else { return }
        activeDragSource = .rack(tileId: tile.id)
        activeDragLetter = tile.isBlank ? "?" : tile.letter
        activeDragIsBlank = tile.isBlank
        activeDragPoints = tile.points
        if let idx = availableRack.firstIndex(where: { $0.id == tile.id }) {
            rackReorderIndex = idx
        }
    }

    func startDragFromBoard(row: Int, col: Int) {
        // Allow on your own turn, or in multiplayer off-turn for hypothetical moves —
        // but never on a finished board.
        let canDrag = !isGameOver && (gameMode == .multiplayer || isLocalPlayerTurn)
        guard !isAnimatingAIMove, canDrag else { return }
        guard let placement = tentativeLetterAt(row: row, col: col) else { return }
        activeDragSource = .board(row: row, col: col)
        activeDragLetter = placement.isBlank ? placement.letter.lowercased() : placement.letter
        activeDragIsBlank = placement.isBlank
        activeDragPoints = placement.isBlank ? 0 : (TileModel.tilePoints[placement.letter.uppercased()] ?? 0)
    }

    func moveRackTile(tileId: UUID, toVisualIndex: Int) {
        var visual = availableRack
        guard let fromIdx = visual.firstIndex(where: { $0.id == tileId }) else { return }
        let toIdx = max(0, min(toVisualIndex, visual.count - 1))
        if fromIdx == toIdx { return }

        let tile = visual.remove(at: fromIdx)
        visual.insert(tile, at: toIdx)

        // Rebuild rack: available tiles get new order, unavailable tiles keep position
        let availableIds = Set(visual.map { $0.id })
        var newRack: [TileModel] = []
        var iter = visual.makeIterator()
        for oldTile in rack {
            if availableIds.contains(oldTile.id) {
                if let next = iter.next() {
                    newRack.append(next)
                }
            } else {
                newRack.append(oldTile)
            }
        }

        rack = newRack
        updateAvailableRack()
    }

    func updateDragLocation(_ location: CGPoint) {
        activeDragLocation = location
        if case .rack = activeDragSource {
            updateRackReorderIndex()
        }
    }

    private func updateRackReorderIndex() {
        let expandedFrame = rackFrame.insetBy(dx: -30, dy: -30)
        if expandedFrame.contains(activeDragLocation) {
            let tileSlot: CGFloat = 47
            let relX = activeDragLocation.x - rackFrame.minX
            let index = max(0, min(Int(relX / tileSlot), availableRack.count - 1))
            if index != rackReorderIndex {
                withAnimation(.easeInOut(duration: 0.15)) {
                    rackReorderIndex = index
                }
            }
        } else if rackReorderIndex != nil {
            withAnimation(.easeInOut(duration: 0.15)) {
                rackReorderIndex = nil
            }
        }
    }

    func endDrag() {
        guard let source = activeDragSource else { return }
        let finalReorderIndex = rackReorderIndex
        rackReorderIndex = nil
        defer { activeDragSource = nil }

        // Transform drag location from visual space back to unzoomed board space
        var point = activeDragLocation
        point.x -= boardPanOffset.width
        point.y -= boardPanOffset.height
        if boardZoomScale != 1.0 {
            let anchorX = boardGeoFrame.minX + boardZoomAnchor.x * boardGeoFrame.width
            let anchorY = boardGeoFrame.minY + boardZoomAnchor.y * boardGeoFrame.height
            point.x = (point.x - anchorX) / boardZoomScale + anchorX
            point.y = (point.y - anchorY) / boardZoomScale + anchorY
        }

        let step = boardSquareSizeForDrag + 0.5
        let relX = point.x - boardGridOrigin.x
        let relY = point.y - boardGridOrigin.y
        // Int() truncates toward zero, so a drop just above/left of the grid would map
        // to row/col 0 (landing on A1) — treat negatives as off-board instead.
        let col = relX >= 0 ? Int(relX / step) : -1
        let row = relY >= 0 ? Int(relY / step) : -1

        let onBoard = row >= 0 && row < board.count &&
                      col >= 0 && col < (board.first?.count ?? 0)
        let validTarget = onBoard &&
                          board[row][col].letter == nil &&
                          tentativeLetterAt(row: row, col: col) == nil

        switch source {
        case .rack(let tileId):
            if validTarget {
                guard let tile = availableRack.first(where: { $0.id == tileId }) else { return }
                if tile.isBlank {
                    pendingBlankRow = row
                    pendingBlankCol = col
                    activeSheet = .blankPicker
                } else {
                    placeTile(letter: tile.letter, isBlank: false, atRow: row, col: col)
                }
            } else if let targetIndex = finalReorderIndex, availableRack.count > 1 {
                moveRackTile(tileId: tileId, toVisualIndex: targetIndex)
            }

        case .board(let fromRow, let fromCol):
            if validTarget {
                moveTentativeTile(fromRow: fromRow, fromCol: fromCol, toRow: row, toCol: col)
            } else if !onBoard {
                // Dropped outside board — return tile to rack
                removeTentativeTile(atRow: fromRow, col: fromCol)
            }
        }
    }

    func placeBlankAs(letter: String) {
        // A poll/turn-event reload can fire resetTransientInteractionState (pendingBlank
        // → -1) while the picker is dismissing; an in-flight button tap must not then
        // place at (-1,-1).
        guard pendingBlankRow >= 0, pendingBlankCol >= 0 else {
            activeSheet = nil
            return
        }
        placeTile(letter: letter, isBlank: true, atRow: pendingBlankRow, col: pendingBlankCol)
        activeSheet = nil
    }

    func placeTile(letter: String, isBlank: Bool, atRow row: Int, col: Int) {
        // Bounds-check defensively — callers (blank picker, drag) can race a board reload.
        guard row >= 0, row < board.count, col >= 0, col < (board.first?.count ?? 0) else { return }
        // Don't place on occupied squares
        if board[row][col].letter != nil { return }
        // Don't place on already-tentatively-placed squares
        if tentativePlacements.contains(where: { $0.row == row && $0.col == col }) { return }

        tentativePlacements.append(TilePlacement(row: row, col: col, letter: letter, isBlank: isBlank))
        updateAvailableRack()
        validateTentativeMove()
    }

    func removeTentativeTile(atRow row: Int, col: Int) {
        tentativePlacements.removeAll { $0.row == row && $0.col == col }
        updateAvailableRack()
        validateTentativeMove()
    }

    func clearTentativePlacements() {
        tentativePlacements = []
        updateAvailableRack()
        isTentativeMoveValid = false
        tentativeMoveScore = 0
        tentativeMoveString = nil
    }

    private func moveTentativeTile(fromRow: Int, fromCol: Int, toRow: Int, toCol: Int) {
        guard let idx = tentativePlacements.firstIndex(where: { $0.row == fromRow && $0.col == fromCol }) else { return }
        if board[toRow][toCol].letter != nil { return }
        if tentativePlacements.contains(where: { $0.row == toRow && $0.col == toCol }) { return }

        let old = tentativePlacements[idx]
        tentativePlacements[idx] = TilePlacement(row: toRow, col: toCol, letter: old.letter, isBlank: old.isBlank)
        validateTentativeMove()
    }

    private func validateTentativeMove() {
        guard !tentativePlacements.isEmpty else {
            isTentativeMoveValid = false
            tentativeMoveScore = 0
            tentativeMoveString = nil
            return
        }

        if let moveStr = buildMoveString() {
            tentativeMoveString = moveStr
            let validity = bridge.validateMove(moveStr)
            let isHypothetical = gameMode == .multiplayer && !isLocalPlayerTurn
            if isHypothetical {
                // Ignore rack check (bit 0x0001) for hypothetical moves
                isTentativeMoveValid = (validity & ~0x0001) == 0
                tentativeMoveScore = isTentativeMoveValid ? Int(bridge.scoreMoveStringIgnoringRack(moveStr)) : 0
            } else {
                isTentativeMoveValid = (validity == 0)
                tentativeMoveScore = isTentativeMoveValid ? Int(bridge.scoreMove(moveStr)) : 0
            }
            print("[Validate] '\(moveStr)' -> validity=\(validity) valid=\(isTentativeMoveValid) score=\(tentativeMoveScore) hypothetical=\(isHypothetical)")
        } else {
            tentativeMoveString = nil
            isTentativeMoveValid = false
            tentativeMoveScore = 0
            print("[Validate] Could not build move string from \(tentativePlacements.count) tiles")
        }
    }

    func tentativeLetterAt(row: Int, col: Int) -> TilePlacement? {
        tentativePlacements.first { $0.row == row && $0.col == col }
    }

    func commitTentativeMove() {
        guard !tentativePlacements.isEmpty else { return }
        errorMessage = nil
        guard canCommitCurrentTurn else {
            errorMessage = "It is not your turn"
            return
        }

        guard let moveString = buildMoveString() else {
            errorMessage = "Invalid tile placement — tiles must be in a line"
            return
        }

        print("[QuackleEngine] Committing move: \(moveString)")

        // Defer commit to avoid SwiftUI mutation during render
        Task {
            let committed = self.bridge.commitMove(moveString)
            if committed {
                self.tentativePlacements = []
                // Read the scoreless count back from the engine (authoritative; a
                // 0-point place move still counts as scoreless there) instead of
                // assuming a place move always resets it.
                self.consecutiveScorelessTurns = Int(self.bridge.scorelessTurns())
                self.refreshState()
                // Accumulate history for BOTH modes (the bridge only holds moves since
                // the last restore, so a full-replace would lose pre-restore history).
                self.appendLatestMoveToHistory()
                switch self.gameMode {
                case .multiplayer:
                    self.onMultiplayerMoveCommitted?()
                case .ai:
                    self.triggerAIIfNeeded()
                }
            } else {
                self.errorMessage = "Invalid move: \(moveString)"
            }
        }
    }

    private func buildMoveString() -> String? {
        guard !tentativePlacements.isEmpty else { return nil }

        let sorted = tentativePlacements.sorted { a, b in
            if a.row == b.row { return a.col < b.col }
            return a.row < b.row
        }

        // Determine direction
        let horizontal: Bool
        if sorted.count == 1 {
            // Single tile: default to horizontal
            horizontal = true
        } else {
            let sameRow = sorted.allSatisfy { $0.row == sorted[0].row }
            let sameCol = sorted.allSatisfy { $0.col == sorted[0].col }
            if sameRow { horizontal = true }
            else if sameCol { horizontal = false }
            else { return nil } // tiles not in a line
        }

        // Find the full extent of the word (including board tiles between placements)
        let startRow: Int
        let startCol: Int

        if horizontal {
            let row = sorted[0].row
            let minCol = sorted.map { $0.col }.min()!
            let maxCol = sorted.map { $0.col }.max()!

            // Extend left to include adjacent board tiles
            var sc = minCol
            while sc > 0 && board[row][sc - 1].letter != nil { sc -= 1 }
            startRow = row
            startCol = sc

            // Extend right
            var ec = maxCol
            while ec < board[0].count - 1 && board[row][ec + 1].letter != nil { ec += 1 }

            // Build word
            var word = ""
            for c in sc...ec {
                let matchRow = row
                let matchCol = c
                if let placement = tentativePlacements.first(where: { $0.row == matchRow && $0.col == matchCol }) {
                    // Blank tiles use lowercase
                    word += placement.isBlank ? placement.letter.lowercased() : placement.letter
                } else if board[row][c].letter != nil {
                    // Already on board: use played-through marker
                    word += "."
                } else {
                    return nil // gap in the word
                }
            }

            // Position string: row (1-indexed) + column letter, e.g. "8H"
            guard let scalar = UnicodeScalar(65 + startCol) else { return nil }
            let colLetter = String(scalar)
            let posString = "\(startRow + 1)\(colLetter)"
            return "\(posString) \(word)"

        } else {
            let col = sorted[0].col
            let minRow = sorted.map { $0.row }.min()!
            let maxRow = sorted.map { $0.row }.max()!

            // Extend up
            var sr = minRow
            while sr > 0 && board[sr - 1][col].letter != nil { sr -= 1 }
            startRow = sr
            startCol = col

            // Extend down
            var er = maxRow
            while er < board.count - 1 && board[er + 1][col].letter != nil { er += 1 }

            // Build word
            var word = ""
            for r in sr...er {
                let matchRow = r
                let matchCol = col
                if let placement = tentativePlacements.first(where: { $0.row == matchRow && $0.col == matchCol }) {
                    word += placement.isBlank ? placement.letter.lowercased() : placement.letter
                } else if board[r][col].letter != nil {
                    word += "."
                } else {
                    return nil
                }
            }

            // Vertical: column letter + row, e.g. "H8"
            guard let scalar = UnicodeScalar(65 + startCol) else { return nil }
            let colLetter = String(scalar)
            let posString = "\(colLetter)\(startRow + 1)"
            return "\(posString) \(word)"
        }
    }

    private func updateAvailableRack() {
        var remaining = rack
        for placement in tentativePlacements {
            if let idx = remaining.firstIndex(where: {
                (placement.isBlank && $0.isBlank) ||
                (!placement.isBlank && $0.letter == placement.letter && !$0.isBlank)
            }) {
                remaining.remove(at: idx)
            }
        }
        availableRack = remaining
    }

    // MARK: - Skill Level

    // Maps skillLevel (0-1) to NormalPlayer parameters
    // Low (0): δ=20, σ=8 — loses ~20 points/turn, very erratic
    // Medium (0.5): δ=10, σ=6 — loses ~10 points/turn
    // High (1): δ=2, σ=2 — near-perfect play
    var skillMeanLoss: Double { skillCurve(low: 20.0, medium: 10.0, high: 2.0) }
    var skillStdDev: Double { skillCurve(low: 8.0, medium: 6.0, high: 2.0) }

    private func skillCurve(low: Double, medium: Double, high: Double) -> Double {
        let clamped = min(max(skillLevel, 0.0), 1.0)
        if clamped <= 0.5 {
            return low + ((medium - low) * (clamped / 0.5))
        }
        return medium + ((high - medium) * ((clamped - 0.5) / 0.5))
    }

    var skillLabel: String {
        if skillLevel < 0.25 { return "Low" }
        if skillLevel < 0.75 { return "Medium" }
        return "High"
    }

    // MARK: - History

    /// Read the bridge's history (which only has moves since last restore)
    /// and append any new entries to the accumulated moveHistory. Used by BOTH
    /// AI and multiplayer modes — a full-replace would lose pre-restore history.
    private func appendLatestMoveToHistory() {
        let entries = bridge.moveHistory()
        let numPlayers = Int(bridge.numberOfPlayers())
        for entry in entries {
            let idx = Int(entry.playerIndex)
            // Attribute the running total by player INDEX (name can collide). Fall
            // back to name only for legacy entries lacking a valid index.
            var totalScore = Int(entry.totalScore)
            if idx >= 0 && idx < numPlayers {
                totalScore = Int(bridge.score(forPlayerIndex: Int32(idx)))
            } else {
                for i in 0..<numPlayers where bridge.name(forPlayerIndex: Int32(i)) == entry.playerName {
                    totalScore = Int(bridge.score(forPlayerIndex: Int32(i)))
                    break
                }
            }
            let newEntry = MoveHistoryEntry(
                turn: Int(entry.turn),
                playerIndex: idx,
                playerName: entry.playerName,
                moveDescription: entry.moveDescription,
                score: Int(entry.score),
                totalScore: totalScore
            )
            // Dedup on (turn, playerIndex) when both indices are known; otherwise
            // fall back to (turn, playerName) for legacy entries.
            let exists = moveHistory.contains { e in
                guard e.turn == newEntry.turn else { return false }
                if e.playerIndex >= 0 && idx >= 0 { return e.playerIndex == idx }
                return e.playerName == newEntry.playerName
            }
            if !exists {
                moveHistory.append(newEntry)
            }
        }
    }

    func showMoveHistory() {
        // moveHistory is accumulated incrementally in both modes (appendLatestMoveToHistory),
        // so no full-replace refresh here — that would drop pre-restore history.
        activeSheet = .history
    }

    // MARK: - Top Moves

    func generateTopMoves() {
        topMoves = kibitz(count: 50)
        activeSheet = .topMoves
    }

    // MARK: - Shuffle

    func shuffleRack() {
        rack.shuffle()
        updateAvailableRack()
    }

    // MARK: - Exchange

    func enterExchangeMode() {
        clearTentativePlacements()
        isExchangeMode = true
        exchangeSelectedIds = []
    }

    func cancelExchange() {
        isExchangeMode = false
        exchangeSelectedIds = []
    }

    func toggleExchangeTile(_ tile: TileModel) {
        if exchangeSelectedIds.contains(tile.id) {
            exchangeSelectedIds.remove(tile.id)
        } else {
            exchangeSelectedIds.insert(tile.id)
        }
    }

    func commitExchange() {
        guard !exchangeSelectedIds.isEmpty else { return }

        // Build the exchange string from selected tiles
        var letters = ""
        for tile in rack {
            if exchangeSelectedIds.contains(tile.id) {
                letters += tile.isBlank ? "?" : tile.letter
            }
        }

        isExchangeMode = false
        exchangeSelectedIds = []
        exchangeTiles(letters)
    }

    // MARK: - Text-based moves


    func pass() {
        guard canCommitCurrentTurn else {
            errorMessage = "It is not your turn"
            return
        }
        tentativePlacements = []
        guard bridge.commitPass() else {
            errorMessage = "Couldn't pass."
            refreshState()
            return
        }
        consecutiveScorelessTurns = Int(bridge.scorelessTurns())
        refreshState()
        appendLatestMoveToHistory()
        switch gameMode {
        case .multiplayer:
            onMultiplayerMoveCommitted?()
        case .ai: triggerAIIfNeeded()
        }
    }

    func exchangeTiles(_ tiles: String) {
        guard canCommitCurrentTurn else {
            errorMessage = "It is not your turn"
            return
        }
        tentativePlacements = []
        // If the bridge refused (e.g. fewer than 7 tiles left in the bag), don't
        // advance the turn / submit an unchanged state as if a move occurred.
        guard bridge.commitExchange(withTiles: tiles) else {
            errorMessage = "Can't exchange — not enough tiles left in the bag."
            refreshState()
            return
        }
        consecutiveScorelessTurns = Int(bridge.scorelessTurns())
        refreshState()
        appendLatestMoveToHistory()
        switch gameMode {
        case .multiplayer:
            onMultiplayerMoveCommitted?()
        case .ai: triggerAIIfNeeded()
        }
    }

    // Raw percentage of bingo words the AI knows. This is intentionally
    // non-linear: 50% skill should feel intermediate, not like knowing half
    // of the entire bingo dictionary.
    // Clamp before pow: pow(negativeBase, non-integer) is NaN, which would propagate
    // into the AI gate and trap Int(round(...)) in the skill-slider readout.
    var bingoKnowledge: Double { pow(min(max(skillLevel, 0.0), 1.0), log(0.10) / log(0.5)) }

    private func triggerAIIfNeeded() {
        guard !isHumanTurn, !isGameOver, gameMode == .ai else { return }
        let bridge = self.bridge
        let queue = self.bridgeQueue
        let bingoKnowledge = self.bingoKnowledge
        let gen = aiGeneration
        aiComputeInFlight = true
        aiTriggerTask?.cancel()
        aiTriggerTask = Task {
            // Bail BEFORE enqueuing the bridge call if this task was already cancelled
            // / superseded (a new game started in the same tick) — don't even issue
            // haveComputerPlay against a game that's gone.
            guard !Task.isCancelled, gen == self.aiGeneration else {
                self.aiComputeInFlight = false
                return
            }
            self.bridgeQueueBusy = true   // a compute is now actually on the queue
            let result = await withCheckedContinuation { (c: CheckedContinuation<QBMoveInfo?, Never>) in
                queue.async { c.resume(returning: bridge.haveComputerPlay(withBingoKnowledge: bingoKnowledge)) }
            }
            self.bridgeQueueBusy = false  // queue work done (resume runs after it returns)
            self.aiComputeInFlight = false
            // Discard a stale result: a new game/restore (or cancellation) happened
            // while the AI was thinking, so this move belongs to a game that's gone.
            guard !Task.isCancelled, gen == self.aiGeneration else { return }
            if let result, result.moveType == 0, !result.placedTiles.isEmpty {
                self.animateAIMove(tiles: result.placedTiles)
            } else {
                self.refreshState()
            }
            // The AI's move is already committed in the bridge — record it so AI
            // history accumulates and persists (mirrors the human-commit path).
            self.appendLatestMoveToHistory()
        }
    }

    func boardPositionForSquare(row: Int, col: Int) -> CGPoint {
        let step = boardSquareSizeForDrag + 0.5
        return CGPoint(
            x: boardGridOrigin.x + CGFloat(col) * step + boardSquareSizeForDrag / 2,
            y: boardGridOrigin.y + CGFloat(row) * step + boardSquareSizeForDrag / 2
        )
    }

    func rackPositionForIndex(_ index: Int, tileWidth: CGFloat, spacing: CGFloat, totalCount: Int) -> CGPoint {
        let totalWidth = CGFloat(totalCount) * tileWidth + CGFloat(totalCount - 1) * spacing
        let startX = opponentRackOrigin.x - totalWidth / 2
        return CGPoint(
            x: startX + CGFloat(index) * (tileWidth + spacing) + tileWidth / 2,
            y: opponentRackOrigin.y
        )
    }

    private func animateAIMove(tiles: [QBTileInfo]) {
        aiAnimTiles = tiles.enumerated().map { i, t in
            AIAnimTile(
                letter: t.letter,
                isBlank: t.isBlank,
                points: Int(t.points),
                targetRow: Int(t.row),
                targetCol: Int(t.col),
                rackIndex: i
            )
        }
        aiAnimPhase = 0
        isAnimatingAIMove = true

        // Phase 0: face-down at rack → Phase 1: flip face-up in rack → Phase 2: fly to board
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.4)) {
                self.aiAnimPhase = 1  // flip in place
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) {
                self.aiAnimPhase = 2  // fly to board
            }
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self.isAnimatingAIMove = false
            self.aiAnimTiles = []
            self.aiAnimPhase = 0
            self.refreshState()
        }
    }

    func kibitz(count: Int = 15) -> [MoveModel] {
        let moves = bridge.kibitzMoves(Int32(count))
        return moves.map { info in
            MoveModel(
                description: info.moveDescription,
                score: Int(info.score),
                equity: info.equity
            )
        }
    }

    private func refreshState() {
        let rows = Int(bridge.boardRows())
        let cols = Int(bridge.boardCols())
        var newBoard: [[SquareModel]] = []
        for row in 0..<rows {
            var rowData: [SquareModel] = []
            for col in 0..<cols {
                let letter = bridge.letter(atRow: Int32(row), col: Int32(col))
                let isBlank = bridge.isBlank(atRow: Int32(row), col: Int32(col))
                let isVacant = bridge.isVacant(atRow: Int32(row), col: Int32(col))
                let lm = bridge.letterMultiplier(atRow: Int32(row), col: Int32(col))
                let wm = bridge.wordMultiplier(atRow: Int32(row), col: Int32(col))

                let bonus: BonusType
                if wm == 3 { bonus = .tripleWord }
                else if wm == 2 { bonus = .doubleWord }
                else if lm == 3 { bonus = .tripleLetter }
                else if lm == 2 { bonus = .doubleLetter }
                else { bonus = .none }

                rowData.append(SquareModel(
                    letter: isVacant ? nil : letter,
                    isBlank: isBlank,
                    bonus: bonus
                ))
            }
            newBoard.append(rowData)
        }
        board = newBoard

        if gameMode == .multiplayer {
            let numPlayers = Int(bridge.numberOfPlayers())
            let over = bridge.isGameOver()
            var newPlayers: [PlayerModel] = []
            for i in 0..<numPlayers {
                // At game over show the endgame-adjusted (deadwood) score, not raw.
                let score = over ? Int(bridge.finalScore(forPlayerIndex: Int32(i)))
                                 : Int(bridge.score(forPlayerIndex: Int32(i)))
                newPlayers.append(PlayerModel(
                    name: bridge.name(forPlayerIndex: Int32(i)),
                    score: score
                ))
            }
            players = newPlayers

            currentPlayerName = bridge.currentPlayerName()
            isHumanTurn = true  // both players are human
            isGameOver = bridge.isGameOver()
            tilesInBag = Int(bridge.tilesRemainingInBag())
            turnNumber = Int(bridge.turnNumber())

            isLocalPlayerTurn = Int(bridge.currentPlayerIndex()) == localPlayerIndex
            let myIndex = Int32(localPlayerIndex)
            let opponentIndex: Int32 = localPlayerIndex == 0 ? 1 : 0
            let rackLetters = bridge.rack(forPlayerIndex: myIndex) as [String]
            rack = rackLetters.map { letter in
                TileModel(letter: letter, points: TileModel.tilePoints[letter] ?? 0, isBlank: letter == "?")
            }
            updateAvailableRack()
            opponentTileCount = (bridge.rack(forPlayerIndex: opponentIndex) as [String]).count
            // History is accumulated via appendLatestMoveToHistory() at each commit
            // (both modes), not rebuilt here — the bridge only holds moves since the
            // last restore.
        } else {
            // Determine humanFirst from the bridge (player 0's name)
            humanFirst = (bridge.name(forPlayerIndex: 0) == "You")
            let humanIndex: Int32 = humanFirst ? 0 : 1
            let aiIndex: Int32 = humanFirst ? 1 : 0

            let rackLetters = bridge.rack(forPlayerIndex: humanIndex) as [String]
            rack = rackLetters.map { letter in
                TileModel(letter: letter, points: TileModel.tilePoints[letter] ?? 0, isBlank: letter == "?")
            }
            updateAvailableRack()

            let numPlayers = Int(bridge.numberOfPlayers())
            let over = bridge.isGameOver()
            var newPlayers: [PlayerModel] = []
            for i in 0..<numPlayers {
                // At game over show the endgame-adjusted (deadwood) score, not raw.
                let score = over ? Int(bridge.finalScore(forPlayerIndex: Int32(i)))
                                 : Int(bridge.score(forPlayerIndex: Int32(i)))
                newPlayers.append(PlayerModel(
                    name: bridge.name(forPlayerIndex: Int32(i)),
                    score: score
                ))
            }
            players = newPlayers

            currentPlayerName = bridge.currentPlayerName()
            isHumanTurn = bridge.isCurrentPlayerHuman()
            isLocalPlayerTurn = isHumanTurn  // AI mode: local = human
            isGameOver = bridge.isGameOver()
            tilesInBag = Int(bridge.tilesRemainingInBag())
            opponentTileCount = (bridge.rack(forPlayerIndex: aiIndex) as [String]).count
            turnNumber = Int(bridge.turnNumber())

            // Auto-save after each state change (AI mode only)
            saveGameState()
        }
    }

    // MARK: - Save/Restore

    func saveGameState() {
        guard isInitialized, !board.isEmpty else { return }
        // Don't read _game while haveComputerPlay is mutating it on bridgeQueue. Only
        // skip during the actual compute (bridgeQueueBusy) — NOT during the post-move
        // animation phase, when _game is already stable (skipping then would drop the
        // latest move from the save).
        guard !bridgeQueueBusy else { return }

        let savedBoard: [[SavedTile?]] = board.map { row in
            row.map { square in
                // Never persist a non-letter cell. A "." (played-thru mark) must not be
                // saved as a tile — restoring it would corrupt the board.
                guard let letter = square.letter, !letter.isEmpty, letter != "." else { return nil }
                return SavedTile(letter: letter, isBlank: square.isBlank)
            }
        }

        var savedPlayers: [SavedPlayer] = []
        let numPlayers = Int(bridge.numberOfPlayers())
        let over = bridge.isGameOver()
        for i in 0..<numPlayers {
            let rackLetters = bridge.rack(forPlayerIndex: Int32(i)) as [String]
            // Persist the endgame-adjusted score at game over (the staged deadwood bonus
            // can't be reconstructed after a restore).
            let score = over ? Int(bridge.finalScore(forPlayerIndex: Int32(i)))
                             : Int(bridge.score(forPlayerIndex: Int32(i)))
            savedPlayers.append(SavedPlayer(
                name: bridge.name(forPlayerIndex: Int32(i)),
                isHuman: bridge.name(forPlayerIndex: Int32(i)) != "AI",
                score: score,
                rack: rackLetters
            ))
        }

        let savedBag = bridge.bagTiles() as [String]

        let state = SavedGameState(
            humanFirst: humanFirst,
            skillLevel: skillLevel,
            board: savedBoard,
            players: savedPlayers,
            bag: savedBag,
            isGameOver: isGameOver,
            isHumanTurn: isHumanTurn,
            scorelessTurns: Int(bridge.scorelessTurns()),
            turnNumber: Int(bridge.turnNumber()),
            moveHistory: moveHistory
        )

        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: "savedGameState")
        }
    }

    func loadSavedGame() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: "savedGameState"),
              let state = try? JSONDecoder().decode(SavedGameState.self, from: data) else {
            return false
        }

        // Tile-conservation guard: a valid English position ALWAYS has exactly 100 tiles
        // distributed across bag + board + racks. An older binary could persist a
        // split-brain save (e.g. a fresh 86-tile bag alongside a populated board and
        // played-thru "." cells). Such a save can never restore to a coherent board —
        // discard it and fall back to a new game rather than present a broken one.
        let boardTileCount = state.board.reduce(0) { acc, row in
            acc + row.reduce(0) { inner, tile in
                guard let letter = tile?.letter, !letter.isEmpty, letter != "." else { return inner }
                return inner + 1
            }
        }
        let rackTileCount = state.players.reduce(0) { $0 + $1.rack.count }
        let totalTiles = state.bag.count + boardTileCount + rackTileCount
        if totalTiles != 100 {
            print("[QuackleEngine] Saved game tile count \(totalTiles) != 100 (bag=\(state.bag.count) board=\(boardTileCount) racks=\(rackTileCount)) — discarding corrupt save")
            UserDefaults.standard.removeObject(forKey: "savedGameState")
            return false
        }

        cancelAIWork()
        resetTransientInteractionState()
        gameMode = .ai
        showModeSelection = false
        gameResultMessage = nil  // never show a stale multiplayer verdict on an AI game

        // Restore skill level before computing meanLoss/stdDev
        skillLevel = state.skillLevel

        let boardLetters: [[String]] = state.board.map { row in
            row.map { tile in tile?.letter ?? "" }
        }
        let boardBlanks: [[NSNumber]] = state.board.map { row in
            row.map { tile in NSNumber(value: tile?.isBlank ?? false) }
        }

        let scores = state.players.map { NSNumber(value: $0.score) }
        let racks = state.players.map { $0.rack }

        withBridgeSync {
            self.bridge.restoreGame(
                withHumanName: "You",
                humanFirst: state.humanFirst,
                aiMeanLoss: self.skillMeanLoss,
                aiStdDev: self.skillStdDev,
                boardLetters: boardLetters,
                boardBlanks: boardBlanks,
                playerScores: scores,
                playerRacks: racks,
                bagTiles: state.bag,
                currentPlayerIsHuman: state.isHumanTurn,
                scorelessTurns: Int32(state.scorelessTurns),
                currentTurnNumber: Int32(state.turnNumber),
                gameOver: state.isGameOver
            )
        }

        // The bridge fails closed (deletes the half-built game) if the restore threw.
        // Detect that and discard the corrupt save rather than presenting a broken board.
        guard Int(bridge.numberOfPlayers()) > 0 else {
            print("[QuackleEngine] Restore produced no game — discarding corrupt saved game")
            UserDefaults.standard.removeObject(forKey: "savedGameState")
            return false
        }

        humanFirst = state.humanFirst
        moveHistory = state.moveHistory
        consecutiveScorelessTurns = state.scorelessTurns
        tentativePlacements = []
        errorMessage = nil
        refreshState()

        // C++ gameOver is now set via the restore param above; keep the Swift flag in sync.
        if state.isGameOver {
            isGameOver = true
        }

        // If it's the AI's turn, trigger AI play
        if !isHumanTurn && !isGameOver {
            let gen = aiGeneration
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard gen == self.aiGeneration else { return }  // a newer game started
                self.triggerAIIfNeeded()
            }
        }

        print("[QuackleEngine] Restored saved game")
        return true
    }

    // MARK: - Game Switching

    func switchToAIGame() {
        if !loadSavedGame() {
            // No saved AI game — start fresh but preserve multiplayer callback
            let callback = onMultiplayerMoveCommitted
            startNewGame()
            onMultiplayerMoveCommitted = callback
        }
    }

    // MARK: - Multiplayer

    func startMultiplayerGame(
        player1Name: String,
        player2Name: String,
        localPlayerIndex: Int,
        player1GameCenterID: String,
        player2GameCenterID: String,
        matchID: String
    ) {
        // Switching from an AI game (possibly mid-AI-think) — invalidate AI work and
        // serialize the destructive bridge call behind any in-flight compute.
        cancelAIWork()
        resetTransientInteractionState()
        withBridgeSync { self.bridge.startNewTwoHumanGame(withPlayer1: player1Name, player2: player2Name) }
        gameMode = .multiplayer
        showModeSelection = false
        self.localPlayerIndex = localPlayerIndex
        multiplayerMatchID = matchID
        multiplayerPlayer1ID = player1GameCenterID
        multiplayerPlayer2ID = player2GameCenterID
        tentativePlacements = []
        moveHistory = []
        errorMessage = nil
        gameResultMessage = nil
        consecutiveScorelessTurns = 0
        isAnimatingAIMove = false
        aiAnimTiles = []
        aiAnimPhase = 0
        refreshState()
    }

    func loadMultiplayerState(_ state: MultiplayerGameState, localPlayerIndex: Int, matchID: String) {
        // Switching from an AI game (possibly mid-AI-think) — invalidate AI work so the
        // destructive restore below can't race an in-flight haveComputerPlay.
        cancelAIWork()
        // A reload (opponent move / cross-device sync) must not leave orphaned exchange/
        // drag/blank-picker UI pointing at now-stale tiles.
        resetTransientInteractionState()
        // Detect newly placed tiles by comparing incoming board with current board
        var newTiles: [AIAnimTile] = []
        let isOpponentMove = state.currentPlayerIndex == localPlayerIndex  // it's now our turn = opponent just moved
        let isSameVisibleMatch = gameMode == .multiplayer && multiplayerMatchID == matchID && !board.isEmpty
        if isOpponentMove && isSameVisibleMatch {
            var tileIndex = 0
            for row in 0..<state.board.count {
                for col in 0..<state.board[row].count {
                    if let tile = state.board[row][col] {
                        let wasEmpty = row < board.count && col < board[row].count && board[row][col].letter == nil
                        if wasEmpty {
                            let pts = tile.isBlank ? 0 : (TileModel.tilePoints[tile.letter] ?? 0)
                            newTiles.append(AIAnimTile(
                                letter: tile.letter,
                                isBlank: tile.isBlank,
                                points: pts,
                                targetRow: row,
                                targetCol: col,
                                rackIndex: tileIndex
                            ))
                            tileIndex += 1
                        }
                    }
                }
            }
        }

        let boardLetters: [[String]] = state.board.map { row in
            row.map { tile in tile?.letter ?? "" }
        }
        let boardBlanks: [[NSNumber]] = state.board.map { row in
            row.map { tile in NSNumber(value: tile?.isBlank ?? false) }
        }

        let scores = state.playerScores.map { NSNumber(value: $0) }
        let racks = state.playerRacks

        withBridgeSync {
            self.bridge.restoreTwoHumanGame(
                withPlayer1: state.player1DisplayName,
                player2: state.player2DisplayName,
                boardLetters: boardLetters,
                boardBlanks: boardBlanks,
                playerScores: scores,
                playerRacks: racks,
                bagTiles: state.bag,
                currentPlayerIndex: Int32(state.currentPlayerIndex),
                currentTurnNumber: Int32(state.turnNumber),
                scorelessTurns: Int32(state.consecutiveScorelessTurns),
                gameOver: state.isGameOver
            )
        }

        gameMode = .multiplayer
        showModeSelection = false
        self.localPlayerIndex = localPlayerIndex
        multiplayerMatchID = matchID
        multiplayerPlayer1ID = state.player1GameCenterID
        multiplayerPlayer2ID = state.player2GameCenterID
        moveHistory = state.moveHistory
        consecutiveScorelessTurns = state.consecutiveScorelessTurns
        tentativePlacements = []
        errorMessage = nil
        if !state.isGameOver { gameResultMessage = nil }

        if !newTiles.isEmpty {
            // Animate opponent's tiles: show board without the new tiles, then animate them in
            aiAnimTiles = newTiles
            aiAnimPhase = 0
            isAnimatingAIMove = true
            // Refresh state but we'll overlay the animation
            refreshState()

            animationTask?.cancel()
            animationTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    self.aiAnimPhase = 1  // flip face-up
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    self.aiAnimPhase = 2  // fly to board
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                self.isAnimatingAIMove = false
                self.aiAnimTiles = []
                self.aiAnimPhase = 0
            }
        } else {
            isAnimatingAIMove = false
            refreshState()
        }

        if state.isGameOver {
            isGameOver = true
        }
    }

    func exportMultiplayerState() -> MultiplayerGameState {
        let savedBoard: [[SavedTile?]] = board.map { row in
            row.map { square in
                // Never persist a non-letter cell. A "." (played-thru mark) must not be
                // saved as a tile — restoring it would corrupt the board.
                guard let letter = square.letter, !letter.isEmpty, letter != "." else { return nil }
                return SavedTile(letter: letter, isBlank: square.isBlank)
            }
        }

        let numPlayers = Int(bridge.numberOfPlayers())
        let over = bridge.isGameOver()
        var scores: [Int] = []
        var racks: [[String]] = []
        for i in 0..<numPlayers {
            // At game over capture the endgame-adjusted (deadwood) score NOW, while the
            // bonus move is still staged — it can't be reconstructed after a restore.
            // This is also what the won/lost/tie decision reads downstream.
            let score = over ? Int(bridge.finalScore(forPlayerIndex: Int32(i)))
                             : Int(bridge.score(forPlayerIndex: Int32(i)))
            scores.append(score)
            racks.append(bridge.rack(forPlayerIndex: Int32(i)) as [String])
        }

        let bag = bridge.bagTiles() as [String]
        let currentIdx = Int(bridge.currentPlayerIndex())

        return MultiplayerGameState(
            player1GameCenterID: multiplayerPlayer1ID,
            player2GameCenterID: multiplayerPlayer2ID,
            player1DisplayName: bridge.name(forPlayerIndex: 0),
            player2DisplayName: bridge.name(forPlayerIndex: 1),
            board: savedBoard,
            playerScores: scores,
            playerRacks: racks,
            bag: bag,
            currentPlayerIndex: currentIdx,
            turnNumber: Int(bridge.turnNumber()),
            moveHistory: moveHistory,
            isGameOver: isGameOver,
            consecutiveScorelessTurns: consecutiveScorelessTurns
        )
    }
}
