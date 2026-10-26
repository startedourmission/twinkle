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

    private var tasksOnSelection: [TaskItem] {
        dated.filter { item in item.due.map { calendar.isDate($0, inSameDayAs: selection) } ?? false }
    }

    /// 이 달 칸들: 앞쪽 빈칸(nil) + 1일~말일
    private var days: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    var body: some View {
        let busyDays = Set(dated.compactMap { $0.due.map { calendar.startOfDay(for: $0) } })
        VStack(alignment: .leading, spacing: 12) {
            header
            weekdayRow
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day, busy: busyDays.contains(calendar.startOfDay(for: day)))
                    } else {
                        Color.clear.frame(height: 34)
                    }
                }
            }

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
                                Text(item.noteTitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
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

    private var weekdayRow: some View {
        let symbols = calendar.veryShortWeekdaySymbols
        let ordered = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        return HStack(spacing: 2) {
            ForEach(Array(ordered.enumerated()), id: \.offset) { index, symbol in
                let weekday = (index + calendar.firstWeekday - 1) % 7 + 1
                Text(symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(weekday == 1 ? Color.red.opacity(0.7) : weekday == 7 ? Color.blue.opacity(0.7) : Color.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ day: Date, busy: Bool) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selection)
        let today = calendar.isDateInToday(day)
        let isOriginal = calendar.isDate(day, inSameDayAs: original)
        let weekday = calendar.component(.weekday, from: day)
        return VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 13, weight: selected || today ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : weekday == 1 ? Color.red.opacity(0.8) : Color.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(selected ? Color.accentColor : (isOriginal ? Color.accentColor.opacity(0.15) : .clear)))
                .overlay(Circle().strokeBorder(today && !selected ? Color.accentColor : .clear, lineWidth: 1.5))
            // 할 일 기한이 있는 날
            Circle()
                .fill(busy ? Color.orange : .clear)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selection = day
            onChoose(day)
        }
        .onTapGesture { selection = day }
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
