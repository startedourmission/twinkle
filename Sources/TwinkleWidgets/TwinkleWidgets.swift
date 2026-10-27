import AppKit
import SwiftUI
import TwinkleShared
import WidgetKit

// 바탕화면·알림 센터 위젯: 할 일 목록, 달력.
// 앱이 할 일이 바뀔 때마다 widget.json을 새로 쓰고 다시 그리라고 알려 줌 (WidgetExporter)

@main
struct TwinkleWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodoWidget()
        CalendarWidget()
    }
}

// MARK: 타임라인

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        // 위젯 갤러리 미리보기는 실제 할 일이 없으면 예시로
        let snapshot = WidgetSnapshot.load()
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview && (snapshot?.todos.isEmpty ?? true) ? .sample : snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        // 바뀌면 앱이 다시 그리라고 알려 주니, 스스로는 자정(오늘 표시)에만
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))
        completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load())], policy: .after(midnight)))
    }
}

// MARK: 할 일 위젯

struct TodoWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "todos", provider: SnapshotProvider()) { entry in
            TodoWidgetView(entry: entry)
        }
        .configurationDisplayName("할 일")
        .description("안 끝난 할 일을 기한순으로 보여 줘요. 누르면 그 메모가 열려요.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct TodoWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var items: [WidgetSnapshot.Item] { entry.snapshot?.todos ?? [] }

    private var rows: Int {
        switch family {
        case .systemLarge: 10
        default: 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 5 : 6) {
            HStack(spacing: 5) {
                Image(systemName: "checklist")
                Text("할 일")
                Spacer(minLength: 0)
                Text("\(items.count)").monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.black.opacity(0.55))

            if entry.snapshot == nil {
                Spacer(minLength: 0)
                Text("Twinkle을 실행하면\n할 일이 여기에 떠요").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if items.isEmpty {
                Spacer(minLength: 0)
                Text("할 일을 모두 끝냈어요 ✨").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(items.prefix(rows)) { item in
                Link(destination: item.url) {
                    TodoRow(item: item, compact: family == .systemSmall, showsNote: family != .systemSmall)
                }
            }
            Spacer(minLength: 0)
            if items.count > rows {
                Text("외 \(items.count - rows)개").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .widgetURL(WidgetLink.mainNote)
        .containerBackground(for: .widget) { NoteBackground() }
    }
}

// MARK: 달력 위젯

struct CalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "calendar", provider: SnapshotProvider()) { entry in
            CalendarWidgetView(entry: entry)
        }
        .configurationDisplayName("달력")
        .description("기한이 있는 할 일을 날짜에 점으로 찍고, 오늘과 다가오는 할 일을 보여 줘요.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct CalendarWidgetView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family
    private let calendar = Calendar.current

    private var dated: [WidgetSnapshot.Item] { entry.snapshot?.dated ?? [] }

    private var today: [WidgetSnapshot.Item] {
        dated.filter { item in item.due.map { calendar.isDate($0, inSameDayAs: entry.date) } ?? false }
    }

    /// 내일부터의 안 끝난 할 일 (기한순)
    private var upcoming: [WidgetSnapshot.Item] {
        let tomorrow = calendar.startOfDay(for: entry.date.addingTimeInterval(86_400))
        return dated.filter { !$0.isDone && ($0.due ?? .distantPast) >= tomorrow }
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemMedium: medium
            default: large
            }
        }
        .widgetURL(WidgetLink.mainNote)
        .containerBackground(for: .widget) { NoteBackground() }
    }

    /// 오늘 날짜 크게 + 오늘 할 일
    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.date.formatted(.dateTime.weekday(.wide)))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.red)
            Text(entry.date.formatted(.dateTime.day()))
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(.black.opacity(0.8))
            Spacer(minLength: 0)
            dayList(today.isEmpty ? Array(upcoming.prefix(2)) : Array(today.prefix(2)), emptyText: "할 일 없음", showsDate: today.isEmpty)
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            MonthGridView(date: entry.date, dated: dated, cellHeight: 17, fontSize: 10)
                .frame(width: 150)
            VStack(alignment: .leading, spacing: 5) {
                Text("오늘").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.55))
                dayList(Array(today.prefix(2)), emptyText: "오늘은 할 일이 없어요", showsDate: false)
                if today.count < 3, !upcoming.isEmpty {
                    Text("다가오는 일").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.55)).padding(.top, 2)
                    dayList(Array(upcoming.prefix(3 - min(today.count, 2))), emptyText: "", showsDate: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            MonthGridView(date: entry.date, dated: dated, cellHeight: 26, fontSize: 13)
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Text("오늘").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.55))
                dayList(Array(today.prefix(3)), emptyText: "오늘은 할 일이 없어요", showsDate: false)
                if !upcoming.isEmpty {
                    Text("다가오는 일").font(.system(size: 12, weight: .semibold)).foregroundStyle(.black.opacity(0.55)).padding(.top, 2)
                    dayList(Array(upcoming.prefix(5 - min(today.count, 3))), emptyText: "", showsDate: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func dayList(_ items: [WidgetSnapshot.Item], emptyText: String, showsDate: Bool) -> some View {
        if items.isEmpty, !emptyText.isEmpty {
            Text(emptyText).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        ForEach(items) { item in
            Link(destination: item.url) {
                TodoRow(item: item, compact: family != .systemLarge, showsNote: false, showsDue: showsDate)
            }
        }
    }
}

/// 한 달 칸: 요일 줄 + 날짜. 할 일 기한이 있는 날 아래 점 (안 끝난 일 주황, 다 끝났으면 회색)
struct MonthGridView: View {
    let date: Date
    let dated: [WidgetSnapshot.Item]
    let cellHeight: CGFloat
    let fontSize: CGFloat
    private let calendar = Calendar.current

    private var month: Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    private var days: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    var body: some View {
        var marks: [Date: Bool] = [:]
        for item in dated {
            guard let due = item.due else { continue }
            let day = calendar.startOfDay(for: due)
            marks[day] = (marks[day] ?? false) || !item.isDone
        }
        let symbols = calendar.veryShortWeekdaySymbols
        let ordered = (0..<7).map { symbols[($0 + calendar.firstWeekday - 1) % 7] }
        return VStack(alignment: .leading, spacing: 3) {
            Text(month.formatted(.dateTime.month(.wide)))
                .font(.system(size: fontSize + 1, weight: .bold))
                .foregroundStyle(.red)
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(ordered.enumerated()), id: \.offset) { index, symbol in
                        let weekday = (index + calendar.firstWeekday - 1) % 7 + 1
                        Text(symbol)
                            .font(.system(size: fontSize - 2, weight: .medium))
                            .foregroundStyle(weekday == 1 ? Color.red.opacity(0.7) : weekday == 7 ? Color.blue.opacity(0.7) : Color.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<(days.count + 6) / 7, id: \.self) { week in
                    GridRow {
                        ForEach(0..<7, id: \.self) { column in
                            let index = week * 7 + column
                            if index < days.count, let day = days[index] {
                                dayCell(day, mark: marks[calendar.startOfDay(for: day)])
                            } else {
                                Color.clear.frame(height: cellHeight)
                            }
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: Date, mark: Bool?) -> some View {
        let isToday = calendar.isDate(day, inSameDayAs: date)
        let weekday = calendar.component(.weekday, from: day)
        let size = cellHeight - 5
        return VStack(spacing: 1) {
            Text("\(calendar.component(.day, from: day))")
                .font(.system(size: fontSize, weight: isToday ? .bold : .regular))
                .foregroundStyle(isToday ? Color.white : weekday == 1 ? Color.red.opacity(0.8) : Color.black.opacity(0.8))
                .frame(width: size, height: size)
                .background(Circle().fill(isToday ? Color.red : .clear))
            Circle()
                .fill(mark.map { $0 ? Color.orange : Color.secondary.opacity(0.5) } ?? .clear)
                .frame(width: 3, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: cellHeight)
    }
}

// MARK: 공용

/// 할 일 한 줄: 상태 아이콘, 에이전트 로고, 제목, 기한
struct TodoRow: View {
    let item: WidgetSnapshot.Item
    var compact = false
    var showsNote = true
    var showsDue = true

    private var isOverdue: Bool {
        guard let due = item.due, !item.isDone else { return false }
        return due < Calendar.current.startOfDay(for: .now)
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: StateStyle.symbol(item.state))
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(StateStyle.color(item.state))
            if let agent = item.agent, let logo = AgentLogo.image(agent) {
                Image(nsImage: logo)
                    .resizable()
                    .scaledToFit()
                    .padding(1.5)
                    .background(Circle().fill(.white))
                    .frame(width: 14, height: 14)
            }
            Text(item.title)
                .font(.system(size: compact ? 11 : 12))
                .strikethrough(item.isDone)
                .foregroundStyle(item.isDone ? Color.secondary : Color.black.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 2)
            if showsDue, let due = item.due {
                Text(due.formatted(.dateTime.month(.defaultDigits).day()))
                    .font(.system(size: 10))
                    .foregroundStyle(isOverdue ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            if showsNote {
                Text(item.noteTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 70, alignment: .trailing)
            }
        }
    }
}

/// 메모와 같은 노란 종이 색
struct NoteBackground: View {
    var body: some View {
        Color(red: 1.0, green: 0.95, blue: 0.62)
    }
}

enum StateStyle {
    static func symbol(_ state: String) -> String {
        switch state {
        case "/": "circle.dotted"
        case "x": "checkmark.square.fill"
        case "!": "exclamationmark.square"
        case "?": "questionmark.square.fill"
        default: "square"
        }
    }

    static func color(_ state: String) -> Color {
        switch state {
        case "/": .orange
        case "x": .green
        case "!": .red
        case "?": .purple
        default: .black.opacity(0.55)
        }
    }
}

/// 위젯 번들 안 Resources/logos/<agent>.png
enum AgentLogo {
    static func image(_ agent: String) -> NSImage? {
        Bundle.main.url(forResource: agent, withExtension: "png", subdirectory: "logos").flatMap(NSImage.init(contentsOf:))
    }
}

extension WidgetSnapshot {
    /// 갤러리 미리보기용 예시
    static var sample: WidgetSnapshot {
        let calendar = Calendar.current
        let day = { (offset: Int) in calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: .now)) }
        let items = [
            Item(title: "원고 마감", state: " ", due: day(0), agent: nil, noteTitle: "원고", path: "Main.md", line: 0),
            Item(title: "README 오타 고치기", state: "/", due: nil, agent: "claude", noteTitle: "Main", path: "Main.md", line: 1),
            Item(title: "저자 미팅", state: " ", due: day(2), agent: nil, noteTitle: "일정", path: "Main.md", line: 2),
            Item(title: "테스트 깨지는 이유 찾기", state: "?", due: nil, agent: "codex", noteTitle: "Main", path: "Main.md", line: 3),
        ]
        return WidgetSnapshot(todos: items, dated: items.filter { $0.due != nil })
    }
}
