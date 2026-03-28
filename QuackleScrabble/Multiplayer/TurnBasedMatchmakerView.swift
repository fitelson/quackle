import SwiftUI
import GameKit

#if os(iOS)
struct TurnBasedMatchmakerView: UIViewControllerRepresentable {
    @Environment(GameCenterManager.self) var manager

    func makeUIViewController(context: Context) -> GKTurnBasedMatchmakerViewController {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        let vc = GKTurnBasedMatchmakerViewController(matchRequest: request)
        vc.turnBasedMatchmakerDelegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: GKTurnBasedMatchmakerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager)
    }

    class Coordinator: NSObject, GKTurnBasedMatchmakerViewControllerDelegate {
        let manager: GameCenterManager

        init(manager: GameCenterManager) {
            self.manager = manager
        }

        func turnBasedMatchmakerViewControllerWasCancelled(_ viewController: GKTurnBasedMatchmakerViewController) {
            Task { @MainActor in
                self.manager.showMatchmaker = false
            }
        }

        func turnBasedMatchmakerViewController(_ viewController: GKTurnBasedMatchmakerViewController, didFailWithError error: Error) {
            Task { @MainActor in
                self.manager.showMatchmaker = false
                self.manager.engine?.errorMessage = error.localizedDescription
            }
        }

        func turnBasedMatchmakerViewController(_ viewController: GKTurnBasedMatchmakerViewController, didFind match: GKTurnBasedMatch) {
            Task { @MainActor in
                self.manager.handleMatchFound(match)
            }
        }
    }
}

#else
struct TurnBasedMatchmakerView: NSViewControllerRepresentable {
    @Environment(GameCenterManager.self) var manager

    func makeNSViewController(context: Context) -> GKTurnBasedMatchmakerViewController {
        let request = GKMatchRequest()
        request.minPlayers = 2
        request.maxPlayers = 2
        let vc = GKTurnBasedMatchmakerViewController(matchRequest: request)
        vc.turnBasedMatchmakerDelegate = context.coordinator
        return vc
    }

    func updateNSViewController(_ nsViewController: GKTurnBasedMatchmakerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(manager: manager)
    }

    class Coordinator: NSObject, GKTurnBasedMatchmakerViewControllerDelegate {
        let manager: GameCenterManager

        init(manager: GameCenterManager) {
            self.manager = manager
        }

        func turnBasedMatchmakerViewControllerWasCancelled(_ viewController: GKTurnBasedMatchmakerViewController) {
            Task { @MainActor in
                self.manager.showMatchmaker = false
            }
        }

        func turnBasedMatchmakerViewController(_ viewController: GKTurnBasedMatchmakerViewController, didFailWithError error: Error) {
            Task { @MainActor in
                self.manager.showMatchmaker = false
                self.manager.engine?.errorMessage = error.localizedDescription
            }
        }

        func turnBasedMatchmakerViewController(_ viewController: GKTurnBasedMatchmakerViewController, didFind match: GKTurnBasedMatch) {
            Task { @MainActor in
                self.manager.handleMatchFound(match)
            }
        }
    }
}
#endif
