import AppKit
import SwiftUI

/// 자주 쓰는 작업 폴더 즐겨찾기. 메모 폴더와 상관없이 앱 전체에서 공유
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published private(set) var paths: [String] = UserDefaults.standard.stringArray(forKey: "workspaces") ?? [] {
        didSet { UserDefaults.standard.set(paths, forKey: "workspaces") }
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

/// 메모 헤더의 📁 버튼으로 여는 팝업: 즐겨찾기 폴더 트리, 끌어서 메모에 경로 넣기
struct WorkspaceBrowser: View {
    @ObservedObject var store: WorkspaceStore
    var onInsert: (String) -> Void

    var body: some View {
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
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(store.paths, id: \.self) { path in
                            FileTreeRow(url: URL(fileURLWithPath: path), depth: 0, isRoot: true, store: store, onInsert: onInsert)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 420)
            }

            Divider()
            Text("끌어서 메모에 놓으면 경로가 들어가요. todo 줄이나 그 위 제목에 경로가 있으면 에이전트가 그 폴더에서 작업합니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .frame(width: 340)
    }
}

private struct FileTreeRow: View {
    let url: URL
    let depth: Int
    let isRoot: Bool
    @ObservedObject var store: WorkspaceStore
    var onInsert: (String) -> Void

    @State private var isExpanded = false
    @State private var children: [URL]?

    private var isDirectory: Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .opacity(isDirectory ? 1 : 0)
                    .frame(width: 12)
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(isRoot ? (url.path as NSString).abbreviatingWithTildeInPath : url.lastPathComponent)
                    .font(.system(size: 12, weight: isRoot ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14 + 8)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture { toggle() }
            .onDrag { NSItemProvider(object: WorkspaceStore.snippet(for: url.path) as NSString) }
            .contextMenu {
                Button("메모에 경로 넣기") { onInsert(WorkspaceStore.snippet(for: url.path)) }
                Button("경로 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
                Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if isRoot {
                    Divider()
                    Button("즐겨찾기에서 빼기", role: .destructive) { store.remove(url.path) }
                }
            }

            if isExpanded, let children {
                ForEach(children, id: \.self) { child in
                    FileTreeRow(url: child, depth: depth + 1, isRoot: false, store: store, onInsert: onInsert)
                }
                if children.isEmpty {
                    Text("비어 있음")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, CGFloat(depth + 1) * 14 + 32)
                        .padding(.vertical, 2)
                }
            }
        }
    }

    private func toggle() {
        guard isDirectory else { return }
        if children == nil {
            // 숨김 파일은 빼고, 폴더 먼저 이름순. 너무 큰 폴더는 앞쪽만
            let items = (try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )) ?? []
            children = items
                .map { ($0, (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false) }
                .sorted { $0.1 != $1.1 ? $0.1 : $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending }
                .prefix(300)
                .map(\.0)
        }
        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
    }
}
