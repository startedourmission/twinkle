import AppKit
import Foundation

// Twinkle 전용 스킬·커넥터(MCP)·플러그인.
// 각 CLI의 전역 설정은 건드리지 않고, Twinkle이 에이전트를 실행할 때만 인자로 넘김.
// 전역에 설치된 것은 CLI가 원래대로 읽으니 그대로 동작함 (설정 창에는 읽기 전용으로 보여 줌)
//
//   ~/Library/Application Support/Twinkle/extensions/
//     config.json                      커넥터·플러그인 목록
//     twinkle-skills/                  Twinkle 스킬을 담은 Claude 플러그인
//       .claude-plugin/plugin.json
//       skills/<이름>/SKILL.md
//     claude-mcp.json                  실행할 때 --mcp-config로 넘기는 파일 (config.json에서 만듦)

/// MCP 서버 하나
struct Connector: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case stdio, http
    }

    var name: String
    var kind: Kind = .stdio
    /// stdio: 실행할 명령과 인자
    var command = ""
    var args: [String] = []
    var env: [String: String] = [:]
    /// http: 서버 주소와 헤더
    var url = ""
    var headers: [String: String] = [:]
    var enabled = true

    var id: String { name }

    /// 목록에 보일 한 줄 요약
    var summary: String {
        switch kind {
        case .stdio: ([command] + args).joined(separator: " ")
        case .http: url
        }
    }

    /// 이름은 영문·숫자·-·_ 만 (CLI 설정 키로 그대로 쓰므로)
    static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Claude Code --mcp-config 형식의 서버 항목
    var claudeJSON: [String: Any] {
        switch kind {
        case .stdio:
            var entry: [String: Any] = ["type": "stdio", "command": command, "args": args]
            if !env.isEmpty { entry["env"] = env }
            return entry
        case .http:
            var entry: [String: Any] = ["type": "http", "url": url]
            if !headers.isEmpty { entry["headers"] = headers }
            return entry
        }
    }

    /// MCP 설명서에 흔히 있는 JSON 붙여넣기: {"mcpServers": {...}}, {"이름": {...}}, 서버 하나({"command": …})
    static func parse(json text: String, fallbackName: String) -> [Connector]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let servers: [String: Any]
        if let wrapped = object["mcpServers"] as? [String: Any] {
            servers = wrapped
        } else if object["command"] != nil || object["url"] != nil {
            servers = [fallbackName: object]
        } else {
            servers = object
        }
        let parsed = servers.compactMap { name, value -> Connector? in
            guard let entry = value as? [String: Any] else { return nil }
            var connector = Connector(name: name)
            if let url = entry["url"] as? String {
                connector.kind = .http
                connector.url = url
                connector.headers = entry["headers"] as? [String: String] ?? [:]
            } else if let command = entry["command"] as? String {
                connector.command = command
                connector.args = entry["args"] as? [String] ?? []
                connector.env = entry["env"] as? [String: String] ?? [:]
            } else {
                return nil
            }
            return connector
        }
        return parsed.isEmpty ? nil : parsed.sorted { $0.name < $1.name }
    }
}

/// Claude Code 플러그인 폴더 또는 .zip
struct PluginRef: Codable, Identifiable, Equatable {
    var path: String
    var enabled = true

    var id: String { path }

    /// .claude-plugin/plugin.json의 이름 (없으면 폴더 이름)
    var name: String {
        let manifest = URL(fileURLWithPath: path).appendingPathComponent(".claude-plugin/plugin.json")
        if let data = try? Data(contentsOf: manifest),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = object["name"] as? String {
            return name
        }
        return (URL(fileURLWithPath: path).lastPathComponent as NSString).deletingPathExtension
    }

    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// SKILL.md 하나 (Twinkle 것 또는 전역)
struct SkillInfo: Identifiable, Equatable {
    let name: String
    let description: String
    let folder: URL

    var id: String { folder.path }

    /// 폴더 안 SKILL.md의 앞머리(--- name/description ---)를 읽음
    static func read(folder: URL) -> SkillInfo? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
        var name = folder.lastPathComponent
        var description = ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "---" { break }
                if trimmed.hasPrefix("name:") { name = Self.value(trimmed.dropFirst(5)) }
                if trimmed.hasPrefix("description:") { description = Self.value(trimmed.dropFirst(12)) }
            }
        }
        return SkillInfo(name: name, description: description, folder: folder)
    }

    private static func value(_ raw: Substring) -> String {
        raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }

    /// 폴더 아래의 스킬들. 링크(심볼릭 링크)를 따라가고, 스킬 묶음 폴더(synced/…/이름)를 위해 세 단계까지 내려감
    static func list(in directory: URL, depth: Int = 3) -> [SkillInfo] {
        guard depth > 0 else { return [] }
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        var found: [SkillInfo] = []
        for folder in folders {
            let resolved = folder.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if let skill = read(folder: resolved) {
                found.append(skill)
            } else {
                found += list(in: resolved, depth: depth - 1)
            }
        }
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// 디스크에 저장된 Twinkle 전용 확장 (에이전트 실행 때 읽음)
struct ExtensionConfig: Codable, Equatable {
    var connectors: [Connector] = []
    var plugins: [PluginRef] = []
}

enum TwinkleExtensions {
    static var root: URL {
        let url = AppPaths.support.appendingPathComponent("extensions", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static var configURL: URL { root.appendingPathComponent("config.json") }
    /// Twinkle 스킬을 담는 Claude 플러그인
    static var skillsPlugin: URL { root.appendingPathComponent("twinkle-skills", isDirectory: true) }
    static var skillsFolder: URL {
        let url = skillsPlugin.appendingPathComponent("skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let manifest = skillsPlugin.appendingPathComponent(".claude-plugin/plugin.json")
        if !FileManager.default.fileExists(atPath: manifest.path) {
            try? FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let json = #"{"name": "twinkle", "version": "1.0.0", "description": "Twinkle 설정에서 등록한 스킬 (Twinkle이 시킬 때만 씀)"}"#
            try? json.write(to: manifest, atomically: true, encoding: .utf8)
        }
        return url
    }

    static func load() -> ExtensionConfig {
        guard let data = try? Data(contentsOf: configURL) else { return ExtensionConfig() }
        return (try? JSONDecoder().decode(ExtensionConfig.self, from: data)) ?? ExtensionConfig()
    }

    static func save(_ config: ExtensionConfig) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(config).write(to: configURL, options: .atomic)
    }

    static var skills: [SkillInfo] { SkillInfo.list(in: skillsFolder) }

    // MARK: 실행 인자

    /// 에이전트를 실행할 때 붙일 인자. Claude는 스킬·커넥터·플러그인, Codex는 커넥터만 (다른 건 실행 단위로 넘길 방법이 없음)
    static func arguments(for kind: AgentKind) -> [String] {
        let config = load()
        let connectors = config.connectors.filter(\.enabled)
        switch kind {
        case .claude:
            var arguments: [String] = []
            if !skills.isEmpty { arguments += ["--plugin-dir", skillsPlugin.path] }
            for plugin in config.plugins where plugin.enabled && plugin.exists {
                arguments += ["--plugin-dir", plugin.path]
            }
            if !connectors.isEmpty {
                let file = root.appendingPathComponent("claude-mcp.json")
                let servers = Dictionary(uniqueKeysWithValues: connectors.map { ($0.name, $0.claudeJSON) })
                if let data = try? JSONSerialization.data(withJSONObject: ["mcpServers": servers], options: [.prettyPrinted, .sortedKeys]),
                   (try? data.write(to: file, options: .atomic)) != nil {
                    arguments += ["--mcp-config", file.path]
                }
            }
            return arguments
        case .codex:
            // -c mcp_servers.<이름>.<키>=<TOML 값>
            return connectors.filter { Connector.isValidName($0.name) }.flatMap { connector -> [String] in
                let key = "mcp_servers.\(connector.name)"
                switch connector.kind {
                case .stdio:
                    var pairs = ["\(key).command=\(toml(connector.command))", "\(key).args=\(toml(connector.args))"]
                    if !connector.env.isEmpty { pairs.append("\(key).env=\(toml(connector.env))") }
                    return pairs.flatMap { ["-c", $0] }
                case .http:
                    var pairs = ["\(key).url=\(toml(connector.url))"]
                    if !connector.headers.isEmpty { pairs.append("\(key).http_headers=\(toml(connector.headers))") }
                    return pairs.flatMap { ["-c", $0] }
                }
            }
        case .grok:
            return []
        }
    }

    /// TOML 값. 문자열은 JSON과 같은 따옴표·이스케이프 (단 \/는 TOML에 없어서 쓰지 않음)
    private static func toml(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(string)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private static func toml(_ array: [String]) -> String {
        "[" + array.map(toml).joined(separator: ", ") + "]"
    }

    private static func toml(_ table: [String: String]) -> String {
        "{" + table.keys.sorted().map { "\(toml($0)) = \(toml(table[$0]!))" }.joined(separator: ", ") + "}"
    }

    // MARK: 전역에 설치된 것 (읽기 전용)

    struct Global: Equatable {
        var skills: [AgentKind: [SkillInfo]] = [:]
        var connectors: [AgentKind: [String]] = [:]
        var plugins: [AgentKind: [String]] = [:]
    }

    /// 각 CLI가 원래 읽는 위치를 훑음. 파일만 읽고 CLI는 실행하지 않음
    static func scanGlobal() -> Global {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = { (relative: String) in home.appendingPathComponent(relative) }
        var global = Global()

        global.skills[.claude] = SkillInfo.list(in: path(".claude/skills"))
        global.skills[.codex] = SkillInfo.list(in: path(".codex/skills")) + SkillInfo.list(in: path(".agents/skills"))
        global.skills[.grok] = SkillInfo.list(in: path(".grok/skills"))

        if let data = try? Data(contentsOf: path(".claude.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            global.connectors[.claude] = ((object["mcpServers"] as? [String: Any])?.keys).map { $0.sorted() } ?? []
        }
        global.connectors[.codex] = tomlSections(in: path(".codex/config.toml"), prefixes: ["mcp_servers"])
        global.connectors[.grok] = tomlSections(in: path(".grok/config.toml"), prefixes: ["mcp_servers", "mcp.servers"])

        if let data = try? Data(contentsOf: path(".claude/settings.json")),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let enabled = object["enabledPlugins"] as? [String: Bool] {
            global.plugins[.claude] = enabled.filter(\.value).keys.sorted()
        }
        global.plugins[.grok] = ((try? FileManager.default.contentsOfDirectory(atPath: path(".grok/installed-plugins").path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
        return global
    }

    /// config.toml의 [접두어.이름] 섹션 이름들
    private static func tomlSections(in file: URL, prefixes: [String]) -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var names: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), trimmed.hasSuffix("]"), !trimmed.hasPrefix("[[") else { continue }
            let inner = trimmed.dropFirst().dropLast()
            for prefix in prefixes where inner.hasPrefix(prefix + ".") {
                // [mcp_servers.이름] 또는 [mcp_servers."이름"] (하위 표 [mcp_servers.이름.env]는 제외)
                let rest = inner.dropFirst(prefix.count + 1)
                let name: String
                if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
                    name = String(rest[rest.index(after: rest.startIndex)..<end])
                } else {
                    name = String(rest.split(separator: ".").first ?? "")
                }
                if !name.isEmpty, !names.contains(name) { names.append(name) }
            }
        }
        return names
    }
}

/// claude.ai 계정에 연결한 커넥터 (Gmail, Google Drive 등). Claude Code가 로그인한 계정에서 그대로 가져와 씀.
/// 로그인·권한은 claude.ai가 맡으니 Twinkle은 연결 페이지를 열고 상태만 봄
struct AccountConnector: Identifiable, Equatable {
    let name: String
    let connected: Bool
    var id: String { name }

    static let settingsURL = URL(string: "https://claude.ai/settings/connectors")!

    /// `claude mcp list`에서 "claude.ai 이름: 주소 - ✔ Connected" 줄만 (몇 초 걸림: 서버마다 연결을 확인해서)
    static func list() async -> [AccountConnector]? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "claude mcp list"]
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                guard process.terminationStatus == 0 else { return continuation.resume(returning: nil) }
                continuation.resume(returning: parse(output))
            }
            do { try process.run() } catch { continuation.resume(returning: nil) }
        }
    }

    static func parse(_ output: String) -> [AccountConnector] {
        output.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("claude.ai "), let colon = line.range(of: ": ") else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 10)..<colon.lowerBound])
            return AccountConnector(name: name, connected: line.contains("✔"))
        }
    }
}
