import AppKit
import SwiftUI

/// 메모 안 ```tasks 블록 하나의 결과
@MainActor
final class TaskBlockModel: ObservableObject {
    @Published var groups: [TaskGroup] = []
    @Published var errors: [String] = []
}

/// ```tasks 블록 자리에 그려지는 할 일 목록
struct TaskQueryView: View {
    @ObservedObject var model: TaskBlockModel
    let library: NoteLibrary
    var onOpenNote: (String) -> Void
    var onEdit: () -> Void

    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 26
    static let groupHeight: CGFloat = 22
    static let errorHeight: CGFloat = 16
    static let padding: CGFloat = 8

    /// 내용에 맞춘 높이. 편집기가 이만큼 자리를 비워 둠
    static func height(groups: [TaskGroup], errors: [String]) -> CGFloat {
        let rows = groups.reduce(0) { $0 + $1.items.count }
        let titled = groups.filter { $0.title != nil }.count
        return headerHeight + CGFloat(errors.count) * errorHeight + CGFloat(titled) * groupHeight
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
                    TaskRow(item: item, library: library, onOpenNote: onOpenNote)
                        .frame(height: Self.rowHeight)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .light)
    }
}

private struct TaskRow: View {
    let item: TaskItem
    let library: NoteLibrary
    var onOpenNote: (String) -> Void

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
            if let due = item.due {
                Text(due, format: .dateTime.month().day())
                    .font(.system(size: 11))
                    .foregroundStyle(due < Calendar.current.startOfDay(for: Date()) && todo.state != .done ? .red : .secondary)
            }
            Button(item.noteTitle) { onOpenNote(todo.docPath) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: MarkdownStyler.linkColor))
                .lineLimit(1)
                .frame(maxWidth: 90, alignment: .trailing)
        }
    }
}
