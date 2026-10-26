import Foundation

/// 할 일 하나 + 쿼리에 필요한 주변 정보
struct TaskItem: Identifiable {
    let todo: Todo
    let noteTitle: String
    let heading: String?
    let due: Date?
    let tags: [String]

    var id: String { todo.id }

    /// 목록에 보일 제목: 기한(📅 …)과 태그는 따로 보여주니 뺌
    var displayTitle: String {
        var title = todo.title.replacing(/📅\s*\d{4}-\d{2}-\d{2}/, with: "").replacing(/\d{4}\.\d{1,2}\.\d{1,2}/, with: "")
        for tag in tags { title = title.replacingOccurrences(of: tag, with: "") }
        return title.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

struct TaskGroup: Identifiable {
    let title: String?
    let items: [TaskItem]
    var id: String { title ?? "" }
}

/// 옵시디언 Tasks 플러그인의 ```tasks 쿼리 (자주 쓰는 것만) + Twinkle 전용 agent 조건.
/// 한 줄에 조건 하나, 여러 줄이면 모두 만족(AND)
struct TaskQuery {
    private var filters: [(TaskItem) -> Bool] = []
    private var sorts: [(key: String, reverse: Bool)] = []
    private var groupKey: String?
    private var limit: Int?
    private(set) var errors: [String] = []

    nonisolated(unsafe) private static let dueRegex = /📅\s*(\d{4}-\d{2}-\d{2})/
    nonisolated(unsafe) private static let chipRegex = /\d{4}\.\d{1,2}\.\d{1,2}/
    nonisolated(unsafe) private static let tagRegex = /(?:^|\s)(#[^\s#]+)/

    static func parse(_ source: String) -> TaskQuery {
        var query = TaskQuery()
        for raw in source.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            query.parse(line: line)
        }
        return query
    }

    private mutating func parse(line: String) {
        let lower = line.lowercased()

        func value(after prefix: String) -> String? {
            guard lower.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }

        // 텍스트 포함 조건: path/filename/description/heading/tag
        let textFields: [(String, (TaskItem) -> [String])] = [
            ("path", { [$0.todo.docPath] }),
            ("filename", { [($0.todo.docPath as NSString).lastPathComponent] }),
            ("description", { [$0.todo.title] }),
            ("heading", { [$0.heading ?? ""] }),
            ("tag", { $0.tags }),
            ("tags", { $0.tags }),
        ]
        for (field, values) in textFields {
            if let needle = value(after: "\(field) includes ") {
                filters.append { item in values(item).contains { $0.localizedCaseInsensitiveContains(needle) } }
                return
            }
            if let needle = value(after: "\(field) does not include ") {
                filters.append { item in !values(item).contains { $0.localizedCaseInsensitiveContains(needle) } }
                return
            }
        }

        switch lower {
        case "done":
            filters.append { $0.todo.state == .done }
            return
        case "not done":
            filters.append { $0.todo.state != .done }
            return
        case "has due date":
            filters.append { $0.due != nil }
            return
        case "no due date":
            filters.append { $0.due == nil }
            return
        case "has tags":
            filters.append { !$0.tags.isEmpty }
            return
        case "no tags":
            filters.append { $0.tags.isEmpty }
            return
        case "has agent":
            filters.append { $0.todo.agent != nil }
            return
        case "no agent":
            filters.append { $0.todo.agent == nil }
            return
        case "short mode", "explain", "all":
            return
        default:
            break
        }

        // 표시 옵션은 조용히 무시
        if lower.hasPrefix("hide ") || lower.hasPrefix("show ") { return }

        if let kind = value(after: "status.type is not ") ?? value(after: "status.type is ") {
            let negate = lower.hasPrefix("status.type is not ")
            guard let states = Self.states(for: kind) else { return fail(line) }
            filters.append { states.contains($0.todo.state) != negate }
            return
        }

        if let name = value(after: "agent is ") {
            guard let agent = AgentKind(rawValue: name.lowercased().replacingOccurrences(of: "@", with: "")) else { return fail(line) }
            filters.append { $0.todo.agent == agent }
            return
        }

        for (word, compare) in [("before", ComparisonResult.orderedAscending), ("after", .orderedDescending), ("on", .orderedSame)] {
            if let text = value(after: "due \(word) ") {
                guard let date = Self.date(text) else { return fail(line) }
                filters.append { item in
                    guard let due = item.due else { return false }
                    return Calendar.current.compare(due, to: date, toGranularity: .day) == compare
                }
                return
            }
        }

        if let text = value(after: "limit to ") ?? value(after: "limit ") {
            guard let number = Int(text.split(separator: " ").first ?? "") else { return fail(line) }
            limit = number
            return
        }

        if let text = value(after: "sort by ") {
            let parts = text.lowercased().split(separator: " ")
            guard let key = parts.first, ["due", "path", "filename", "description", "status", "heading", "agent"].contains(String(key)) else { return fail(line) }
            sorts.append((String(key), parts.contains("reverse")))
            return
        }

        if let text = value(after: "group by ") {
            let key = text.lowercased()
            guard ["path", "filename", "folder", "heading", "status", "agent", "due"].contains(key) else { return fail(line) }
            groupKey = key
            return
        }

        fail(line)
    }

    private mutating func fail(_ line: String) {
        errors.append("알 수 없는 조건: \(line)")
    }

    private static func states(for name: String) -> Set<TodoState>? {
        switch name.uppercased() {
        case "TODO": [.open]
        case "IN_PROGRESS": [.doing]
        case "DONE": [.done]
        case "WAITING": [.waiting]
        case "FAILED", "CANCELLED": [.failed]
        default: nil
        }
    }

    private static func date(_ text: String) -> Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        switch text.lowercased() {
        case "today": return today
        case "tomorrow": return calendar.date(byAdding: .day, value: 1, to: today)
        case "yesterday": return calendar.date(byAdding: .day, value: -1, to: today)
        default:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter.date(from: text)
        }
    }

    // MARK: 실행

    @MainActor
    func run(in library: NoteLibrary) -> [TaskGroup] {
        let items = library.todos.map { Self.item(for: $0, in: library) }
        var matched = items.filter { item in filters.allSatisfy { $0(item) } }

        for (key, reverse) in sorts.reversed() {
            matched.sort { a, b in
                let order = Self.compare(a, b, by: key)
                return reverse ? order == .orderedDescending : order == .orderedAscending
            }
        }
        if let limit { matched = Array(matched.prefix(limit)) }

        guard let groupKey else { return [TaskGroup(title: nil, items: matched)] }
        var order: [String] = []
        var groups: [String: [TaskItem]] = [:]
        for item in matched {
            let title = Self.groupTitle(item, by: groupKey)
            if groups[title] == nil { order.append(title) }
            groups[title, default: []].append(item)
        }
        return order.map { TaskGroup(title: $0, items: groups[$0] ?? []) }
    }

    @MainActor
    private static func item(for todo: Todo, in library: NoteLibrary) -> TaskItem {
        let document = library.documents[todo.docPath]
        let lines = document?.text.split(separator: "\n", omittingEmptySubsequences: false) ?? []
        // 할 일 위로 올라가며 가장 가까운 제목
        var heading: String?
        var index = min(todo.line, lines.count) - 1
        while index >= 0 {
            if lines[index].hasPrefix("#") {
                heading = lines[index].drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                break
            }
            index -= 1
        }
        // 📅 YYYY-MM-DD (옵시디언 Tasks) 또는 yyyy.mm.dd 날짜 칩
        let due = todo.body.firstMatch(of: dueRegex).flatMap { date(String($0.1)) }
            ?? todo.body.firstMatch(of: chipRegex).flatMap { MarkdownStyler.chipDate(String($0.0)) }
        let tags = todo.body.matches(of: tagRegex).map { String($0.1) }
        return TaskItem(todo: todo, noteTitle: document?.title ?? todo.docPath, heading: heading, due: due, tags: tags)
    }

    private static func compare(_ a: TaskItem, _ b: TaskItem, by key: String) -> ComparisonResult {
        switch key {
        case "due":
            // 기한 없는 할 일은 뒤로
            switch (a.due, b.due) {
            case let (x?, y?): return x.compare(y)
            case (.some, nil): return .orderedAscending
            case (nil, .some): return .orderedDescending
            default: return .orderedSame
            }
        case "status": return statusRank(a.todo.state) < statusRank(b.todo.state) ? .orderedAscending : statusRank(a.todo.state) == statusRank(b.todo.state) ? .orderedSame : .orderedDescending
        case "description": return a.todo.title.localizedStandardCompare(b.todo.title)
        case "heading": return (a.heading ?? "").localizedStandardCompare(b.heading ?? "")
        case "agent": return (a.todo.agent?.rawValue ?? "~").compare(b.todo.agent?.rawValue ?? "~")
        default: return a.todo.docPath.localizedStandardCompare(b.todo.docPath)
        }
    }

    private static func statusRank(_ state: TodoState) -> Int {
        switch state {
        case .waiting: 0
        case .doing: 1
        case .open: 2
        case .failed: 3
        case .done: 4
        }
    }

    private static func groupTitle(_ item: TaskItem, by key: String) -> String {
        switch key {
        case "heading": return item.heading ?? "(제목 없음)"
        case "status":
            switch item.todo.state {
            case .open: return "할 일"
            case .doing: return "진행 중"
            case .waiting: return "답변 필요"
            case .failed: return "실패"
            case .done: return "완료"
            }
        case "agent": return item.todo.agent?.displayName ?? "에이전트 없음"
        case "folder":
            let folder = (item.todo.docPath as NSString).deletingLastPathComponent
            return folder.isEmpty ? "/" : folder
        case "due":
            guard let due = item.due else { return "기한 없음" }
            return due.formatted(.dateTime.year().month().day())
        default: return item.noteTitle
        }
    }
}
