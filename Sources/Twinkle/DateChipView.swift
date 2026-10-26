import AppKit
import SwiftUI

/// 날짜 칩을 누르면 뜨는 달력. 날짜를 골라 둘러보고(그날 할 일), "이 날짜로 바꾸기"로 메모의 날짜를 바꿈
struct DateChipView: View {
    let original: Date
    @ObservedObject var library: NoteLibrary
    var onChoose: (Date) -> Void
    var onOpenNote: (String) -> Void

    @State private var selection: Date

    init(original: Date, library: NoteLibrary, onChoose: @escaping (Date) -> Void, onOpenNote: @escaping (String) -> Void) {
        self.original = original
        self.library = library
        self.onChoose = onChoose
        self.onOpenNote = onOpenNote
        _selection = State(initialValue: original)
    }

    private var isChanged: Bool {
        !Calendar.current.isDate(selection, inSameDayAs: original)
    }

    /// 고른 날의 할 일 (📅 기한이나 날짜 칩이 그날인 것)
    private var tasksOnDay: [TaskItem] {
        var query = "has due date"
        query += "\ndue on \(selection.formatted(.iso8601.year().month().day()))"
        return TaskQuery.parse(query).run(in: library).flatMap(\.items)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DatePicker("", selection: $selection, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()

            Divider()

            Text(selection.formatted(.dateTime.month().day().weekday(.wide)) + "의 할 일")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if tasksOnDay.isEmpty {
                Text("없어요").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(tasksOnDay) { item in
                    HStack(spacing: 6) {
                        Image(systemName: TodoRowIcon.name(for: item.todo.state))
                            .foregroundStyle(Color(nsColor: MarkdownStyler.color(for: item.todo.state)))
                        Text(item.displayTitle).lineLimit(1)
                        Spacer()
                        Button(item.noteTitle) { onOpenNote(item.todo.docPath) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    .font(.system(size: 12))
                }
            }

            HStack {
                Button("오늘") { selection = Date() }
                Spacer()
                Button("이 날짜로 바꾸기") { onChoose(selection) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isChanged)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 260)
    }
}
