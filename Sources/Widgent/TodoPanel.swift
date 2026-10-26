import AppKit
import SwiftUI

/// 모든 메모의 체크박스를 모아 보는 창 + 에이전트 상태판
struct TodoPanelView: View {
    @ObservedObject var vault: Vault
    @ObservedObject var runner: AgentRunner
    var onOpenNote: (String) -> Void
    var onOpenConfig: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            agentSection
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14, pinnedViews: []) {
                    section("답변 필요", todos { $0.state == .waiting })
                    section("진행 중", todos { $0.state == .doing })
                    section("에이전트 대기", todos { $0.state == .open && $0.agent != nil })
                    section("할 일", todos { $0.state == .open && $0.agent == nil })
                    section("실패", todos { $0.state == .failed })
                    section("완료", todos { $0.state == .done })
                }
                .padding(14)
            }
        }
        .frame(minWidth: 360, minHeight: 300)
    }

    private func todos(_ filter: (Todo) -> Bool) -> [Todo] {
        vault.todos.filter(filter)
    }

    private var agentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("에이전트 자동 실행", isOn: $runner.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Button("설정 파일", action: onOpenConfig)
                    .controlSize(.small)
            }
            Text("작업 폴더: \(vault.workdir.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            ForEach(AgentKind.allCases) { kind in
                if let job = runner.jobs[kind] {
                    JobRow(job: job) { runner.stop(kind) }
                } else {
                    HStack(spacing: 8) {
                        AgentBadge(kind: kind).opacity(0.45)
                        Text(kind.displayName).font(.callout)
                        Text("쉬는 중").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [Todo]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(title) \(items.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(items) { todo in
                    TodoRow(todo: todo, vault: vault, runner: runner, onOpenNote: onOpenNote)
                }
            }
        }
    }
}

private struct TodoRow: View {
    let todo: Todo
    let vault: Vault
    let runner: AgentRunner
    var onOpenNote: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button {
                vault.setState(of: todo, to: todo.state == .done ? .open : .done)
            } label: {
                Image(systemName: TodoRowIcon.name(for: todo.state))
                    .foregroundStyle(Color(nsColor: MarkdownStyler.color(for: todo.state)))
            }
            .buttonStyle(.plain)
            .disabled(todo.state == .doing)

            if let agent = todo.agent {
                AgentBadge(kind: agent, size: 15)
            }
            Text(todo.title)
                .strikethrough(todo.state == .done)
                .foregroundStyle(todo.state == .done ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let document = vault.documents[todo.docPath] {
                ThreadButton(todo: todo, document: document, vault: vault, runner: runner)
            }

            Button(todo.docPath.replacingOccurrences(of: ".md", with: "")) {
                onOpenNote(todo.docPath)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

}

private struct JobRow: View {
    @ObservedObject var job: AgentJob
    var onStop: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AgentBadge(kind: job.kind)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(job.todo.title).font(.callout.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text(job.startedAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("중지", action: onStop).controlSize(.mini)
                }
                Text(job.activity)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

/// 댓글 수 + 클릭하면 스레드 팝오버
private struct ThreadButton: View {
    let todo: Todo
    @ObservedObject var document: NoteDocument
    let vault: Vault
    let runner: AgentRunner
    @State private var isOpen = false

    var body: some View {
        let count = Todo.thread(in: document.text, todoLine: todo.line).count
        Button {
            isOpen = true
        } label: {
            Label("\(count)", systemImage: todo.state == .waiting ? "bubble.left.and.exclamationmark.bubble.right.fill" : "bubble.left")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(todo.state == .waiting ? Color.purple : .secondary)
        }
        .buttonStyle(.plain)
        .opacity(count == 0 && todo.agent == nil ? 0.4 : 1)
        .help("댓글")
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            ThreadView(document: document, runner: runner, vault: vault, todoBody: todo.body)
        }
    }
}
