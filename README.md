# Scrabble (iOS)

A personal Scrabble app for iPhone, built with SwiftUI and the [Quackle](https://github.com/quackle/quackle) C++ engine.

## Features

- **Tap-to-place** tile interaction — no text input
- **Real-time validation** — green tiles for valid moves, red for invalid
- **AI opponent** using Quackle's NormalPlayer with Gaussian move selection
- **Skill slider** — adjust AI difficulty from easy (0.0) to near-perfect (1.0)
- **Blank tile picker** — tap a blank, choose a letter from an A–Z grid
- **Exchange, pass, and new game** support
- **Move history** and **top 50 candidate moves** views
- Uses the **TWL06** dictionary

## Requirements

- Xcode 16.3+
- iOS 17.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build

```bash
xcodegen generate
xcodebuild -project QuackleScrabble.xcodeproj \
  -scheme QuackleScrabble \
  -configuration Release \
  build
```

> **Note:** Always use the `Release` configuration. Debug builds trigger a `strict_weak_ordering` assertion in Quackle's move comparator.

## Project Structure

```
QuackleScrabble/
  App/            — SwiftUI app entry point and main ContentView
  Bridge/         — Obj-C++ bridge (QuackleBridge) and QuackleEngine
  Model/          — GameState, TilePlacement, MoveHistoryEntry
  Views/
    Board/        — BoardView, SquareView
    Rack/         — RackView
    Game/         — ScoreboardView, MoveInputView
  Assets.xcassets — App icon
libquackle/       — Quackle C++ engine sources
data/             — TWL06 dictionary, alphabet, strategy files
project.yml       — XcodeGen project spec
```

## Acknowledgments

This app uses the [Quackle](https://github.com/quackle/quackle) crossword game AI engine, created by **Jason Katz-Brown**, **John O'Laughlin**, and **John Fultz**. Quackle is released under the [GPL v3+](https://www.gnu.org/licenses/gpl-3.0.html).

## Related

- [quackle-macos](https://github.com/fitelson/quackle-macos) — the macOS version of this app
