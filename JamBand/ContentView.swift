import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            switch state.phase {
            case .lobby:
                LobbyView()
            case .countdown, .playing:
                PlayingView()
            }
        }
        .onAppear { state.startServices() }
    }
}
