import AppKit

/// 체크박스 안의 글자. `[/]` 진행 중은 옵시디언 Tasks 플러그인 표기와 같음
enum TodoState: String {
    case open = " "
    case doing = "/"
    case done = "x"
    case failed = "!"

    init(mark: Character) {
        switch mark {
        case "x", "X": self = .done
        case "/": self = .doing
        case "!": self = .failed
        default: self = .open
        }
    }
}

enum AgentKind: String, CaseIterable, Identifiable {
    case claude, codex, grok

    var id: String { rawValue }
    var tag: String { "@\(rawValue)" }

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok Build"
        }
    }

    /// 로고 이미지가 없을 때 배지에 그릴 기호
    var symbolName: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .grok: "bolt.fill"
        }
    }

    var color: NSColor {
        switch self {
        case .claude: NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        case .codex: NSColor(red: 0.16, green: 0.62, blue: 0.50, alpha: 1)
        case .grok: NSColor(red: 0.20, green: 0.20, blue: 0.22, alpha: 1)
        }
    }
}

struct Todo: Identifiable, Hashable {
    let docPath: String
    let line: Int
    let state: TodoState
    /// 체크박스 뒤 원문 (에이전트 태그 포함). 줄을 다시 찾을 때 키로 씀
    let body: String
    let agent: AgentKind?

    var id: String { "\(docPath):\(line)" }

    var title: String {
        guard let agent else { return body }
        return body.replacingOccurrences(of: agent.tag, with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
    }

    nonisolated(unsafe) static let lineRegex = /^(\s*)[-*+] \[(.)\] (.*)$/
    nonisolated(unsafe) static let agentRegex = /@(claude|codex|grok)\b/.ignoresCase()

    static func parse(_ text: String, docPath: String) -> [Todo] {
        var result: [Todo] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            guard let match = line.wholeMatch(of: lineRegex) else { continue }
            let body = String(match.3)
            let agent = body.firstMatch(of: agentRegex).flatMap { AgentKind(rawValue: $0.1.lowercased()) }
            result.append(Todo(docPath: docPath, line: index, state: TodoState(mark: match.2.first ?? " "), body: body, agent: agent))
        }
        return result
    }

    /// body가 같은 첫 번째 todo 줄의 상태를 바꾼 새 텍스트. 결과 메모가 있으면 바로 아래 줄에 덧붙임
    static func updating(_ text: String, body: String, to state: TodoState, resultNote: String? = nil) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(where: { $0.wholeMatch(of: lineRegex).map { String($0.3) == body } ?? false }),
              let match = lines[index].wholeMatch(of: lineRegex)
        else { return nil }

        let indent = String(match.1)
        lines[index] = "\(indent)- [\(state.rawValue)] \(body)"
        if let resultNote, !resultNote.isEmpty {
            lines.insert("\(indent)    - ↳ \(resultNote)", at: index + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// body가 같은 첫 todo 줄의 번호 (편집으로 줄이 밀려도 다시 찾기 위해)
    static func lineIndex(in text: String, body: String) -> Int? {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .firstIndex { $0.wholeMatch(of: lineRegex).map { String($0.3) == body } ?? false }
    }

    /// 편집기에서 체크박스를 클릭했을 때: 줄 번호로 바로 토글
    static func toggling(_ text: String, line: Int) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.indices.contains(line), let match = lines[line].wholeMatch(of: lineRegex) else { return nil }
        let next: TodoState = TodoState(mark: match.2.first ?? " ") == .done ? .open : .done
        lines[line] = "\(match.1)- [\(next.rawValue)] \(match.3)"
        return lines.joined(separator: "\n")
    }
}
