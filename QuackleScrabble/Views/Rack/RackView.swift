import SwiftUI

struct RackView: View {
    @Environment(QuackleEngine.self) var engine

    private var rackDisplayOrder: [TileModel] {
        guard case .rack(let dragId) = engine.activeDragSource,
              let targetIdx = engine.rackReorderIndex else {
            return engine.availableRack
        }
        var tiles = engine.availableRack
        guard let fromIdx = tiles.firstIndex(where: { $0.id == dragId }) else {
            return engine.availableRack
        }
        if fromIdx == targetIdx { return tiles }
        let tile = tiles.remove(at: fromIdx)
        tiles.insert(tile, at: min(targetIdx, tiles.count))
        return tiles
    }

    var body: some View {
        HStack(spacing: 3) {
            if engine.isExchangeMode {
                // Exchange mode: show all rack tiles, tap to toggle selection
                ForEach(engine.rack) { tile in
                    let isSelected = engine.exchangeSelectedIds.contains(tile.id)
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected
                                  ? Color(red: 1.0, green: 0.6, blue: 0.6)
                                  : Color(red: 1.0, green: 0.92, blue: 0.80))
                            .frame(width: 44, height: 44)
                            .shadow(radius: 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(isSelected ? Color.red : Color.clear, lineWidth: 2)
                            )

                        Text(tile.isBlank ? "?" : tile.letter)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.black)

                        if !tile.isBlank {
                            Text("\(tile.points)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.black.opacity(0.6))
                                .padding(3)
                                .frame(width: 44, height: 44, alignment: .bottomTrailing)
                        }
                    }
                    .onTapGesture {
                        engine.toggleExchangeTile(tile)
                    }
                }
            } else {
                // Normal mode: drag tiles to the board (with live reorder preview)
                ForEach(rackDisplayOrder) { tile in
                    ZStack {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(red: 1.0, green: 0.92, blue: 0.80))
                            .frame(width: 44, height: 44)
                            .shadow(radius: 1)

                        Text(tile.isBlank ? "?" : tile.letter)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(.black)

                        if !tile.isBlank {
                            Text("\(tile.points)")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.black.opacity(0.6))
                                .padding(3)
                                .frame(width: 44, height: 44, alignment: .bottomTrailing)
                        }
                    }
                    .opacity(engine.activeDragSource == .rack(tileId: tile.id) ? 0.3 : 1.0)
                    .gesture(
                        DragGesture(minimumDistance: 5, coordinateSpace: .named("game"))
                            .onChanged { value in
                                if engine.activeDragSource == nil {
                                    engine.startDragFromRack(tile: tile)
                                }
                                engine.updateDragLocation(value.location)
                            }
                            .onEnded { _ in
                                engine.endDrag()
                            }
                    )
                }
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.task(id: geo.size.width) {
                    engine.rackFrame = geo.frame(in: .named("game"))
                }
            }
        )
        .padding(.vertical, 8)
    }
}
