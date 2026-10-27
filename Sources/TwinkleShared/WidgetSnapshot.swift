import Foundation

/// 앱이 써 두고 위젯이 읽는 할 일 목록.
/// 위젯은 샌드박스 안이라 메모 폴더를 못 읽고, Twinkle 지원 폴더의 이 파일만 읽을 수 있음
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    /// 안 끝난 할 일 (기한 있는 것 먼저, 기한순)
    public var todos: [Item]
    /// 기한 있는 할 일 전부 (끝난 것도, 달력용)
    public var dated: [Item]

    public init(todos: [Item], dated: [Item]) {
        self.todos = todos
        self.dated = dated
    }

    public struct Item: Codable, Sendable, Hashable, Identifiable {
        public var title: String
        /// 체크박스 글자: " " 할 일, "/" 하는 중, "x" 끝남, "!" 실패, "?" 답 기다림
        public var state: String
        public var due: Date?
        /// claude / codex / grok
        public var agent: String?
        public var noteTitle: String
        /// 메모 폴더 기준 경로와 줄 번호 (누르면 그 할 일로)
        public var path: String
        public var line: Int

        public var id: String { "\(path)#\(line)" }
        public var isDone: Bool { state == "x" }

        public init(title: String, state: String, due: Date?, agent: String?, noteTitle: String, path: String, line: Int) {
            self.title = title
            self.state = state
            self.due = due
            self.agent = agent
            self.noteTitle = noteTitle
            self.path = path
            self.line = line
        }

        /// 위젯에서 누르면 여는 주소
        public var url: URL { WidgetLink.todo(path: path, line: line) }
    }

    /// ~/Library/Application Support/Twinkle/widget.json (샌드박스 안에서도 진짜 홈 기준)
    public static var fileURL: URL {
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Twinkle/widget.json")
    }

    public static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public func write() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: Self.fileURL, options: .atomic)
    }
}

/// twinkle:// 주소 (위젯 → 앱)
public enum WidgetLink {
    public static let scheme = "twinkle"

    public static func todo(path: String, line: Int) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "todo"
        components.queryItems = [URLQueryItem(name: "path", value: path), URLQueryItem(name: "line", value: String(line))]
        return components.url!
    }

    public static var mainNote: URL { URL(string: "\(scheme)://note")! }

    /// 앱이 받은 주소 → (메모 경로, 줄). 줄이 없으면 메모만 열기
    public static func parse(_ url: URL) -> (path: String?, line: Int?)? {
        guard url.scheme == scheme, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let value = { (name: String) in components.queryItems?.first { $0.name == name }?.value }
        return (value("path"), value("line").flatMap(Int.init))
    }
}
