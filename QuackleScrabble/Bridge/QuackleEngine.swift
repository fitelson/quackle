import Foundation
import Observation

enum BonusType {
    case none, doubleLetter, tripleLetter, doubleWord, tripleWord
}

struct TileModel: Identifiable, Equatable {
    let id = UUID()
    let letter: String
    let points: Int
    let isBlank: Bool

    static func == (lhs: TileModel, rhs: TileModel) -> Bool {
        lhs.id == rhs.id
    }
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
    var turnNumber: Int = 0
    var lastMoveDescription: String = ""
    var errorMessage: String? = nil
    var isInitialized: Bool = false
    var loadingProgress: Double = 0.0
    var loadingStatus: String = ""

    // Tap-to-place state
    var tentativePlacements: [TilePlacement] = []
    var availableRack: [TileModel] = []  // rack minus placed tiles
    var selectedRackTileId: UUID? = nil  // currently selected rack tile
    var isTentativeMoveValid: Bool = false  // real-time validation
    var tentativeMoveString: String? = nil  // the built move string
    var showBlankPicker: Bool = false  // show letter picker for blank tile
    var pendingBlankRow: Int = -1
    var pendingBlankCol: Int = -1
    var isExchangeMode: Bool = false  // exchange tile selection mode
    var exchangeSelectedIds: Set<UUID> = []  // rack tiles selected for exchange
    var showSkillSlider: Bool = false
    var skillLevel: Double = 0.5  // 0=low, 0.5=medium, 1=high
    var showHistory: Bool = false
    var moveHistory: [MoveHistoryEntry] = []
    var showMoves: Bool = false
    var topMoves: [MoveModel] = []

    private let bridge = QuackleBridge.shared()

    func initialize() {
        guard let dataPath = Bundle.main.path(forResource: "data", ofType: nil) else {
            errorMessage = "Could not find data directory in bundle"
            return
        }

        loadingStatus = "Setting up engine..."
        loadingProgress = 0.0

        let bridge = self.bridge
        let lexicon = "twl06"

        Task.detached {
            bridge.initStage1Setup(withDataPath: dataPath)
            await MainActor.run {
                self.loadingProgress = 0.25
                self.loadingStatus = "Loading dictionary..."
            }

            let dawgOK = bridge.initStage2LoadDawg(lexicon)
            guard dawgOK else {
                await MainActor.run { self.errorMessage = "Failed to load dictionary" }
                return
            }
            await MainActor.run {
                self.loadingProgress = 0.50
                self.loadingStatus = "Loading word graph..."
            }

            bridge.initStage3LoadGaddag(lexicon)
            await MainActor.run {
                self.loadingProgress = 0.75
                self.loadingStatus = "Loading strategy..."
            }

            bridge.initStage4LoadStrategy(lexicon)
            await MainActor.run {
                self.loadingProgress = 0.90
                self.loadingStatus = "Starting game..."
            }

            bridge.initStageFinalize()
            await MainActor.run {
                self.loadingProgress = 1.0
                self.isInitialized = true
                self.startNewGame()
            }
        }
    }

    func startNewGame() {
        bridge.startNewGame(withHumanName: "You", aiMeanLoss: skillMeanLoss, aiStdDev: skillStdDev)
        tentativePlacements = []
        errorMessage = nil
        lastMoveDescription = ""
        refreshState()
    }

    // MARK: - Tap to Place

    func selectRackTile(_ tile: TileModel) {
        if selectedRackTileId == tile.id {
            selectedRackTileId = nil  // deselect
        } else {
            selectedRackTileId = tile.id
        }
    }

    func handleBoardTap(row: Int, col: Int) {
        // If tapping a tentative tile, remove it
        if tentativeLetterAt(row: row, col: col) != nil {
            removeTentativeTile(atRow: row, col: col)
            return
        }

        // If a rack tile is selected, place it
        guard let selectedId = selectedRackTileId,
              let tile = availableRack.first(where: { $0.id == selectedId }) else {
            return
        }

        // Don't place on occupied squares
        if board[row][col].letter != nil { return }
        if tentativePlacements.contains(where: { $0.row == row && $0.col == col }) { return }

        if tile.isBlank {
            // Show letter picker for blank tile
            pendingBlankRow = row
            pendingBlankCol = col
            showBlankPicker = true
        } else {
            placeTile(letter: tile.letter, isBlank: false, atRow: row, col: col)
            selectedRackTileId = nil
        }
    }

    func placeBlankAs(letter: String) {
        placeTile(letter: letter, isBlank: true, atRow: pendingBlankRow, col: pendingBlankCol)
        selectedRackTileId = nil
        showBlankPicker = false
    }

    func placeTile(letter: String, isBlank: Bool, atRow row: Int, col: Int) {
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
        tentativeMoveString = nil
    }

    private func validateTentativeMove() {
        guard !tentativePlacements.isEmpty else {
            isTentativeMoveValid = false
            tentativeMoveString = nil
            return
        }

        if let moveStr = buildMoveString() {
            tentativeMoveString = moveStr
            let validity = bridge.validateMove(moveStr)
            isTentativeMoveValid = (validity == 0)
            print("[Validate] '\(moveStr)' -> validity=\(validity) valid=\(isTentativeMoveValid)")
        } else {
            tentativeMoveString = nil
            isTentativeMoveValid = false
            print("[Validate] Could not build move string from \(tentativePlacements.count) tiles")
        }
    }

    func tentativeLetterAt(row: Int, col: Int) -> TilePlacement? {
        tentativePlacements.first { $0.row == row && $0.col == col }
    }

    func commitTentativeMove() {
        guard !tentativePlacements.isEmpty else { return }
        errorMessage = nil

        guard let moveString = buildMoveString() else {
            errorMessage = "Invalid tile placement — tiles must be in a line"
            return
        }

        print("[QuackleEngine] Committing move: \(moveString)")

        // Do the commit on next run loop to avoid SwiftUI mutation during render
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            let committed = self.bridge.commitMove(moveString)
            if committed {
                self.tentativePlacements = []
                self.selectedRackTileId = nil
                self.refreshState()
                self.triggerAIIfNeeded()
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
            let minCol = sorted.map(\.col).min()!
            let maxCol = sorted.map(\.col).max()!

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
                if let placement = tentativePlacements.first(where: { $0.row == row && $0.col == c }) {
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
            let posString = "\(startRow + 1)\(String(UnicodeScalar(65 + startCol)!))"
            return "\(posString) \(word)"

        } else {
            let col = sorted[0].col
            let minRow = sorted.map(\.row).min()!
            let maxRow = sorted.map(\.row).max()!

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
                if let placement = tentativePlacements.first(where: { $0.row == r && $0.col == col }) {
                    word += placement.isBlank ? placement.letter.lowercased() : placement.letter
                } else if board[r][col].letter != nil {
                    word += "."
                } else {
                    return nil
                }
            }

            // Vertical: column letter + row, e.g. "H8"
            let posString = "\(String(UnicodeScalar(65 + startCol)!))\(startRow + 1)"
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
    var skillMeanLoss: Double { 20.0 - (skillLevel * 18.0) }  // 20 -> 2
    var skillStdDev: Double { 8.0 - (skillLevel * 6.0) }      // 8 -> 2

    var skillLabel: String {
        if skillLevel < 0.25 { return "Low" }
        if skillLevel < 0.75 { return "Medium" }
        return "High"
    }

    // MARK: - History

    func showMoveHistory() {
        let entries = bridge.moveHistory()
        moveHistory = entries.map { entry in
            MoveHistoryEntry(
                turn: Int(entry.turn),
                playerName: entry.playerName,
                moveDescription: entry.moveDescription,
                score: Int(entry.score),
                totalScore: Int(entry.totalScore)
            )
        }
        showHistory = true
    }

    // MARK: - Top Moves

    func generateTopMoves() {
        topMoves = kibitz(count: 50)
        showMoves = true
    }

    // MARK: - Shuffle

    func shuffleRack() {
        rack.shuffle()
        updateAvailableRack()
    }

    // MARK: - Exchange

    func enterExchangeMode() {
        clearTentativePlacements()
        selectedRackTileId = nil
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

    func playMove(_ moveString: String) {
        errorMessage = nil
        let valid = bridge.commitMove(moveString)
        if valid {
            tentativePlacements = []
            refreshState()
            triggerAIIfNeeded()
        } else {
            errorMessage = "Invalid move: \(moveString)"
        }
    }

    func pass() {
        tentativePlacements = []
        bridge.commitPass()
        refreshState()
        triggerAIIfNeeded()
    }

    func exchangeTiles(_ tiles: String) {
        tentativePlacements = []
        bridge.commitExchange(withTiles: tiles)
        refreshState()
        triggerAIIfNeeded()
    }

    private func triggerAIIfNeeded() {
        if !isHumanTurn && !isGameOver {
            let bridge = self.bridge
            Task.detached {
                _ = bridge.haveComputerPlay()
                await MainActor.run { [weak self] in
                    self?.refreshState()
                }
            }
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

        let rackLetters = bridge.currentPlayerRack()
        rack = rackLetters.map { letter in
            TileModel(letter: letter, points: 0, isBlank: letter == "?")
        }
        updateAvailableRack()

        let numPlayers = Int(bridge.numberOfPlayers())
        var newPlayers: [PlayerModel] = []
        for i in 0..<numPlayers {
            newPlayers.append(PlayerModel(
                name: bridge.name(forPlayerIndex: Int32(i)),
                score: Int(bridge.score(forPlayerIndex: Int32(i)))
            ))
        }
        players = newPlayers

        currentPlayerName = bridge.currentPlayerName()
        isHumanTurn = bridge.isCurrentPlayerHuman()
        isGameOver = bridge.isGameOver()
        tilesInBag = Int(bridge.tilesRemainingInBag())
        turnNumber = Int(bridge.turnNumber())
    }
}
