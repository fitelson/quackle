import SwiftUI

struct OpponentRackView: View {
    @Environment(QuackleEngine.self) var engine

    var body: some View {
        let count = engine.opponentTileCount
        let animatingCount = engine.isAnimatingAIMove ? engine.aiAnimTiles.count : 0
        let visibleCount = max(0, count - animatingCount)

        HStack(spacing: 3) {
            ForEach(0..<visibleCount, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(red: 1.0, green: 0.92, blue: 0.80))
                    .frame(width: 44, height: 44)
                    .shadow(radius: 1)
            }
        }
        .overlay {
            GeometryReader { geo in
                Color.clear.onAppear {
                    let frame = geo.frame(in: .named("game"))
                    engine.opponentRackOrigin = CGPoint(x: frame.midX, y: frame.midY)
                    engine.opponentTileSize = 44
                }
                .onChange(of: geo.size) {
                    let frame = geo.frame(in: .named("game"))
                    engine.opponentRackOrigin = CGPoint(x: frame.midX, y: frame.midY)
                }
            }
        }
        .frame(height: 48)
    }
}
