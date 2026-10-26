import AppKit

/// `.widgent/config.json` — 사용자가 직접 고칠 수 있는 프로젝트 설정.
/// 파일에 없는 항목만 기본값으로 채우고, 사용자가 고친 값은 그대로 둠
struct VaultConfig: Codable {
    /// 에이전트가 작업할 폴더. 비어 있으면 프로젝트 폴더 자체
    var workdir = ""
    /// 에이전트별 첫 실행 명령. `{prompt}` 자리에 할 일 프롬프트가 들어감
    var agents: [String: [String]] = [
        "claude": ["claude", "-p", "{prompt}", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits"],
        "codex": ["codex", "exec", "--json", "-s", "workspace-write", "--skip-git-repo-check", "{prompt}"],
        // grok은 headless에서 acceptEdits로는 파일 수정이 거부되어 bypassPermissions가 필요함
        "grok": ["grok", "-p", "{prompt}", "--output-format", "streaming-json", "--permission-mode", "bypassPermissions"],
    ]
    /// 대댓글로 같은 세션을 이어갈 때. `{session}` 자리에 세션 ID
    var resume: [String: [String]] = [
        "claude": ["claude", "-p", "{prompt}", "--resume", "{session}", "--output-format", "stream-json", "--verbose", "--permission-mode", "acceptEdits"],
        // codex exec resume는 -s를 받지 않아 설정 덮어쓰기로 샌드박스를 지정
        "codex": ["codex", "exec", "resume", "{session}", "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"workspace-write\"", "{prompt}"],
        "grok": ["grok", "-p", "{prompt}", "-r", "{session}", "--output-format", "streaming-json", "--permission-mode", "bypassPermissions"],
    ]
    /// 대댓글에서 권한을 허용했을 때 이어가기 명령 뒤에 붙일 인자. `{rule}`이 있으면 규칙마다 반복
    var approve: [String: [String]] = [
        "claude": ["--allowedTools", "{rule}"],
        "codex": ["-c", "sandbox_mode=\"danger-full-access\""],
        "grok": ["--always-approve"],
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let defaults = VaultConfig()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workdir = try container.decodeIfPresent(String.self, forKey: .workdir) ?? defaults.workdir
        agents = defaults.agents.merging(try container.decodeIfPresent([String: [String]].self, forKey: .agents) ?? [:]) { $1 }
        resume = defaults.resume.merging(try container.decodeIfPresent([String: [String]].self, forKey: .resume) ?? [:]) { $1 }
        approve = defaults.approve.merging(try container.decodeIfPresent([String: [String]].self, forKey: .approve) ?? [:]) { $1 }
    }
}

enum NoteColor: String, Codable, CaseIterable {
    case yellow, pink, blue, green, purple, gray

    var label: String {
        switch self {
        case .yellow: "노랑"
        case .pink: "분홍"
        case .blue: "파랑"
        case .green: "초록"
        case .purple: "보라"
        case .gray: "회색"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .yellow: NSColor(red: 1.00, green: 0.95, blue: 0.62, alpha: 1)
        case .pink: NSColor(red: 1.00, green: 0.82, blue: 0.86, alpha: 1)
        case .blue: NSColor(red: 0.78, green: 0.89, blue: 1.00, alpha: 1)
        case .green: NSColor(red: 0.80, green: 0.95, blue: 0.78, alpha: 1)
        case .purple: NSColor(red: 0.88, green: 0.83, blue: 1.00, alpha: 1)
        case .gray: NSColor(red: 0.90, green: 0.90, blue: 0.90, alpha: 1)
        }
    }
}

/// desktop: 바탕화면에 붙어 있음 (다른 창 아래, 모든 Space에 고정)
/// floating: 항상 다른 창 위에 떠 있음
enum NoteLevel: String, Codable {
    case desktop, floating
}

struct WindowState: Codable {
    var frame: CGRect
    var color: NoteColor = .yellow
    var level: NoteLevel = .desktop
}

/// `.widgent/windows.json` — 어떤 메모가 어디에 어떤 모양으로 열려 있는지
struct WindowLayout: Codable {
    var open: [String] = []
    var states: [String: WindowState] = [:]
}

/// md 파일 하나. 편집기와 에이전트 실행기 모두 이 객체를 통해서만 내용을 바꿈
@MainActor
final class NoteDocument: ObservableObject {
    let relativePath: String
    let url: URL
    weak var vault: Vault?

    @Published var text: String {
        didSet {
            guard text != oldValue else { return }
            if text != savedText { scheduleSave() }
            vault?.documentDidChange()
        }
    }

    /// 편집기 커서가 있는 줄 (편집기에 포커스가 없으면 nil). 작성 중인 todo를 에이전트가 가져가지 않게 함
    var editingLine: Int?

    private var savedText: String
    private(set) var diskModified: Date?
    private var pendingSave: DispatchWorkItem?

    var name: String { url.deletingPathExtension().lastPathComponent }
    var isDirty: Bool { text != savedText }

    init(relativePath: String, url: URL) {
        self.relativePath = relativePath
        self.url = url
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text = content
        savedText = content
        diskModified = Self.modificationDate(of: url)
    }

    /// 다른 프로그램(옵시디언, 에이전트 등)이 파일을 바꿨을 때. 편집 중인 내용이 있으면 우리 것을 유지
    func reloadFromDisk() {
        diskModified = Self.modificationDate(of: url)
        guard !isDirty, let content = try? String(contentsOf: url, encoding: .utf8) else { return }
        savedText = content
        text = content
    }

    func save() {
        pendingSave?.cancel()
        pendingSave = nil
        guard isDirty else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            diskModified = Self.modificationDate(of: url)
        } catch {
            NSLog("Widgent: \(relativePath) 저장 실패: \(error)")
        }
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

/// 프로젝트 폴더 하나 = vault. 안의 md 파일을 모두 들고 있고 todo 색인을 유지함
@MainActor
final class Vault: ObservableObject {
    let root: URL
    private(set) var config = VaultConfig()
    @Published private(set) var documents: [String: NoteDocument] = [:]
    @Published private(set) var todos: [Todo] = []

    private var scanTimer: Timer?
    private var todosDirty = false

    var metaDirectory: URL { root.appendingPathComponent(".widgent", isDirectory: true) }
    var configURL: URL { metaDirectory.appendingPathComponent("config.json") }
    var logsDirectory: URL { metaDirectory.appendingPathComponent("logs", isDirectory: true) }
    private var layoutURL: URL { metaDirectory.appendingPathComponent("windows.json") }

    var workdir: URL {
        config.workdir.isEmpty ? root : URL(fileURLWithPath: (config.workdir as NSString).expandingTildeInPath)
    }

    static let mainNotePath = "Main.md"

    init(root: URL) {
        self.root = root.standardizedFileURL
        let fm = FileManager.default
        try? fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        loadConfig()

        let mainURL = self.root.appendingPathComponent(Self.mainNotePath)
        if !fm.fileExists(atPath: mainURL.path) {
            try? Self.welcomeText.write(to: mainURL, atomically: true, encoding: .utf8)
        }

        scan()
        // FSEvents 대신 단순 폴링. 메모 몇백 개 수준이면 충분히 가벼움
        scanTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.scan() }
        }
    }

    func close() {
        scanTimer?.invalidate()
        documents.values.forEach { $0.save() }
    }

    // MARK: 파일

    func scan() {
        var found: [String: URL] = [:]
        let keys: [URLResourceKey] = [.isRegularFileKey]
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
                let standardized = url.standardizedFileURL
                found[relativePath(of: standardized)] = standardized
            }
        }

        var changed = false
        for (path, url) in found {
            if let doc = documents[path] {
                if NoteDocument.modificationDate(of: url) != doc.diskModified {
                    doc.reloadFromDisk()
                }
            } else {
                let doc = NoteDocument(relativePath: path, url: url)
                doc.vault = self
                documents[path] = doc
                changed = true
            }
        }
        for path in documents.keys where found[path] == nil && !(documents[path]?.isDirty ?? false) {
            documents[path] = nil
            changed = true
        }
        if changed || todosDirty { rebuildTodos() }
    }

    func documentDidChange() {
        // 타이핑할 때마다 전체 색인을 다시 만들지 않도록 한 틱 미룸
        guard !todosDirty else { return }
        todosDirty = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.rebuildTodos() }
        }
    }

    private func rebuildTodos() {
        todosDirty = false
        todos = documents.values
            .sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
            .flatMap { Todo.parse($0.text, docPath: $0.relativePath) }
    }

    private func relativePath(of url: URL) -> String {
        String(url.path.dropFirst(root.path.count).drop(while: { $0 == "/" }))
    }

    /// `[[이름]]` → 문서. 옵시디언처럼 파일 이름(확장자 제외)이나 상대 경로로 찾음
    func resolve(link: String) -> NoteDocument? {
        let target = link.split(separator: "|").first.map(String.init) ?? link
        let key = target.trimmingCharacters(in: .whitespaces).lowercased()
        return documents.values.first { doc in
            doc.name.lowercased() == key
                || doc.relativePath.lowercased() == key
                || doc.relativePath.lowercased() == key + ".md"
        }
    }

    /// 없는 이름이면 프로젝트 폴더 바로 아래에 새 md를 만듦
    func documentForLink(_ link: String) -> NoteDocument? {
        if let doc = resolve(link: link) { return doc }
        let name = (link.split(separator: "|").first.map(String.init) ?? link)
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "/", with: "-")
        guard !name.isEmpty else { return nil }
        return createNote(named: name)
    }

    func createUntitledNote() -> NoteDocument {
        var index = 1
        var name = "새 메모"
        while documents["\(name).md"] != nil || FileManager.default.fileExists(atPath: root.appendingPathComponent("\(name).md").path) {
            index += 1
            name = "새 메모 \(index)"
        }
        return createNote(named: name)
    }

    private func createNote(named name: String) -> NoteDocument {
        let url = root.appendingPathComponent("\(name).md").standardizedFileURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "# \(name)\n\n".write(to: url, atomically: true, encoding: .utf8)
        }
        scan()
        return documents[relativePath(of: url)]!
    }

    // MARK: todo 수정 (에이전트 실행기와 todo 패널이 사용)

    @discardableResult
    func setState(of todo: Todo, to state: TodoState?, comment: (author: String, text: String, meta: CommentMeta?)? = nil) -> Bool {
        guard let doc = documents[todo.docPath],
              let updated = Todo.updating(doc.text, body: todo.body, to: state, comment: comment)
        else { return false }
        doc.text = updated
        doc.save()
        return true
    }

    /// 지금 문서 기준으로 todo를 다시 찾음 (줄이 밀렸을 수 있어서)
    func current(_ todo: Todo) -> Todo? {
        guard let doc = documents[todo.docPath], let line = Todo.lineIndex(in: doc.text, body: todo.body) else { return nil }
        return Todo.parse(doc.text, docPath: todo.docPath).first { $0.line == line }
    }

    func thread(of todo: Todo) -> [Comment] {
        guard let doc = documents[todo.docPath], let line = Todo.lineIndex(in: doc.text, body: todo.body) else { return [] }
        return Todo.thread(in: doc.text, todoLine: line)
    }

    /// 사용자의 대댓글. 에이전트 todo면 다시 대기 상태로 돌려서 실행기가 같은 세션으로 이어감
    func reply(to todo: Todo, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setState(of: todo, to: todo.agent != nil ? .open : nil, comment: (Comment.userAuthor, trimmed, nil))
    }

    // MARK: 설정, 창 배치

    private func loadConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? Data(contentsOf: configURL) else {
            try? encoder.encode(config).write(to: configURL, options: .atomic)
            return
        }
        do {
            config = try JSONDecoder().decode(VaultConfig.self, from: data)
            // 새 버전에서 생긴 항목이 파일에 없으면 채워서 보여줌 (사용자 값은 유지)
            if let merged = try? encoder.encode(config),
               let old = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let new = try? JSONSerialization.jsonObject(with: merged) as? [String: Any],
               Set(new.keys) != Set(old.keys) {
                try? merged.write(to: configURL, options: .atomic)
            }
        } catch {
            // 사용자가 고치다 JSON이 깨졌으면 파일은 건드리지 않고 기본값으로 동작
            NSLog("Widgent: config.json 읽기 실패, 기본값 사용: \(error)")
        }
    }

    func reloadConfig() { loadConfig() }

    func loadLayout() -> WindowLayout {
        guard let data = try? Data(contentsOf: layoutURL) else { return WindowLayout() }
        return (try? JSONDecoder().decode(WindowLayout.self, from: data)) ?? WindowLayout()
    }

    func saveLayout(_ layout: WindowLayout) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(layout).write(to: layoutURL, options: .atomic)
    }

    private static let welcomeText = """
    # Main

    Widgent 메인 메모입니다. 일반 마크다운으로 쓰면 됩니다.

    ## 할 일
    - [ ] 체크박스를 클릭하면 완료로 바뀝니다
    - [ ] 태그를 붙인 할 일은 에이전트가 가져갑니다 (메뉴 막대 → 에이전트 자동 실행 켜기)
    - [ ] @claude 예시: README.md에 이 프로젝트 소개를 한 문단 써줘

    ## 링크
    [[아이디어]] 처럼 쓰면 다른 메모로 이동합니다. 없는 메모면 새로 만들어요.

    """
}
