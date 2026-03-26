# QuackleScrabble

Multiplatform (iOS + macOS) Scrabble game powered by the Quackle C++ engine.

## Build

```bash
# iOS Simulator
xcodebuild -project QuackleScrabble.xcodeproj -scheme QuackleScrabble -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

# macOS
xcodebuild -project QuackleScrabble.xcodeproj -scheme QuackleScrabble -destination 'platform=macOS' build
```

## Project structure

- `QuackleScrabble/App/` — ContentView, GameView, sheet views (BlankPicker, History, TopMoves, SkillSlider)
- `QuackleScrabble/Bridge/` — QuackleEngine.swift (main Observable engine), QuackleBridge (Obj-C++ bridge to C++ Quackle)
- `QuackleScrabble/Views/Board/` — BoardView, SquareView
- `QuackleScrabble/Views/Rack/` — RackView
- `QuackleScrabble/Model/` — GameState (TilePlacement, MoveHistoryEntry, SavedGameState)

## Key conventions

- Tile placement uses immediate DragGesture (not tap-to-place or system onDrag/onDrop)
- The "game" named coordinate space is defined on GameView's VStack and used by all drag gestures
- Board geometry (grid origin, square size, zoom state) is reported to the engine for drop-target calculation
- Drag-and-drop is zoom-aware: endDrag() inverse-transforms coordinates through scaleEffect + offset
- Rack tiles can be reordered by dragging within the rack (animated live preview)
- Game state persists across launches via UserDefaults (auto-saves after each move)
- LetterString is FixedLengthString (max 40 chars); use LongLetterString (std::string) for bag-sized data
- Bundle ID: `com.bef.quacklescrabble`
- Lexicon: TWL06
