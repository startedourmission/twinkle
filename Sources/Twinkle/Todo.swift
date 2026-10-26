import AppKit

/// 체크박스 안의 글자. `[/]` 진행 중, `[?]` 답변 필요는 옵시디언 Tasks 플러그인 표기와 같음
enum TodoState: String {
    case open = " "
    case doing = "/"
    case done = "x"
    case failed = "!"
    /// 에이전트가 권한이나 질문으로 사용자 답을 기다리는 중
    case waiting = "?"

    init(mark: Character) {
        switch mark {
        case "x", "X": self = .done
        case "/": self = .doing
        case "!": self = .failed
        case "?": self = .waiting
        default: self = .open
        }
    }
}

/// 댓글 줄 끝에 숨겨 두는 정보: `<!--twinkle {"session":"…"}-->` (옵시디언 읽기 화면에선 안 보임)
struct CommentMeta: Codable, Equatable {
    /// 이어서 대화할 에이전트 세션
    var session: String?
    /// 에이전트 댓글: "permission"(권한 요청), "question"(질문), nil(일반 결과)
    /// 사용자 답글: "approval"(allow에 고른 규칙만 허용), "approveAll"(이번 작업만 모두 허용), "deny"
    var kind: String?
    /// 권한 요청이면 필요한 규칙들, 허용 답글이면 사용자가 고른 규칙들 (예: `Bash(npm install)`)
    var allow: [String]?
}

/// todo 아래 `- ↳ 작성자: 내용` 한 줄
struct Comment: Identifiable, Equatable {
    let line: Int
    let author: String
    let text: String
    let meta: CommentMeta?

    var id: Int { line }
    var agent: AgentKind? { AgentKind(rawValue: author) }
    var isUser: Bool { author == Comment.userAuthor }

    static let userAuthor = "나"
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
    nonisolated(unsafe) static let commentRegex = /^(\s*)- ↳ ([^:\n]+): (.*)$/
    /// 예전 이름(widgent)으로 저장된 댓글도 읽음
    nonisolated(unsafe) static let metaRegex = /\s*<!--(?:twinkle|widgent) (\{.*\})-->\s*$/
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

    /// body가 같은 첫 번째 todo 줄의 상태를 바꾼 새 텍스트. 댓글이 있으면 스레드 맨 끝에 덧붙임
    static func updating(_ text: String, body: String, to state: TodoState?, comment: (author: String, text: String, meta: CommentMeta?)? = nil) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let index = lines.firstIndex(where: { $0.wholeMatch(of: lineRegex).map { String($0.3) == body } ?? false }),
              let match = lines[index].wholeMatch(of: lineRegex)
        else { return nil }

        let indent = String(match.1)
        if let state {
            lines[index] = "\(indent)- [\(state.rawValue)] \(body)"
        }
        if let comment {
            var end = index + 1
            while end < lines.count, lines[end].wholeMatch(of: commentRegex) != nil { end += 1 }
            lines.insert(commentLine(indent: indent, author: comment.author, text: comment.text, meta: comment.meta), at: end)
        }
        return lines.joined(separator: "\n")
    }

    static func commentLine(indent: String, author: String, text: String, meta: CommentMeta?) -> String {
        // 마크다운 한 줄에 담기도록 줄바꿈은 <br>로 (옵시디언 읽기 화면에서도 줄바꿈으로 보임)
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "<br>")
        var line = "\(indent)    - ↳ \(author): \(flat.isEmpty ? "(내용 없음)" : flat)"
        if let meta, let data = try? JSONEncoder().encode(meta), let json = String(data: data, encoding: .utf8) {
            line += " <!--twinkle \(json)-->"
        }
        return line
    }

    /// todo 줄 바로 아래 이어지는 댓글들
    static func thread(in text: String, todoLine: Int) -> [Comment] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var comments: [Comment] = []
        var index = todoLine + 1
        while index < lines.count, let match = lines[index].wholeMatch(of: commentRegex) {
            var content = String(match.3)
            var meta: CommentMeta?
            if let metaMatch = content.firstMatch(of: metaRegex) {
                meta = try? JSONDecoder().decode(CommentMeta.self, from: Data(metaMatch.1.utf8))
                content.removeSubrange(metaMatch.range)
            }
            comments.append(Comment(line: index, author: String(match.2).trimmingCharacters(in: .whitespaces), text: content, meta: meta))
            index += 1
        }
        return comments
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

/// 댓글 글자를 읽기 좋게: <br> 줄바꿈, **굵게**·`코드`·링크, "- " 목록은 •
enum CommentText {
    static func lines(_ text: String) -> [String] {
        var text = text.replacingOccurrences(of: "<br>", with: "\n")
        // 예전에 한 줄로 붙여 저장된 댓글: 문장 끝 뒤의 " - "는 목록이 붙은 것
        if !text.contains("\n") {
            text = text.replacing(/([.!?:)\]*다요음함됨])\s+-\s+/) { "\($0.1)\n- " }
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    static func attributed(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, raw) in lines(text).enumerated() {
            if index > 0 { result += AttributedString("\n") }
            var line = raw.trimmingCharacters(in: .whitespaces)
            var prefix = ""
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                prefix = "•  "
                line = String(line.dropFirst(2))
            } else if line.hasPrefix("#") {
                line = "**" + line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) + "**"
            }
            let body = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(line)
            result += AttributedString(prefix) + body
        }
        return result
    }

    /// 접힌 한 줄 미리보기용: 첫 줄만
    static func firstLine(_ text: String) -> String {
        lines(text).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text
    }
}

/// 마크다운 원문을 화면용 글자로: [글자](주소) → 글자, [[메모|별칭]] → 별칭,
/// **굵게**·`코드` 기호 제거, 맨 주소는 짧게 (docs.google.com/document/…)
enum MarkdownPlain {
    static func text(_ markdown: String) -> String {
        var text = markdown
        text = text.replacing(/\[([^\]\n]+)\]\([^)\s]+\)/) { String($0.1) }
        text = text.replacing(/\[\[([^\]|\n]+)(?:\|([^\]\n]+))?\]\]/) { String($0.2 ?? $0.1) }
        text = text.replacing(/\*\*([^*\n]+)\*\*/) { String($0.1) }
        text = text.replacing(/`([^`\n]+)`/) { String($0.1) }
        text = text.replacing(/https?:\/\/([^\s\/]+)(\/[^\s\/]*)?\S*/) { match in
            let host = String(match.1).replacingOccurrences(of: "www.", with: "")
            let first = match.2.map(String.init) ?? ""
            return String(match.0).count > host.count + first.count + 8 ? "\(host)\(first)/…" : String(match.0)
        }
        return text
    }
}
