import AppKit
import SwiftUI

/// 요일 줄 + 한 달 날짜 칸. 날짜 칩 달력과 ```cal 블록이 같이 씀
struct MonthGrid: View {
    let month: Date
    @Binding var selection: Date
    /// 날짜 아래 점 색 (할 일이 있는 날)
    var mark: (Date) -> Color? = { _ in nil }
    /// 옅게 칠해 둘 날 (날짜 칩의 지금 날짜)
    var highlighted: Date?
    var onDoubleClick: ((Date) -> Void)?

    static let cellHeight: CGFloat = 34
    static let weekdayHeight: CGFloat = 14
    static let spacing: CGFloat = 4

    /// 요일 줄 + 6주 (몇 주짜리 달이든 높이가 같게)
    static var height: CGFloat { weekdayHeight + spacing + 6 * cellHeight + 5 * spacing }

    private let calendar = Calendar.current

    /// 이 달 칸들: 앞쪽 빈칸(nil) + 1일~말일
    private var days: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    var body: some View {
        VStack(spacing: Self.spacing) {
            weekdayRow
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: Self.spacing) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        dayCell(day)
                    } else {
                        Color.clear.frame(height: Self.cellHeight)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: Self.height, alignment: .top)
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
        .frame(height: Self.weekdayHeight)
    }

    private func dayCell(_ day: Date) -> some View {
        let selected = calendar.isDate(day, inSameDayAs: selection)
        let today = calendar.isDateInToday(day)
        let isHighlighted = highlighted.map { calendar.isDate(day, inSameDayAs: $0) } ?? false
        let weekday = calendar.component(.weekday, from: day)
        return VStack(spacing: 2) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: 13, weight: selected || today ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : weekday == 1 ? Color.red.opacity(0.8) : Color.primary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(selected ? Color.accentColor : (isHighlighted ? Color.accentColor.opacity(0.15) : .clear)))
                .overlay(Circle().strokeBorder(today && !selected ? Color.accentColor : .clear, lineWidth: 1.5))
            Circle()
                .fill(mark(day) ?? .clear)
                .frame(width: 4, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.cellHeight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            selection = day
            onDoubleClick?(day)
        }
        .onTapGesture { selection = day }
    }
}

/// ```cal 블록 자리에 그려지는 달력. 기한이 있는 할 일을 날짜에 점으로, 고른 날의 할 일을 아래에
struct CalendarBlockView: View {
    @ObservedObject var model: TaskBlockModel
    let library: NoteLibrary
    var onOpenTodo: (Todo) -> Void
    var onEdit: () -> Void

    @State private var selection = Date()
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()

    static let headerHeight: CGFloat = 28
    static let dayTitleHeight: CGFloat = 22
    static let rowHeight: CGFloat = 24
    static let visibleRows = 3
    static let errorHeight: CGFloat = 16
    static let padding: CGFloat = 10

    /// 편집기가 비워 둘 높이 (항상 같음: 6주 달력 + 할 일 세 줄)
    static func height(errors: [String]) -> CGFloat {
        headerHeight + CGFloat(errors.count) * errorHeight + 6 + MonthGrid.height + 9
            + dayTitleHeight + CGFloat(visibleRows) * rowHeight + padding * 2
    }

    private let calendar = Calendar.current

    private var items: [TaskItem] { model.groups.flatMap(\.items) }

    private var itemsOnSelection: [TaskItem] {
        items.filter { item in item.due.map { calendar.isDate($0, inSameDayAs: selection) } ?? false }
    }

    var body: some View {
        // 날짜별: 안 끝난 할 일이 있으면 주황, 다 끝났으면 회색
        var marks: [Date: Bool] = [:]
        for item in items {
            guard let due = item.due else { continue }
            let day = calendar.startOfDay(for: due)
            marks[day] = (marks[day] ?? false) || item.todo.state != .done
        }
        return VStack(alignment: .leading, spacing: 0) {
            header

            ForEach(model.errors, id: \.self) { error in
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .frame(height: Self.errorHeight)
            }

            MonthGrid(month: month, selection: $selection, mark: { day in
                marks[calendar.startOfDay(for: day)].map { $0 ? Color.orange : Color.secondary.opacity(0.5) }
            })
            .padding(.top, 6)

            Divider().padding(.vertical, 4)

            HStack {
                Text(selection.formatted(.dateTime.month().day().weekday(.wide)))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if itemsOnSelection.count > Self.visibleRows {
                    Text("\(itemsOnSelection.count)개")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: Self.dayTitleHeight)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if itemsOnSelection.isEmpty {
                        Text("이 날의 할 일이 없어요")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(height: Self.rowHeight)
                    }
                    ForEach(itemsOnSelection) { item in
                        TaskRow(item: item, library: library, showsDue: false, onOpenTodo: onOpenTodo)
                            .frame(height: Self.rowHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: CGFloat(Self.visibleRows) * Self.rowHeight)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .light)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(month.formatted(.dateTime.year().month(.wide)))
                .font(.system(size: 14, weight: .bold))
            Spacer()
            if !calendar.isDate(month, equalTo: Date(), toGranularity: .month) || !calendar.isDateInToday(selection) {
                Button("오늘") {
                    selection = Date()
                    month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
            Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .help("조건 편집")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.black.opacity(0.7))
        .frame(height: Self.headerHeight)
    }

    private func shiftMonth(_ delta: Int) {
        month = calendar.date(byAdding: .month, value: delta, to: month) ?? month
    }
}
