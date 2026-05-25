import SwiftUI

struct PaneLayoutView: View {
    var layout: String
    var panes: [TmuxPane]
    var activePaneId: String?
    var onSelect: ((TmuxPane) -> Void)?
    var compact = false

    var body: some View {
        GeometryReader { proxy in
            let parsed = try? PaneLayoutParser.parse(layout)
            let leaves = parsed?.leaves ?? fallbackLeaves
            let root = parsed?.rect ?? PaneLayoutRect(width: max(1, panes.count), height: 1, x: 0, y: 0)

            ZStack(alignment: .topLeading) {
                ForEach(leaves) { leaf in
                    if let pane = pane(for: leaf) {
                        paneRectangle(pane: pane)
                            .frame(
                                width: PaneLayoutParser.frame(for: leaf.rect, in: proxy.size, root: root).width,
                                height: PaneLayoutParser.frame(for: leaf.rect, in: proxy.size, root: root).height
                            )
                            .position(
                                x: PaneLayoutParser.frame(for: leaf.rect, in: proxy.size, root: root).midX,
                                y: PaneLayoutParser.frame(for: leaf.rect, in: proxy.size, root: root).midY
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect?(pane)
                            }
                    }
                }
            }
        }
    }

    private func paneRectangle(pane: TmuxPane) -> some View {
        let isActive = pane.id == activePaneId || (activePaneId == nil && pane.isActive)
        return RoundedRectangle(cornerRadius: compact ? 4 : 6)
            .fill(isActive ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 4 : 6)
                    .stroke(isActive ? Color.accentColor : Color.secondary.opacity(0.28), lineWidth: isActive ? 2 : 1)
            )
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.id)
                        .font(.system(size: compact ? 8 : 11, weight: .semibold, design: .monospaced))
                    if !compact {
                        Text(pane.currentCommand)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(compact ? 3 : 6)
                .minimumScaleFactor(0.7)
            }
    }

    private func pane(for leaf: PaneLayoutLeaf) -> TmuxPane? {
        panes.first { $0.index == leaf.paneIndex }
    }

    private var fallbackLeaves: [PaneLayoutLeaf] {
        let count = max(1, panes.count)
        return panes.enumerated().map { offset, pane in
            PaneLayoutLeaf(
                paneIndex: pane.index,
                rect: PaneLayoutRect(width: 1, height: 1, x: offset % count, y: 0)
            )
        }
    }
}
