import SwiftUI

struct NewHostView: View {
    @Environment(DataStore.self) private var dataStore
    @Environment(\.dismiss) private var dismiss

    var onCreated: ((Host) -> Void)?

    @State private var displayName = ""
    @State private var hostname = ""
    @State private var port = "22"
    @State private var username = ""
    @State private var defaultTmuxSessionName = "0"
    @State private var tmuxCommand = ""
    @State private var privateKeyPEM = ""
    @State private var usesJumpHost = false
    @State private var jumpHostname = ""
    @State private var jumpPort = "22"
    @State private var jumpUsername = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Display Name", text: $displayName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Hostname", text: $hostname)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Attach tmux Session", text: $defaultTmuxSessionName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("tmux Command", text: $tmuxCommand)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Private Key") {
                    TextEditor(text: $privateKeyPEM)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Text("Paste your PEM-encoded private key above.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Jump Host") {
                    Toggle("Connect through jump host", isOn: $usesJumpHost)
                    if usesJumpHost {
                        TextField("Jump Hostname", text: $jumpHostname)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Jump Port", text: $jumpPort)
                            .keyboardType(.numberPad)
                        TextField("Jump Username", text: $jumpUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Text("The jump host reuses this host's private key.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Host")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveHost() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !displayName.isEmpty &&
            !hostname.isEmpty &&
            !username.isEmpty &&
            (!usesJumpHost || (!jumpHostname.isEmpty && !jumpUsername.isEmpty))
    }

    private func saveHost() {
        let portNumber = Int(port) ?? 22
        let jumpPortNumber = Int(jumpPort) ?? 22
        let keychainRef = "ssh-key-\(UUID().uuidString)"

        if !privateKeyPEM.isEmpty {
            guard let keyData = privateKeyPEM.data(using: .utf8) else {
                errorMessage = "Invalid key data"
                return
            }
            do {
                try KeychainManager.save(key: keychainRef, data: keyData)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        let host = Host(
            displayName: displayName,
            hostname: hostname,
            port: portNumber,
            username: username,
            privateKeyRef: privateKeyPEM.isEmpty ? "" : keychainRef,
            jumpHost: usesJumpHost ? SSHJumpHost(
                hostname: jumpHostname,
                port: jumpPortNumber,
                username: jumpUsername
            ) : nil,
            defaultTmuxSessionName: defaultTmuxSessionName.isEmpty ? "0" : defaultTmuxSessionName,
            tmuxCommand: tmuxCommand
        )
        dataStore.addHost(host)
        onCreated?(host)
        dismiss()
    }
}
