import AppKit

/// 실행 중인 에이전트 프로세스 하나. 출력(JSON 줄)을 읽어 지금 하는 일을 갱신함
@MainActor
final class AgentJob: ObservableObject {
    let kind: AgentKind
    let todo: Todo
    let logURL: URL
    /// 이 작업을 실행한 폴더
    let workdir: URL
    /// 대댓글로 이어서 실행 중인지
    let isResume: Bool
    let startedAt = Date()

    @Published private(set) var activity = "시작하는 중…"

    fileprivate let process = Process()
    fileprivate var stopRequested = false
    private var log: FileHandle?
    private var buffer = Data()
    private var streamedText = ""
    private var finalText: String?
    /// JSON이 아닌 출력(셸 오류 등)의 마지막 줄. 실패 이유로 보여줌
    private var lastRawLine: String?
    private var reportedSuccess: Bool?
    private var exitCode: Int32?
    private var outputClosed = false
    /// 이어서 대화할 때 쓸 세션 ID (claude session_id, codex thread_id, grok sessionId)
    fileprivate(set) var sessionID: String?
    /// 승인이 없어 막힌 도구 규칙들 (예: `Bash(npm install)`)
    fileprivate(set) var deniedRules: [String] = []
    fileprivate var onFinish: ((AgentJob, Bool, String) -> Void)?

    init(kind: AgentKind, todo: Todo, logURL: URL, workdir: URL, isResume: Bool) {
        self.kind = kind
        self.todo = todo
        self.logURL = logURL
        self.workdir = workdir
        self.isResume = isResume
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        log = try? FileHandle(forWritingTo: logURL)
    }

    fileprivate func consume(_ data: Data) {
        if data.isEmpty {
            outputClosed = true
            if !buffer.isEmpty { handle(line: String(decoding: buffer, as: UTF8.self)) }
            finishIfDone()
            return
        }
        log?.write(data)
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            handle(line: line)
        }
    }

    fileprivate func processExited(_ code: Int32) {
        exitCode = code
        finishIfDone()
    }

    private func finishIfDone() {
        guard outputClosed, let exitCode else { return }
        try? log?.close()
        log = nil
        let succeeded = !stopRequested && exitCode == 0 && reportedSuccess != false
        let summary = stopRequested ? "중지됨" : (finalText ?? (streamedText.isEmpty ? lastRawLine ?? "" : streamedText))
        onFinish?(self, succeeded, summary)
        onFinish = nil
    }

    // MARK: CLI별 출력 해석 (2026-10 기준 각 CLI의 실제 출력 형식에 맞춤)

    private func handle(line: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String
        else {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lastRawLine = trimmed }
            // grok: "permission required: Edit `경로` was not run, as a headless run cannot ask for approval"
            if trimmed.hasPrefix("permission required: "),
               let tool = trimmed.dropFirst("permission required: ".count).split(separator: " ").first {
                let rule = String(tool)
                if !deniedRules.contains(rule) { deniedRules.append(rule) }
            }
            return
        }
        for key in ["session_id", "thread_id", "sessionId"] {
            if let id = object[key] as? String, !id.isEmpty { sessionID = id }
        }

        switch kind {
        case .claude:
            if type == "assistant",
               let content = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] {
                for block in content {
                    if let name = block["name"] as? String {
                        activity = "🔧 \(name)"
                    } else if let text = block["text"] as? String {
                        finalText = text
                        activity = text
                    }
                }
            } else if type == "result" {
                reportedSuccess = (object["is_error"] as? Bool) == false
                if let result = object["result"] as? String { finalText = result }
                // acceptEdits 모드에서 승인 없이 막힌 도구들 → 대댓글로 허용받을 규칙
                for denial in object["permission_denials"] as? [[String: Any]] ?? [] {
                    guard let tool = denial["tool_name"] as? String else { continue }
                    let input = denial["tool_input"] as? [String: Any]
                    let rule = if tool == "Bash", let command = input?["command"] as? String {
                        "Bash(\(command))"
                    } else {
                        tool
                    }
                    if !deniedRules.contains(rule) { deniedRules.append(rule) }
                }
            }

        case .codex:
            let item = object["item"] as? [String: Any]
            switch (type, item?["type"] as? String) {
            case (_, "command_execution"):
                if let command = item?["command"] as? String { activity = "$ \(command)" }
            case (_, "file_change"):
                activity = "✏️ 파일 수정"
            case ("item.completed", "agent_message"):
                if let text = item?["text"] as? String {
                    finalText = text
                    activity = text
                }
            case ("turn.completed", _):
                reportedSuccess = true
            case ("turn.failed", _), ("error", _):
                reportedSuccess = false
            default:
                break
            }

        case .grok:
            switch type {
            case "text":
                streamedText += object["data"] as? String ?? ""
                activity = streamedText
            case "tool_call":
                // 도구 호출 전의 말은 중간 설명이라 버리고, 마지막 덩어리만 요약으로 씀
                streamedText = ""
                activity = "🔧 \(object["toolName"] as? String ?? object["title"] as? String ?? "도구")"
            case "end":
                reportedSuccess = (object["stopReason"] as? String) == "end_turn"
            default:
                break
            }
        }
    }
}

/// 켜져 있는 동안 태그 달린 todo를 하나씩 집어 해당 에이전트에게 맡김 (에이전트당 동시에 하나)
@MainActor
final class AgentRunner: ObservableObject {
    @Published var isEnabled = UserDefaults.standard.bool(forKey: "runnerEnabled") {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "runnerEnabled")
            if isEnabled { tick() }
        }
    }
    @Published private(set) var jobs: [AgentKind: AgentJob] = [:]
    /// 작업 하나가 끝났을 때 결과 상태 (로고 애니메이션용)
    var onJobFinished: ((AgentKind, TodoState) -> Void)?

    private weak var library: NoteLibrary?
    private var timer: Timer?
    private var sleepActivity: NSObjectProtocol?

    /// todo가 지금 모양 그대로 처음 보인 시각. 외부 편집기에서 쓰는 중인 줄을 거르기 위함
    private var firstSeen: [String: Date] = [:]
    private static let settleDelay: TimeInterval = 2

    /// enabledOverride: 테스트용 실행 인자(--autorun). 이때는 켜짐 상태를 저장하지 않음
    init(library: NoteLibrary, enabledOverride: Bool? = nil) {
        self.library = library
        if let enabledOverride { isEnabled = enabledOverride }
        resetOrphanedTodos()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func shutdown() {
        timer?.invalidate()
        for job in jobs.values {
            job.onFinish = nil
            job.process.terminate()
            library?.setState(of: job.todo, to: .open)
        }
        jobs.removeAll()
        updateSleepAssertion()
    }

    func stop(_ kind: AgentKind) {
        guard let job = jobs[kind] else { return }
        job.stopRequested = true
        job.process.terminate()
    }

    /// 앱이 작업 도중 꺼졌으면 `[/]`로 남은 줄이 있음 → 다시 대기 상태로
    private func resetOrphanedTodos() {
        guard let library else { return }
        for todo in library.todos where todo.state == .doing && todo.agent != nil {
            library.setState(of: todo, to: .open)
        }
    }

    private func tick() {
        guard isEnabled, let library else { return }
        let now = Date()
        var seen: [String: Date] = [:]
        for todo in library.todos where todo.state == .open && todo.agent != nil {
            let key = "\(todo.docPath)\u{0}\(todo.body)"
            seen[key] = firstSeen[key] ?? now
        }
        firstSeen = seen

        func isReady(_ todo: Todo) -> Bool {
            // 커서가 그 줄에 있으면 아직 쓰는 중. 엔터를 치거나 다른 곳을 누르면 대상이 됨
            if library.documents[todo.docPath]?.editingLine == todo.line { return false }
            let key = "\(todo.docPath)\u{0}\(todo.body)"
            return now.timeIntervalSince(seen[key] ?? now) >= Self.settleDelay
        }

        for kind in AgentKind.allCases where jobs[kind] == nil {
            if let todo = library.todos.first(where: { $0.state == .open && $0.agent == kind && isReady($0) }) {
                start(todo, with: kind, in: library)
            }
        }
    }

    private func start(_ todo: Todo, with kind: AgentKind, in library: NoteLibrary) {
        guard let document = library.documents[todo.docPath] else { return }

        let thread = library.thread(of: todo)
        // todo 줄이나 그 위 제목에 적힌 경로에서 작업. 없으면 기본 작업 폴더
        let line = Todo.lineIndex(in: document.text, body: todo.body) ?? todo.line
        let workdir = PathMentions.workdir(forTodoAt: line, in: document.text) ?? library.root
        guard let (arguments, isResume) = Self.command(for: todo, kind: kind, thread: thread, document: document, workdir: workdir, library: library),
              !arguments.isEmpty
        else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let logURL = AppPaths.logs.appendingPathComponent("\(stamp)-\(kind.rawValue).jsonl")
        let job = AgentJob(kind: kind, todo: todo, logURL: logURL, workdir: workdir, isResume: isResume)

        // 앱을 Finder에서 띄우면 PATH가 짧아서, 로그인 셸을 거쳐 사용자 PATH로 실행함
        let process = job.process
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$0\" \"$@\""] + arguments
        process.currentDirectoryURL = workdir
        process.standardInput = FileHandle.nullDevice

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { job.consume(data) }
            }
        }
        process.terminationHandler = { process in
            let code = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated { job.processExited(code) }
            }
        }
        job.onFinish = { [weak self] job, succeeded, summary in
            self?.finish(job, succeeded: succeeded, summary: summary)
        }

        do {
            try process.run()
        } catch {
            library.setState(of: todo, to: .failed, comment: (kind.rawValue, "실행 실패: \(error.localizedDescription)", nil))
            return
        }
        library.setState(of: todo, to: .doing)
        jobs[kind] = job
        updateSleepAssertion()
    }

    /// 첫 실행인지, 대댓글에 답하는 이어가기인지 정해서 실행 인자를 만듦
    private static func command(for todo: Todo, kind: AgentKind, thread: [Comment], document: NoteDocument, workdir: URL, library: NoteLibrary) -> ([String], Bool)? {
        let config = AgentConfig.load()
        func fill(_ template: [String], prompt: String, session: String = "") -> [String] {
            template.map {
                $0.replacingOccurrences(of: "{prompt}", with: prompt).replacingOccurrences(of: "{session}", with: session)
            }
        }

        // 마지막 에이전트 댓글 뒤의 사용자 답글들
        let lastAgentIndex = thread.lastIndex { $0.agent == kind }
        let replies = Array(thread.suffix(from: lastAgentIndex.map { $0 + 1 } ?? thread.startIndex).filter(\.isUser))
        let lastAgent = lastAgentIndex.map { thread[$0] }
        let answer = replies.map(\.text).joined(separator: "\n")
        let grant = permissionGrant(replies: replies, request: lastAgent, answer: answer)
        let extra = grant.map { approvalArguments(for: kind, grant: $0, config: config) } ?? []

        // 세션이 있으면 같은 세션으로 이어감
        if lastAgent != nil, !replies.isEmpty,
           let session = lastAgent?.meta?.session,
           let template = config.resume[kind.rawValue], !template.isEmpty {
            let prompt: String
            switch grant {
            case .all:
                prompt = """
                사용자가 이번 작업에 필요한 권한을 모두 허용했다. 사용자 말: \(answer)
                막혔던 작업을 이어서 끝까지 진행하고, 끝나면 한두 문장의 한국어 요약을 마지막 메시지로 남겨라.
                """
            case .rules(let rules):
                prompt = """
                사용자가 다음 권한만 허용했다: \(rules.joined(separator: ", "))
                사용자 말: \(answer)
                허용된 범위에서 막혔던 작업을 이어서 진행하고, 끝나면 한두 문장의 한국어 요약을 마지막 메시지로 남겨라.
                """
            case nil where lastAgent?.meta?.kind == "permission":
                prompt = """
                사용자가 권한을 허용하지 않았다. 사용자 말: \(answer)
                그 작업 없이 할 수 있는 만큼만 진행하고, 끝나면 한두 문장의 한국어 요약을 마지막 메시지로 남겨라.
                """
            case nil:
                prompt = """
                사용자가 네 댓글에 답했다: \(answer)
                이 답을 반영해 이어서 진행하고, 끝나면 한두 문장의 한국어 요약을 마지막 메시지로 남겨라.
                또 사용자 결정이 꼭 필요하면 마지막 메시지를 "질문:"으로 시작해 질문만 하고 멈춰라.
                """
            }
            return (fill(template, prompt: prompt, session: session) + extra, true)
        }

        // 세션이 없으면(예전 댓글 등) 댓글 기록을 프롬프트에 넣어 새로 실행. 허용한 권한은 그대로 적용
        guard let template = config.agents[kind.rawValue], !template.isEmpty else { return nil }
        return (fill(template, prompt: prompt(for: todo, document: document, thread: thread, workdir: workdir, library: library)) + extra, false)
    }

    enum PermissionGrant {
        /// 이번 작업만 모두 허용
        case all
        /// 고른 규칙만 허용
        case rules([String])
    }

    /// 사용자 답글에서 허용 범위를 읽음: 버튼으로 남긴 meta가 우선, 없으면 "허용" 같은 말로 판단
    private static func permissionGrant(replies: [Comment], request: Comment?, answer: String) -> PermissionGrant? {
        if let meta = replies.last(where: { $0.meta?.kind != nil })?.meta {
            switch meta.kind {
            case "approveAll": return .all
            case "approval": return (meta.allow ?? []).isEmpty ? nil : .rules(meta.allow ?? [])
            default: return nil
            }
        }
        guard request?.meta?.kind == "permission", isApproval(answer) else { return nil }
        let rules = request?.meta?.allow ?? []
        return rules.isEmpty ? .all : .rules(rules)
    }

    private static func approvalArguments(for kind: AgentKind, grant: PermissionGrant, config: AgentConfig) -> [String] {
        switch grant {
        case .all:
            return config.approveAll[kind.rawValue] ?? []
        case .rules(let rules):
            let approve = config.approve[kind.rawValue] ?? []
            // `{rule}`이 있는 템플릿은 규칙마다 반복, 없으면 한 번만
            guard approve.contains(where: { $0.contains("{rule}") }) else { return approve }
            return rules.flatMap { rule in approve.map { $0.replacingOccurrences(of: "{rule}", with: rule) } }
        }
    }

    /// "허용", "✅", "ok", "yes" 등은 허용. "거부", "❌", "안 돼"가 들어 있으면 거부
    static func isApproval(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["거부", "❌", "안돼", "안 돼", "하지 마", "no"].contains(where: lower.contains) { return false }
        return ["허용", "✅", "승인", "ok", "yes", "ㅇㅇ", "응", "좋아"].contains(where: lower.contains)
    }

    private func finish(_ job: AgentJob, succeeded: Bool, summary: String) {
        jobs[job.kind] = nil
        updateSleepAssertion()
        guard let library else { return }

        let text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        var meta = CommentMeta(session: job.sessionID)
        let state: TodoState
        let comment: String

        if job.stopRequested {
            state = .failed
            comment = "중지됨"
        } else if !job.deniedRules.isEmpty {
            // 권한이 없어 막힘 → 대댓글로 허용을 받으면 같은 세션으로 이어감
            state = .waiting
            meta.kind = "permission"
            meta.allow = job.deniedRules
            comment = "🔐 권한이 필요해요: \(job.deniedRules.joined(separator: ", ")) — 허용하면 이어서 진행합니다." + (text.isEmpty ? "" : " (\(text))")
        } else if let need = Self.prefixed(text, by: ["권한:", "PERMISSION:"]) {
            // 도구 거부로 잡히지 않았지만 에이전트가 직접 권한이 필요하다고 한 경우
            state = .waiting
            meta.kind = "permission"
            comment = "🔐 \(need)"
        } else if let question = Self.question(in: text) {
            state = .waiting
            meta.kind = "question"
            comment = "❓ \(question)"
        } else if succeeded {
            state = .done
            comment = text.isEmpty ? "완료" : text
        } else {
            state = .failed
            comment = "실패 — \(text.isEmpty ? "출력 없음" : text) (로그: \((job.logURL.path as NSString).abbreviatingWithTildeInPath))"
        }

        library.setState(of: job.todo, to: state, comment: (job.kind.rawValue, comment, meta))
        onJobFinished?(job.kind, state)
        tick()
    }

    /// 마지막 메시지가 "질문:"/"QUESTION:"으로 시작하면 사용자에게 묻는 것
    private static func question(in text: String) -> String? {
        prefixed(text, by: ["질문:", "QUESTION:", "Question:"])
    }

    private static func prefixed(_ text: String, by prefixes: [String]) -> String? {
        for prefix in prefixes where text.hasPrefix(prefix) {
            return text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// 에이전트가 일하는 동안에는 잠자기 방지 (화면은 꺼져도 됨)
    private func updateSleepAssertion() {
        if jobs.isEmpty, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        } else if !jobs.isEmpty, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Twinkle 에이전트 작업 중"
            )
        }
    }

    private static func prompt(for todo: Todo, document: NoteDocument, thread: [Comment], workdir: URL, library: NoteLibrary) -> String {
        let history = thread.isEmpty ? "" : """

        이 할 일에 달린 이전 댓글:
        \(thread.map { "- \($0.author): \($0.text)" }.joined(separator: "\n"))

        """
        return """
        Twinkle 메모 앱이 너에게 할 일 하나를 맡겼다.

        할 일: \(todo.title)
        출처 메모: \(document.relativePath) (메모 폴더: \(library.root.path))
        \(history)
        참고용 메모 전체 내용:
        <memo>
        \(document.text)
        </memo>

        현재 작업 폴더(\(workdir.path))에서 이 할 일을 끝까지 수행해라.
        메모 파일의 체크박스와 댓글 줄(↳)은 앱이 관리하므로 직접 고치지 마라.
        사용자 결정이 꼭 필요하면 마지막 메시지를 "질문:"으로 시작해 질문만 하고 멈춰라. 사용자가 댓글로 답하면 이어서 진행하게 된다.
        권한이 없어 못 한 작업이 있으면 우회하지 말고, 마지막 메시지를 "권한:"으로 시작해 무엇이 왜 필요한지 적고 멈춰라. 사용자가 허용하면 이어서 진행하게 된다.
        끝나면 무엇을 했는지 한두 문장의 한국어 요약을 마지막 메시지로 남겨라.
        """
    }
}
