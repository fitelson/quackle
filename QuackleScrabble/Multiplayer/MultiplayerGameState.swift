import Foundation

struct MultiplayerGameState: Codable {
    let version: Int
    var player1GameCenterID: String
    var player2GameCenterID: String
    var player1DisplayName: String
    var player2DisplayName: String
    let board: [[SavedTile?]]
    let playerScores: [Int]
    let playerRacks: [[String]]
    let bag: [String]
    let currentPlayerIndex: Int
    let turnNumber: Int
    let moveHistory: [MoveHistoryEntry]
    let isGameOver: Bool
    let consecutiveScorelessTurns: Int

    init(
        player1GameCenterID: String,
        player2GameCenterID: String,
        player1DisplayName: String,
        player2DisplayName: String,
        board: [[SavedTile?]],
        playerScores: [Int],
        playerRacks: [[String]],
        bag: [String],
        currentPlayerIndex: Int,
        turnNumber: Int = 1,
        moveHistory: [MoveHistoryEntry],
        isGameOver: Bool,
        consecutiveScorelessTurns: Int
    ) {
        self.version = 1
        self.player1GameCenterID = player1GameCenterID
        self.player2GameCenterID = player2GameCenterID
        self.player1DisplayName = player1DisplayName
        self.player2DisplayName = player2DisplayName
        self.board = board
        self.playerScores = playerScores
        self.playerRacks = playerRacks
        self.bag = bag
        self.currentPlayerIndex = currentPlayerIndex
        self.turnNumber = turnNumber
        self.moveHistory = moveHistory
        self.isGameOver = isGameOver
        self.consecutiveScorelessTurns = consecutiveScorelessTurns
    }

    enum CodingKeys: String, CodingKey {
        case version
        case player1GameCenterID
        case player2GameCenterID
        case player1DisplayName
        case player2DisplayName
        case board
        case playerScores
        case playerRacks
        case bag
        case currentPlayerIndex
        case turnNumber
        case moveHistory
        case isGameOver
        case consecutiveScorelessTurns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        player1GameCenterID = try container.decode(String.self, forKey: .player1GameCenterID)
        player2GameCenterID = try container.decode(String.self, forKey: .player2GameCenterID)
        player1DisplayName = try container.decode(String.self, forKey: .player1DisplayName)
        player2DisplayName = try container.decode(String.self, forKey: .player2DisplayName)
        board = try container.decode([[SavedTile?]].self, forKey: .board)
        playerScores = try container.decode([Int].self, forKey: .playerScores)
        playerRacks = try container.decode([[String]].self, forKey: .playerRacks)
        bag = try container.decode([String].self, forKey: .bag)
        currentPlayerIndex = try container.decode(Int.self, forKey: .currentPlayerIndex)
        moveHistory = try container.decode([MoveHistoryEntry].self, forKey: .moveHistory)
        turnNumber = try container.decodeIfPresent(Int.self, forKey: .turnNumber)
            ?? MultiplayerGameState.inferredTurnNumber(
                moveHistory: moveHistory,
                currentPlayerIndex: currentPlayerIndex
            )
        isGameOver = try container.decode(Bool.self, forKey: .isGameOver)
        consecutiveScorelessTurns = try container.decode(Int.self, forKey: .consecutiveScorelessTurns)
    }

    private static func inferredTurnNumber(
        moveHistory: [MoveHistoryEntry],
        currentPlayerIndex: Int
    ) -> Int {
        guard let maxTurn = moveHistory.map(\.turn).max(), maxTurn > 0 else {
            return 1
        }

        // In a two-player game, player 2 moves in the same turn number as
        // player 1; the next turn starts when play cycles back to player 1.
        return currentPlayerIndex == 0 ? maxTurn + 1 : maxTurn
    }
}
