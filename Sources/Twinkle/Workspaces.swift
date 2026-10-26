import AppKit
import SwiftUI

/// 자주 쓰는 작업 폴더 즐겨찾기. 메모 폴더와 상관없이 앱 전체에서 공유
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var paths: [String] {
        didSet { if persists { UserDefaults.standard.set(paths, forKey: "workspaces") } }
    }
    private let persists: Bool

    init() {
        paths = UserDefaults.standard.stringArray(forKey: "workspaces") ?? []
        persists = true
    }

    /// 테스트 미리보기용: 저장하지 않는 즐겨찾기
    init(previewPaths: [String]) {
        paths = previewPaths
        persists = false
    }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !paths.contains(path) else { return }
        paths.append(path)
    }

    func remove(_ path: String) {
        paths.removeAll { $0 == path }
    }

    func chooseAndAdd() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "추가"
        panel.message = "자주 쓰는 작업 폴더를 고르세요"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(add)
    }

    /// 메모에 넣을 때의 모양: 홈은 ~로 줄이고 백틱으로 감쌈
    static func snippet(for path: String) -> String {
        "`\((path as NSString).abbreviatingWithTildeInPath)`"
    }
}

/// 메모 안의 경로 찾기. 에이전트 작업 폴더를 정할 때 씀
enum PathMentions {
    nonisolated(unsafe) private static let backticked = /`([^`\n]+)`/
    nonisolated(unsafe) private static let bare = /(?:^|\s)(~?\/[^\s`]+)/

    /// 줄 안에서 실제로 존재하는 첫 경로를 폴더로 (파일이면 그 폴더)
    static func directory(in line: Substring) -> URL? {
        let candidates = line.matches(of: backticked).map { String($0.1) } + line.matches(of: bare).map { String($0.1) }
        for candidate in candidates where candidate.hasPrefix("/") || candidate.hasPrefix("~/") {
            let path = (candidate as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            let url = URL(fileURLWithPath: path)
            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
        }
        return nil
    }

    /// todo 줄 → 위로 올라가며 같은 섹션의 줄들 → 그 섹션 제목 순으로 가장 가까운 경로
    static func workdir(forTodoAt line: Int, in text: String) -> URL? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var index = line
        while index >= 0, lines.indices.contains(index) {
            if let url = directory(in: lines[index]) { return url }
            if lines[index].hasPrefix("#") { break }
            index -= 1
        }
        return nil
    }
}

/// 작업 폴더 트리에서 지금 보이는 한 줄
struct WorkspaceRow: Identifiable, Equatable {
    let url: URL
    let depth: Int
    let isRoot: Bool
    let isDirectory: Bool
    /// 펼쳤는데 내용이 없는 폴더 자리 표시
    var isEmptyMarker = false

    var id: String { isEmptyMarker ? url.path + "/\u{0}empty" : url.path }
    var path: String { url.path }
    var name: String { isRoot ? (url.path as NSString).abbreviatingWithTildeInPath : url.lastPathComponent }
}

/// 펼침 상태와 선택을 한 곳에서 관리해서 키보드로 다룰 수 있게 함
@MainActor
final class WorkspaceTree: ObservableObject {
    @Published var expanded: Set<String> = []
    @Published var selection: String?
    private var childrenCache: [String: [(URL, Bool)]] = [:]

    func rows(for roots: [String]) -> [WorkspaceRow] {
        var rows: [WorkspaceRow] = []
        func append(_ url: URL, depth: Int, isRoot: Bool, isDirectory: Bool) {
            rows.append(WorkspaceRow(url: url, depth: depth, isRoot: isRoot, isDirectory: isDirectory))
            guard isDirectory, expanded.contains(url.path) else { return }
            let children = children(of: url)
            if children.isEmpty {
                rows.append(WorkspaceRow(url: url, depth: depth + 1, isRoot: false, isDirectory: false, isEmptyMarker: true))
            }
            for (child, childIsDirectory) in children {
                append(child, depth: depth + 1, isRoot: false, isDirectory: childIsDirectory)
            }
        }
        for root in roots {
            append(URL(fileURLWithPath: root), depth: 0, isRoot: true, isDirectory: true)
        }
        return rows
    }

    /// 숨김 파일은 빼고, 폴더 먼저 이름순. 너무 큰 폴더는 앞쪽만
    private func children(of url: URL) -> [(URL, Bool)] {
        if let cached = childrenCache[url.path] { return cached }
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )) ?? []
        let children = items
            .map { ($0, (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
            .sorted { $0.1 != $1.1 ? $0.1 : $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending }
        let limited = Array(children.prefix(300))
        childrenCache[url.path] = limited
        return limited
    }

    func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
            // 접은 폴더 안에 선택이 있었으면 그 폴더로
            if let selection, selection.hasPrefix(path + "/") { self.selection = path }
        } else {
            childrenCache[path] = nil  // 펼칠 때마다 새로 읽음
            expanded.insert(path)
        }
    }
}

/// 메모 헤더의 📁 버튼으로 여는 팝업: 즐겨찾기 폴더 트리. 마우스와 키보드 모두로 탐색하고
/// 끌어다 놓거나 ⏎로 메모에 경로를 넣음
struct WorkspaceBrowser: View {
    @ObservedObject var store: WorkspaceStore
    var onInsert: (String) -> Void
    /// 테스트 미리보기용: 처음부터 펼쳐 둘 폴더
    var initiallyExpanded: [String] = []

    @StateObject private var tree = WorkspaceTree()
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var typeahead = ""
    @State private var typeaheadTime = Date.distantPast

    private static let rowHeight: CGFloat = 24

    var body: some View {
        let rows = tree.rows(for: store.paths)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("작업 폴더").font(.headline)
                Spacer()
                Button {
                    store.chooseAndAdd()
                } label: {
                    Label("경로 추가", systemImage: "plus")
                }
                .controlSize(.small)
            }
            .padding(12)
            Divider()

            if store.paths.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus").font(.largeTitle).foregroundStyle(.secondary)
                    Text("자주 쓰는 폴더를 추가해 두면\n여기서 펼쳐 보고 메모로 끌어다 놓을 수 있어요")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(30)
            } else {
                list(rows)
            }

            Divider()
            Text("↑↓ 이동 · → ← 펼치기/접기 · ⏎ 메모에 넣기 · ⌘C 경로 복사 · 끌어서 놓아도 돼요")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 380)
        .onAppear {
            if tree.selection == nil { tree.selection = store.paths.first }
            initiallyExpanded.forEach { tree.toggle($0) }
            focused = true
        }
    }

    /// 보이는 줄 수만큼 늘어나다가 화면 높이의 70%에서 멈춤
    private func listHeight(_ count: Int) -> CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return min(max(CGFloat(count) * Self.rowHeight + 12, 140), screen * 0.7)
    }

    private func list(_ rows: [WorkspaceRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        rowView(row)
                            .id(row.id)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(height: listHeight(rows.count))
            .animation(.easeInOut(duration: 0.15), value: rows.count)
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                handle(press, rows: rows)
            }
            .onChange(of: tree.selection) { _, selection in
                guard let selection else { return }
                withAnimation(.easeInOut(duration: 0.1)) { proxy.scrollTo(selection) }
            }
        }
    }

    @ViewBuilder
    private func rowView(_ row: WorkspaceRow) -> some View {
        if row.isEmptyMarker {
            Text("비어 있음")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, CGFloat(row.depth) * 14 + 32)
                .frame(height: Self.rowHeight)
        } else {
            let selected = tree.selection == row.path
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(selected && focused ? .white : .secondary)
                    .rotationEffect(.degrees(tree.expanded.contains(row.path) ? 90 : 0))
                    .opacity(row.isDirectory ? 1 : 0)
                    .frame(width: 14, height: Self.rowHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { if row.isDirectory { tree.toggle(row.path) } }
                Image(nsImage: NSWorkspace.shared.icon(forFile: row.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(row.name)
                    .font(.system(size: 12, weight: row.isRoot ? .semibold : .regular))
                    .foregroundStyle(selected && focused ? .white : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(row.depth) * 14 + 6)
            .padding(.trailing, 8)
            .frame(height: Self.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? (focused ? Color.accentColor : Color.gray.opacity(0.2)) : .clear)
                    .padding(.horizontal, 6)
            )
            .contentShape(Rectangle())
            // 더블클릭: 폴더는 펼치기/접기, 파일은 메모에 넣기
            .onTapGesture(count: 2) {
                tree.selection = row.path
                if row.isDirectory { tree.toggle(row.path) } else { insert(row) }
            }
            .onTapGesture {
                tree.selection = row.path
                focused = true
            }
            .onDrag { NSItemProvider(object: WorkspaceStore.snippet(for: row.path) as NSString) }
            .contextMenu {
                Button("메모에 경로 넣기") { insert(row) }
                Button("경로 복사") { copy(row) }
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([row.url]) }
                if row.isRoot {
                    Divider()
                    Button("즐겨찾기에서 빼기", role: .destructive) { store.remove(row.path) }
                }
            }
        }
    }

    // MARK: 키보드

    private func handle(_ press: KeyPress, rows: [WorkspaceRow]) -> KeyPress.Result {
        let selectable = rows.filter { !$0.isEmptyMarker }
        let index = selectable.firstIndex { $0.path == tree.selection }
        let current = index.map { selectable[$0] }

        switch press.key {
        case .downArrow:
            tree.selection = selectable[min((index ?? -1) + 1, selectable.count - 1)].path
        case .upArrow:
            tree.selection = selectable[max((index ?? 1) - 1, 0)].path
        case .rightArrow:
            guard let current, current.isDirectory else { return .handled }
            if !tree.expanded.contains(current.path) {
                tree.toggle(current.path)
            } else if let index, index + 1 < selectable.count, selectable[index + 1].depth > current.depth {
                tree.selection = selectable[index + 1].path
            }
        case .leftArrow:
            guard let current else { return .handled }
            if current.isDirectory, tree.expanded.contains(current.path) {
                tree.toggle(current.path)
            } else if !current.isRoot {
                tree.selection = current.url.deletingLastPathComponent().path
            }
        case .space:
            if let current, current.isDirectory { tree.toggle(current.path) }
        case .return:
            if let current { insert(current) }
        case .delete where press.modifiers.contains(.command):
            if let current, current.isRoot {
                store.remove(current.path)
                tree.selection = store.paths.first
            }
        default:
            if press.modifiers.contains(.command) {
                if press.characters == "c", let current { copy(current) }
                return press.characters == "c" ? .handled : .ignored
            }
            return typeahead(press.characters, rows: selectable)
        }
        return .handled
    }

    /// 글자를 치면 그 이름으로 시작하는 다음 항목으로 (1초 안에 이어 치면 이어 붙여 찾음)
    private func typeahead(_ characters: String, rows: [WorkspaceRow]) -> KeyPress.Result {
        guard !characters.isEmpty, characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return .ignored }
        let now = Date()
        typeahead = now.timeIntervalSince(typeaheadTime) < 1 ? typeahead + characters : characters
        typeaheadTime = now
        let start = rows.firstIndex { $0.path == tree.selection } ?? 0
        let ordered = rows[start...] + rows[..<start]
        // 이어 치는 중이면 지금 항목부터, 새로 치면 다음 항목부터
        let candidates = typeahead.count > 1 ? Array(ordered) : Array(ordered.dropFirst()) + ordered.prefix(1)
        if let match = candidates.first(where: { Self.matches($0.url.lastPathComponent, typed: typeahead) }) {
            tree.selection = match.path
        }
        return .handled
    }

    /// 한글 자판 상태에서 친 글자도 찾게: 영문 자판 글자로 바꿔 보거나(ㄴ → s), 한글 이름은 초성으로(ㄷ → 디자인)
    private static func matches(_ name: String, typed: String) -> Bool {
        let name = name.lowercased(), typed = typed.lowercased()
        if name.hasPrefix(typed) { return true }
        let latin = KoreanKeyboard.latin(typed)
        if latin != typed, name.hasPrefix(latin) { return true }
        return choseong(of: name).hasPrefix(typed)
    }

    private static let initials: [Character] = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")

    /// 완성형 한글 음절은 초성으로, 나머지는 그대로
    private static func choseong(of text: String) -> String {
        String(text.map { character -> Character in
            guard let scalar = character.unicodeScalars.first, (0xAC00...0xD7A3).contains(scalar.value) else { return character }
            return initials[Int((scalar.value - 0xAC00) / 588)]
        })
    }

    private func insert(_ row: WorkspaceRow) {
        dismiss()
        onInsert(WorkspaceStore.snippet(for: row.path))
    }

    private func copy(_ row: WorkspaceRow) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(row.path, forType: .string)
    }
}
