import SwiftUI

struct AIAnimationOverlay: View {
    @Environment(QuackleEngine.self) var engine

    private let tileSize: CGFloat = 44
    private let rackSpacing: CGFloat = 3

    var body: some View {
        let phase = engine.aiAnimPhase
        let tiles = engine.aiAnimTiles
        let totalRack = engine.opponentTileCount

        ForEach(tiles) { tile in
            let rackPos = engine.rackPositionForIndex(
                tile.rackIndex,
                tileWidth: tileSize,
                spacing: rackSpacing,
                totalCount: totalRack
            )
            let boardPos = engine.boardPositionForSquare(
                row: tile.targetRow,
                col: tile.targetCol
            )
            let boardSize = engine.boardSquareSizeForDrag

            // Phase 0: blank at rack, Phase 1: face-up at rack, Phase 2: face-up at board
            let atBoard = phase >= 2
            let isRevealed = phase >= 1
            let targetPos = atBoard ? boardPos : rackPos
            let targetSize = atBoard ? boardSize : tileSize

            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 1.0, green: 0.92, blue: 0.80))
                    .shadow(radius: isRevealed ? 3 : 1)

                if isRevealed {
                    Text(tile.isBlank ? tile.letter.lowercased() : tile.letter)
                        .font(.system(size: targetSize * 0.5, weight: .bold))
                        .foregroundColor(tile.isBlank ? .red : .black)

                    if !tile.isBlank {
                        Text("\(tile.points)")
                            .font(.system(size: targetSize * 0.22, weight: .bold))
                            .foregroundColor(.black.opacity(0.5))
                            .padding(targetSize * 0.04)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                }
            }
            .frame(width: targetSize, height: targetSize)
            .rotation3DEffect(
                .degrees(isRevealed ? 360 : 180),
                axis: (x: 0, y: 1, z: 0)
            )
            .position(targetPos)
        }
    }
}
