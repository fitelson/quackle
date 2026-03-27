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
    let playerName: String
    let moveDescription: String
    let score: Int
    let totalScore: Int

    init(turn: Int, playerName: String, moveDescription: String, score: Int, totalScore: Int) {
        self.id = UUID()
        self.turn = turn
        self.playerName = playerName
        self.moveDescription = moveDescription
        self.score = score
        self.totalScore = totalScore
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
