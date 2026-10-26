import AppKit
import SwiftUI

/// todo 하나에 달린 댓글 스레드 전체 + 대댓글 입력. 권한 요청이면 허용/거부 버튼
struct ThreadView: View {
    @ObservedObject var document: NoteDocument
    @ObservedObject var runner: AgentRunner
    let library: NoteLibrary
    /// todo 원문. 줄 번호는 편집으로 밀릴 수 있어서 원문으로 다시 찾음
    let body_: String
    /// 댓글 속 메모(.md) 링크를 누르면 Twinkle에서 열기
    var onOpenNote: (String) -> Void = { _ in }

    @State private var draft = ""
    @FocusState private var focused: Bool

    init(document: NoteDocument, runner: AgentRunner, library: NoteLibrary, todoBody: String) {
        self.document = document
        self.runner = runner
        self.library = library
        body_ = todoBody
    }

    private var todo: Todo? {
        guard let line = Todo.lineIndex(in: document.text, body: body_) else { return nil }
        return Todo.parse(document.text, docPath: document.relativePath).first { $0.line == line }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let todo {
                header(todo)
                Divider()
                comments(todo)
                let job = runner.jobs.values.first { $0.todo.docPath == todo.docPath && $0.todo.body == todo.body }
                if job == nil, let request = pendingPermission(todo) {
                    PermissionPanel(rules: request) { meta, text in
                        library.reply(to: todo, text: text, meta: meta)
                    }
                }
                if let job {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("\(job.kind.displayName)가 \(job.isResume ? "답하는" : "작업하는") 중…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                replyField(todo)
            } else {
                Text("이 할 일을 찾을 수 없어요 (지워졌거나 내용이 바뀜)")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 380)
        .environment(\.openURL, OpenURLAction { url in
            if let name = NoteLink.noteName(for: url) {
                onOpenNote(name)
                return .handled
            }
            return .systemAction
        })
        .onAppear { focused = true }
    }

    private func header(_ todo: Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: TodoRowIcon.name(for: todo.state))
                .foregroundStyle(Color(nsColor: MarkdownStyler.color(for: todo.state)))
            if let agent = todo.agent {
                AgentBadge(kind: agent, size: 16)
            }
            Text(MarkdownPlain.text(todo.title))
                .font(.system(size: 13, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func comments(_ todo: Todo) -> some View {
        let thread = Todo.thread(in: document.text, todoLine: todo.line)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(thread) { comment in
                        CommentBubble(comment: comment)
                            .id(comment.id)
                    }
                    if thread.isEmpty {
                        Text("아직 댓글이 없어요").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            .onAppear { proxy.scrollTo(thread.last?.id, anchor: .bottom) }
            .onChange(of: thread.count) { _, _ in
                withAnimation { proxy.scrollTo(thread.last?.id, anchor: .bottom) }
            }
        }
    }

    /// 마지막 에이전트 댓글이 권한 요청이고 아직 답하지 않았으면 그 규칙들
    private func pendingPermission(_ todo: Todo) -> [String]? {
        let thread = Todo.thread(in: document.text, todoLine: todo.line)
        guard todo.state == .waiting, let last = thread.last, !last.isUser, last.meta?.kind == "permission" else { return nil }
        return last.meta?.allow ?? []
    }

    private func replyField(_ todo: Todo) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(todo.agent == nil ? "댓글 달기…" : "\(todo.agent!.displayName)에게 답글…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { send(todo) }
            Button("보내기") { send(todo) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func send(_ todo: Todo) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        library.reply(to: todo, text: text)
        draft = ""
    }
}

private struct CommentBubble: View {
    let comment: Comment

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let agent = comment.agent {
                AgentBadge(kind: agent, size: 22)
            } else {
                Text(String(comment.author.prefix(1)))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.accentColor))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(comment.agent?.displayName ?? comment.author)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(CommentText.attributed(comment.text))
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(comment.isUser ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.1))
                    )
            }
        }
    }
}

enum TodoRowIcon {
    static func name(for state: TodoState) -> String {
        switch state {
        case .open: "square"
        case .doing: "circle.dotted"
        case .done: "checkmark.square.fill"
        case .failed: "exclamationmark.square"
        case .waiting: "questionmark.square.fill"
        }
    }
}

/// 권한 요청: 막힌 항목마다 체크박스, 고른 것만 허용 / 이번 작업만 모두 허용 / 거부
struct PermissionPanel: View {
    let rules: [String]
    var onReply: (CommentMeta, String) -> Void
    @State private var selected: Set<String>

    init(rules: [String], onReply: @escaping (CommentMeta, String) -> Void) {
        self.rules = rules
        self.onReply = onReply
        _selected = State(initialValue: Set(rules))
    }

    private func approveAll() {
        onReply(CommentMeta(kind: "approveAll"), "✅ 이번 작업만 모든 권한 허용")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("권한이 필요해요", systemImage: "lock.shield")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.purple)
            ForEach(rules, id: \.self) { rule in
                Toggle(isOn: Binding(
                    get: { selected.contains(rule) },
                    set: { if $0 { selected.insert(rule) } else { selected.remove(rule) } }
                )) {
                    Text(rule)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .toggleStyle(.checkbox)
            }
            HStack(spacing: 6) {
                if !rules.isEmpty {
                    Button {
                        let chosen = rules.filter(selected.contains)
                        onReply(CommentMeta(kind: "approval", allow: chosen), "✅ 허용: \(chosen.joined(separator: ", "))")
                    } label: {
                        Label(selected.count == rules.count ? "허용" : "선택한 \(selected.count)개 허용", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty)
                }
                if rules.isEmpty {
                    Button("허용하고 계속", action: approveAll).buttonStyle(.borderedProminent)
                } else {
                    Button("이번 작업만 모두 허용", action: approveAll)
                }
                Button("거부") {
                    onReply(CommentMeta(kind: "deny"), "❌ 거부")
                }
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.purple.opacity(0.07)))
    }
}

