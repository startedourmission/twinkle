import AppKit
import SwiftUI

/// 로고를 클릭하면 뜨는 상세 작업 내역. 일하는 중이면 지금 작업, 아니면 마지막 작업
struct JobDetailView: View {
    let kind: AgentKind
    @ObservedObject var runner: AgentRunner
    @ObservedObject private var monitor = UsageMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentBadge(kind: kind, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.displayName).font(.headline)
                    if let usage = monitor.usage[kind] {
                        // 예: 5시간 29% · 7일 6% (가장 이른 초기화 시각)
                        let reset = usage.windows.compactMap(\.resetsAt).filter { $0 > Date() }.min()
                        Text("사용량 " + usage.summary + (reset.map { " · \($0.formatted(.dateTime.hour().minute())) 초기화" } ?? ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let job = runner.jobs[kind] ?? runner.lastJobs[kind] {
                    StateChip(job: job, isRunning: runner.jobs[kind] != nil)
                } else {
                    Text("쉬는 중").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let job = runner.jobs[kind] ?? runner.lastJobs[kind] {
                JobHistory(job: job, isRunning: runner.jobs[kind] != nil)
                FollowUp(job: job, runner: runner, isRunning: runner.jobs[kind] != nil)
            } else {
                Text(AppSettings.shared.settings(for: kind).enabled
                     ? "아직 맡은 작업이 없어요. 할 일에 \(kind.tag) 태그를 붙이면 가져가요."
                     : "설정에서 꺼져 있어요.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 400)
    }
}

private struct StateChip: View {
    @ObservedObject var job: AgentJob
    let isRunning: Bool

    var body: some View {
        let (label, color): (String, Color) = if isRunning {
            (job.isResume ? "답하는 중" : "작업 중", .orange)
        } else {
            switch job.finishedState {
            case .done: ("완료", .green)
            case .waiting: ("답변 필요", .purple)
            default: ("실패", .red)
            }
        }
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

private struct JobHistory: View {
    @ObservedObject var job: AgentJob
    let isRunning: Bool

    private static let timeFormat: Date.FormatStyle = .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    private func row(_ entry: ActivityEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.date, format: Self.timeFormat)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(CommentText.attributed(entry.text))
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(MarkdownPlain.text(job.todo.title))
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Label((job.workdir.path as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if isRunning {
                        Label { Text(job.startedAt, style: .timer) } icon: { Image(systemName: "clock") }
                            .monospacedDigit()
                    } else if let finishedAt = job.finishedAt {
                        Label(Duration.seconds(finishedAt.timeIntervalSince(job.startedAt)).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated)), systemImage: "clock")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(HistorySegment.group(job.history)) { segment in
                            switch segment {
                            case .message(let entry):
                                row(entry)
                            case .tools(let entries):
                                ToolGroupRow(entries: entries, timeFormat: Self.timeFormat)
                            }
                        }
                        if job.history.isEmpty {
                            Text("시작하는 중…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 80, maxHeight: 320)
                .onAppear { proxy.scrollTo(HistorySegment.group(job.history).last?.id, anchor: .bottom) }
                .onChange(of: job.history.count) { _, _ in
                    proxy.scrollTo(HistorySegment.group(job.history).last?.id, anchor: .bottom)
                }
            }
        }
    }
}

/// 권한 허용과 추가 지시. 일하는 중이면 지금 차례가 끝난 뒤 이어서 전달
private struct FollowUp: View {
    @ObservedObject var job: AgentJob
    @ObservedObject var runner: AgentRunner
    let isRunning: Bool
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rules = runner.pendingPermission(for: job) {
                PermissionPanel(rules: rules) { meta, text in
                    runner.send(text, meta: meta, about: job)
                }
            }

            if let queued = runner.queuedPrompts[job.kind], !queued.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("이번 차례가 끝나면 전달할 지시", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(Array(queued.enumerated()), id: \.offset) { _, text in
                        Text(text)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.1)))
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField(isRunning ? "끝나면 이어서 전달할 지시…" : "이어서 시킬 일…", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(send)
                Button(isRunning ? "대기열에" : "보내기", action: send)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if isRunning {
                    Button {
                        runner.stop(job.kind)
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("작업 중지")
                }
            }
            .controlSize(.small)
        }
    }

    private func send() {
        runner.send(draft, about: job)
        draft = ""
    }
}

/// 작업 기록 한 덩어리: 에이전트의 말은 한 줄씩, 연달아 쓴 도구는 한 묶음으로
enum HistorySegment: Identifiable {
    case message(ActivityEntry)
    case tools([ActivityEntry])

    var id: UUID {
        switch self {
        case .message(let entry): entry.id
        case .tools(let entries): entries[0].id
        }
    }

    static func isTool(_ entry: ActivityEntry) -> Bool {
        entry.text.hasPrefix("🔧") || entry.text.hasPrefix("$") || entry.text.hasPrefix("✏️")
    }

    static func group(_ history: [ActivityEntry]) -> [HistorySegment] {
        var segments: [HistorySegment] = []
        var tools: [ActivityEntry] = []
        for entry in history {
            if isTool(entry) {
                tools.append(entry)
                continue
            }
            if !tools.isEmpty { segments.append(.tools(tools)); tools = [] }
            segments.append(.message(entry))
        }
        if !tools.isEmpty { segments.append(.tools(tools)) }
        return segments
    }
}

/// "도구 5개 · Bash 3, Read 2" 한 줄. 누르면 펼쳐서 하나씩
private struct ToolGroupRow: View {
    let entries: [ActivityEntry]
    let timeFormat: Date.FormatStyle
    @State private var isExpanded = false

    /// 도구 이름별 횟수 (많은 순)
    private var summary: String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for entry in entries {
            let name: String
            if entry.text.hasPrefix("$") { name = "명령" }
            else if entry.text.hasPrefix("✏️") { name = "파일 수정" }
            else { name = entry.text.dropFirst(2).split(separator: " ").first.map(String.init) ?? "도구" }
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.sorted { counts[$0]! > counts[$1]! }.prefix(4).map { "\($0) \(counts[$0]!)" }.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entries[0].date, format: timeFormat)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                    Text("🔧 도구 \(entries.count)개 · \(summary)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(entry.date, format: timeFormat)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(entry.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                    }
                }
                .padding(.leading, 18)
            }
        }
    }
}
