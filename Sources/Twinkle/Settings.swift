import AppKit
import ServiceManagement
import SwiftUI

/// 에이전트 하나의 설정. 명령줄 인자는 여기서 만들어 내므로 사용자는 고르기만 하면 됨
struct AgentSettings: Codable, Equatable {
    var enabled = true
    /// 권한 수준 (AgentKind.permissionLevels의 id)
    var permission: String
    /// 비우면 CLI 기본 모델
    var model = ""
}

struct PermissionLevel: Identifiable {
    let id: String
    let label: String
    let detail: String
}

extension AgentKind {
    var permissionLevels: [PermissionLevel] {
        switch self {
        case .claude:
            [
                PermissionLevel(id: "bypassPermissions", label: "모두 자동 승인", detail: "묻지 않고 명령 실행·웹 접근까지 알아서 해요 (기본)"),
                PermissionLevel(id: "acceptEdits", label: "파일 수정만 자동 승인", detail: "명령 실행이나 웹 접근이 필요하면 댓글로 허락을 구해요"),
                PermissionLevel(id: "default", label: "모두 물어보기", detail: "파일 수정도 댓글로 허락을 구해요"),
            ]
        case .codex:
            [
                PermissionLevel(id: "danger-full-access", label: "제한 없음", detail: "컴퓨터 전체에 쓰고 네트워크도 써요 (기본)"),
                PermissionLevel(id: "workspace-write", label: "작업 폴더 안에서만 쓰기", detail: "작업 폴더 밖은 읽기만 하고 네트워크는 막혀요"),
                PermissionLevel(id: "read-only", label: "읽기 전용", detail: "파일을 바꾸지 않아요"),
            ]
        case .grok:
            [
                PermissionLevel(id: "bypassPermissions", label: "모두 자동 승인", detail: "묻지 않고 알아서 해요. Grok은 이 수준이어야 파일을 고칠 수 있어요 (기본)"),
                PermissionLevel(id: "acceptEdits", label: "물어보기", detail: "막힐 때마다 댓글로 허락을 구해요"),
            ]
        }
    }

    var defaultSettings: AgentSettings {
        AgentSettings(permission: permissionLevels[0].id)
    }

    /// 사용자가 고른 설정으로 CLI 인자 만들기. 2026-10 기준 각 CLI 옵션에 맞춤
    func runArguments(_ settings: AgentSettings, prompt: String) -> [String] {
        let model = settings.model.trimmingCharacters(in: .whitespaces)
        switch self {
        case .claude:
            return ["claude", "-p", prompt, "--output-format", "stream-json", "--verbose", "--permission-mode", settings.permission]
                + (model.isEmpty ? [] : ["--model", model])
        case .codex:
            return ["codex", "exec", "--json", "-s", settings.permission, "--skip-git-repo-check"]
                + (model.isEmpty ? [] : ["-m", model]) + [prompt]
        case .grok:
            return ["grok", "-p", prompt, "--output-format", "streaming-json", "--permission-mode", settings.permission]
                + (model.isEmpty ? [] : ["-m", model])
        }
    }

    /// 대댓글로 같은 세션을 이어갈 때
    func resumeArguments(_ settings: AgentSettings, session: String, prompt: String) -> [String] {
        let model = settings.model.trimmingCharacters(in: .whitespaces)
        switch self {
        case .claude:
            return runArguments(settings, prompt: prompt) + ["--resume", session]
        case .codex:
            // codex exec resume는 -s를 받지 않아 설정 덮어쓰기로 샌드박스를 지정
            return ["codex", "exec", "resume", session, "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"\(settings.permission)\""]
                + (model.isEmpty ? [] : ["-m", model]) + [prompt]
        case .grok:
            return runArguments(settings, prompt: prompt) + ["-r", session]
        }
    }

    /// 대댓글에서 고른 규칙만 허용
    func approveArguments(rules: [String]) -> [String] {
        switch self {
        case .claude: rules.flatMap { ["--allowedTools", $0] }
        case .codex: ["-c", "sandbox_mode=\"danger-full-access\""]
        case .grok: ["--always-approve"]
        }
    }

    /// 대댓글에서 "이번 작업만 모두 허용"
    var approveAllArguments: [String] {
        switch self {
        case .claude: ["--permission-mode", "bypassPermissions"]
        case .codex: ["-c", "sandbox_mode=\"danger-full-access\""]
        case .grok: ["--always-approve"]
        }
    }
}

/// 앱 설정. 설정 창에서 고치고 UserDefaults에 저장
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var agents: [String: AgentSettings] {
        didSet {
            if let data = try? JSONEncoder().encode(agents) {
                UserDefaults.standard.set(data, forKey: "agentSettings")
            }
        }
    }

    private init() {
        var saved = UserDefaults.standard.data(forKey: "agentSettings")
            .flatMap { try? JSONDecoder().decode([String: AgentSettings].self, from: $0) } ?? [:]
        // 기본 권한을 "되도록 묻지 않기"로 바꾸면서, 예전 기본값 그대로 저장된 것만 한 번 올림
        if !UserDefaults.standard.bool(forKey: "permissionDefaultsV2") {
            if saved["claude"]?.permission == "acceptEdits" { saved["claude"]?.permission = "bypassPermissions" }
            if saved["codex"]?.permission == "workspace-write" { saved["codex"]?.permission = "danger-full-access" }
            // init 안에서는 didSet이 안 불리니 직접 저장
            if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: "agentSettings") }
            UserDefaults.standard.set(true, forKey: "permissionDefaultsV2")
        }
        agents = saved
    }

    func settings(for kind: AgentKind) -> AgentSettings {
        agents[kind.rawValue] ?? kind.defaultSettings
    }

    func binding(for kind: AgentKind) -> Binding<AgentSettings> {
        Binding(
            get: { self.settings(for: kind) },
            set: { self.agents[kind.rawValue] = $0 }
        )
    }
}

/// 에이전트 CLI가 설치돼 있는지 (로그인 셸 PATH 기준)
struct CLIStatus: Equatable {
    var path: String?
    var version: String?

    static func check(_ kind: AgentKind) async -> CLIStatus {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v \(kind.rawValue) && \(kind.rawValue) --version 2>/dev/null | head -1"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let lines = output.split(separator: "\n").map(String.init)
                continuation.resume(returning: CLIStatus(path: lines.first, version: lines.dropFirst().first))
            }
            do { try process.run() } catch { continuation.resume(returning: CLIStatus()) }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var runner: AgentRunner
    @ObservedObject var workspaces: WorkspaceStore
    let notesFolder: URL
    var onChangeNotesFolder: () -> Void
    @State var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("일반", systemImage: "gearshape") }.tag("general")
            agents.tabItem { Label("에이전트", systemImage: "sparkles") }.tag("agents")
            folders.tabItem { Label("작업 폴더", systemImage: "folder") }.tag("folders")
        }
        .frame(width: 520, height: 470)
    }

    // MARK: 일반

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var general: some View {
        Form {
            Section("메모 폴더") {
                HStack {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: notesFolder.path))
                        .resizable()
                        .frame(width: 20, height: 20)
                    Text((notesFolder.path as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Finder에서 열기") { NSWorkspace.shared.open(notesFolder) }
                    Button("바꾸기…", action: onChangeNotesFolder)
                }
                Text("메모(md 파일)가 여기에 저장돼요. 옵시디언 보관함을 골라도 돼요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("실행") {
                Toggle("에이전트 자동 실행", isOn: $runner.isEnabled)
                Text("켜 두면 @claude, @codex, @grok 태그가 붙은 할 일을 컴퓨터가 켜져 있는 동안 계속 처리해요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("로그인할 때 Twinkle 열기", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = "설정하지 못했어요: \(error.localizedDescription)"
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 에이전트

    private var agents: some View {
        Form {
            ForEach(AgentKind.allCases) { kind in
                AgentSettingsSection(kind: kind, settings: settings.binding(for: kind))
            }
        }
        .formStyle(.grouped)
    }

    // MARK: 작업 폴더

    private var folders: some View {
        Form {
            Section {
                if workspaces.paths.isEmpty {
                    Text("아직 없어요. 자주 쓰는 폴더를 추가하면 메모 헤더의 📁에서 펼쳐 보고 메모로 끌어다 놓을 수 있어요.")
                        .foregroundStyle(.secondary)
                }
                ForEach(workspaces.paths, id: \.self) { path in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            workspaces.remove(path)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("즐겨찾기에서 빼기")
                    }
                }
            } header: {
                HStack {
                    Text("자주 쓰는 작업 폴더")
                    Spacer()
                    Button("추가…") { workspaces.chooseAndAdd() }
                        .controlSize(.small)
                }
            } footer: {
                Text("할 일이나 그 위 제목에 경로가 있으면 에이전트가 그 폴더에서 작업해요. 없으면 메모 폴더에서 작업해요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AgentSettingsSection: View {
    let kind: AgentKind
    @Binding var settings: AgentSettings
    @State private var status: CLIStatus?

    var body: some View {
        Section {
            Toggle("사용", isOn: $settings.enabled)
            Picker("권한", selection: $settings.permission) {
                ForEach(kind.permissionLevels) { level in
                    Text(level.label).tag(level.id)
                }
            }
            .disabled(!settings.enabled)
            if let level = kind.permissionLevels.first(where: { $0.id == settings.permission }) {
                Text(level.detail).font(.caption).foregroundStyle(.secondary)
            }
            TextField("모델", text: $settings.model, prompt: Text("비우면 기본 모델"))
                .disabled(!settings.enabled)
        } header: {
            HStack(spacing: 8) {
                AgentBadge(kind: kind, size: 20)
                Text(kind.displayName).font(.headline)
                Text(kind.tag).font(.caption.monospaced()).foregroundStyle(.secondary)
                Spacer()
                statusLabel
            }
        }
        .task { status = await CLIStatus.check(kind) }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case nil:
            ProgressView().controlSize(.small)
        case .some(let status) where status.path != nil:
            Label(status.version ?? "설치됨", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .help(status.path ?? "")
        case .some:
            Label("설치 안 됨", systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
