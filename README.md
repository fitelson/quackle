# Quackle

A personal Scrabble app for iPhone and Mac, built with SwiftUI and the [Quackle](https://github.com/quackle/quackle) C++ engine.

## Features

### Two Game Modes
- **Play vs AI** — Quackle's NormalPlayer with **two independent sliders**: *AI Skill* (move quality, easy → near-perfect) and *Bingo vocabulary* (the share of bingo words the AI knows, common words first)
- **Play Online** — Game Center turn-based multiplayer hard-coded for two configured players

### Gameplay
- **Drag-and-drop** tile placement — drag tiles from rack to board, reposition on board, or drag back to rack
- **Rack reordering** — drag tiles within the rack to rearrange, with animated live preview
- **Shuffle** button to randomize rack tile order
- **Real-time validation** — green tiles for valid moves, red for invalid
- **Tile point values** displayed on every tile (standard Scrabble scoring)
- **Blank tile picker** — tap a blank, choose a letter from an A-Z grid
- **Exchange, pass, and new game** support
- **Move history** and **top 50 candidate moves** views
- **Game history** — every finished game (online *and* vs AI) is archived with date, opponent, final scores, winner, and a final-board snapshot; synced across each player's own devices via iCloud, browsable from the "…" menu
- **Board zoom** — double-tap/click to zoom in, drag to pan (drag-and-drop is zoom-aware)
- **Game persistence** — AI games save board, racks, scores, and bag across app launches; a tile-conservation check (bag + board + racks must total 100) discards any corrupt save and falls back to a fresh game
- **AI move animation** — opponent tiles flip face-up then fly to board positions
- **Coin flip** determines who goes first in AI games
- Uses the **CSW19** dictionary

### Multiplayer
- Game Center turn-based auto-match between two configured accounts (allowlist-gated), with iCloud KVS active-match handoff. **Either player can start** a new game; the other joins it, so the two players (and each player's own devices) always converge on one game. A deterministic tiebreak (the lower Game Center ID is the "keeper") collapses the rare simultaneous-start case onto one game
- Endgame-adjusted final scores (the unplayed-tiles/deadwood bonus is included in the result and win/loss/tie verdict)
- Turn submission with 3x retry and exponential backoff; a game-ending move retries too (no lost deciding move)
- Pending turns persisted by match ID to UserDefaults for cross-restart recovery
- 3-second polling for opponent moves and forfeit detection
- Hypothetical moves: place tiles and see scores while waiting for opponent
- Opponent move animation (3-phase flip + fly to board)
- Game switching: play AI and online games without forfeiting either
- Same game visible on multiple devices (iPhone + Mac) via Game Center

## Current Implementation Notes

- Xcode project generation is driven by `project.yml`; keep Game Center and iCloud KVS entitlements there.
- AI skill (move quality) is calibrated so the *AI Skill* slider midpoint (`0.5`) maps to Quackle `NormalPlayer(meanLoss: 10, stdDev: 6)`; it's applied at the start of the next new game.
- *Bingo vocabulary* is a separate, independently-persisted slider (not derived from skill). It's a deterministic **draw-probability** filter calibrated to **true frequency**: a bingo is known iff its full word clears the (1 − knowledge) quantile of CSW19 words **of the same length** (per-length tables in `kBingoQuantile`, extracted from the bundled DAWG by `tools/bingo_calib.py`). So "10%" ≈ the 10% most-probable bingos at each length — common words first, applied immediately.
- Multiplayer state includes turn number, consecutive scoreless turns, game-over state, racks, bag, board, scores, and move history.
- Multiplayer is intentionally hard-coded to the two configured Game Center `gamePlayerID`s in `FamilyMultiplayer`; other signed-in accounts and unexpected match participants are rejected. Matchmaking is auto-match (`find(for:)`), which needs no Game Center friendship — the private app's match pool only ever contains the two accounts.
- Matchmaking: either player can initiate via `find(for:)` (it joins the opponent's open seat if one exists, else creates one — so the second tapper joins the first's seat). The "owner" (lower Game Center ID) reuses one canonical seat via `ownerCanonicalSeat` to avoid duplicates; the non-owner clears its own stale empty seats first. iCloud KVS only ever stores a PAIRED/has-data match (never an empty seat), so devices never get stuck resuming an opponent-less game. Convergence is non-destructive — no after-the-fact seat deletion (it would wipe an in-progress opening move). `match.remove()` is used only on a player's own empty seats and finished/quit matches, never a live game or the partner's seat. (Direct invite is a confirmed dead end: the Game Center friends/player-resolution APIs return empty even with confirmed friendship.)
- Simulator validation target used during recent fixes: `platform=iOS Simulator,name=iPhone 17 Pro`.

## Requirements

- Xcode 16.3+
- iOS 17.0+ / macOS 14.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Apple Developer account (for Game Center multiplayer)
- Both configured accounts signed into Game Center (no friendship required — auto-match pairs them)

## Build

```bash
xcodegen generate

# iOS
xcodebuild -scheme QuackleScrabble \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  build

# macOS
xcodebuild -scheme QuackleScrabble \
  -destination 'platform=macOS' \
  -allowProvisioningUpdates \
  build
```

## Project Structure

```
QuackleScrabble/
  App/            — SwiftUI app entry point, ContentView, GameView, WaitingForOpponentView
  Bridge/         — Obj-C++ bridge (QuackleBridge) and QuackleEngine
  Model/          — GameState, TilePlacement, MoveHistoryEntry
  Multiplayer/    — GameCenterManager, MultiplayerGameState
  Views/
    Board/        — BoardView, SquareView
    Rack/         — RackView
    Game/         — ScoreboardView, MoveInputView, ModeSelectionView, AIAnimationOverlay
  Assets.xcassets — App icon (iOS + macOS)
libquackle/       — Quackle C++ engine sources
data/             — CSW19 dictionary, alphabet, strategy files
project.yml       — XcodeGen project spec (multiplatform)
```

## Acknowledgments

This app uses the [Quackle](https://github.com/quackle/quackle) crossword game AI engine, created by **Jason Katz-Brown**, **John O'Laughlin**, and **John Fultz**. Quackle is released under the [GPL v3+](https://www.gnu.org/licenses/gpl-3.0.html).
