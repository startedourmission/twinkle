import Foundation

/// 한도 하나의 사용률 (예: 5시간 29%)
struct UsageWindow: Codable, Equatable {
    var name: String
    var fraction: Double
    var resetsAt: Date?
}

struct AgentUsage: Codable, Equatable {
    var windows: [UsageWindow]
    var updatedAt: Date

    /// 테두리에 그릴 값: 더 많이 쓴 한도 기준. 초기화 시각이 지난 한도는 0으로 봄
    var fraction: Double {
        windows.map { window in
            if let resetsAt = window.resetsAt, resetsAt < Date() { return 0 }
            return window.fraction
        }.max() ?? 0
    }

    var summary: String {
        windows.map { "\($0.name) \(Int(($0.fraction * 100).rounded()))%" }.joined(separator: " · ")
    }
}

/// 에이전트별 사용량 한도.
/// Claude Code는 실행할 때 나오는 rate_limit_event, Codex는 ~/.codex/sessions 기록에서 읽음.
/// Grok Build는 사용률을 남기지 않아 없음
@MainActor
final class UsageMonitor: ObservableObject {
    static let shared = UsageMonitor()

    @Published private(set) var usage: [AgentKind: AgentUsage] = [:]
    @Published var showsRing = UserDefaults.standard.object(forKey: "showsUsageRing") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showsRing, forKey: "showsUsageRing") }
    }

    private var timer: Timer?

    private init() {
        if let data = UserDefaults.standard.data(forKey: "agentUsage"),
           let saved = try? JSONDecoder().decode([String: AgentUsage].self, from: data) {
            for (key, value) in saved {
                if let kind = AgentKind(rawValue: key) { usage[kind] = value }
            }
        }
        if usage[.claude] == nil { loadClaudeFromLogs() }
        refreshCodex()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshCodex() }
        }
    }

    private func set(_ kind: AgentKind, _ value: AgentUsage) {
        guard usage[kind] != value else { return }
        usage[kind] = value
        let encoded = Dictionary(uniqueKeysWithValues: usage.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) { UserDefaults.standard.set(data, forKey: "agentUsage") }
    }

    /// Claude Code stream-json의 rate_limit_event
    func updateClaude(from event: [String: Any]) {
        guard let info = event["rate_limit_info"] as? [String: Any],
              let windows = info["unifiedWindows"] as? [String: Any]
        else { return }
        let names = ["five_hour": "5시간", "seven_day": "7일", "seven_day_opus": "7일(Opus)"]
        let parsed: [UsageWindow] = windows.keys.sorted().compactMap { key in
            guard let window = windows[key] as? [String: Any], let utilization = (window["utilization"] as? NSNumber)?.doubleValue else { return nil }
            let resets = (window["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(name: names[key] ?? key, fraction: utilization, resetsAt: resets)
        }
        guard !parsed.isEmpty else { return }
        set(.claude, AgentUsage(windows: parsed.sorted { $0.name < $1.name }, updatedAt: Date()))
    }

    /// 처음 켤 때: 지난 실행 로그에서 마지막 rate_limit_event를 찾아 둠
    private func loadClaudeFromLogs() {
        let files = ((try? FileManager.default.contentsOfDirectory(at: AppPaths.logs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasSuffix("-claude.jsonl") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for file in files.prefix(10) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limit_event\"") {
                if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                    updateClaude(from: object)
                    return
                }
            }
        }
    }

    /// Codex가 세션 기록에 남기는 rate_limits (가장 최근 기록 파일의 마지막 값)
    func refreshCodex() {
        guard let file = Self.latestCodexSession(),
              let handle = try? FileHandle(forReadingFrom: file)
        else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        guard let data = try? handle.readToEnd() else { return }
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
        for line in lines where line.contains("\"rate_limits\"") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let limits = Self.find("rate_limits", in: object) as? [String: Any]
            else { continue }
            var windows: [UsageWindow] = []
            for key in ["primary", "secondary"] {
                guard let window = limits[key] as? [String: Any], let percent = (window["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
                let name = minutes >= 1440 ? "\(minutes / 1440)일" : minutes >= 60 ? "\(minutes / 60)시간" : "\(minutes)분"
                let resets = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(UsageWindow(name: name, fraction: percent / 100, resetsAt: resets))
            }
            if !windows.isEmpty {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
                set(.codex, AgentUsage(windows: windows, updatedAt: modified))
            }
            return
        }
    }

    private static func latestCodexSession() -> URL? {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        // 날짜 폴더(YYYY/MM/DD)라 최근 며칠만 보면 됨
        let calendar = Calendar.current
        for daysAgo in 0..<14 {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!))
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let latest = files.filter { $0.pathExtension == "jsonl" }.max { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da < db
            }
            if let latest { return latest }
        }
        return nil
    }

    private static func find(_ key: String, in object: Any) -> Any? {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary[key] { return value }
            for value in dictionary.values { if let found = find(key, in: value) { return found } }
        } else if let array = object as? [Any] {
            for value in array { if let found = find(key, in: value) { return found } }
        }
        return nil
    }
}
