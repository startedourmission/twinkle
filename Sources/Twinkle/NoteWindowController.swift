import AppKit
import Combine
import SwiftUI

@MainActor
final class NoteWindowController: NSWindowController, NSWindowDelegate {
    let note: NoteDocument
    let appearance: NoteAppearance
    var onLayoutChange: (@MainActor () -> Void)?
    var onOpenLink: (@MainActor (String) -> Void)?
    var onNew: (@MainActor () -> Void)?
    var onShowTodos: (@MainActor () -> Void)?
    var onShowCanvas: (@MainActor () -> Void)?
    var onClose: (@MainActor (NoteWindowController) -> Void)?
    private var cancellables: Set<AnyCancellable> = []
    private weak var textView: NSTextView?
    private let runner: AgentRunner
    private var threadPopover: NSPopover?
    private var deactivationObserver: NSObjectProtocol?

    var state: WindowState {
        WindowState(frame: window?.frame ?? .zero, color: appearance.color, level: appearance.level)
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
            onNew: { [weak self] in self?.onNew?() },
            onShowTodos: { [weak self] in self?.onShowTodos?() },
            onShowCanvas: { [weak self] in self?.onShowCanvas?() },
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
        applyLevel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func toggleLevel() {
        appearance.level = appearance.level == .desktop ? .floating : .desktop
        applyLevel()
    }

    private func applyLevel() {
        guard let window else { return }
        switch appearance.level {
        case .desktop:
            // 바탕화면 아이콘 바로 위: 일반 창들보다 아래에 깔리고 Mission Control에도 고정
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        case .floating:
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
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
    private func openThread(todoLine: Int, at rect: NSRect) {
        guard let textView, let library = note.library,
              let todo = Todo.parse(note.text, docPath: note.relativePath).first(where: { $0.line == todoLine })
        else { return }
        threadPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ThreadView(document: note, runner: runner, library: library, todoBody: todo.body))
        NSApp.activate()
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
        threadPopover = popover
    }

    // MARK: 로고가 날아갈 위치

    /// todo 줄 높이의 메모 오른쪽 가장자리. 스크롤로 안 보이는 줄이면 보이는 영역 위/아래 끝에 붙음
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
        return LogoAnchor(point: CGPoint(x: window.frame.maxX - 6, y: y), level: window.level)
    }

    /// 쉬는 자리: 메모 위쪽 바깥에 나란히. 화면 위가 모자라면 아래쪽으로
    func idleAnchor(index: Int) -> LogoAnchor? {
        guard let window, window.isVisible else { return nil }
        let frame = window.frame
        let x = frame.maxX - 26 - CGFloat(index) * 46
        let screenTop = (window.screen ?? NSScreen.main)?.visibleFrame.maxY ?? .greatestFiniteMagnitude
        let y = frame.maxY + 50 < screenTop ? frame.maxY + 22 : frame.minY - 22
        return LogoAnchor(point: CGPoint(x: x, y: y), level: window.level)
    }

    private func closeNote() {
        note.save()
        window?.close()
        onClose?(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard appearance.level == .desktop, let window else { return }
        window.level = .normal
        window.orderFrontRegardless()
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
