import SwiftUI

struct BoardView: View {
    @Environment(QuackleEngine.self) var engine

    private let spacing: CGFloat = 0.5
    private let labelWidth: CGFloat = 16

    @State private var zoomScale: CGFloat = 1.0
    @State private var zoomAnchor: UnitPoint = .center
    @State private var dragOffset: CGSize = .zero
    @State private var lastDragOffset: CGSize = .zero

    private var isZoomed: Bool { zoomScale > 1.0 }
    private let zoomedScale: CGFloat = 2.5

    var body: some View {
        let board = engine.board
        if board.isEmpty {
            Text("No board")
        } else {
            let cols = CGFloat(board[0].count)
            let rows = CGFloat(board.count)
            let ratio = cols / (rows + 0.5)

            GeometryReader { geo in
                let totalHSpacing = spacing * (cols - 1)
                let squareSize = (geo.size.width - labelWidth - totalHSpacing) / cols
                let headerHeight = squareSize * 0.5

                VStack(spacing: 0) {
                    // Column headers
                    HStack(spacing: spacing) {
                        Color.clear
                            .frame(width: labelWidth, height: headerHeight)
                        ForEach(0..<board[0].count, id: \.self) { col in
                            Text(String(UnicodeScalar(65 + col)!))
                                .font(.system(size: max(7, squareSize * 0.35), weight: .bold))
                                .frame(width: squareSize, height: headerHeight)
                        }
                    }

                    ForEach(0..<board.count, id: \.self) { row in
                        HStack(spacing: spacing) {
                            Text("\(row + 1)")
                                .font(.system(size: max(7, squareSize * 0.3), weight: .bold))
                                .frame(width: labelWidth, height: squareSize)

                            ForEach(0..<board[row].count, id: \.self) { col in
                                SquareView(
                                    square: board[row][col],
                                    tentative: engine.tentativeLetterAt(row: row, col: col),
                                    isValid: engine.isTentativeMoveValid,
                                    hasTentativeTiles: !engine.tentativePlacements.isEmpty,
                                    row: row,
                                    col: col,
                                    size: squareSize
                                )
                                .onTapGesture {
                                    engine.handleBoardTap(row: row, col: col)
                                }
                            }
                        }
                    }
                }
                .scaleEffect(zoomScale, anchor: zoomAnchor)
                .offset(x: dragOffset.width, y: dragOffset.height)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if isZoomed {
                                dragOffset = CGSize(
                                    width: lastDragOffset.width + value.translation.width,
                                    height: lastDragOffset.height + value.translation.height
                                )
                            }
                        }
                        .onEnded { value in
                            if isZoomed {
                                lastDragOffset = dragOffset
                                // Clamp so board doesn't fly off screen
                                let maxX = geo.size.width * (zoomScale - 1) / 2
                                let maxY = geo.size.height * (zoomScale - 1) / 2
                                withAnimation(.easeOut(duration: 0.2)) {
                                    dragOffset.width = min(max(dragOffset.width, -maxX), maxX)
                                    dragOffset.height = min(max(dragOffset.height, -maxY), maxY)
                                }
                                lastDragOffset = dragOffset
                            }
                        }
                )
                .onTapGesture(count: 2) { location in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        if isZoomed {
                            zoomScale = 1.0
                            dragOffset = .zero
                            lastDragOffset = .zero
                        } else {
                            // Zoom into the tapped point
                            zoomAnchor = UnitPoint(
                                x: location.x / geo.size.width,
                                y: location.y / geo.size.height
                            )
                            zoomScale = zoomedScale
                            dragOffset = .zero
                            lastDragOffset = .zero
                        }
                    }
                }
            }
            .aspectRatio(ratio, contentMode: .fit)
            .clipped()
        }
    }
}

struct SquareView: View {
    let square: SquareModel
    let tentative: TilePlacement?
    let isValid: Bool
    let hasTentativeTiles: Bool
    let row: Int
    let col: Int
    let size: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(backgroundColor)
                .frame(width: size, height: size)

            if let t = tentative {
                Text(t.isBlank ? t.letter.lowercased() : t.letter)
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundColor(.white)
            } else if let letter = square.letter {
                Text(square.isBlank ? letter.lowercased() : letter)
                    .font(.system(size: size * 0.55, weight: .bold))
                    .foregroundColor(square.isBlank ? .red : .black)
            } else {
                Text(bonusText)
                    .font(.system(size: size * 0.22, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }

    var bonusText: String {
        switch square.bonus {
        case .tripleWord: return "TW"
        case .doubleWord: return "DW"
        case .tripleLetter: return "TL"
        case .doubleLetter: return "DL"
        case .none:
            if row == 7 && col == 7 { return "\u{2605}" }
            return ""
        }
    }

    var backgroundColor: Color {
        if tentative != nil {
            // Red if invalid, green if valid
            if hasTentativeTiles && isValid {
                return Color(red: 0.2, green: 0.7, blue: 0.2) // green
            } else {
                return Color(red: 0.85, green: 0.25, blue: 0.25) // red
            }
        }
        if square.letter != nil {
            return Color(red: 1.0, green: 0.92, blue: 0.80)
        }
        switch square.bonus {
        case .tripleWord: return Color(red: 0.94, green: 0.31, blue: 0.37)
        case .doubleWord: return Color(red: 1.0, green: 0.58, blue: 0.77)
        case .tripleLetter: return Color(red: 0.11, green: 0.41, blue: 0.94)
        case .doubleLetter: return Color(red: 0.13, green: 0.74, blue: 0.94)
        case .none:
            if row == 7 && col == 7 {
                return Color(red: 1.0, green: 0.58, blue: 0.77)
            }
            return Color(red: 0.95, green: 0.93, blue: 0.88)
        }
    }
}
