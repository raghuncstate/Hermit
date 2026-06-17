import SwiftUI

@Observable
final class AppNavigator {
    var shortcutRequest: TmuxShortcutNavigationRequest?

    func open(_ shortcut: TmuxShortcut) {
        shortcutRequest = TmuxShortcutNavigationRequest(shortcut: shortcut)
    }

    func clearShortcutRequest() {
        shortcutRequest = nil
    }
}

struct TmuxShortcutNavigationRequest: Equatable {
    var id = UUID()
    var shortcut: TmuxShortcut
}

@main
struct HermitApp: App {
    @State private var dataStore = DataStore()
    @State private var navigator = AppNavigator()
    @State private var voiceCoordinator = VoiceInputCoordinator()
    @State private var showingAbout = !AboutView.hasSeenAbout

    var body: some Scene {
        WindowGroup {
            SessionListView()
                .environment(dataStore)
                .environment(navigator)
                .environment(voiceCoordinator)
                .onOpenURL { url in
                    voiceCoordinator.handleCallbackURL(url)
                }
                .sheet(isPresented: $showingAbout) {
                    AboutView.hasSeenAbout = true
                } content: {
                    AboutView()
                }
                #if DEBUG && targetEnvironment(simulator)
                .task {
                    await SimulatorSelfTestRunner.runIfRequested(dataStore: dataStore)
                }
                #endif
        }
    }
}
