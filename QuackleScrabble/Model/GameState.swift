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
    let humanFirst: Bool
    let skillLevel: Double
    let board: [[SavedTile?]]
    let players: [SavedPlayer]
    let bag: [String]
    let isGameOver: Bool
    let isHumanTurn: Bool
    let moveHistory: [MoveHistoryEntry]
}
