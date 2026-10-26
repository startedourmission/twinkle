import AppKit

/// 앱 데이터 위치. 메모 폴더에는 md만 두고 나머지는 전부 여기에
enum AppPaths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Twinkle", isDirectory: true)
        // 예전 이름(Widgent)일 때의 설정·로그를 복사해 옴. 원본은 그대로 둠
        let old = base.appendingPathComponent("Widgent", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: old.path) {
            try? FileManager.default.copyItem(at: old, to: url)
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// 예전 이름(Widgent, com.widgent.app)일 때의 앱 설정을 한 번 가져옴
    static func migrateOldDefaults() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromWidgent") else { return }
        for (key, value) in defaults.persistentDomain(forName: "com.widgent.app") ?? [:] where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
        defaults.set(true, forKey: "migratedFromWidgent")
    }

    static var windows: URL { support.appendingPathComponent("windows.json") }
    /// 사용자가 로고를 바꾸고 싶을 때 <kind>.png를 넣는 곳
    static var logos: URL { support.appendingPathComponent("logos", isDirectory: true) }
    static var logs: URL {
        let url = support.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 예전 버전이 메모 폴더 안 `.widgent`에 두던 창 배치를 한 번 옮겨 옴
    static func migrateLegacyData(from root: URL) {
        let legacy = root.appendingPathComponent(".widgent", isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: windows.path),
           let data = try? Data(contentsOf: legacy.appendingPathComponent("windows.json")),
           let old = try? JSONDecoder().decode(WindowLayout.self, from: data) {
            // 예전엔 메모 폴더 기준 상대 경로였음 → 절대 경로로
            var layout = WindowLayout()
            layout.open = old.open.map { root.appendingPathComponent($0).path }
            layout.states = Dictionary(uniqueKeysWithValues: old.states.map { (root.appendingPathComponent($0.key).path, $0.value) })
            if let encoded = try? JSONEncoder().encode(layout) { try? encoded.write(to: windows, options: .atomic) }
        }
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
    /// 접어 둔 제목들 (예전 파일엔 없을 수 있어 옵셔널)
    var folded: [String]?
}

/// 어떤 메모가 어디에 어떤 모양으로 열려 있는지. 파일에는 절대 경로로, 메모 폴더 안에서는 상대 경로로 다룸
struct WindowLayout: Codable {
    var open: [String] = []
    var states: [String: WindowState] = [:]
}

/// md 파일 하나. 편집기와 에이전트 실행기 모두 이 객체를 통해서만 내용을 바꿈
@MainActor
final class NoteDocument: ObservableObject {
    let relativePath: String
    let url: URL
    weak var library: NoteLibrary?

    @Published var text: String {
        didSet {
            guard text != oldValue else { return }
            if text != savedText { scheduleSave() }
            library?.documentDidChange()
        }
    }

    /// 편집기 커서가 있는 줄 (편집기에 포커스가 없으면 nil). 작성 중인 todo를 에이전트가 가져가지 않게 함
    var editingLine: Int?
    /// 접어 둔 제목들. 키는 MarkdownStyler.headingKey
    @Published var foldedHeadings: Set<String> = []

    func toggleFold(_ key: String) {
        if foldedHeadings.contains(key) { foldedHeadings.remove(key) } else { foldedHeadings.insert(key) }
    }

    private var savedText: String
    private(set) var diskModified: Date?
    private var pendingSave: DispatchWorkItem?

    var name: String { url.deletingPathExtension().lastPathComponent }

    /// 메모 맨 윗줄이 제목 (`# ` 머리는 뗌). 비어 있으면 파일 이름.
    /// 파일 이름은 바꾸지 않음 — 링크·캔버스·실행 중인 에이전트가 경로로 가리키고 있어서
    var title: String {
        guard let first = text.split(separator: "\n", omittingEmptySubsequences: true).first else { return name }
        let stripped = MarkdownPlain.text(first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
        return stripped.isEmpty ? name : stripped
    }

    /// 첫 줄에서 제목 글자가 있는 범위 (새 메모를 열 때 바로 고쳐 쓰도록 선택해 줌)
    var titleRange: NSRange? {
        let string = text as NSString
        let line = string.lineRange(for: NSRange(location: 0, length: 0))
        let content = string.substring(with: line).trimmingCharacters(in: .newlines)
        let head = content.prefix { $0 == "#" || $0 == " " }.utf16.count
        let length = content.utf16.count - head
        return length > 0 ? NSRange(location: line.location + head, length: length) : nil
    }
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
            NSLog("Twinkle: \(relativePath) 저장 실패: \(error)")
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

/// 프로젝트 폴더 하나 = library. 안의 md 파일을 모두 들고 있고 todo 색인을 유지함
@MainActor
final class NoteLibrary: ObservableObject {
    let root: URL
    @Published private(set) var documents: [String: NoteDocument] = [:]
    @Published private(set) var todos: [Todo] = []

    private var scanTimer: Timer?
    private var todosDirty = false

    static let mainNotePath = "Main.md"

    init(root: URL) {
        self.root = root.standardizedFileURL
        let fm = FileManager.default
        AppPaths.migrateLegacyData(from: self.root)

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
            for case let url as URL in enumerator {
                // 메모 폴더 바로 아래와 한 단계 하위 폴더까지만
                if enumerator.level >= 2 { enumerator.skipDescendants() }
                guard url.pathExtension.lowercased() == "md" else { continue }
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
                doc.library = self
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
                || doc.title.lowercased() == key
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

    /// 사용자의 대댓글. 에이전트 todo면 다시 대기 상태로 돌려서 실행기가 같은 세션으로 이어감.
    /// meta로 권한 선택("approval" + 고른 규칙, "approveAll")을 함께 남김
    func reply(to todo: Todo, text: String, meta: CommentMeta? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setState(of: todo, to: todo.agent != nil ? .open : nil, comment: (Comment.userAuthor, trimmed, meta))
    }

    // MARK: 창 배치

    /// 이 메모 폴더에 속한 창 배치만 상대 경로로
    func loadLayout() -> WindowLayout {
        let all = Self.readLayoutFile()
        let prefix = root.path + "/"
        var layout = WindowLayout()
        layout.open = all.open.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        for (path, state) in all.states where path.hasPrefix(prefix) {
            layout.states[String(path.dropFirst(prefix.count))] = state
        }
        return layout
    }

    /// 다른 메모 폴더의 배치는 남겨 두고 이 폴더 것만 바꿈
    func saveLayout(_ layout: WindowLayout) {
        var all = Self.readLayoutFile()
        let prefix = root.path + "/"
        all.open = all.open.filter { !$0.hasPrefix(prefix) } + layout.open.map { prefix + $0 }
        for (path, state) in layout.states { all.states[prefix + path] = state }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? encoder.encode(all).write(to: AppPaths.windows, options: .atomic)
    }

    private static func readLayoutFile() -> WindowLayout {
        guard let data = try? Data(contentsOf: AppPaths.windows) else { return WindowLayout() }
        return (try? JSONDecoder().decode(WindowLayout.self, from: data)) ?? WindowLayout()
    }

    private static let welcomeText = """
    # Main

    Twinkle 메인 메모입니다. 일반 마크다운으로 쓰면 됩니다.

    ## 할 일
    - [ ] 체크박스를 클릭하면 완료로 바뀝니다
    - [ ] 태그를 붙인 할 일은 에이전트가 가져갑니다 (메뉴 막대 → 에이전트 자동 실행 켜기)
    - [ ] @claude 예시: 작업 폴더에 hello.txt를 만들어줘

    ## 작업 폴더
    제목이나 todo 줄에 경로를 넣으면 에이전트가 그 폴더에서 작업합니다. 경로가 없으면 이 메모 폴더에서 작업해요.
    헤더의 📁 버튼에서 자주 쓰는 폴더를 추가하고 메모로 끌어다 놓을 수 있어요.

    ## 링크
    [[아이디어]] 처럼 쓰면 다른 메모로 이동합니다. 없는 메모면 새로 만들어요.

    """
}
