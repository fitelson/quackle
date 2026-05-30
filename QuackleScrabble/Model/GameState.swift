import Foundation

struct TilePlacement: Equatable {
    let row: Int
    let col: Int
    let letter: String
    let isBlank: Bool
}

struct AIAnimTile: Identifiable {
    let id = UUID()
    let letter: String
    let isBlank: Bool
    let points: Int
    let targetRow: Int
    let targetCol: Int
    let rackIndex: Int  // which opponent rack slot this tile comes from
}

struct MoveHistoryEntry: Identifiable, Codable {
    let id: UUID
    let turn: Int
    /// Player index (0 or 1) the move belongs to. -1 for legacy entries decoded
    /// from data written before this field existed.
    let playerIndex: Int
    let playerName: String
    let moveDescription: String
    let score: Int
    let totalScore: Int

    init(turn: Int, playerIndex: Int = -1, playerName: String, moveDescription: String, score: Int, totalScore: Int) {
        self.id = UUID()
        self.turn = turn
        self.playerIndex = playerIndex
        self.playerName = playerName
        self.moveDescription = moveDescription
        self.score = score
        self.totalScore = totalScore
    }

    enum CodingKeys: String, CodingKey {
        case id, turn, playerIndex, playerName, moveDescription, score, totalScore
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        turn = try c.decode(Int.self, forKey: .turn)
        // Legacy data (match data / saved AI games) predates playerIndex.
        playerIndex = try c.decodeIfPresent(Int.self, forKey: .playerIndex) ?? -1
        playerName = try c.decode(String.self, forKey: .playerName)
        moveDescription = try c.decode(String.self, forKey: .moveDescription)
        score = try c.decode(Int.self, forKey: .score)
        totalScore = try c.decode(Int.self, forKey: .totalScore)
    }
}

// MARK: - Game State Persistence

struct SavedTile: Codable {
    let letter: String
    let isBlank: Bool
}

struct SavedPlayer: Codable {
    let name: String
    let isHuman: Bool
    let score: Int
    let rack: [String]
}

struct SavedGameState: Codable {
    let version: Int
    let humanFirst: Bool
    let skillLevel: Double
    /// Fraction (0–1) of bingo words the AI knows — independent of skillLevel.
    /// Defaults to 0.10 for saves from before the two-slider split.
    let bingoKnowledge: Double
    let board: [[SavedTile?]]
    let players: [SavedPlayer]
    let bag: [String]
    let isGameOver: Bool
    let isHumanTurn: Bool
    /// Consecutive scoreless turns (for the six-scoreless game-end rule). Defaults to
    /// 0 when decoding a payload from before this field existed.
    let scorelessTurns: Int
    /// Current C++ turn number, restored so post-restore moves continue the sequence
    /// (otherwise the bridge restarts at 1 and new history entries collide with saved
    /// ones on the (turn, playerIndex) dedup key). Defaults to 1 for legacy saves.
    let turnNumber: Int
    let moveHistory: [MoveHistoryEntry]

    init(humanFirst: Bool, skillLevel: Double, bingoKnowledge: Double = 0.10,
         board: [[SavedTile?]], players: [SavedPlayer],
         bag: [String], isGameOver: Bool, isHumanTurn: Bool, scorelessTurns: Int = 0,
         turnNumber: Int = 1, moveHistory: [MoveHistoryEntry], version: Int = 1) {
        self.version = version
        self.humanFirst = humanFirst
        self.skillLevel = skillLevel
        self.bingoKnowledge = bingoKnowledge
        self.board = board
        self.players = players
        self.bag = bag
        self.isGameOver = isGameOver
        self.isHumanTurn = isHumanTurn
        self.scorelessTurns = scorelessTurns
        self.turnNumber = turnNumber
        self.moveHistory = moveHistory
    }

    enum CodingKeys: String, CodingKey {
        case version, humanFirst, skillLevel, bingoKnowledge, board, players, bag, isGameOver, isHumanTurn, scorelessTurns, turnNumber, moveHistory
    }

    // Custom decoder: tolerate older saves that lack newer fields (decodeIfPresent +
    // defaults) so a schema addition never silently discards an in-progress AI game.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        humanFirst = try c.decode(Bool.self, forKey: .humanFirst)
        skillLevel = try c.decode(Double.self, forKey: .skillLevel)
        bingoKnowledge = try c.decodeIfPresent(Double.self, forKey: .bingoKnowledge) ?? 0.10
        board = try c.decode([[SavedTile?]].self, forKey: .board)
        players = try c.decode([SavedPlayer].self, forKey: .players)
        bag = try c.decode([String].self, forKey: .bag)
        isGameOver = try c.decode(Bool.self, forKey: .isGameOver)
        isHumanTurn = try c.decode(Bool.self, forKey: .isHumanTurn)
        scorelessTurns = try c.decodeIfPresent(Int.self, forKey: .scorelessTurns) ?? 0
        turnNumber = try c.decodeIfPresent(Int.self, forKey: .turnNumber) ?? 1
        moveHistory = try c.decode([MoveHistoryEntry].self, forKey: .moveHistory)
    }
}
