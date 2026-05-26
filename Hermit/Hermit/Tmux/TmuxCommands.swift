import Foundation

enum TmuxCommandQuoter {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension TmuxControlClient {
    func listSessions() async throws -> [TmuxSession] {
        let output = try await send("list-sessions -F '#{session_id}|#{session_name}|#{session_attached}|#{session_activity}'")
        return output.nonEmptyLines.compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3 else { return nil }
            let activity: Date?
            if fields.count > 3, let timestamp = TimeInterval(fields[3]) {
                activity = Date(timeIntervalSince1970: timestamp)
            } else {
                activity = nil
            }
            return TmuxSession(
                id: fields[0],
                name: fields[1],
                attachedCount: Int(fields[2]) ?? 0,
                activity: activity,
                windowCount: nil
            )
        }
    }

    func listWindows(sessionId: String) async throws -> [TmuxWindow] {
        let target = TmuxCommandQuoter.quote(sessionId)
        let output = try await send("list-windows -t \(target) -F '#{window_id}|#{window_index}|#{window_name}|#{window_active}|#{window_layout}'")
        return output.nonEmptyLines.compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 5 else { return nil }
            return TmuxWindow(
                id: fields[0],
                sessionId: sessionId,
                index: Int(fields[1]) ?? 0,
                name: fields[2],
                isActive: fields[3] == "1",
                layout: fields[4]
            )
        }
    }

    func listPanes(windowId: String) async throws -> [TmuxPane] {
        let target = TmuxCommandQuoter.quote(windowId)
        let output = try await send("list-panes -t \(target) -F '#{pane_id}|#{pane_index}|#{pane_title}|#{pane_active}|#{pane_width}|#{pane_height}|#{pane_current_command}'")
        return output.nonEmptyLines.compactMap { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7 else { return nil }
            return TmuxPane(
                id: fields[0],
                index: Int(fields[1]) ?? 0,
                title: fields[2],
                isActive: fields[3] == "1",
                width: Int(fields[4]) ?? 0,
                height: Int(fields[5]) ?? 0,
                currentCommand: fields[6]
            )
        }
    }

    func capturePane(paneId: String, historyLimit: Int = 3000) async throws -> String {
        let target = TmuxCommandQuoter.quote(paneId)
        if historyLimit <= 0 {
            return try await send("capture-pane -p -e -t \(target) -S 0")
        }
        return try await send("capture-pane -p -e -t \(target) -S -\(historyLimit)")
    }

    func selectPane(paneId: String) async throws {
        let target = TmuxCommandQuoter.quote(paneId)
        _ = try await send("select-pane -t \(target)")
    }

    func selectWindow(windowId: String) async throws {
        let target = TmuxCommandQuoter.quote(windowId)
        _ = try await send("select-window -t \(target)")
    }

    func newWindow(sessionId: String) async throws {
        let target = TmuxCommandQuoter.quote("\(sessionId):")
        _ = try await send("new-window -t \(target)")
    }

    func newSession(named name: String) async throws {
        _ = try await send("new-session -d -s \(TmuxCommandQuoter.quote(name))")
    }

    func killSession(sessionId: String) async throws {
        _ = try await send("kill-session -t \(TmuxCommandQuoter.quote(sessionId))")
    }

    func renameWindow(windowId: String, name: String) async throws {
        let target = TmuxCommandQuoter.quote(windowId)
        _ = try await send("rename-window -t \(target) \(TmuxCommandQuoter.quote(name))")
    }

    func killWindow(windowId: String) async throws {
        let target = TmuxCommandQuoter.quote(windowId)
        _ = try await send("kill-window -t \(target)")
    }

    func moveWindow(windowId: String, by offset: Int) async throws {
        let source = TmuxCommandQuoter.quote(windowId)
        let direction = offset < 0 ? ":-1" : ":+1"
        _ = try await send("swap-window -s \(source) -t \(TmuxCommandQuoter.quote(direction))")
    }

    func splitPane(paneId: String, vertical: Bool) async throws {
        let target = TmuxCommandQuoter.quote(paneId)
        _ = try await send("split-window -t \(target) \(vertical ? "-v" : "-h")")
    }

    func killPane(paneId: String) async throws {
        let target = TmuxCommandQuoter.quote(paneId)
        _ = try await send("kill-pane -t \(target)")
    }

    func swapPane(sourcePaneId: String, targetPaneId: String) async throws {
        _ = try await send("swap-pane -s \(TmuxCommandQuoter.quote(sourcePaneId)) -t \(TmuxCommandQuoter.quote(targetPaneId))")
    }

    func resizePane(paneId: String, cols: Int, rows: Int) async throws {
        let target = TmuxCommandQuoter.quote(paneId)
        _ = try await send("resize-pane -t \(target) -x \(cols) -y \(rows)")
    }

    func resizeDisplay(windowId: String, cols: Int, rows: Int) async throws {
        let target = TmuxCommandQuoter.quote(windowId)
        _ = try await send("refresh-client -C \(cols)x\(rows)")
        _ = try await send("resize-window -t \(target) -x \(cols) -y \(rows)")
    }

    func continuePaneOutput(paneId: String) async throws {
        let target = TmuxCommandQuoter.quote("\(paneId):continue")
        _ = try await send("refresh-client -A \(target)")
    }

    func sendText(_ text: String, to paneId: String, enter: Bool) async throws {
        let target = TmuxCommandQuoter.quote(paneId)
        if text.isEmpty {
            if enter {
                _ = try await send("send-keys -t \(target) Enter")
            }
            return
        }

        let suffix = enter ? " Enter" : ""
        _ = try await send("send-keys -t \(target) -- \(TmuxCommandQuoter.quote(text))\(suffix)")
    }

    func sendKey(_ key: String, to paneId: String) async throws {
        let target = TmuxCommandQuoter.quote(paneId)
        _ = try await send("send-keys -t \(target) \(key)")
    }

    func sendBackspace(count: Int, to paneId: String) async throws {
        guard count > 0 else { return }
        let target = TmuxCommandQuoter.quote(paneId)
        _ = try await send("send-keys -N \(count) -t \(target) BSpace")
    }
}

private extension String {
    var nonEmptyLines: [String] {
        split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
