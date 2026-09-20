import Foundation

#if DEBUG && targetEnvironment(simulator)
@MainActor
enum SimulatorSelfTestRunner {
    static func runIfRequested(dataStore: DataStore) async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["HERMIT_SIM_SELFTEST_SWITCH"] == "1" else { return }

        let hostName = environment["HERMIT_SIM_HOST_NAME"] ?? "Simulator Local Mac"
        let sessionName = environment["HERMIT_SIM_TMUX_SESSION"] ?? "hermit-switch-test"
        let windowNames = (environment["HERMIT_SIM_SWITCH_WINDOWS"] ?? "alpha,beta,gamma")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var report: [String: Any] = [
            "host": hostName,
            "session": sessionName,
            "requestedWindows": windowNames,
            "startedAt": ISO8601DateFormatter().string(from: Date())
        ]

        guard var host = dataStore.hosts.first(where: { $0.displayName == hostName }) else {
            report["success"] = false
            report["error"] = "host not found"
            write(report)
            return
        }

        if environment["HERMIT_SIM_SELFTEST_JUMP"] == "1" {
            host.jumpHost = SSHJumpHost(
                hostname: environment["HERMIT_SIM_JUMP_HOST"] ?? host.hostname,
                port: Int(environment["HERMIT_SIM_JUMP_PORT"] ?? "") ?? host.port,
                username: environment["HERMIT_SIM_JUMP_USER"] ?? host.username,
                privateKeyRef: host.privateKeyRef
            )
        }
        report["jumpHost"] = host.jumpHost != nil

        let model = TmuxWorkspaceModel(host: host)
        report["phase"] = "connecting"
        write(report)
        await model.connectIfNeeded()

        guard model.status == .connected else {
            report["success"] = false
            report["error"] = String(describing: model.status)
            write(report)
            return
        }

        await model.refreshSessions()
        report["phase"] = "connected"
        write(report)

        guard let session = model.sessions.first(where: { $0.name == sessionName }) else {
            report["success"] = false
            report["error"] = "session not found"
            report["sessions"] = model.sessions.map(\.name)
            write(report)
            await model.disconnect()
            return
        }

        report["phase"] = "refreshing windows"
        write(report)
        await model.refreshWindows(for: session)

        var results: [[String: Any]] = []
        var success = true

        for name in windowNames {
            report["phase"] = "selecting \(name)"
            write(report)
            guard let window = model.windows(for: session).first(where: { $0.name == name }) else {
                success = false
                results.append(["window": name, "success": false, "error": "window not found"])
                continue
            }

            await model.selectWindow(window, in: session)
            await model.refreshWindows(for: session)

            let refreshedWindow = model.windows(for: session).first(where: { $0.id == window.id }) ?? window
            let pane = model.activePane(for: refreshedWindow) ?? model.panes(for: refreshedWindow).first
            if let pane {
                await model.captureLive(pane)
            }

            let snapshotText = pane.flatMap { model.snapshotsByPane[$0.id]?.rawText } ?? ""
            let activeWindowName = model.windows(for: session).first(where: \.isActive)?.name ?? ""
            let matched = activeWindowName == name && snapshotText.localizedCaseInsensitiveContains(name)
            success = success && matched
            results.append([
                "window": name,
                "selectedActiveWindow": activeWindowName,
                "snapshotContainsWindowName": snapshotText.localizedCaseInsensitiveContains(name),
                "success": matched
            ])
        }

        let reconnectCycles = min(100, max(0, Int(environment["HERMIT_SIM_RECONNECT_CYCLES"] ?? "0") ?? 0))
        var reconnectResults: [[String: Any]] = []
        for cycle in 0..<reconnectCycles {
            report["phase"] = "reconnecting \(cycle + 1)"
            write(report)
            await model.reconnect()
            guard model.status == .connected,
                  let currentSession = model.sessions.first(where: { $0.id == session.id }) else {
                success = false
                reconnectResults.append([
                    "cycle": cycle + 1, "success": false, "error": "reconnect failed",
                    "status": String(describing: model.status), "detail": model.errorMessage ?? "",
                    "sessionIDs": model.sessions.map(\.id)
                ])
                break
            }
            await model.refreshWindows(for: currentSession)
            guard let window = model.windows(for: currentSession).first(where: { windowNames.contains($0.name) }) else {
                success = false
                reconnectResults.append(["cycle": cycle + 1, "success": false, "error": "window missing after reconnect"])
                break
            }
            await model.selectWindow(window, in: currentSession)
            guard let pane = model.activePane(for: window) ?? model.panes(for: window).first else {
                success = false
                reconnectResults.append(["cycle": cycle + 1, "success": false, "error": "pane missing after reconnect"])
                break
            }
            model.setFollow(pane.id, enabled: true)
            await model.captureLive(pane)
            let firstFrame = model.snapshotsByPane[pane.id]?.rawText ?? ""
            try? await Task.sleep(for: .milliseconds(300))
            await model.captureLive(pane)
            let lastFrame = model.snapshotsByPane[pane.id]?.rawText ?? ""
            let isStreaming = !lastFrame.isEmpty && firstFrame != lastFrame

            // Close with a history read in flight, as when a busy terminal is backgrounded.
            let pendingRead = Task { await model.captureScrollback(pane) }
            try? await Task.sleep(for: .milliseconds(cycle % 5 + 1))
            await model.disconnect()
            await pendingRead.value
            let disconnected = model.status == .disconnected
            let passed = isStreaming && disconnected
            success = success && passed
            reconnectResults.append([
                "cycle": cycle + 1, "streaming": isStreaming,
                "disconnected": disconnected, "success": passed
            ])
            report["completedReconnectCycles"] = cycle + 1
            report["reconnectResults"] = reconnectResults
            write(report)
        }

        report["success"] = success
        report["phase"] = "finished"
        report["results"] = results
        report["reconnectResults"] = reconnectResults
        write(report)
        await model.disconnect()
    }

    private static func write(_ report: [String: Any]) {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: documents.appendingPathComponent("hermit-sim-selftest.json"), options: .atomic)
    }
}
#endif
