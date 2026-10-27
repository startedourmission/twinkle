import AppKit
import SwiftUI

/// 메뉴 막대 아이콘을 누르면 뜨는 메모 모아보기 (카드 그리드)
struct NoteGridView: View {
    @ObservedObject var library: NoteLibrary
    @ObservedObject var runner: AgentRunner
    let openPaths: Set<String>
    let colorFor: (String) -> NoteColor
    /// 항상 위에 고정한 메모인지
    let isPinned: (String) -> Bool
    var onOpen: (String) -> Void
    var onCloseNote: (String) -> Void
    var onTrash: (String) -> Void
    var onNew: () -> Void
    var onSettings: () -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private static let columns = 3
    private static let spacing: CGFloat = 10

    /// 검색어(제목·본문·초성)에 맞는 메모. Main이 맨 앞, 그다음 고정한 메모, 나머지는 최근 수정 순
    private var notes: [NoteDocument] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let rank = { (doc: NoteDocument) in
            doc.relativePath == NoteLibrary.mainNotePath ? 0 : isPinned(doc.relativePath) ? 1 : 2
        }
        let all = library.documents.values.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return (a.diskModified ?? .distantPast) > (b.diskModified ?? .distantPast)
        }
        guard !trimmed.isEmpty else { return all }
        return all.filter { doc in
            doc.title.localizedCaseInsensitiveContains(trimmed)
                || doc.text.localizedCaseInsensitiveContains(trimmed)
                || KoreanKeyboard.choseong(of: doc.title).contains(trimmed)
        }
    }

    /// 킵처럼 엇갈린 열: 카드마다 예상 높이를 더해 가장 짧은 열에 넣음
    private var columnsOfNotes: [[NoteDocument]] {
        var columns = Array(repeating: [NoteDocument](), count: Self.columns)
        var heights = Array(repeating: CGFloat(0), count: Self.columns)
        for doc in notes {
            let shortest = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            columns[shortest].append(doc)
            heights[shortest] += NoteCard.estimatedHeight(doc) + Self.spacing
        }
        return columns
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("메모 검색", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = notes.first { onOpen(first.relativePath) } }
                Button(action: onNew) { Label("새 메모", systemImage: "plus") }
                    .controlSize(.small)
            }
            .padding(12)
            Divider()

            ScrollView {
                if notes.isEmpty {
                    Text(query.isEmpty ? "메모가 없어요" : "찾는 메모가 없어요")
                        .foregroundStyle(.secondary)
                        .padding(40)
                } else {
                    HStack(alignment: .top, spacing: Self.spacing) {
                        ForEach(Array(columnsOfNotes.enumerated()), id: \.offset) { _, column in
                            VStack(spacing: Self.spacing) {
                                ForEach(column, id: \.relativePath) { doc in
                                    NoteCard(
                                        document: doc,
                                        color: colorFor(doc.relativePath),
                                        isOpen: openPaths.contains(doc.relativePath),
                                        agent: AgentKind.allCases.first { runner.jobs[$0]?.todo.docPath == doc.relativePath }
                                    )
                                    .onTapGesture { onOpen(doc.relativePath) }
                                    .contextMenu {
                                        Button("열기") { onOpen(doc.relativePath) }
                                        if openPaths.contains(doc.relativePath) {
                                            Button("화면에서 닫기") { onCloseNote(doc.relativePath) }
                                        }
                                        Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
                                        Divider()
                                        Button("휴지통으로", role: .destructive) { onTrash(doc.relativePath) }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
            HStack {
                Toggle("에이전트 자동 실행", isOn: $runner.isEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Spacer()
                Button("설정…", action: onSettings)
                Button("종료") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // 작은 화면에서도 잘리지 않게 쓸 수 있는 높이의 80%까지만
        .frame(width: 640, height: min(600, (NSScreen.main?.visibleFrame.height ?? 800) * 0.8))
        .onAppear { searchFocused = true }
    }
}

private struct NoteCard: View {
    @ObservedObject var document: NoteDocument
    let color: NoteColor
    let isOpen: Bool
    let agent: AgentKind?

    static let previewLines = 9

    /// 카드 미리보기: 첫 줄(제목) 다음부터, 댓글·코드 펜스는 빼고, 체크박스는 ☐/☑
    static func preview(_ text: String) -> [String] {
        var lines: [String] = []
        var inFence = false
        for raw in text.split(separator: "\n").dropFirst() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence || line.isEmpty || line.hasPrefix("- ↳") { continue }
            var shown = line
            if let match = line.wholeMatch(of: /[-*+] \[(.)\] (.*)/) {
                shown = (match.1 == "x" || match.1 == "X" ? "☑ " : "☐ ") + match.2
            } else if line.hasPrefix("#") {
                shown = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") {
                shown = "• " + line.dropFirst(2)
            }
            lines.append(MarkdownPlain.text(shown))
            if lines.count == previewLines { break }
        }
        return lines
    }

    static let maxPreviewLines = 8

    /// 엇갈림 배치용 높이 추정: 카드 폭에 한 줄 약 16자로 보고 줄바꿈 수를 셈
    static func estimatedHeight(_ document: NoteDocument) -> CGFloat {
        let wrapped = preview(document.text).reduce(0) { $0 + max(1, Int((Double($1.count) / 16).rounded(.up))) }
        let titleLines = document.title.count > 14 ? 2 : 1
        return CGFloat(min(wrapped, maxPreviewLines)) * 18 + CGFloat(titleLines) * 18 + 46
    }

    /// 미리보기를 한 덩어리 글로: 줄마다 자르지 않고, 전체가 넘칠 때만 끝에 "…"
    private func previewText(_ lines: [String]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var part = AttributedString(line + (index < lines.count - 1 ? "\n" : ""))
            if line.hasPrefix("☑") {
                part.strikethroughStyle = .single
                part.foregroundColor = .black.opacity(0.4)
            } else {
                part.foregroundColor = .black.opacity(0.72)
            }
            result += part
        }
        return result
    }

    private var openTodos: Int {
        Todo.parse(document.text, docPath: document.relativePath).filter { $0.state != .done }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text(document.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let agent {
                    AgentBadge(kind: agent, size: 16)
                }
            }
            let lines = Self.preview(document.text)
            if !lines.isEmpty {
                Text(previewText(lines))
                    .font(.system(size: 12))
                    .lineSpacing(3)
                    .lineLimit(Self.maxPreviewLines)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if openTodos > 0 {
                    Label("\(openTodos)", systemImage: "checklist").labelStyle(.titleAndIcon)
                }
                Spacer(minLength: 0)
                if let modified = document.diskModified {
                    Text(modified, format: .relative(presentation: .named))
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.black.opacity(0.45))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: color.nsColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isOpen ? Color.accentColor.opacity(0.7) : Color.black.opacity(0.08), lineWidth: isOpen ? 1.5 : 0.5)
        )
        .environment(\.colorScheme, .light)
        .contentShape(Rectangle())
        .help(isOpen ? "화면에 떠 있는 메모" : "누르면 열기")
    }
}
