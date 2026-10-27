import Combine
import Foundation
import TwinkleShared
import WidgetKit

/// 할 일이 바뀌면 위젯용 목록(widget.json)을 다시 쓰고 위젯을 새로 그리게 함.
/// 위젯은 샌드박스 안이라 메모 폴더를 직접 못 읽음
@MainActor
final class WidgetExporter {
    private var cancellable: AnyCancellable?
    private var last: WidgetSnapshot?

    init(library: NoteLibrary) {
        cancellable = library.$todos
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self, weak library] _ in
                MainActor.assumeIsolated {
                    guard let self, let library else { return }
                    self.export(library)
                }
            }
    }

    private func export(_ library: NoteLibrary) {
        let snapshot = WidgetSnapshot(
            todos: TaskQuery.parse("not done\nsort by due").run(in: library).flatMap(\.items).prefix(100).map(Self.item),
            dated: TaskQuery.parse("has due date\nsort by due").run(in: library).flatMap(\.items).prefix(500).map(Self.item)
        )
        // 할 일 목록이 같으면 위젯을 깨우지 않음
        guard snapshot != last else { return }
        do {
            try snapshot.write()
            last = snapshot
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            NSLog("위젯 목록 저장 실패: \(error)")
        }
    }

    private static func item(_ item: TaskItem) -> WidgetSnapshot.Item {
        var title = item.displayTitle
        // 에이전트는 로고로 보여 주니 태그 글자는 뺌
        if let agent = item.todo.agent {
            title = title.replacingOccurrences(of: agent.tag, with: "")
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        }
        return WidgetSnapshot.Item(
            title: title,
            state: item.todo.state.rawValue,
            due: item.due,
            agent: item.todo.agent?.rawValue,
            noteTitle: item.noteTitle,
            path: item.todo.docPath,
            line: item.todo.line
        )
    }
}
