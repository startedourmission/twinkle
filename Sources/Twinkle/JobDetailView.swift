import AppKit
import SwiftUI

/// 로고를 클릭하면 뜨는 상세 작업 내역. 일하는 중이면 지금 작업, 아니면 마지막 작업
struct JobDetailView: View {
    let kind: AgentKind
    @ObservedObject var runner: AgentRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AgentBadge(kind: kind, size: 24)
                Text(kind.displayName).font(.headline)
                Spacer()
                if let job = runner.jobs[kind] ?? runner.lastJobs[kind] {
                    StateChip(job: job, isRunning: runner.jobs[kind] != nil)
                } else {
                    Text("쉬는 중").font(.caption).foregroundStyle(.secondary)
                }
            }

            if let job = runner.jobs[kind] ?? runner.lastJobs[kind] {
                JobHistory(job: job, isRunning: runner.jobs[kind] != nil) {
                    runner.stop(kind)
                }
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
    var onStop: () -> Void

    private static let timeFormat: Date.FormatStyle = .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.todo.title)
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
                        ForEach(job.history) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(entry.date, format: Self.timeFormat)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(entry.text)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .id(entry.id)
                        }
                        if job.history.isEmpty {
                            Text("시작하는 중…").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 80, maxHeight: 320)
                .onAppear { proxy.scrollTo(job.history.last?.id, anchor: .bottom) }
                .onChange(of: job.history.count) { _, _ in
                    proxy.scrollTo(job.history.last?.id, anchor: .bottom)
                }
            }

            HStack {
                Button("로그 파일 열기") { NSWorkspace.shared.activateFileViewerSelecting([job.logURL]) }
                Spacer()
                if isRunning {
                    Button("중지", role: .destructive, action: onStop)
                }
            }
            .controlSize(.small)
        }
    }
}
