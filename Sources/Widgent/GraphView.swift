import AppKit
import Combine
import SwiftUI

/// `[[링크]]`로 이어진 메모들의 힘-기반 배치 (옵시디언 Graph view와 같은 방식)
@MainActor
final class GraphModel: ObservableObject {
    struct Node {
        let id: String
        var name: String
        var position: CGPoint
        var velocity: CGVector = .zero
        var degree = 0
    }

    struct Edge: Hashable {
        let a: String
        let b: String
    }

    @Published private(set) var nodes: [String: Node] = [:]
    private(set) var edges: [Edge] = []
    private var neighborMap: [String: Set<String>] = [:]
    /// 온도. 높을수록 많이 움직이고, 식으면 시뮬레이션을 멈춤
    private var alpha: CGFloat = 1
    var pinned: String?
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.step() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func neighbors(of id: String) -> Set<String> { neighborMap[id] ?? [] }

    var bounds: CGRect {
        nodes.values.reduce(CGRect.null) { $0.union(CGRect(origin: $1.position, size: .zero)) }
    }

    func sync(with vault: Vault) {
        var edgeSet = Set<Edge>()
        for doc in vault.documents.values {
            for target in WikiLinks.targets(in: doc.text) {
                guard let other = vault.resolve(link: target), other.relativePath != doc.relativePath else { continue }
                let pair = [doc.relativePath, other.relativePath].sorted()
                edgeSet.insert(Edge(a: pair[0], b: pair[1]))
            }
        }

        var neighborMap: [String: Set<String>] = [:]
        for edge in edgeSet {
            neighborMap[edge.a, default: []].insert(edge.b)
            neighborMap[edge.b, default: []].insert(edge.a)
        }

        var changed = edgeSet != Set(edges) || vault.documents.count != nodes.count
        var newNodes: [String: Node] = [:]
        for doc in vault.documents.values {
            let id = doc.relativePath
            if var node = nodes[id] {
                node.name = doc.name
                node.degree = neighborMap[id]?.count ?? 0
                newNodes[id] = node
            } else {
                // 새 메모는 이미 있는 이웃 근처에서 태어남
                let base = neighborMap[id]?.lazy.compactMap { self.nodes[$0]?.position }.first ?? .zero
                newNodes[id] = Node(
                    id: id,
                    name: doc.name,
                    position: CGPoint(x: base.x + .random(in: -50...50), y: base.y + .random(in: -50...50)),
                    degree: neighborMap[id]?.count ?? 0
                )
                changed = true
            }
        }

        nodes = newNodes
        edges = Array(edgeSet)
        self.neighborMap = neighborMap
        if changed { alpha = max(alpha, 0.8) }
    }

    func move(_ id: String, to position: CGPoint) {
        nodes[id]?.position = position
        nodes[id]?.velocity = .zero
        alpha = max(alpha, 0.3)
    }

    private func step() {
        guard alpha > 0.005, !nodes.isEmpty else { return }
        var nodes = self.nodes
        let ids = Array(nodes.keys)
        var force: [String: CGVector] = Dictionary(uniqueKeysWithValues: ids.map { ($0, .zero) })

        // 모든 노드끼리 밀어냄
        for i in ids.indices {
            for j in (i + 1)..<ids.count {
                let a = nodes[ids[i]]!.position, b = nodes[ids[j]]!.position
                var dx = a.x - b.x, dy = a.y - b.y
                if dx == 0, dy == 0 { dx = .random(in: -1...1); dy = .random(in: -1...1) }
                let distSq = max(dx * dx + dy * dy, 400)
                let dist = distSq.squareRoot()
                let strength = 6000 / distSq
                force[ids[i]]!.dx += dx / dist * strength
                force[ids[i]]!.dy += dy / dist * strength
                force[ids[j]]!.dx -= dx / dist * strength
                force[ids[j]]!.dy -= dy / dist * strength
            }
        }

        // 링크는 용수철
        for edge in edges {
            guard let a = nodes[edge.a]?.position, let b = nodes[edge.b]?.position else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let dist = max((dx * dx + dy * dy).squareRoot(), 1)
            let strength = (dist - 110) * 0.04
            force[edge.a]!.dx += dx / dist * strength
            force[edge.a]!.dy += dy / dist * strength
            force[edge.b]!.dx -= dx / dist * strength
            force[edge.b]!.dy -= dy / dist * strength
        }

        for id in ids where id != pinned {
            var node = nodes[id]!
            let f = force[id]!
            // 가운데로 살짝 끌어당김 (링크 없는 메모가 멀리 도망가지 않게)
            node.velocity.dx = (node.velocity.dx + (f.dx - node.position.x * 0.006) * alpha) * 0.6
            node.velocity.dy = (node.velocity.dy + (f.dy - node.position.y * 0.006) * alpha) * 0.6
            node.position.x += node.velocity.dx
            node.position.y += node.velocity.dy
            nodes[id] = node
        }

        self.nodes = nodes
        if pinned == nil { alpha *= 0.985 }
    }
}

struct GraphView: View {
    @ObservedObject var vault: Vault
    @ObservedObject var runner: AgentRunner
    var onOpenNote: (String) -> Void

    @StateObject private var model = GraphModel()
    @State private var viewport = Viewport()
    @State private var size: CGSize = .zero
    @State private var hovered: String?
    @State private var dragging: DragMode?
    @State private var pinchBase: Viewport?

    private enum DragMode {
        case node(String)
        case pan(CGSize)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color(nsColor: .textBackgroundColor)
                ScrollCatcher { event, point in viewport.handleScroll(event, at: point) }
                Canvas { context, _ in draw(in: &context) }
                workingBadges
                fitButton
            }
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            .onContinuousHover { phase in
                if case .active(let point) = phase { hovered = hitTest(point) } else { hovered = nil }
            }
            .onAppear {
                size = geometry.size
                viewport.offset = CGSize(width: geometry.size.width / 2, height: geometry.size.height / 2)
                model.sync(with: vault)
                model.start()
                // 처음 배치가 어느 정도 자리를 잡은 뒤 화면에 맞춤
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeInOut(duration: 0.4)) { fitToContent() }
                }
            }
            .onDisappear { model.stop() }
            .onChange(of: geometry.size) { oldSize, newSize in
                size = newSize
                // 처음 크기가 정해질 때 원점을 가운데로
                if oldSize == .zero { viewport.offset = CGSize(width: newSize.width / 2, height: newSize.height / 2) }
            }
            .onReceive(vault.objectWillChange.debounce(for: .milliseconds(300), scheduler: RunLoop.main)) { _ in
                model.sync(with: vault)
            }
        }
    }

    // MARK: 그리기

    private func radius(_ node: GraphModel.Node) -> CGFloat {
        (5 + CGFloat(node.degree).squareRoot() * 2.5) * min(max(viewport.scale, 0.7), 1.6)
    }

    private func workingAgent(for id: String) -> AgentKind? {
        AgentKind.allCases.first { runner.jobs[$0]?.todo.docPath == id }
    }

    private func draw(in context: inout GraphicsContext) {
        let focus = hovered.map { model.neighbors(of: $0).union([$0]) }

        for edge in model.edges {
            guard let a = model.nodes[edge.a], let b = model.nodes[edge.b] else { continue }
            var path = Path()
            path.move(to: viewport.toScreen(a.position))
            path.addLine(to: viewport.toScreen(b.position))
            let lit = hovered == edge.a || hovered == edge.b
            context.stroke(
                path,
                with: .color(lit ? .accentColor : .gray.opacity(focus == nil ? 0.45 : 0.15)),
                lineWidth: lit ? 1.6 : 1
            )
        }

        for node in model.nodes.values {
            let center = viewport.toScreen(node.position)
            let r = radius(node)
            let dimmed = focus.map { !$0.contains(node.id) } ?? false
            let color: Color = if let agent = workingAgent(for: node.id) {
                Color(nsColor: agent.color)
            } else if node.id == hovered {
                .accentColor
            } else if node.id == Vault.mainNotePath {
                .orange
            } else {
                .gray
            }
            context.fill(
                Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(dimmed ? 0.25 : 1))
            )
            if viewport.scale > 0.45 || focus?.contains(node.id) == true {
                context.draw(
                    Text(node.name)
                        .font(.system(size: 11, weight: node.id == hovered ? .semibold : .regular))
                        .foregroundColor(.primary.opacity(dimmed ? 0.3 : 0.85)),
                    at: CGPoint(x: center.x, y: center.y + r + 3),
                    anchor: .top
                )
            }
        }
    }

    /// 에이전트가 일하는 메모 노드에 로고를 붙임
    private var workingBadges: some View {
        ForEach(AgentKind.allCases) { kind in
            if let job = runner.jobs[kind], let node = model.nodes[job.todo.docPath] {
                let center = viewport.toScreen(node.position)
                AgentBadge(kind: kind, size: 22)
                    .shadow(radius: 2)
                    .position(x: center.x + radius(node) + 10, y: center.y - radius(node) - 6)
                    .allowsHitTesting(false)
            }
        }
    }

    private var fitButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.3)) { fitToContent() }
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .help("화면에 맞추기")
        .padding(10)
    }

    private func fitToContent() {
        viewport.fit(model.bounds.insetBy(dx: -40, dy: -40), in: size)
    }

    // MARK: 조작

    private func hitTest(_ point: CGPoint) -> String? {
        model.nodes.values
            .map { ($0.id, hypot(viewport.toScreen($0.position).x - point.x, viewport.toScreen($0.position).y - point.y), radius($0)) }
            .filter { $0.1 <= $0.2 + 4 }
            .min { $0.1 < $1.1 }?.0
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragging == nil {
                    if let id = hitTest(value.startLocation) {
                        dragging = .node(id)
                        model.pinned = id
                    } else {
                        dragging = .pan(viewport.offset)
                    }
                }
                switch dragging {
                case .node(let id):
                    model.move(id, to: viewport.toWorld(value.location))
                case .pan(let start):
                    viewport.offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { value in
                // 거의 안 움직였으면 클릭: 메모 열기
                if case .node(let id) = dragging, hypot(value.translation.width, value.translation.height) < 3 {
                    onOpenNote(id)
                }
                model.pinned = nil
                dragging = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = pinchBase ?? viewport
                if pinchBase == nil { pinchBase = viewport }
                var next = base
                next.zoom(by: value.magnification, around: value.startLocation)
                viewport = next
            }
            .onEnded { _ in pinchBase = nil }
    }
}
