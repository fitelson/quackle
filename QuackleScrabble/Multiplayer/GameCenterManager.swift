import Foundation
import GameKit
import Observation

@MainActor
@Observable
class GameCenterManager: NSObject, GKLocalPlayerListener {
    var isAuthenticated = false
    var localPlayerID = ""
    var localDisplayName = ""
    var authError: String?
    var currentMatch: GKTurnBasedMatch?
    var showMatchmaker = false
    var isWaitingForOpponent = false

    weak var engine: QuackleEngine?

    func authenticate() {
        GKLocalPlayer.local.authenticateHandler = { [weak self] viewController, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.authError = error.localizedDescription
                    self.isAuthenticated = false
                    return
                }
                let player = GKLocalPlayer.local
                self.isAuthenticated = player.isAuthenticated
                if player.isAuthenticated {
                    self.localPlayerID = player.gamePlayerID
                    self.localDisplayName = player.displayName
                    self.authError = nil
                    GKLocalPlayer.local.register(self)
                }
            }
        }
    }

    // MARK: - Find or Create Match

    var isFinding = false

    func findOrCreateMatch() {
        guard !isFinding else { return }
        isFinding = true

        Task {
            defer { self.isFinding = false }
            do {
                // 1. Remove all existing matches (stale, finished, or abandoned)
                let matches = try await GKTurnBasedMatch.loadMatches()
                print("[GameCenter] Found \(matches.count) existing matches, removing all")
                for match in matches {
                    print("[GameCenter]   removing match status=\(match.status.rawValue)")
                    try? await match.remove()
                }

                // 2. Programmatic auto-match (no UI)
                print("[GameCenter] Starting programmatic auto-match...")
                let request = GKMatchRequest()
                request.minPlayers = 2
                request.maxPlayers = 2
                let match = try await GKTurnBasedMatch.find(for: request)
                print("[GameCenter] Auto-match found!")
                self.handleMatchFound(match)
            } catch {
                print("[GameCenter] Error: \(error.localizedDescription)")
                self.engine?.errorMessage = "Game Center: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Match Management

    func handleMatchFound(_ match: GKTurnBasedMatch) {
        currentMatch = match
        showMatchmaker = false

        let isMyTurn = match.currentParticipant?.player?.gamePlayerID == localPlayerID
        let hasData = match.matchData != nil && !(match.matchData?.isEmpty ?? true)
        print("[GameCenter] Match found: isMyTurn=\(isMyTurn), hasData=\(hasData), participants=\(match.participants.count)")
        for p in match.participants {
            print("[GameCenter]   participant: \(p.player?.displayName ?? "?") id=\(p.player?.gamePlayerID ?? "nil")")
        }
        print("[GameCenter]   currentParticipant: \(match.currentParticipant?.player?.displayName ?? "?")")
        print("[GameCenter]   localPlayerID: \(localPlayerID)")

        if let data = match.matchData, !data.isEmpty,
           let state = try? JSONDecoder().decode(MultiplayerGameState.self, from: data) {
            print("[GameCenter] Restoring existing game state")
            self.loadMatchState(state, from: match)
        } else if isMyTurn {
            print("[GameCenter] New match — I go first, initializing game")
            self.startNewMultiplayerGame(from: match)
        } else {
            print("[GameCenter] New match — opponent goes first, waiting")
            self.isWaitingForOpponent = true
            self.engine?.gameMode = .multiplayer
            self.engine?.showModeSelection = false
            // Clear stale state from any previous game so waiting view shows cleanly
            self.engine?.board = []
            self.engine?.rack = []
            self.engine?.availableRack = []
            self.engine?.players = []
            self.engine?.moveHistory = []
            self.engine?.tentativePlacements = []
            self.engine?.isGameOver = false
        }
    }

    private func startNewMultiplayerGame(from match: GKTurnBasedMatch) {
        guard let engine else { return }
        let participants = match.participants
        guard participants.count == 2 else { return }

        let localID = localPlayerID
        let localName = localDisplayName
        var opponentName = "Opponent"
        var opponentID = ""

        for p in participants {
            if let player = p.player, player.gamePlayerID != localID {
                opponentName = player.displayName
                opponentID = player.gamePlayerID
            }
        }

        engine.startMultiplayerGame(
            player1Name: localName,
            player2Name: opponentName,
            localPlayerIndex: 0,
            player1GameCenterID: localID,
            player2GameCenterID: opponentID
        )
    }

    private func loadMatchState(_ state: MultiplayerGameState, from match: GKTurnBasedMatch) {
        guard let engine else { return }

        // Update display names from resolved match participants
        var updatedState = state
        for p in match.participants {
            guard let player = p.player else { continue }
            if player.gamePlayerID == state.player1GameCenterID {
                updatedState = MultiplayerGameState(
                    player1GameCenterID: updatedState.player1GameCenterID,
                    player2GameCenterID: updatedState.player2GameCenterID,
                    player1DisplayName: player.displayName,
                    player2DisplayName: updatedState.player2DisplayName,
                    board: updatedState.board,
                    playerScores: updatedState.playerScores,
                    playerRacks: updatedState.playerRacks,
                    bag: updatedState.bag,
                    currentPlayerIndex: updatedState.currentPlayerIndex,
                    moveHistory: updatedState.moveHistory,
                    isGameOver: updatedState.isGameOver,
                    consecutiveScorelessTurns: updatedState.consecutiveScorelessTurns
                )
            } else if player.gamePlayerID == state.player2GameCenterID ||
                      state.player2GameCenterID.isEmpty {
                updatedState = MultiplayerGameState(
                    player1GameCenterID: updatedState.player1GameCenterID,
                    player2GameCenterID: player.gamePlayerID,
                    player1DisplayName: updatedState.player1DisplayName,
                    player2DisplayName: player.displayName,
                    board: updatedState.board,
                    playerScores: updatedState.playerScores,
                    playerRacks: updatedState.playerRacks,
                    bag: updatedState.bag,
                    currentPlayerIndex: updatedState.currentPlayerIndex,
                    moveHistory: updatedState.moveHistory,
                    isGameOver: updatedState.isGameOver,
                    consecutiveScorelessTurns: updatedState.consecutiveScorelessTurns
                )
            }
        }

        let localIndex = (updatedState.player1GameCenterID == localPlayerID) ? 0 : 1
        engine.loadMultiplayerState(updatedState, localPlayerIndex: localIndex)
    }

    func submitTurn(matchData: Data) {
        guard let match = currentMatch else {
            print("[GameCenter] submitTurn: no current match!")
            return
        }
        let nextParticipants = match.participants.filter {
            $0.player?.gamePlayerID != localPlayerID
        }
        print("[GameCenter] submitTurn: \(matchData.count) bytes, nextParticipants=\(nextParticipants.count)")
        for p in nextParticipants {
            print("[GameCenter]   next: \(p.player?.displayName ?? "?") id=\(p.player?.gamePlayerID ?? "nil") status=\(p.status.rawValue)")
        }
        guard !nextParticipants.isEmpty else {
            print("[GameCenter] submitTurn: no next participants!")
            return
        }

        Task {
            do {
                try await match.endTurn(
                    withNextParticipants: nextParticipants,
                    turnTimeout: GKTurnTimeoutDefault,
                    match: matchData
                )
                print("[GameCenter] submitTurn: SUCCESS")
            } catch {
                print("[GameCenter] submitTurn: FAILED — \(error.localizedDescription)")
                self.engine?.errorMessage = "Failed to send turn: \(error.localizedDescription)"
            }
        }
    }

    func endMatch(matchData: Data, localWon: Bool) {
        guard let match = currentMatch else { return }
        for p in match.participants {
            if p.player?.gamePlayerID == localPlayerID {
                p.matchOutcome = localWon ? .won : .lost
            } else {
                p.matchOutcome = localWon ? .lost : .won
            }
        }
        Task {
            do {
                try await match.endMatchInTurn(withMatch: matchData)
            } catch {
                self.engine?.errorMessage = "Failed to end match: \(error.localizedDescription)"
            }
            self.isWaitingForOpponent = false
        }
    }

    func forfeitMatch() {
        guard let match = currentMatch else { return }
        let isMyTurn = match.currentParticipant?.player?.gamePlayerID == localPlayerID

        Task {
            if isMyTurn {
                let nextParticipants = match.participants.filter {
                    $0.player?.gamePlayerID != self.localPlayerID
                }
                try? await match.participantQuitInTurn(
                    with: .quit,
                    nextParticipants: nextParticipants,
                    turnTimeout: GKTurnTimeoutDefault,
                    match: match.matchData ?? Data()
                )
            } else {
                try? await match.participantQuitOutOfTurn(with: .quit)
            }
            self.currentMatch = nil
            self.isWaitingForOpponent = false
            self.engine?.showModeSelection = true
        }
    }

    // MARK: - Polling

    func pollForMatchUpdate() {
        guard let match = currentMatch else { return }
        Task {
            do {
                let refreshed = try await GKTurnBasedMatch.load(withID: match.matchID)
                self.currentMatch = refreshed
                if let data = refreshed.matchData, !data.isEmpty,
                   let state = try? JSONDecoder().decode(MultiplayerGameState.self, from: data) {
                    // Waiting player: opponent made first move
                    if self.isWaitingForOpponent {
                        print("[GameCenter] poll: got match data while waiting, loading state")
                        self.isWaitingForOpponent = false
                        self.loadMatchState(state, from: refreshed)
                        return
                    }
                    // Non-active player: check if opponent has moved (currentPlayerIndex changed)
                    let localIndex = (state.player1GameCenterID == self.localPlayerID) ? 0 : 1
                    if state.currentPlayerIndex == localIndex {
                        print("[GameCenter] poll: it's now our turn, loading state")
                        self.loadMatchState(state, from: refreshed)
                    }
                }
            } catch {
                print("[GameCenter] poll error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - GKTurnBasedEventListener

    nonisolated func player(_ player: GKPlayer, receivedTurnEventFor match: GKTurnBasedMatch, didBecomeActive: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let hasData = match.matchData != nil && !(match.matchData?.isEmpty ?? true)
            print("[GameCenter] receivedTurnEvent: didBecomeActive=\(didBecomeActive), hasData=\(hasData), dataSize=\(match.matchData?.count ?? 0)")
            self.currentMatch = match

            if let data = match.matchData, !data.isEmpty,
               let state = try? JSONDecoder().decode(MultiplayerGameState.self, from: data) {
                print("[GameCenter] receivedTurnEvent: decoded state, currentPlayer=\(state.currentPlayerIndex)")
                self.isWaitingForOpponent = false
                self.loadMatchState(state, from: match)
            } else {
                print("[GameCenter] receivedTurnEvent: no valid match data, ignoring")
            }
        }
    }

    nonisolated func player(_ player: GKPlayer, matchEnded match: GKTurnBasedMatch) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            print("[GameCenter] matchEnded")
            if let data = match.matchData, !data.isEmpty,
               let state = try? JSONDecoder().decode(MultiplayerGameState.self, from: data) {
                self.loadMatchState(state, from: match)
            }
        }
    }
}
