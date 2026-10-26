import AppKit
import SwiftUI

/// 메모 안 ```tasks 블록 하나의 결과
@MainActor
final class TaskBlockModel: ObservableObject {
    @Published var groups: [TaskGroup] = []
    @Published var errors: [String] = []
    @Published var queryLines: [String] = []
}

/// ```tasks 블록 자리에 그려지는 할 일 목록
struct TaskQueryView: View {
    @ObservedObject var model: TaskBlockModel
    let library: NoteLibrary
    let notePath: String
    var onOpenTodo: (Todo) -> Void
    var onEdit: () -> Void
    var onChangeQuery: ([String]) -> Void

    static let headerHeight: CGFloat = 26
    static let controlsHeight: CGFloat = 26
    static let rowHeight: CGFloat = 26
    static let groupHeight: CGFloat = 22
    static let errorHeight: CGFloat = 16
    static let padding: CGFloat = 8

    /// 내용에 맞춘 높이. 편집기가 이만큼 자리를 비워 둠
    static func height(groups: [TaskGroup], errors: [String]) -> CGFloat {
        let rows = groups.reduce(0) { $0 + $1.items.count }
        let titled = groups.filter { $0.title != nil }.count
        return headerHeight + controlsHeight + CGFloat(errors.count) * errorHeight + CGFloat(titled) * groupHeight
            + CGFloat(max(rows, 1)) * rowHeight + padding * 2
    }

    private var count: Int { model.groups.reduce(0) { $0 + $1.items.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "checklist")
                    .font(.system(size: 11, weight: .semibold))
                Text("할 일 \(count)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("쿼리 편집", action: onEdit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.black.opacity(0.55))
            .frame(height: Self.headerHeight)

            QueryControls(settings: QuerySettings(lines: model.queryLines, notePath: notePath)) { settings in
                onChangeQuery(settings.lines(notePath: notePath))
            }
            .frame(height: Self.controlsHeight)

            ForEach(model.errors, id: \.self) { error in
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(height: Self.errorHeight)
            }

            if count == 0 {
                Text("조건에 맞는 할 일이 없어요")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(height: Self.rowHeight)
            }

            ForEach(model.groups) { group in
                if let title = group.title {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(height: Self.groupHeight, alignment: .bottom)
                }
                ForEach(group.items) { item in
                    TaskRow(item: item, library: library, onOpenTodo: onOpenTodo)
                        .frame(height: Self.rowHeight)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .light)
    }
}

/// 할 일 한 줄 (```tasks 목록, ```cal 달력이 같이 씀)
struct TaskRow: View {
    let item: TaskItem
    let library: NoteLibrary
    var showsDue = true
    var onOpenTodo: (Todo) -> Void

    var body: some View {
        let todo = item.todo
        HStack(spacing: 7) {
            Button {
                library.setState(of: todo, to: todo.state == .done ? .open : .done)
            } label: {
                Image(systemName: TodoRowIcon.name(for: todo.state))
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: MarkdownStyler.color(for: todo.state)))
            }
            .buttonStyle(.plain)
            .disabled(todo.state == .doing)

            if let agent = todo.agent {
                AgentBadge(kind: agent, size: 16)
            }
            Text(item.displayTitle)
                .font(.system(size: 13))
                .strikethrough(todo.state == .done)
                .foregroundStyle(todo.state == .done ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if showsDue, let due = item.due {
                Text(due, format: .dateTime.month().day())
                    .font(.system(size: 11))
                    .foregroundStyle(due < Calendar.current.startOfDay(for: Date()) && todo.state != .done ? .red : .secondary)
            }
            Button(item.noteTitle) { onOpenTodo(todo) }
                .help("이 할 일로 이동")
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: MarkdownStyler.linkColor))
                .lineLimit(1)
                .frame(maxWidth: 90, alignment: .trailing)
        }
    }
}

/// 버튼으로 다루는 조건들. 나머지 줄(직접 쓴 조건)은 그대로 보존
struct QuerySettings: Equatable {
    var status = "not done"   // "not done" | "done" | "all"
    var group = ""            // "", "filename", "heading", "status", "agent"
    var sort = ""             // "", "due", "status", "description"
    var agent = ""            // "", "has agent", "no agent", "agent is claude" …
    var onlyThisNote = false
    var others: [String] = []

    init(lines: [String], notePath: String) {
        let meaningful = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if meaningful.isEmpty { return }   // 빈 쿼리 = 안 끝난 것
        status = "all"
        for line in meaningful {
            let lower = line.lowercased()
            if ["not done", "done", "all"].contains(lower) { status = lower }
            else if lower.hasPrefix("group by ") { group = String(lower.dropFirst(9)) }
            else if lower.hasPrefix("sort by ") { sort = String(lower.dropFirst(8)) }
            else if ["has agent", "no agent"].contains(lower) || lower.hasPrefix("agent is ") { agent = lower }
            else if line == "path includes \(notePath)" { onlyThisNote = true }
            else { others.append(line) }
        }
    }

    func lines(notePath: String) -> [String] {
        var lines = [status]
        if onlyThisNote { lines.append("path includes \(notePath)") }
        if !agent.isEmpty { lines.append(agent) }
        lines += others
        if !sort.isEmpty { lines.append("sort by \(sort)") }
        if !group.isEmpty { lines.append("group by \(group)") }
        return lines
    }
}

private struct QueryControls: View {
    let settings: QuerySettings
    var onChange: (QuerySettings) -> Void

    var body: some View {
        // 메모 폭이 좁으면 버튼 줄만 가로로 스크롤 (목록 전체가 밀리지 않게)
        ScrollView(.horizontal, showsIndicators: false) {
            buttons
        }
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            picker(settings.status, [("not done", "안 끝난 것"), ("done", "끝난 것"), ("all", "전체")]) { $0.status = $1 }
            picker(settings.agent, [("", "누구나"), ("has agent", "에이전트만"), ("no agent", "사람만"),
                                    ("agent is claude", "Claude"), ("agent is codex", "Codex"), ("agent is grok", "Grok")]) { $0.agent = $1 }
            picker(settings.group, [("", "묶지 않음"), ("filename", "메모별"), ("heading", "제목별"), ("status", "상태별"), ("agent", "에이전트별")]) { $0.group = $1 }
            picker(settings.sort, [("", "기본 순서"), ("due", "기한순"), ("status", "상태순"), ("description", "이름순")]) { $0.sort = $1 }
            Toggle("이 메모만", isOn: Binding(
                get: { settings.onlyThisNote },
                set: { var next = settings; next.onlyThisNote = $0; onChange(next) }
            ))
            .toggleStyle(.button)
            .font(.system(size: 11))
            Spacer(minLength: 0)
        }
        .controlSize(.mini)
    }

    private func picker(_ current: String, _ options: [(String, String)], apply: @escaping (inout QuerySettings, String) -> Void) -> some View {
        Menu {
            ForEach(options, id: \.0) { value, label in
                Button {
                    var next = settings
                    apply(&next, value)
                    onChange(next)
                } label: {
                    if value == current { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            Text(options.first { $0.0 == current }?.1 ?? current)
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(.black.opacity(0.06)))
    }
}
