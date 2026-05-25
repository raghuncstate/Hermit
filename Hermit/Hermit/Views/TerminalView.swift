import SwiftUI

struct TerminalView: View {
    let session: Session

    @Environment(DataStore.self) private var dataStore

    var body: some View {
        if let host = dataStore.host(for: session) {
            RemoteSessionListView(host: host)
        } else {
            ContentUnavailableView("Host Missing", systemImage: "server.rack")
        }
    }
}
