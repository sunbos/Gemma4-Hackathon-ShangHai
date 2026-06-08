import SwiftUI

struct MeetingMindMapCanvas: View {
    let nodes: [MindMapNode]
    var rootTitle: String = "会议"

    private let branchColors: [Color] = [.blue, .green, .orange, .teal, .purple, .pink]

    var body: some View {
        if nodes.isEmpty {
            Text("暂无思维导图")
                .foregroundStyle(.secondary)
        } else {
            ScrollView([.horizontal, .vertical]) {
                HStack(alignment: .center, spacing: 0) {
                    rootNode
                        .anchorPreference(key: MindMapCanvasAnchorKey.self, value: .bounds) {
                            MindMapCanvasAnchors(root: $0)
                        }

                    VStack(alignment: .leading, spacing: 18) {
                        ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                            MindMapTopicBranch(
                                node: node,
                                color: color(for: index)
                            )
                            .anchorPreference(key: MindMapCanvasAnchorKey.self, value: .bounds) { anchor in
                                MindMapCanvasAnchors(topics: [MindMapTopicAnchor(index: index, anchor: anchor)])
                            }
                            .padding(.leading, 72)
                        }
                    }
                }
                .padding(18)
                .frame(minWidth: 900, alignment: .leading)
                .backgroundPreferenceValue(MindMapCanvasAnchorKey.self) { anchors in
                    GeometryReader { proxy in
                        if let rootAnchor = anchors.root {
                            MindMapConnectorLayer(
                                rootFrame: proxy[rootAnchor],
                                topics: anchors.topics.map {
                                    MindMapTopicFrame(
                                        index: $0.index,
                                        frame: proxy[$0.anchor]
                                    )
                                },
                                colors: branchColors
                            )
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 360, maxHeight: 620, alignment: .leading)
            .background(.quaternary.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var rootNode: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.blue.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue.opacity(0.42), lineWidth: 1)
                )
            VStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text(rootTitle)
                    .font(.headline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Text("思维导图")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .frame(width: 150, height: 104)
    }

    private func color(for index: Int) -> Color {
        branchColors[index % branchColors.count]
    }
}

private struct MindMapTopicBranch: View {
    let node: MindMapNode
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(node.title)
                .font(.subheadline.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if node.children.isEmpty {
                Text("暂无子议题")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
                    ForEach(node.children) { child in
                        MindMapSubtopicCard(node: child, color: color)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 660, alignment: .leading)
        .background(.background)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.34), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 190, maximum: 315), spacing: 10, alignment: .topLeading),
            GridItem(.flexible(minimum: 190, maximum: 315), spacing: 10, alignment: .topLeading)
        ]
    }
}

private struct MindMapSubtopicCard: View {
    let node: MindMapNode
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                Text(node.title)
                    .font(.caption.weight(.semibold))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(flattenedLeaves(from: node.children).prefix(8)) { leaf in
                        Text(leaf.title)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(color.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        .background(.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func flattenedLeaves(from nodes: [MindMapNode]) -> [MindMapNode] {
        nodes.flatMap { node -> [MindMapNode] in
            if node.children.isEmpty {
                return [node]
            }
            return [node] + flattenedLeaves(from: node.children)
        }
    }
}

private struct MindMapTopicAnchor {
    let index: Int
    let anchor: Anchor<CGRect>
}

private struct MindMapCanvasAnchors {
    var root: Anchor<CGRect>?
    var topics: [MindMapTopicAnchor] = []
}

private struct MindMapCanvasAnchorKey: PreferenceKey {
    static let defaultValue = MindMapCanvasAnchors()

    static func reduce(value: inout MindMapCanvasAnchors, nextValue: () -> MindMapCanvasAnchors) {
        let next = nextValue()
        value.root = value.root ?? next.root
        value.topics.append(contentsOf: next.topics)
    }
}

private struct MindMapTopicFrame {
    let index: Int
    let frame: CGRect
}

private struct MindMapConnectorLayer: View {
    let rootFrame: CGRect
    let topics: [MindMapTopicFrame]
    let colors: [Color]

    var body: some View {
        Canvas { context, size in
            guard !topics.isEmpty else { return }

            let rootPort = CGPoint(x: rootFrame.maxX, y: rootFrame.midY)
            let sortedTopics = topics.sorted { lhs, rhs in
                if lhs.frame.midY == rhs.frame.midY {
                    return lhs.index < rhs.index
                }
                return lhs.frame.midY < rhs.frame.midY
            }
            let trunkX = rootPort.x + 36
            let minTopicY = sortedTopics.map(\.frame.midY).min() ?? rootPort.y
            let maxTopicY = sortedTopics.map(\.frame.midY).max() ?? rootPort.y

            var rootStub = Path()
            rootStub.move(to: rootPort)
            rootStub.addLine(to: CGPoint(x: trunkX, y: rootPort.y))
            context.stroke(rootStub, with: .color(Color.blue.opacity(0.38)), lineWidth: 2)

            var trunk = Path()
            trunk.move(to: CGPoint(x: trunkX, y: min(rootPort.y, minTopicY)))
            trunk.addLine(to: CGPoint(x: trunkX, y: max(rootPort.y, maxTopicY)))
            context.stroke(trunk, with: .color(Color.blue.opacity(0.26)), lineWidth: 2)

            let rootDot = CGRect(x: rootPort.x - 5, y: rootPort.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: rootDot), with: .color(Color.blue))

            for topic in sortedTopics {
                let color = colors[topic.index % colors.count]
                let topicPort = CGPoint(x: topic.frame.minX, y: topic.frame.midY)

                var branch = Path()
                branch.move(to: CGPoint(x: trunkX, y: topicPort.y))
                branch.addLine(to: topicPort)
                context.stroke(branch, with: .color(color.opacity(0.58)), lineWidth: 2)

                let topicDot = CGRect(x: topicPort.x - 5, y: topicPort.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: topicDot), with: .color(color))
            }
        }
        .allowsHitTesting(false)
    }
}
