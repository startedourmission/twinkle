import AppKit
import SwiftUI

/// JSON Canvas (https://jsoncanvas.org) 노드. 옵시디언 .canvas와 같은 형식.
/// 우리가 모르는 필드는 extra에 담아 두었다가 저장할 때 그대로 돌려놓음
struct CanvasNode: Identifiable {
    var id: String
    var type: String
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
    var text: String?
    var file: String?
    var url: String?
    var label: String?
    var color: String?
    var extra: [String: Any] = [:]

    var rect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set {
            x = newValue.minX
            y = newValue.minY
            width = newValue.width
            height = newValue.height
        }
    }

    static let knownKeys: Set<String> = ["id", "type", "x", "y", "width", "height", "text", "file", "url", "label", "color"]
}

struct CanvasEdge: Identifiable {
    var id: String
    var fromNode: String
    var fromSide: String?
    var toNode: String
    var toSide: String?
    var fromEnd: String?
    var toEnd: String?
    var label: String?
    var color: String?
    var extra: [String: Any] = [:]

    static let knownKeys: Set<String> = ["id", "fromNode", "fromSide", "toNode", "toSide", "fromEnd", "toEnd", "label", "color"]
}

@MainActor
final class CanvasDocument: ObservableObject {
    let url: URL
    @Published var nodes: [CanvasNode] = [] {
        didSet { if !isLoading { scheduleSave() } }
    }
    @Published var edges: [CanvasEdge] = [] {
        didSet { if !isLoading { scheduleSave() } }
    }

    private var isLoading = false
    private var isDirty = false
    private var diskModified: Date?
    private var pendingSave: DispatchWorkItem?
    private var pollTimer: Timer?

    var name: String { url.deletingPathExtension().lastPathComponent }

    init(url: URL) {
        self.url = url
        load()
        // 옵시디언 등에서 같은 파일을 고치면 다시 읽음
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDirty, NoteDocument.modificationDate(of: self.url) != self.diskModified else { return }
                self.load()
            }
        }
    }

    func close() {
        pollTimer?.invalidate()
        save()
    }

    static func createEmpty(at url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? Data("{\"nodes\":[],\"edges\":[]}\n".utf8).write(to: url, options: .atomic)
    }

    static func newID() -> String {
        (0..<16).map { _ in String(format: "%x", Int.random(in: 0..<16)) }.joined()
    }

    // MARK: 읽기/쓰기

    private func load() {
        diskModified = NoteDocument.modificationDate(of: url)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        isLoading = true
        defer { isLoading = false }
        nodes = (root["nodes"] as? [[String: Any]] ?? []).compactMap(Self.decodeNode)
        edges = (root["edges"] as? [[String: Any]] ?? []).compactMap(Self.decodeEdge)
    }

    func save() {
        pendingSave?.cancel()
        guard isDirty else { return }
        let root: [String: Any] = [
            "nodes": nodes.map(Self.encode),
            "edges": edges.map(Self.encode),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try data.write(to: url, options: .atomic)
            isDirty = false
            diskModified = NoteDocument.modificationDate(of: url)
        } catch {
            NSLog("Twinkle: 캔버스 저장 실패 \(url.path): \(error)")
        }
    }

    private func scheduleSave() {
        isDirty = true
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private static func number(_ value: Any?) -> CGFloat? {
        (value as? NSNumber).map { CGFloat($0.doubleValue) }
    }

    private static func decodeNode(_ raw: [String: Any]) -> CanvasNode? {
        guard let id = raw["id"] as? String, let type = raw["type"] as? String else { return nil }
        return CanvasNode(
            id: id,
            type: type,
            x: number(raw["x"]) ?? 0,
            y: number(raw["y"]) ?? 0,
            width: number(raw["width"]) ?? 250,
            height: number(raw["height"]) ?? 60,
            text: raw["text"] as? String,
            file: raw["file"] as? String,
            url: raw["url"] as? String,
            label: raw["label"] as? String,
            color: raw["color"] as? String,
            extra: raw.filter { !CanvasNode.knownKeys.contains($0.key) }
        )
    }

    private static func decodeEdge(_ raw: [String: Any]) -> CanvasEdge? {
        guard let id = raw["id"] as? String, let from = raw["fromNode"] as? String, let to = raw["toNode"] as? String else { return nil }
        return CanvasEdge(
            id: id,
            fromNode: from,
            fromSide: raw["fromSide"] as? String,
            toNode: to,
            toSide: raw["toSide"] as? String,
            fromEnd: raw["fromEnd"] as? String,
            toEnd: raw["toEnd"] as? String,
            label: raw["label"] as? String,
            color: raw["color"] as? String,
            extra: raw.filter { !CanvasEdge.knownKeys.contains($0.key) }
        )
    }

    private static func encode(_ node: CanvasNode) -> [String: Any] {
        var raw = node.extra
        raw["id"] = node.id
        raw["type"] = node.type
        // 옵시디언은 정수 좌표를 씀
        raw["x"] = Int(node.x.rounded())
        raw["y"] = Int(node.y.rounded())
        raw["width"] = Int(node.width.rounded())
        raw["height"] = Int(node.height.rounded())
        raw["text"] = node.text
        raw["file"] = node.file
        raw["url"] = node.url
        raw["label"] = node.label
        raw["color"] = node.color
        return raw
    }

    private static func encode(_ edge: CanvasEdge) -> [String: Any] {
        var raw = edge.extra
        raw["id"] = edge.id
        raw["fromNode"] = edge.fromNode
        raw["fromSide"] = edge.fromSide
        raw["toNode"] = edge.toNode
        raw["toSide"] = edge.toSide
        raw["fromEnd"] = edge.fromEnd
        raw["toEnd"] = edge.toEnd
        raw["label"] = edge.label
        raw["color"] = edge.color
        return raw
    }

    // MARK: 색, 연결선 모양

    /// JSON Canvas 색: "1"~"6" 프리셋 또는 "#RRGGBB"
    static func color(_ value: String?) -> Color? {
        guard let value else { return nil }
        switch value {
        case "1": return .red
        case "2": return .orange
        case "3": return .yellow
        case "4": return .green
        case "5": return .cyan
        case "6": return .purple
        default:
            guard value.hasPrefix("#"), value.count == 7, let rgb = Int(value.dropFirst(), radix: 16) else { return nil }
            return Color(red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
        }
    }

    static let presetColors: [(String, String)] = [("1", "빨강"), ("2", "주황"), ("3", "노랑"), ("4", "초록"), ("5", "청록"), ("6", "보라")]

    static func sidePoint(of rect: CGRect, _ side: String) -> CGPoint {
        switch side {
        case "top": CGPoint(x: rect.midX, y: rect.minY)
        case "bottom": CGPoint(x: rect.midX, y: rect.maxY)
        case "left": CGPoint(x: rect.minX, y: rect.midY)
        default: CGPoint(x: rect.maxX, y: rect.midY)
        }
    }

    static func normal(of side: String) -> CGVector {
        switch side {
        case "top": CGVector(dx: 0, dy: -1)
        case "bottom": CGVector(dx: 0, dy: 1)
        case "left": CGVector(dx: -1, dy: 0)
        default: CGVector(dx: 1, dy: 0)
        }
    }

    /// 두 사각형의 상대 위치로 마주 보는 면을 고름
    static func facingSides(from: CGRect, to: CGRect) -> (String, String) {
        let dx = to.midX - from.midX, dy = to.midY - from.midY
        if abs(dx) > abs(dy) {
            return dx > 0 ? ("right", "left") : ("left", "right")
        }
        return dy > 0 ? ("bottom", "top") : ("top", "bottom")
    }

    /// 화면 좌표의 연결선 (베지어) 제어점 4개
    static func curve(from a: CGRect, _ fromSide: String?, to b: CGRect, _ toSide: String?) -> (CGPoint, CGPoint, CGPoint, CGPoint, CGVector) {
        let auto = facingSides(from: a, to: b)
        let s1 = fromSide ?? auto.0, s2 = toSide ?? auto.1
        let p1 = sidePoint(of: a, s1), p2 = sidePoint(of: b, s2)
        let n1 = normal(of: s1), n2 = normal(of: s2)
        let reach = max(hypot(p2.x - p1.x, p2.y - p1.y) * 0.4, 30)
        let c1 = CGPoint(x: p1.x + n1.dx * reach, y: p1.y + n1.dy * reach)
        let c2 = CGPoint(x: p2.x + n2.dx * reach, y: p2.y + n2.dy * reach)
        return (p1, c1, c2, p2, n2)
    }
}
