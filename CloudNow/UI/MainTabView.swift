import SwiftUI

struct MainTabView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = GamesViewModel()
    @State private var gameToPlay: GameInfo?
    @State private var sessionToResume: ActiveSessionInfo? = nil
    @State private var directSessionToResume: SessionInfo? = nil
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                HomeView(
                    onPlay: { game in
                        directSessionToResume = nil
                        sessionToResume = viewModel.activeSessions.first { session in
                            game.variants.contains { v in
                                guard let appId = v.appId, let sessionAppId = session.appId else { return false }
                                return appId == sessionAppId
                            }
                        }
                        gameToPlay = game
                    },
                    onResume: { rs in
                        directSessionToResume = rs.session
                        sessionToResume = nil
                        gameToPlay = rs.game
                    }
                )
            }
            Tab("Library", systemImage: "books.vertical.fill") {
                LibraryView(games: viewModel.libraryGames, onPlay: { gameToPlay = $0 })
            }
Tab("Settings", systemImage: "gearshape.fill") {
                SettingsView()
            }
        }
        .environment(viewModel)
        .overlay(alignment: .top) {
            if viewModel.showRefreshComplete {
                Text("Games updated")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.green.opacity(0.85), in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .padding(.top, 12)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.showRefreshComplete)
        .onChange(of: viewModel.showRefreshComplete) { _, showing in
            guard showing else { return }
            dismissTask?.cancel()
            dismissTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                withAnimation { viewModel.showRefreshComplete = false }
            }
        }
        .task { await viewModel.load(authManager: authManager) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await viewModel.refreshLibrary(authManager: authManager) }
        }
        .onChange(of: viewModel.streamSettings) { viewModel.saveSettings() }
        .onChange(of: gameToPlay) { _, new in
            if new == nil {
                directSessionToResume = nil
                Task { await viewModel.refreshActiveSessions(authManager: authManager) }
            } else if directSessionToResume == nil {
                if let rs = viewModel.resumableSession,
                   rs.game.id == new?.id,
                   let ctrl = rs.streamController,
                   ctrl.state == .streaming {
                    directSessionToResume = rs.session
                } else {
                    viewModel.resumableSession?.streamController?.disconnect()
                    viewModel.resumableSession = nil
                }
            }
        }
        .fullScreenCover(item: $gameToPlay) { game in
            StreamView(
                game: game,
                settings: viewModel.streamSettings,
                existingSession: sessionToResume,
                directSession: directSessionToResume,
                liveController: viewModel.resumableSession?.streamController,
                onDismiss: {
                    gameToPlay = nil
                    sessionToResume = nil
                },
                onLeave: { leftGame, session, controller in
                    viewModel.resumableSession = ResumableSession(
                        game: leftGame,
                        session: session,
                        leftAt: Date(),
                        streamController: controller
                    )
                }
            )
            .environment(authManager)
            .environment(viewModel)
        }
    }
}
