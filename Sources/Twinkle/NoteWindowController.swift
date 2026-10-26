import AppKit
import Combine
import SwiftUI

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate {
    let note: NoteDocument
    let appearance: NoteAppearance
    var onLayoutChange: (@MainActor () -> Void)?
    var onOpenLink: (@MainActor (String) -> Void)?
    /// 다른 메모의 할 일로 이동 (앱이 그 메모를 열고 reveal을 부름)
    var onOpenTodo: (@MainActor (Todo) -> Void)?
    var onNew: (@MainActor () -> Void)?
    var onClose: (@MainActor (NoteWindowController) -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private weak var textView: NSTextView?
    private let runner: AgentRunner
    private var threadPopover: BubblePanel?
    private var deactivationObserver: NSObjectProtocol?

    var state: WindowState {
        WindowState(
            frame: window?.frame ?? .zero,
            color: appearance.color,
            level: appearance.level,
            folded: note.foldedHeadings.isEmpty ? nil : note.foldedHeadings.sorted()
        )
    }

    init(document: NoteDocument, state: WindowState, runner: AgentRunner, workspaces: WorkspaceStore) {
        self.note = document
        self.runner = runner
        appearance = NoteAppearance(color: state.color, level: state.level)

        let window = NSWindow(
            contentRect: state.frame,
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 180, height: 120)
        // 메모지는 밝은 색이라 다크 모드에서도 글자를 검정으로 유지
        window.appearance = NSAppearance(named: .aqua)

        super.init(window: window)

        let hosting = NSHostingView(rootView: NoteView(
            document: document,
            appearance: appearance,
            runner: runner,
            workspaces: workspaces,
            onOpenLink: { [weak self] in self?.onOpenLink?($0) },
            onTextViewReady: { [weak self] in self?.textView = $0 },
            onOpenThread: { [weak self] in self?.openThread(todoLine: $0, at: $1) },
            onInsertText: { [weak self] in self?.insertAtCursor($0) },
            onOpenTodo: { [weak self] todo in
                guard let self else { return }
                if todo.docPath == self.note.relativePath { self.reveal(todoBody: todo.body) } else { self.onOpenTodo?(todo) }
            },
            onNew: { [weak self] in self?.onNew?() },
            onToggleLevel: { [weak self] in self?.toggleLevel() },
            onClose: { [weak self] in self?.closeNote() }
        ))
        // SwiftUI 콘텐츠 크기가 창 크기를 바꾸지 않도록
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setFrame(state.frame, display: false)
        window.delegate = self

        // 바탕화면 메모도 클릭하면 맨 앞으로, 다른 앱으로 넘어가면 다시 바탕화면으로
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyLevel() }
        }

        appearance.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.onLayoutChange?() }
            .store(in: &cancellables)
        if let folded = state.folded { document.foldedHeadings = Set(folded) }
        document.$foldedHeadings
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onLayoutChange?() }
            .store(in: &cancellables)
        applyLevel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func toggleLevel() {
        appearance.level = appearance.level == .desktop ? .floating : .desktop
        applyLevel()
    }

    static let desktopLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)

    /// 바탕화면 메모를 다시 바탕 층으로 (클릭해서 앞으로 올렸던 것을 내릴 때)
    func sendToBackIfDesktop() {
        guard appearance.level == .desktop else { return }
        window?.level = Self.desktopLevel
    }

    /// 클릭하면 맨 앞으로: 바탕 메모도 잠시 보통 층으로 올림 (다른 앱으로 넘어가면 applyLevel이 다시 내림)
    func windowDidBecomeKey(_ notification: Notification) {
        guard appearance.level == .desktop, let window else { return }
        window.level = .normal
        window.orderFrontRegardless()
    }

    private func applyLevel() {
        guard let window else { return }
        switch appearance.level {
        case .desktop:
            // 보통 창 바로 아래 층: 모든 앱 창 뒤, 바탕화면 아이콘 위에 깔림.
            // 바탕화면 아이콘 층과 달리 관리 대상 창이라 Mission Control에서 고를 수 있게
            // (비활성 앱의 orderBack은 최근 macOS에서 다른 앱 창 뒤로 못 가서 층으로 해결)
            window.level = Self.desktopLevel
            window.collectionBehavior = [.canJoinAllSpaces, .managed, .participatesInCycle]
        case .floating:
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .managed, .participatesInCycle, .fullScreenAuxiliary]
        }
    }

    /// 작업 폴더 팝업의 "메모에 경로 넣기": 커서 자리에 넣음
    private func insertAtCursor(_ text: String) {
        guard let textView else { return }
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    // MARK: 댓글 스레드

    /// 접힌 댓글을 클릭하면 스레드 전체와 답글 입력창을 팝오버로
    /// 테스트용: 본문에 needle이 든 할 일의 접힌 댓글을 클릭한 것처럼 스레드 열기
    func debugOpenThread(containing needle: String) {
        guard let textView else { return }
        let text = textView.string
        guard let todo = Todo.parse(text, docPath: note.relativePath).first(where: { $0.body.contains(needle) }),
              let last = Todo.thread(in: text, todoLine: todo.line).last
        else { return }
        let string = text as NSString
        var start = 0
        for _ in 0..<last.line { start = NSMaxRange(string.lineRange(for: NSRange(location: start, length: 0))) }
        textView.scrollRangeToVisible(NSRange(location: start, length: 0))
        let rect = textView.firstRect(forCharacterRange: NSRange(location: start + 8, length: 1), actualRange: nil)
        openThread(todoLine: todo.line, at: rect)
    }

    /// rect: 클릭한 댓글 글자의 화면 위치. 그 아래에 말풍선 (자리가 없으면 위)
    private func openThread(todoLine: Int, at rect: NSRect) {
        guard let library = note.library,
              let todo = Todo.parse(note.text, docPath: note.relativePath).first(where: { $0.line == todoLine })
        else { return }
        threadPopover?.close()
        let panel = BubblePanel(
            content: ThreadView(document: note, runner: runner, library: library, todoBody: todo.body),
            anchor: rect,
            gap: 4,
            preferAbove: false,
            onClose: { [weak self] in self?.threadPopover = nil }
        )
        threadPopover = panel
        panel.present()
    }

    // MARK: 로고가 날아갈 위치

    /// todo 줄 높이의 메모 오른쪽 바깥. 스크롤로 안 보이는 줄이면 보이는 영역 위/아래 끝에 붙음
    func anchor(forTodoBody body: String) -> LogoAnchor? {
        guard let window, window.isVisible, let textView, let scrollView = textView.enclosingScrollView,
              let line = Todo.lineIndex(in: textView.string, body: body)
        else { return nil }

        let string = textView.string as NSString
        var location = 0
        var current = 0
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, range, _, stop in
            if current == line {
                location = range.location
                stop.pointee = true
            }
            current += 1
        }
        let lineRect = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        let visible = window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil))
        let y = min(max(lineRect.midY, visible.minY + 14), visible.maxY - 14)
        // 로고 반지름(18) + 여유만큼 메모 바깥에 붙여 글자를 가리지 않게.
        // 오른쪽이 화면 끝이면 왼쪽 바깥으로
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        let right = window.frame.maxX + 26
        let x = right + 26 <= screen.maxX ? right : window.frame.minX - 26
        return LogoAnchor(point: CGPoint(x: x, y: y), parent: window)
    }

    /// 쉬는 자리: 메모 위쪽 바깥에 나란히. 화면 위가 모자라면 아래쪽으로
    func idleAnchor(index: Int) -> LogoAnchor? {
        guard let window, window.isVisible else { return nil }
        let frame = window.frame
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
        // 세 로고가 화면 안에 들어오게 가로로 밀어 넣음
        let x = min(max(frame.maxX - 26 - CGFloat(index) * 46, screen.minX + 30 + CGFloat(2 - index) * 46), screen.maxX - 30 - CGFloat(index) * 46)
        let y = frame.maxY + 50 < screen.maxY ? frame.maxY + 22 : frame.minY - 22
        return LogoAnchor(point: CGPoint(x: x, y: y), parent: window)
    }

    func closeNote() {
        note.save()
        window?.close()
        onClose?(self)
    }

    /// 할 일 위치로: 접힌 제목 안이면 펼치고, 할 일 글자 앞에 커서, 스크롤, 찾기 표시로 강조
    func reveal(todoBody body: String) {
        guard let line = Todo.lineIndex(in: note.text, body: body) else { return }
        // 이 줄을 감싸는 제목들 중 접힌 것은 펼침 (맨 윗줄 제목은 접지 않으니 제외)
        let lines = note.text.split(separator: "\n", omittingEmptySubsequences: false)
        var enclosing: [(level: Int, key: String)] = []
        for index in 1..<max(line, 1) where index < lines.count {
            guard let match = lines[index].wholeMatch(of: /^(#{1,6})\s+(.*)$/) else { continue }
            let level = match.1.count
            enclosing.removeAll { $0.level >= level }
            enclosing.append((level, MarkdownStyler.headingKey(level: level, title: String(match.2))))
        }
        for heading in enclosing where note.foldedHeadings.contains(heading.key) {
            note.foldedHeadings.remove(heading.key)
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // 펼친 결과가 그려진 뒤에 위치를 잡음
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let textView = self.textView else { return }
                let string = textView.string as NSString
                var start = 0
                for _ in 0..<line { start = NSMaxRange(string.lineRange(for: NSRange(location: start, length: 0))) }
                let lineRange = string.lineRange(for: NSRange(location: min(start, string.length), length: 0))
                let text = string.substring(with: lineRange)
                let offset = text.firstMatch(of: #/^\s*[-*+] \[.\] /#).map { $0.0.utf16.count } ?? 0
                let caret = NSRange(location: lineRange.location + offset, length: 0)
                self.window?.makeFirstResponder(textView)
                textView.setSelectedRange(caret)
                textView.scrollRangeToVisible(caret)
                var highlight = lineRange
                if highlight.length > 0, string.character(at: NSMaxRange(highlight) - 1) == 10 { highlight.length -= 1 }
                textView.showFindIndicator(for: NSRange(location: caret.location, length: max(NSMaxRange(highlight) - caret.location, 0)))
            }
        }
    }

    /// 편집기에 포커스를 주고 커서를 문서 끝에
    func focusEditor() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let textView = self.textView else { return }
                self.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
            }
        }
    }

    /// 새 메모: 제목 글자를 선택해 두어 바로 고쳐 쓰게
    func selectTitle() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let textView = self.textView, let range = self.note.titleRange else { return }
                self.window?.makeFirstResponder(textView)
                textView.setSelectedRange(range)
            }
        }
    }

    func windowDidMove(_ notification: Notification) { onLayoutChange?() }
    func windowDidResize(_ notification: Notification) { onLayoutChange?() }
}
