import AppKit
import SwiftUI

/// 캔버스 탭: 위쪽 도구 막대 + 고른 .canvas 파일 편집기
struct CanvasBoardView: View {
    @ObservedObject var vault: Vault
    @ObservedObject var runner: AgentRunner
    var onOpenNote: (String) -> Void

    @AppStorage("lastCanvas") private var lastCanvas = "Main.canvas"
    @State private var document: CanvasDocument?
    @State private var canvasFiles: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            if let document {
                CanvasEditor(document: document, vault: vault, runner: runner, onOpenNote: onOpenNote, toolbar: AnyView(toolbar(document)))
                    .id(document.url)
            }
        }
        .onAppear { open(lastCanvas) }
        .onDisappear { document?.close() }
    }

    private func toolbar(_ document: CanvasDocument) -> some View {
        Menu {
            ForEach(canvasFiles, id: \.self) { path in
                Button(path.replacingOccurrences(of: ".canvas", with: "")) { open(path) }
            }
            Divider()
            Button("새 캔버스") { open(newCanvasPath()) }
        } label: {
            Label(document.name, systemImage: "rectangle.on.rectangle.angled")
        }
        .fixedSize()
    }

    private func refreshFiles() {
        var files: [String] = []
        if let enumerator = FileManager.default.enumerator(at: vault.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator {
                if enumerator.level >= 2 { enumerator.skipDescendants() }
                guard url.pathExtension == "canvas" else { continue }
                files.append(String(url.standardizedFileURL.path.dropFirst(vault.root.path.count + 1)))
            }
        }
        canvasFiles = files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func open(_ path: String) {
        document?.close()
        let url = vault.root.appendingPathComponent(path)
        CanvasDocument.createEmpty(at: url)
        lastCanvas = path
        document = CanvasDocument(url: url)
        refreshFiles()
    }

    private func newCanvasPath() -> String {
        var index = 1
        while FileManager.default.fileExists(atPath: vault.root.appendingPathComponent("캔버스 \(index).canvas").path) {
            index += 1
        }
        return "캔버스 \(index).canvas"
    }
}

private struct CanvasEditor: View {
    @ObservedObject var document: CanvasDocument
    @ObservedObject var vault: Vault
    @ObservedObject var runner: AgentRunner
    var onOpenNote: (String) -> Void
    var toolbar: AnyView

    @State private var viewport = Viewport()
    @State private var size: CGSize = .zero
    /// 사용자가 직접 이동/확대했으면 창 크기가 바뀌어도 다시 맞추지 않음
    @State private var userAdjusted = false
    @State private var selectedNode: String?
    @State private var selectedEdge: String?
    @State private var editingNode: String?
    @State private var hoveredNode: String?
    @State private var panStart: CGSize?
    @State private var pinchBase: Viewport?
    /// 노드를 끌기 시작할 때의 위치들 (그룹이면 안에 든 노드까지)
    @State private var moveOrigins: [String: CGPoint]?
    @State private var resizeOrigin: CGRect?
    @State private var connecting: (from: String, point: CGPoint)?

    private let board = "board"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                toolbar
                Button { addTextNode(at: viewCenter) } label: { Label("텍스트", systemImage: "text.alignleft") }
                Menu {
                    ForEach(vault.documents.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }, id: \.self) { path in
                        Button(path.replacingOccurrences(of: ".md", with: "")) { addFileNode(path, at: viewCenter) }
                    }
                } label: {
                    Label("메모", systemImage: "doc.text")
                }
                .fixedSize()
                Button { addGroup(at: viewCenter) } label: { Label("그룹", systemImage: "rectangle.dashed") }
                Spacer()
                Text("더블클릭: 텍스트 추가 · 오른쪽 점을 끌어 연결 · ⌘+스크롤: 확대")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button { withAnimation(.easeInOut(duration: 0.3)) { fit() } } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .help("화면에 맞추기")
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    background
                    ScrollCatcher { event, point in
                        userAdjusted = true
                        viewport.handleScroll(event, at: point)
                    }
                    Canvas { context, _ in drawEdges(in: &context) }
                        .allowsHitTesting(false)
                    ForEach(orderedNodes) { node in
                        nodeView(node)
                    }
                    if let edge = selectedEdgeMidpoint {
                        Button("연결 삭제", role: .destructive) { deleteEdge(edge.id) }
                            .controlSize(.small)
                            .position(edge.point)
                    }
                }
                .coordinateSpace(name: board)
                .clipped()
                .simultaneousGesture(magnifyGesture)
                .onAppear { sizeChanged(geometry.size) }
                .onChange(of: geometry.size) { _, newSize in sizeChanged(newSize) }
            }
        }
    }

    // MARK: 배경 (이동, 더블클릭으로 텍스트 추가, 연결선 선택)

    private var background: some View {
        Canvas { context, canvasSize in
            // 점 격자. 확대에 따라 간격이 같이 변함
            let spacing = 24 * viewport.scale
            guard spacing > 6 else { return }
            let startX = viewport.offset.width.truncatingRemainder(dividingBy: spacing)
            let startY = viewport.offset.height.truncatingRemainder(dividingBy: spacing)
            var dots = Path()
            var x = startX
            while x < canvasSize.width {
                var y = startY
                while y < canvasSize.height {
                    dots.addEllipse(in: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6))
                    y += spacing
                }
                x += spacing
            }
            context.fill(dots, with: .color(.gray.opacity(0.35)))
        }
        .background(Color(nsColor: .textBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, coordinateSpace: .named(board)) { point in
            addTextNode(at: viewport.toWorld(point), startEditing: true)
        }
        .onTapGesture(count: 1, coordinateSpace: .named(board)) { point in
            editingNode = nil
            selectedNode = nil
            selectedEdge = edgeHit(at: point)
        }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    let start = panStart ?? viewport.offset
                    if panStart == nil { panStart = start }
                    userAdjusted = true
                    viewport.offset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
                }
                .onEnded { _ in panStart = nil }
        )
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                userAdjusted = true
                let base = pinchBase ?? viewport
                if pinchBase == nil { pinchBase = viewport }
                var next = base
                next.zoom(by: value.magnification, around: value.startLocation)
                viewport = next
            }
            .onEnded { _ in pinchBase = nil }
    }

    // MARK: 노드

    /// 그룹이 뒤에 깔리도록
    private var orderedNodes: [CanvasNode] {
        document.nodes.filter { $0.type == "group" } + document.nodes.filter { $0.type != "group" }
    }

    private func nodeView(_ node: CanvasNode) -> some View {
        let screen = viewport.toScreen(node.rect)
        let isEditing = editingNode == node.id
        return CanvasNodeCard(
            node: node,
            note: node.file.flatMap { vault.documents[$0] },
            agent: node.file.flatMap { file in AgentKind.allCases.first { runner.jobs[$0]?.todo.docPath == file } },
            isSelected: selectedNode == node.id,
            isEditing: isEditing,
            text: textBinding(for: node.id)
        )
        .frame(width: node.width, height: node.height)
        .overlay(alignment: .bottomTrailing) { resizeHandle(node) }
        .overlay(alignment: .trailing) { connectHandle(node) }
        .scaleEffect(viewport.scale, anchor: .topLeading)
        .offset(x: screen.minX, y: screen.minY)
        .onHover { hoveredNode = $0 ? node.id : (hoveredNode == node.id ? nil : hoveredNode) }
        .onTapGesture(count: 2) {
            switch node.type {
            case "file": if let file = node.file { onOpenNote(file) }
            case "text": editingNode = node.id
            case "link": if let url = node.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
            default: break
            }
        }
        .onTapGesture {
            selectedNode = node.id
            selectedEdge = nil
            if editingNode != node.id { editingNode = nil }
        }
        .gesture(moveGesture(node), including: isEditing ? .subviews : .all)
        .contextMenu { contextMenu(node) }
    }

    private func moveGesture(_ node: CanvasNode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(board))
            .onChanged { value in
                if moveOrigins == nil {
                    var origins = [node.id: node.rect.origin]
                    if node.type == "group" {
                        for other in document.nodes where other.id != node.id && node.rect.contains(other.rect) {
                            origins[other.id] = other.rect.origin
                        }
                    }
                    moveOrigins = origins
                    selectedNode = node.id
                }
                let dx = value.translation.width / viewport.scale, dy = value.translation.height / viewport.scale
                for (id, origin) in moveOrigins ?? [:] {
                    update(id) { $0.x = origin.x + dx; $0.y = origin.y + dy }
                }
            }
            .onEnded { _ in moveOrigins = nil }
    }

    private func resizeHandle(_ node: CanvasNode) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.secondary)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
            .opacity(selectedNode == node.id || hoveredNode == node.id ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(board))
                    .onChanged { value in
                        let start = resizeOrigin ?? node.rect
                        if resizeOrigin == nil { resizeOrigin = start }
                        update(node.id) {
                            $0.width = max(start.width + value.translation.width / viewport.scale, 80)
                            $0.height = max(start.height + value.translation.height / viewport.scale, 40)
                        }
                    }
                    .onEnded { _ in resizeOrigin = nil }
            )
    }

    private func connectHandle(_ node: CanvasNode) -> some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(.white, lineWidth: 1.5))
            .frame(width: 12, height: 12)
            .offset(x: 6)
            .opacity(selectedNode == node.id || hoveredNode == node.id ? 1 : 0)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(board))
                    .onChanged { value in connecting = (node.id, value.location) }
                    .onEnded { value in
                        connecting = nil
                        let world = viewport.toWorld(value.location)
                        // 그룹보다 그 위에 놓인 일반 노드를 우선
                        let target = document.nodes.last { $0.type != "group" && $0.rect.contains(world) && $0.id != node.id }
                            ?? document.nodes.last { $0.rect.contains(world) && $0.id != node.id }
                        if let target { addEdge(from: node.id, to: target.id) }
                    }
            )
    }

    @ViewBuilder
    private func contextMenu(_ node: CanvasNode) -> some View {
        if let file = node.file {
            Button("메모 열기") { onOpenNote(file) }
        }
        if node.type == "text" {
            Button("편집") { editingNode = node.id }
        }
        if node.type == "group" {
            Button("이름 바꾸기") { renameGroup(node) }
        }
        Menu("색") {
            Button("기본") { update(node.id) { $0.color = nil } }
            ForEach(CanvasDocument.presetColors, id: \.0) { value, label in
                Button(label) { update(node.id) { $0.color = value } }
            }
        }
        Divider()
        Button("삭제", role: .destructive) { deleteNode(node.id) }
    }

    // MARK: 연결선

    private func drawEdges(in context: inout GraphicsContext) {
        let rects = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, viewport.toScreen($0.rect)) })
        for edge in document.edges {
            guard let a = rects[edge.fromNode], let b = rects[edge.toNode] else { continue }
            let (p1, c1, c2, p2, endNormal) = CanvasDocument.curve(from: a, edge.fromSide, to: b, edge.toSide)
            var path = Path()
            path.move(to: p1)
            path.addCurve(to: p2, control1: c1, control2: c2)
            let selected = edge.id == selectedEdge
            let color = CanvasDocument.color(edge.color) ?? .gray
            context.stroke(path, with: .color(selected ? .accentColor : color.opacity(0.8)), lineWidth: selected ? 3 : 2)

            if edge.toEnd != "none" { drawArrow(in: &context, at: p2, pointing: endNormal, color: selected ? .accentColor : color) }
            if edge.fromEnd == "arrow" {
                let (_, _, _, _, startNormal) = CanvasDocument.curve(from: b, edge.toSide, to: a, edge.fromSide)
                drawArrow(in: &context, at: p1, pointing: startNormal, color: color)
            }
            if let label = edge.label, !label.isEmpty {
                context.draw(
                    Text(label).font(.system(size: 11)).foregroundColor(.secondary),
                    at: bezierPoint(p1, c1, c2, p2, 0.5)
                )
            }
        }

        if let connecting, let from = rects[connecting.from] {
            let start = CanvasDocument.sidePoint(of: from, "right")
            var path = Path()
            path.move(to: start)
            path.addCurve(
                to: connecting.point,
                control1: CGPoint(x: start.x + 60, y: start.y),
                control2: CGPoint(x: connecting.point.x - 60, y: connecting.point.y)
            )
            context.stroke(path, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
    }

    /// 면의 바깥 방향(normal) 쪽에서 들어오는 화살촉
    private func drawArrow(in context: inout GraphicsContext, at tip: CGPoint, pointing normal: CGVector, color: Color) {
        let length = 10 * min(max(viewport.scale, 0.6), 1.4)
        let back = CGPoint(x: tip.x + normal.dx * length, y: tip.y + normal.dy * length)
        let side = CGVector(dx: -normal.dy * length * 0.55, dy: normal.dx * length * 0.55)
        var arrow = Path()
        arrow.move(to: tip)
        arrow.addLine(to: CGPoint(x: back.x + side.dx, y: back.y + side.dy))
        arrow.addLine(to: CGPoint(x: back.x - side.dx, y: back.y - side.dy))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }

    private func bezierPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    /// 클릭 위치에서 6pt 안에 지나가는 연결선
    private func edgeHit(at point: CGPoint) -> String? {
        let rects = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.id, viewport.toScreen($0.rect)) })
        var best: (String, CGFloat)?
        for edge in document.edges {
            guard let a = rects[edge.fromNode], let b = rects[edge.toNode] else { continue }
            let (p1, c1, c2, p2, _) = CanvasDocument.curve(from: a, edge.fromSide, to: b, edge.toSide)
            for step in 0...40 {
                let p = bezierPoint(p1, c1, c2, p2, CGFloat(step) / 40)
                let distance = hypot(p.x - point.x, p.y - point.y)
                if distance < 6, distance < (best?.1 ?? .greatestFiniteMagnitude) { best = (edge.id, distance) }
            }
        }
        return best?.0
    }

    private var selectedEdgeMidpoint: (id: String, point: CGPoint)? {
        guard let id = selectedEdge,
              let edge = document.edges.first(where: { $0.id == id }),
              let a = document.nodes.first(where: { $0.id == edge.fromNode }),
              let b = document.nodes.first(where: { $0.id == edge.toNode })
        else { return nil }
        let (p1, c1, c2, p2, _) = CanvasDocument.curve(from: viewport.toScreen(a.rect), edge.fromSide, to: viewport.toScreen(b.rect), edge.toSide)
        let mid = bezierPoint(p1, c1, c2, p2, 0.5)
        return (id, CGPoint(x: mid.x, y: mid.y - 18))
    }

    // MARK: 편집 동작

    private var viewCenter: CGPoint {
        viewport.toWorld(CGPoint(x: size.width / 2, y: size.height / 2))
    }

    /// 창 크기가 정해지거나 바뀌면 화면에 맞춤 (onAppear 시점엔 크기가 0이거나 복원 전 크기일 수 있음)
    private func sizeChanged(_ newSize: CGSize) {
        size = newSize
        guard !userAdjusted, newSize.width > 0, newSize.height > 0 else { return }
        fit()
    }

    private func fit() {
        let bounds = document.nodes.reduce(CGRect.null) { $0.union($1.rect) }
        if bounds.isNull {
            viewport = Viewport(scale: 1, offset: CGSize(width: size.width / 2, height: size.height / 2))
        } else {
            viewport.fit(bounds, in: size)
        }
    }

    private func update(_ id: String, _ change: (inout CanvasNode) -> Void) {
        guard let index = document.nodes.firstIndex(where: { $0.id == id }) else { return }
        change(&document.nodes[index])
    }

    private func textBinding(for id: String) -> Binding<String> {
        Binding(
            get: { document.nodes.first { $0.id == id }?.text ?? "" },
            set: { newValue in update(id) { $0.text = newValue } }
        )
    }

    private func addTextNode(at center: CGPoint, startEditing: Bool = false) {
        let node = CanvasNode(id: CanvasDocument.newID(), type: "text", x: center.x - 125, y: center.y - 30, width: 250, height: 60, text: "")
        document.nodes.append(node)
        selectedNode = node.id
        if startEditing { editingNode = node.id }
    }

    private func addFileNode(_ path: String, at center: CGPoint) {
        let node = CanvasNode(id: CanvasDocument.newID(), type: "file", x: center.x - 200, y: center.y - 150, width: 400, height: 300, file: path)
        document.nodes.append(node)
        selectedNode = node.id
    }

    private func addGroup(at center: CGPoint) {
        let node = CanvasNode(id: CanvasDocument.newID(), type: "group", x: center.x - 300, y: center.y - 200, width: 600, height: 400, label: "그룹")
        document.nodes.insert(node, at: 0)
        selectedNode = node.id
    }

    private func addEdge(from: String, to: String) {
        guard let a = document.nodes.first(where: { $0.id == from }), let b = document.nodes.first(where: { $0.id == to }) else { return }
        let sides = CanvasDocument.facingSides(from: a.rect, to: b.rect)
        document.edges.append(CanvasEdge(id: CanvasDocument.newID(), fromNode: from, fromSide: sides.0, toNode: to, toSide: sides.1))
    }

    private func deleteNode(_ id: String) {
        document.edges.removeAll { $0.fromNode == id || $0.toNode == id }
        document.nodes.removeAll { $0.id == id }
        if selectedNode == id { selectedNode = nil }
    }

    private func deleteEdge(_ id: String) {
        document.edges.removeAll { $0.id == id }
        selectedEdge = nil
    }

    private func renameGroup(_ node: CanvasNode) {
        let alert = NSAlert()
        alert.messageText = "그룹 이름"
        let field = NSTextField(string: node.label ?? "")
        field.frame = CGRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "확인")
        alert.addButton(withTitle: "취소")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        update(node.id) { $0.label = field.stringValue }
    }
}

/// 캔버스 위 카드 하나 (메모 / 텍스트 / 링크 / 그룹)
private struct CanvasNodeCard: View {
    let node: CanvasNode
    let note: NoteDocument?
    let agent: AgentKind?
    let isSelected: Bool
    let isEditing: Bool
    @Binding var text: String

    private var tint: Color? { CanvasDocument.color(node.color) }

    var body: some View {
        if node.type == "group" {
            group
        } else {
            card
        }
    }

    private var group: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill((tint ?? .gray).opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.accentColor : (tint ?? .gray).opacity(0.5), lineWidth: isSelected ? 2 : 1.5)
            )
            .overlay(alignment: .topLeading) {
                Text(node.label ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle((tint ?? .secondary).opacity(0.9))
                    .padding(10)
            }
    }

    private var card: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let tint {
                RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.12))
            }
            content
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : (tint ?? .gray.opacity(0.5)), lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .overlay(alignment: .topTrailing) {
            if let agent {
                AgentBadge(kind: agent, size: 22)
                    .shadow(radius: 2)
                    .offset(x: 8, y: -8)
                    .help("\(agent.displayName) 작업 중")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch node.type {
        case "file":
            VStack(alignment: .leading, spacing: 6) {
                Label(note?.name ?? node.file ?? "", systemImage: "doc.text")
                    .font(.system(size: 13, weight: .semibold))
                if let note {
                    Text(preview(of: note.text))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("파일을 찾을 수 없음").font(.caption).foregroundStyle(.red)
                }
            }
        case "link":
            Label(node.url ?? "", systemImage: "link")
                .font(.system(size: 12))
                .foregroundStyle(Color.accentColor)
        default:
            if isEditing {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
            } else if text.isEmpty {
                Text("더블클릭해서 입력").font(.system(size: 13)).foregroundStyle(.tertiary)
            } else {
                Text(LocalizedStringKey(text)).font(.system(size: 13))
            }
        }
    }

    /// 메모 미리보기: 첫 제목 줄은 카드 제목과 겹치니 빼고 앞부분만
    private func preview(of text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if let first = lines.first, first.hasPrefix("# ") { lines.removeFirst() }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines).prefix(1200).description
    }
}
