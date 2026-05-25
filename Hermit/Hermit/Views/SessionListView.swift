import SwiftUI

struct SessionListView: View {
    @Environment(DataStore.self) private var dataStore
    @State private var showingNewHost = false
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if dataStore.hosts.isEmpty {
                    ContentUnavailableView(
                        "No Hosts",
                        systemImage: "server.rack",
                        description: Text("Add a host to open a mobile tmux control session.")
                    )
                } else {
                    hostList
                }
            }
            .navigationTitle("Hermit")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gear")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNewHost = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Host")
                }
            }
            .sheet(isPresented: $showingNewHost) {
                NewHostView()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }

    private var hostList: some View {
        List {
            Section("Hosts") {
                ForEach(dataStore.hosts.sorted { $0.displayName < $1.displayName }) { host in
                    NavigationLink {
                        RemoteSessionListView(host: host)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(host.displayName)
                                .font(.body.weight(.medium))
                            Text("\(host.username)@\(host.hostname):\(host.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("mobile session: \(host.defaultTmuxSessionName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            dataStore.deleteHost(host)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }
}
