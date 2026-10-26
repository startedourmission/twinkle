import AppKit

/// 실행 중인 에이전트 프로세스 하나. 출력(JSON 줄)을 읽어 지금 하는 일을 갱신함
@MainActor
final class AgentJob: ObservableObject {
    let kind: AgentKind
    let todo: Todo
    let logURL: URL
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
    fileprivate var onFinish: ((AgentJob, Bool, String) -> Void)?

    init(kind: AgentKind, todo: Todo, logURL: URL) {
        self.kind = kind
        self.todo = todo
        self.logURL = logURL
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
            return
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

    private weak var vault: Vault?
    private var timer: Timer?
    private var sleepActivity: NSObjectProtocol?

    init(vault: Vault) {
        self.vault = vault
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
            vault?.setState(of: job.todo, to: .open)
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
        guard let vault else { return }
        for todo in vault.todos where todo.state == .doing && todo.agent != nil {
            vault.setState(of: todo, to: .open)
        }
    }

    private func tick() {
        guard isEnabled, let vault else { return }
        for kind in AgentKind.allCases where jobs[kind] == nil {
            if let todo = vault.todos.first(where: { $0.state == .open && $0.agent == kind }) {
                start(todo, with: kind, in: vault)
            }
        }
    }

    private func start(_ todo: Todo, with kind: AgentKind, in vault: Vault) {
        vault.reloadConfig()
        guard let template = vault.config.agents[kind.rawValue], !template.isEmpty,
              let document = vault.documents[todo.docPath]
        else { return }

        let prompt = Self.prompt(for: todo, document: document, vault: vault)
        let arguments = template.map { $0.replacingOccurrences(of: "{prompt}", with: prompt) }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let logURL = vault.logsDirectory.appendingPathComponent("\(stamp)-\(kind.rawValue).jsonl")
        let job = AgentJob(kind: kind, todo: todo, logURL: logURL)

        // 앱을 Finder에서 띄우면 PATH가 짧아서, 로그인 셸을 거쳐 사용자 PATH로 실행함
        let process = job.process
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "exec \"$0\" \"$@\""] + arguments
        process.currentDirectoryURL = vault.workdir
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
            vault.setState(of: todo, to: .failed, resultNote: "\(kind.rawValue) 실행 실패: \(error.localizedDescription)")
            return
        }
        vault.setState(of: todo, to: .doing)
        jobs[kind] = job
        updateSleepAssertion()
    }

    private func finish(_ job: AgentJob, succeeded: Bool, summary: String) {
        jobs[job.kind] = nil
        updateSleepAssertion()
        guard let vault else { return }

        var note = summary
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if note.count > 200 { note = String(note.prefix(200)) + "…" }
        if !succeeded {
            note = "실패 — \(note.isEmpty ? "출력 없음" : note) (로그: .widgent/logs/\(job.logURL.lastPathComponent))"
        }
        vault.setState(of: job.todo, to: succeeded ? .done : .failed, resultNote: "\(job.kind.rawValue): \(note)")
        tick()
    }

    /// 에이전트가 일하는 동안에는 잠자기 방지 (화면은 꺼져도 됨)
    private func updateSleepAssertion() {
        if jobs.isEmpty, let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        } else if !jobs.isEmpty, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "Widgent 에이전트 작업 중"
            )
        }
    }

    private static func prompt(for todo: Todo, document: NoteDocument, vault: Vault) -> String {
        """
        Widgent 메모 앱이 너에게 할 일 하나를 맡겼다.

        할 일: \(todo.title)
        출처 메모: \(document.relativePath) (메모 폴더: \(vault.root.path))

        참고용 메모 전체 내용:
        <memo>
        \(document.text)
        </memo>

        현재 작업 폴더에서 이 할 일을 끝까지 수행해라.
        메모 파일의 체크박스는 앱이 관리하므로 직접 고치지 마라.
        끝나면 무엇을 했는지 한두 문장의 한국어 요약을 마지막 메시지로 남겨라.
        """
    }
}
