import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 설정 → 확장: Twinkle 전용 스킬·커넥터·플러그인 등록, 전역에 설치된 것 보기
@MainActor
final class ExtensionStore: ObservableObject {
    @Published private(set) var config = TwinkleExtensions.load()
    @Published private(set) var skills = TwinkleExtensions.skills
    @Published private(set) var global = TwinkleExtensions.Global()

    func reload() {
        config = TwinkleExtensions.load()
        skills = TwinkleExtensions.skills
        Task.detached {
            let global = TwinkleExtensions.scanGlobal()
            await MainActor.run { self.global = global }
        }
    }

    private func update(_ change: (inout ExtensionConfig) -> Void) {
        var next = config
        change(&next)
        TwinkleExtensions.save(next)
        config = next
    }

    // MARK: 스킬

    /// 새 스킬: skills/<이름>/SKILL.md
    func createSkill(name: String, description: String, body: String) throws {
        let folder = TwinkleExtensions.skillsFolder.appendingPathComponent(name, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: folder.path) else { throw ExtensionError.exists(name) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = "---\nname: \(name)\ndescription: \(description.replacingOccurrences(of: "\n", with: " "))\n---\n\n\(body)\n"
        try text.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        skills = TwinkleExtensions.skills
    }

    /// 스킬 가져오기. 고를 수 있는 것:
    /// - SKILL.md가 든 스킬 폴더 하나
    /// - SKILL.md 없이 스킬이 여러 개 든 폴더 (플러그인의 skills/…, 스킬 묶음)
    /// - 위 둘을 압축한 .zip / .skill
    /// 찾은 스킬 폴더를 하나씩 skills/ 아래로 복사함. 이미 있는 이름은 건너뜀
    func importSkills(from urls: [URL]) throws -> (added: [String], skipped: [String]) {
        var added: [String] = [], skipped: [String] = []
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("twinkle-skill-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for url in urls {
            var root = url
            var fallbackName = url.lastPathComponent
            if ["zip", "skill"].contains(url.pathExtension.lowercased()) {
                root = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try Self.unzip(url, to: root)
                fallbackName = url.deletingPathExtension().lastPathComponent
            }
            let found: [(folder: URL, name: String)] = FileManager.default.fileExists(atPath: root.appendingPathComponent("SKILL.md").path)
                ? [(root, fallbackName)]
                : SkillInfo.list(in: root, depth: 4).map { ($0.folder, $0.folder.lastPathComponent) }
            for skill in found {
                let destination = TwinkleExtensions.skillsFolder.appendingPathComponent(skill.name, isDirectory: true)
                if FileManager.default.fileExists(atPath: destination.path) || added.contains(skill.name) {
                    skipped.append(skill.name)
                    continue
                }
                try FileManager.default.copyItem(at: skill.folder, to: destination)
                added.append(skill.name)
            }
        }
        skills = TwinkleExtensions.skills
        if added.isEmpty {
            if let name = skipped.first { throw ExtensionError.exists(skipped.count == 1 ? name : skipped.joined(separator: ", ")) }
            throw ExtensionError.noSkillFile
        }
        return (added, skipped)
    }

    private static func unzip(_ archive: URL, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, folder.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExtensionError.badArchive(archive.lastPathComponent) }
    }

    /// 휴지통으로 (실수로 지워도 되살릴 수 있게)
    func removeSkill(_ skill: SkillInfo) {
        try? FileManager.default.trashItem(at: skill.folder, resultingItemURL: nil)
        skills = TwinkleExtensions.skills
    }

    // MARK: 커넥터

    func addConnectors(_ connectors: [Connector]) throws {
        for connector in connectors {
            guard Connector.isValidName(connector.name) else { throw ExtensionError.badName(connector.name) }
            guard !config.connectors.contains(where: { $0.name == connector.name }) else { throw ExtensionError.exists(connector.name) }
        }
        update { $0.connectors += connectors }
    }

    func removeConnector(_ connector: Connector) {
        update { $0.connectors.removeAll { $0.name == connector.name } }
    }

    func setConnector(_ connector: Connector, enabled: Bool) {
        update { config in
            if let index = config.connectors.firstIndex(where: { $0.name == connector.name }) { config.connectors[index].enabled = enabled }
        }
    }

    // MARK: 플러그인

    func addPlugin(at url: URL) throws {
        let isZip = url.pathExtension.lowercased() == "zip"
        guard isZip || FileManager.default.fileExists(atPath: url.appendingPathComponent(".claude-plugin/plugin.json").path) else {
            throw ExtensionError.noPluginManifest
        }
        guard !config.plugins.contains(where: { $0.path == url.path }) else { throw ExtensionError.exists(url.lastPathComponent) }
        update { $0.plugins.append(PluginRef(path: url.path)) }
    }

    func removePlugin(_ plugin: PluginRef) {
        update { $0.plugins.removeAll { $0.path == plugin.path } }
    }

    func setPlugin(_ plugin: PluginRef, enabled: Bool) {
        update { config in
            if let index = config.plugins.firstIndex(where: { $0.path == plugin.path }) { config.plugins[index].enabled = enabled }
        }
    }
}

enum ExtensionError: LocalizedError {
    case exists(String)
    case badName(String)
    case noSkillFile
    case noPluginManifest
    case badJSON
    case badArchive(String)

    var errorDescription: String? {
        switch self {
        case .exists(let name): "'\(name)'은(는) 이미 있어요."
        case .badName(let name): "'\(name)': 이름은 영문·숫자·-·_ 만 쓸 수 있어요."
        case .noSkillFile: "SKILL.md가 든 스킬을 찾지 못했어요."
        case .badArchive(let name): "'\(name)'의 압축을 풀지 못했어요."
        case .noPluginManifest: "Claude Code 플러그인 폴더가 아니에요 (.claude-plugin/plugin.json이 없음)."
        case .badJSON: "JSON에서 서버를 찾지 못했어요. {\"mcpServers\": {…}} 모양이나 서버 하나({\"command\": …})를 넣어 주세요."
        }
    }
}

struct ExtensionsSettingsView: View {
    @StateObject private var store = ExtensionStore()
    @State private var section = "skills"
    @State private var sheet: Sheet?
    @State private var error: String?
    @State private var notice: String?

    enum Sheet: Identifiable {
        case newSkill, connector
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                Text("스킬").tag("skills")
                Text("커넥터").tag("connectors")
                Text("플러그인").tag("plugins")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.horizontal, .top], 16)

            Form {
                switch section {
                case "skills": skills
                case "connectors": connectors
                default: plugins
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { store.reload() }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .newSkill: NewSkillSheet(store: store)
            case .connector: ConnectorSheet(store: store)
            }
        }
        .alert("가져왔어요", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인") { notice = nil }
        } message: {
            Text(notice ?? "")
        }
        .alert("추가하지 못했어요", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("확인") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    // MARK: 스킬

    @ViewBuilder
    private var skills: some View {
        Section {
            if store.skills.isEmpty {
                Text("아직 없어요").foregroundStyle(.secondary)
            }
            ForEach(store.skills) { skill in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                        if !skill.description.isEmpty {
                            Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Button { NSWorkspace.shared.activateFileViewerSelecting([skill.folder.appendingPathComponent("SKILL.md")]) } label: {
                        Image(systemName: "folder")
                    }
                    .help("Finder에서 보기")
                    Button(role: .destructive) { store.removeSkill(skill) } label: { Image(systemName: "trash") }
                        .help("휴지통으로")
                }
                .buttonStyle(.borderless)
            }
            HStack {
                Button("새 스킬…") { sheet = .newSkill }
                Button("가져오기…", action: importSkill)
            }
        } header: {
            Text("Twinkle 전용")
        } footer: {
            Text("Twinkle이 시킬 때만 Claude Code에 넘겨요. Codex·Grok은 실행할 때 스킬을 따로 넘길 수 없어서 전역에 설치된 것만 써요.")
                .font(.caption).foregroundStyle(.secondary)
        }

        globalSection { kind in
            (store.global.skills[kind] ?? []).map { $0.name }
        }
    }

    private func importSkill() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.folder, .zip, UTType(filenameExtension: "skill") ?? .zip]
        panel.message = "스킬 폴더(SKILL.md), 스킬이 여러 개 든 폴더·플러그인, 또는 .zip을 고르세요"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        do {
            let result = try store.importSkills(from: panel.urls)
            // 하나만 깔끔히 들어왔으면 목록에 보이니 따로 알리지 않음
            if result.added.count > 1 || !result.skipped.isEmpty {
                var lines = ["\(result.added.count)개: \(result.added.joined(separator: ", "))"]
                if !result.skipped.isEmpty { lines.append("이미 있어서 건너뜀: \(result.skipped.joined(separator: ", "))") }
                notice = lines.joined(separator: "\n")
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: 커넥터

    @ViewBuilder
    private var connectors: some View {
        Section {
            if store.config.connectors.isEmpty {
                Text("아직 없어요").foregroundStyle(.secondary)
            }
            ForEach(store.config.connectors) { connector in
                HStack {
                    Toggle("", isOn: Binding(get: { connector.enabled }, set: { store.setConnector(connector, enabled: $0) }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connector.name)
                        Text(connector.summary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(role: .destructive) { store.removeConnector(connector) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            Button("커넥터 추가…") { sheet = .connector }
        } header: {
            Text("Twinkle 전용")
        } footer: {
            Text("MCP 서버예요. Twinkle이 시킬 때만 Claude Code와 Codex에 넘겨요 (Grok은 전역에 등록된 것만 써요).")
                .font(.caption).foregroundStyle(.secondary)
        }

        globalSection { kind in store.global.connectors[kind] ?? [] }
    }

    // MARK: 플러그인

    @ViewBuilder
    private var plugins: some View {
        Section {
            if store.config.plugins.isEmpty {
                Text("아직 없어요").foregroundStyle(.secondary)
            }
            ForEach(store.config.plugins) { plugin in
                HStack {
                    Toggle("", isOn: Binding(get: { plugin.enabled }, set: { store.setPlugin(plugin, enabled: $0) }))
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(plugin.name)
                        Text((plugin.path as NSString).abbreviatingWithTildeInPath)
                            .font(.caption).foregroundStyle(plugin.exists ? Color.secondary : Color.red).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button(role: .destructive) { store.removePlugin(plugin) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            Button("플러그인 추가…", action: addPlugin)
        } header: {
            Text("Twinkle 전용")
        } footer: {
            Text("Claude Code 플러그인 폴더나 .zip이에요. 복사하지 않고 그 자리의 것을 써서, 고치면 다음 실행부터 바로 반영돼요.")
                .font(.caption).foregroundStyle(.secondary)
        }

        globalSection { kind in store.global.plugins[kind] ?? [] }
    }

    private func addPlugin() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.message = "Claude Code 플러그인 폴더(.claude-plugin/plugin.json이 있는 곳)나 .zip을 고르세요"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.addPlugin(at: url) } catch { self.error = error.localizedDescription }
    }

    // MARK: 전역

    private func globalSection(_ names: @escaping (AgentKind) -> [String]) -> some View {
        Section {
            ForEach(AgentKind.allCases) { kind in
                // 같은 이름은 한 번만 (여러 동기화 폴더에 같은 스킬이 있을 수 있음)
                let list = names(kind).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                HStack(alignment: .firstTextBaseline) {
                    AgentBadge(kind: kind, size: 16)
                    Text(kind.displayName).frame(width: 90, alignment: .leading)
                    Text(list.isEmpty ? "없음" : list.joined(separator: ", "))
                        .foregroundStyle(list.isEmpty ? .tertiary : .secondary)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("전역에 설치됨 · 항상 사용")
        } footer: {
            Text("터미널에서 각 CLI로 설치한 것들이에요. Twinkle에서 시킬 때도 그대로 써요.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 새 스킬: 이름, 언제 쓰는지(설명), 내용
private struct NewSkillSheet: View {
    @ObservedObject var store: ExtensionStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    @State private var content = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("새 스킬").font(.headline)
            Form {
                TextField("이름", text: $name, prompt: Text("예: weekly-report"))
                TextField("설명", text: $description, prompt: Text("언제 쓰는 스킬인지 (에이전트가 이걸 보고 골라 써요)"), axis: .vertical)
                    .lineLimit(2...3)
            }
            Text("내용 (SKILL.md 본문, 마크다운)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $content)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("만들기") {
                    let slug = name.trimmingCharacters(in: .whitespaces)
                    guard Connector.isValidName(slug) else { error = ExtensionError.badName(slug).localizedDescription; return }
                    do {
                        try store.createSkill(name: slug, description: description, body: content)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || description.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

/// 커넥터 추가: 직접 입력하거나 MCP 설명서의 JSON을 붙여넣기
private struct ConnectorSheet: View {
    @ObservedObject var store: ExtensionStore
    @Environment(\.dismiss) private var dismiss
    @State private var usesJSON = false
    @State private var name = ""
    @State private var kind = Connector.Kind.stdio
    @State private var commandLine = ""
    @State private var url = ""
    @State private var pairs = ""
    @State private var json = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("커넥터 추가").font(.headline)
            Picker("", selection: $usesJSON) {
                Text("직접 입력").tag(false)
                Text("JSON 붙여넣기").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if usesJSON {
                Text("MCP 서버 설명서의 설정 JSON을 그대로 붙여넣으세요. {\"mcpServers\": {…}} 안의 서버가 모두 추가돼요.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $json)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 200)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            } else {
                Form {
                    TextField("이름", text: $name, prompt: Text("예: github"))
                    Picker("종류", selection: $kind) {
                        Text("명령 실행 (stdio)").tag(Connector.Kind.stdio)
                        Text("원격 서버 (URL)").tag(Connector.Kind.http)
                    }
                    if kind == .stdio {
                        TextField("명령", text: $commandLine, prompt: Text("예: npx -y @modelcontextprotocol/server-github"))
                            .font(.system(size: 12, design: .monospaced))
                    } else {
                        TextField("주소", text: $url, prompt: Text("https://…/mcp"))
                    }
                    TextField(kind == .stdio ? "환경 변수" : "헤더", text: $pairs,
                              prompt: Text(kind == .stdio ? "KEY=값 (한 줄에 하나)" : "Authorization=Bearer … (한 줄에 하나)"), axis: .vertical)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2...5)
                }
                .formStyle(.grouped)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button("추가", action: add).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private func add() {
        do {
            let connectors: [Connector]
            if usesJSON {
                guard let parsed = Connector.parse(json: json, fallbackName: "server") else { throw ExtensionError.badJSON }
                connectors = parsed
            } else {
                var connector = Connector(name: name.trimmingCharacters(in: .whitespaces), kind: kind)
                let values = Self.pairs(pairs)
                if kind == .stdio {
                    let words = Self.split(commandLine)
                    connector.command = words.first ?? ""
                    connector.args = Array(words.dropFirst())
                    connector.env = values
                } else {
                    connector.url = url.trimmingCharacters(in: .whitespaces)
                    connector.headers = values
                }
                connectors = [connector]
            }
            try store.addConnectors(connectors)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// KEY=값 줄들
    private static func pairs(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            result[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// 셸처럼 공백으로 나누되 따옴표 안은 한 덩어리
    private static func split(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
