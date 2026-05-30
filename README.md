# Quackle

A personal Scrabble app for iPhone and Mac, built with SwiftUI and the [Quackle](https://github.com/quackle/quackle) C++ engine.

## Features

### Two Game Modes
- **Play vs AI** — Quackle's NormalPlayer with adjustable skill slider (easy to near-perfect); skill controls both move quality and how much of the bingo vocabulary the AI knows
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
- **Board zoom** — double-tap/click to zoom in, drag to pan (drag-and-drop is zoom-aware)
- **Game persistence** — AI games save board, racks, scores, and bag across app launches
- **AI move animation** — opponent tiles flip face-up then fly to board positions
- **Coin flip** determines who goes first in AI games
- Uses the **CSW19** dictionary

### Multiplayer
- Game Center turn-based auto-match between two configured accounts (allowlist-gated), with iCloud KVS active-match handoff
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
- AI skill is calibrated so slider midpoint (`0.5`) maps to Quackle `NormalPlayer(meanLoss: 10, stdDev: 6)`.
- AI bingo vocabulary is a deterministic word-knowledge filter, not a per-turn bingo probability; slider midpoint maps to about 10% raw bingo-word knowledge.
- Multiplayer state includes turn number, consecutive scoreless turns, game-over state, racks, bag, board, scores, and move history.
- Multiplayer is intentionally hard-coded to the two configured Game Center `gamePlayerID`s in `FamilyMultiplayer`; other signed-in accounts and unexpected match participants are rejected. Matchmaking is auto-match (`find(for:)`), which needs no Game Center friendship — the private app's match pool only ever contains the two accounts.
- Match selection (`bestPlayableMatch`) is non-destructive: it skips finished/unpaired matches but never calls `match.remove()`, because removing an open match orphans the other device's pending Game Center request. Only explicit forfeit/end flows clear the local active match and KVS ID.
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
