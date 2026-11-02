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
        // 한 번 클릭은 바로 고르고, 더블클릭은 같이 받음 (onTapGesture(count: 2)를 먼저 걸면 한 번 클릭이 더블클릭 간격만큼 늦어짐)
        .onTapGesture { selection = day }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { onDoubleClick?(day) },
            including: onDoubleClick == nil ? .subviews : .all
        )
    }
}

/// ```cal 블록 자리에 그려지는 달력.
/// 월: 기한이 있는 할 일을 날짜에 점으로, 고른 날의 할 일을 아래에.
/// 3일: 사흘을 칸반처럼 나란히, 할 일 카드를 다른 날로 끌어 놓으면 기한이 바뀜
struct CalendarBlockView: View {
    @ObservedObject var model: TaskBlockModel
    let library: NoteLibrary
    var onOpenTodo: (Todo) -> Void
    var onEdit: () -> Void

    @State private var selection = Date()
    @State private var month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    /// "month" | "3day" (모든 달력 블록이 같이 기억)
    @AppStorage("calendarBlockMode") private var mode = "month"
    /// 3일 보기의 첫날
    @State private var start = Calendar.current.startOfDay(for: Date())
    /// 끌고 있는 카드가 올라가 있는 날
    @State private var dropTarget: Date?

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

            if mode == "3day" {
                threeDays
                    .padding(.top, 6)
                    .frame(height: 6 + MonthGrid.height + 9 + Self.dayTitleHeight + CGFloat(Self.visibleRows) * Self.rowHeight, alignment: .top)
            } else {
                monthView(marks: marks)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.45)))
        .background(HorizontalSwipeReader(oncePerGesture: mode != "3day") { shift($0) })
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .environment(\.colorScheme, .light)
    }

    @ViewBuilder
    private func monthView(marks: [Date: Bool]) -> some View {
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

    // MARK: 3일

    private var days: [Date] {
        (0..<3).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private func items(on day: Date) -> [TaskItem] {
        items.filter { item in item.due.map { calendar.isDate($0, inSameDayAs: day) } ?? false }
    }

    private var threeDays: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(days, id: \.self) { day in
                dayColumn(day)
            }
        }
    }

    private func dayColumn(_ day: Date) -> some View {
        let dayItems = items(on: day)
        let isToday = calendar.isDateInToday(day)
        let weekday = calendar.component(.weekday, from: day)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(isToday ? Color.white : weekday == 1 ? Color.red.opacity(0.8) : Color.primary)
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Circle().fill(isToday ? Color.accentColor : .clear))
                Text(day.formatted(.dateTime.weekday(.abbreviated)))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(weekday == 1 ? Color.red.opacity(0.7) : weekday == 7 ? Color.blue.opacity(0.7) : Color.secondary)
                Spacer(minLength: 0)
                if !dayItems.isEmpty {
                    Text("\(dayItems.count)").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(dayItems) { card($0) }
                    if dayItems.isEmpty {
                        Text("없음")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(dropTarget == day ? Color.accentColor.opacity(0.14) : Color.black.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(dropTarget == day ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1.5)
        )
        // 다른 날의 카드를 놓으면 그 할 일의 기한을 이 날로
        .dropDestination(for: String.self) { ids, _ in
            dropTarget = nil
            guard let id = ids.first, let item = items.first(where: { $0.id == id }),
                  !(item.due.map { calendar.isDate($0, inSameDayAs: day) } ?? false)
            else { return false }
            return library.setDue(of: item.todo, to: day)
        } isTargeted: { targeted in
            if targeted { dropTarget = day } else if dropTarget == day { dropTarget = nil }
        }
    }

    /// 할 일 카드: 체크박스, 제목(세 줄까지), 메모 위치. 하는 중인 에이전트 일은 옮기지 않음 (결과를 그 줄에 다시 써야 해서)
    private func card(_ item: TaskItem) -> some View {
        let todo = item.todo
        let content = VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 4) {
                Button {
                    library.setState(of: todo, to: todo.state == .done ? .open : .done)
                } label: {
                    Image(systemName: TodoRowIcon.name(for: todo.state))
                        .font(.system(size: 12))
                        .foregroundStyle(Color(nsColor: MarkdownStyler.color(for: todo.state)))
                }
                .buttonStyle(.plain)
                .disabled(todo.state == .doing)
                Text(item.displayTitle)
                    .font(.system(size: 12))
                    .strikethrough(todo.state == .done)
                    .foregroundStyle(todo.state == .done ? Color.secondary : Color.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
            }
            // 좁은 칸에서 제목 자리를 넓게: 에이전트 로고는 아래 줄에
            HStack(spacing: 4) {
                if let agent = todo.agent {
                    AgentBadge(kind: agent, size: 13)
                }
                Button(item.location) { onOpenTodo(todo) }
                    .help("이 할 일로 이동: \(item.location)")
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: MarkdownStyler.linkColor))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.9)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 6))

        return Group {
            if todo.state == .doing {
                content.help("하는 중인 일은 옮길 수 없어요")
            } else {
                content.draggable(item.id) {
                    Text(item.displayTitle)
                        .font(.system(size: 12))
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.white))
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(mode == "3day" ? rangeTitle : month.formatted(.dateTime.year().month(.wide)))
                .font(.system(size: 14, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
            Spacer()
            if mode == "3day" ? !calendar.isDateInToday(start)
                : !calendar.isDate(month, equalTo: Date(), toGranularity: .month) || !calendar.isDateInToday(selection) {
                Button("오늘") {
                    selection = Date()
                    start = calendar.startOfDay(for: Date())
                    month = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Picker("", selection: $mode) {
                Text("월").tag("month")
                Text("3일").tag("3day")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .fixedSize()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .help("조건 편집")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.black.opacity(0.7))
        .frame(height: Self.headerHeight)
    }

    /// "11월 2–4일" (달이 바뀌면 "10월 31일–11월 2일")
    private var rangeTitle: String {
        guard let last = days.last else { return "" }
        let first = start.formatted(.dateTime.month().day())
        if calendar.isDate(start, equalTo: last, toGranularity: .month) {
            return "\(start.formatted(.dateTime.month())) \(calendar.component(.day, from: start))–\(calendar.component(.day, from: last))일"
        }
        return "\(first)–\(last.formatted(.dateTime.month().day()))"
    }

    /// 월 보기는 한 달씩, 3일 보기는 하루씩 (좌우로 쓸어도 같음: 3일 보기는 쓴 거리만큼 며칠씩)
    private func shift(_ delta: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            if mode == "3day" {
                start = calendar.date(byAdding: .day, value: delta, to: start) ?? start
            } else {
                month = calendar.date(byAdding: .month, value: delta, to: month) ?? month
            }
        }
    }
}

/// 트랙패드 두 손가락 좌우 쓸기(또는 Shift+휠)를 받아 달력을 넘김. 세로 스크롤은 메모로 그대로 넘어감.
/// 뒤에 깔아 두고 이벤트를 엿보기만 해서, 위에 있는 버튼·끌어 놓기는 그대로 동작함
struct HorizontalSwipeReader: NSViewRepresentable {
    /// true: 한 번 쓸 때 한 칸만 (월 넘기기). false: 쓴 거리만큼 여러 칸 (관성 포함)
    var oncePerGesture: Bool
    /// 한 칸 넘어가는 거리 (pt)
    var step: CGFloat = 40
    /// +1 다음(미래), -1 이전
    var onStep: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.reader = self
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator(reader: self) }

    @MainActor
    final class Coordinator {
        var reader: HorizontalSwipeReader
        weak var view: NSView?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        private var fired = false

        init(reader: HorizontalSwipeReader) { self.reader = reader }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                // 이벤트는 메인 스레드로만 옴. NSEvent는 Sendable이 아니라 값만 꺼내 넘김
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// true면 달력이 먹음 (메모로 안 넘김)
        private func handle(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window else { return false }
            let point: NSPoint
            if let eventWindow = event.window {
                guard eventWindow === window else { return false }
                point = view.convert(event.locationInWindow, from: nil)
            } else {
                // 창이 안 정해진 이벤트는 화면 좌표: 그 자리 맨 위 창이 이 창일 때만
                guard NSWindow.windowNumber(at: event.locationInWindow, belowWindowWithWindowNumber: 0) == window.windowNumber else { return false }
                point = view.convert(window.convertPoint(fromScreen: event.locationInWindow), from: nil)
            }
            guard view.bounds.contains(point) else { return false }

            if event.phase == .began || event.phase == .mayBegin {
                accumulated = 0
                fired = false
            }
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            // 세로가 더 크면 메모 스크롤
            guard abs(dx) > abs(dy) else { return false }
            // 한 번만 넘기는 쪽은 관성은 버림 (손을 뗀 뒤 또 넘어가지 않게)
            if reader.oncePerGesture, event.momentumPhase != [] { return true }

            if !event.hasPreciseScrollingDeltas {
                // 마우스 휠(Shift+휠): 한 눈금에 한 칸
                reader.onStep(dx < 0 ? 1 : -1)
                return true
            }
            accumulated += dx
            // 내용이 왼쪽으로 밀리면(손가락을 왼쪽으로) 다음 날·다음 달
            if reader.oncePerGesture {
                if !fired, abs(accumulated) >= reader.step * 1.5 {
                    fired = true
                    reader.onStep(accumulated < 0 ? 1 : -1)
                }
            } else {
                let steps = Int(accumulated / reader.step)
                if steps != 0 {
                    accumulated -= CGFloat(steps) * reader.step
                    reader.onStep(-steps)
                }
            }
            return true
        }
    }
}
