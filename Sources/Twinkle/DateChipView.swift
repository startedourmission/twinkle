import AppKit
import SwiftUI

/// 날짜 칩을 누르면 뜨는 달력. 날짜를 골라 그날 할 일을 보고, "○월 ○일로 바꾸기"(또는 더블클릭)로 메모의 날짜를 바꿈
struct DateChipView: View {
    let original: Date
    @ObservedObject var library: NoteLibrary
    var onChoose: (Date) -> Void
    var onOpenTodo: (Todo) -> Void

    @State private var selection: Date
    @State private var month: Date

    private let calendar = Calendar.current

    init(original: Date, library: NoteLibrary, onChoose: @escaping (Date) -> Void, onOpenTodo: @escaping (Todo) -> Void) {
        self.original = original
        self.library = library
        self.onChoose = onChoose
        self.onOpenTodo = onOpenTodo
        _selection = State(initialValue: original)
        _month = State(initialValue: Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: original)) ?? original)
    }

    /// 기한이 있는 할 일 (📅 기한이나 날짜 칩)
    private var dated: [TaskItem] {
        TaskQuery.parse("has due date").run(in: library).flatMap(\.items)
    }

    var body: some View {
        // 할 일 검색은 그릴 때마다 한 번만 (날짜를 고를 때마다 다시 그려짐)
        let dated = self.dated
        let busyDays = Set(dated.compactMap { $0.due.map { calendar.startOfDay(for: $0) } })
        let tasksOnSelection = dated.filter { item in item.due.map { calendar.isDate($0, inSameDayAs: selection) } ?? false }
        VStack(alignment: .leading, spacing: 12) {
            header
            MonthGrid(
                month: month,
                selection: $selection,
                mark: { busyDays.contains(calendar.startOfDay(for: $0)) ? .orange : nil },
                highlighted: original,
                onDoubleClick: onChoose
            )

            HStack(spacing: 6) {
                quick("오늘", Date())
                quick("내일", calendar.date(byAdding: .day, value: 1, to: Date()))
                quick("다음 주", calendar.date(byAdding: .day, value: 7, to: Date()))
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(selection.formatted(.dateTime.month().day().weekday(.wide)))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                if tasksOnSelection.isEmpty {
                    Text("이 날의 할 일이 없어요").font(.system(size: 12)).foregroundStyle(.tertiary)
                } else {
                    ForEach(tasksOnSelection) { item in
                        Button { onOpenTodo(item.todo) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: TodoRowIcon.name(for: item.todo.state))
                                    .foregroundStyle(Color(nsColor: MarkdownStyler.color(for: item.todo.state)))
                                Text(item.displayTitle).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(item.location).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .font(.system(size: 12))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Button {
                onChoose(selection)
            } label: {
                Text(isChanged ? "\(selection.formatted(.dateTime.month().day()))로 바꾸기" : "지금 날짜예요")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!isChanged)
        }
        .padding(16)
        .frame(width: 280)
    }

    private var isChanged: Bool {
        !calendar.isDate(selection, inSameDayAs: original)
    }

    private var header: some View {
        HStack {
            Text(month.formatted(.dateTime.year().month(.wide)))
                .font(.system(size: 15, weight: .bold))
            Spacer()
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 13, weight: .semibold))
    }

    private func quick(_ title: String, _ date: Date?) -> some View {
        Button(title) {
            guard let date else { return }
            selection = date
            month = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func shiftMonth(_ delta: Int) {
        month = calendar.date(byAdding: .month, value: delta, to: month) ?? month
    }
}
