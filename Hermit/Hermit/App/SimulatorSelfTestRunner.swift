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
            "requestedWindows": windowNames
        ]

        guard let host = dataStore.hosts.first(where: { $0.displayName == hostName }) else {
            report["success"] = false
            report["error"] = "host not found"
            write(report)
            return
        }

        let model = TmuxWorkspaceModel(host: host)
        await model.connectIfNeeded()

        guard model.status == .connected else {
            report["success"] = false
            report["error"] = String(describing: model.status)
            write(report)
            return
        }

        await model.refreshSessions()

        guard let session = model.sessions.first(where: { $0.name == sessionName }) else {
            report["success"] = false
            report["error"] = "session not found"
            report["sessions"] = model.sessions.map(\.name)
            write(report)
            await model.disconnect()
            return
        }

        await model.refreshWindows(for: session)

        var results: [[String: Any]] = []
        var success = true

        for name in windowNames {
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

        report["success"] = success
        report["results"] = results
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
